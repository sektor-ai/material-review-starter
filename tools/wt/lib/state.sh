#!/usr/bin/env bash
# Slot allocation and env.json persistence for `wt`.
#
# One state directory per environment lives under $WT_STATE_ROOT/<slug>/, holding env.json (the
# record below), the rendered app.env, the rendered process-compose file, the process-compose Unix
# socket, built binaries and per-process logs. Nothing is written into the worktree, so a worktree can
# never accidentally commit generated state.

# ── slots and ports ───────────────────────────────────────────────────────────────────────────────
#
# A slot is taken either by a finished environment (its env.json records it) or by a `wt create` still
# building one (it holds a reservation, below). Both count: allocate_slot must not hand out a slot that
# a create in flight has already claimed but not yet written.
#
# The lock and the reservations live at the root of the state directory. Both names start with a dot,
# so the "$WT_STATE_ROOT"/*/env.json glob that enumerates environments cannot see them.
readonly SLOT_LOCK_DIR="$WT_STATE_ROOT/.slot.lock"
readonly SLOT_RESERVE_DIR="$WT_STATE_ROOT/.slots"

# How long a create waits for the slot lock before giving up, as a poll interval and a cap on polls.
# The lock is only ever held across the sub-second allocate-and-reserve, so waiting at all means
# another create is in exactly that window; ten seconds is far more than it can need.
readonly SLOT_LOCK_POLL_SECONDS=0.2
readonly SLOT_LOCK_MAX_POLLS=50

# owner_alive reports whether the process that wrote the given file is still running. It is how both the
# lock and the reservations detect an owner that died without cleaning up (SIGKILL, a closed terminal).
# The pid is the first field — a reservation records the slug after it — and a missing or empty file
# means the owner is mid-write, which counts as alive rather than dead, so neither a lock nor a slot is
# ever stolen from a create that is still being born.
owner_alive() {
	local file=$1 owner
	[[ -f $file ]] || return 0
	owner=$(cat "$file" 2>/dev/null)
	owner=${owner%% *}
	[[ -n $owner ]] || return 0
	kill -0 "$owner" 2>/dev/null
}

# ── the slot lock ─────────────────────────────────────────────────────────────────────────────────
#
# allocate_slot only *reads* state, and the slot does not become the new environment's until it is on
# disk. Two concurrent `wt create`s would otherwise both scan before either had written, both pick the
# same lowest free slot, and collide on every port. This mutex serialises allocate-and-reserve, so only
# one create is ever between the scan and the write.
#
# mkdir is the lock: it is atomic on POSIX filesystems, so exactly one racer's mkdir succeeds. flock
# would be the obvious tool, but macOS — bash 3.2, which this tool targets — does not ship it.

# slot_lock_acquire blocks until it holds the lock, reclaiming one whose owning process is gone (a
# crashed create must not wedge every future one), and dying with a clear message if it cannot get it.
slot_lock_acquire() {
	local polls=0
	mkdir -p "$WT_STATE_ROOT"
	while ! mkdir "$SLOT_LOCK_DIR" 2>/dev/null; do
		owner_alive "$SLOT_LOCK_DIR/owner" || {
			warn 'reclaiming a stale slot lock (its owner is gone)'
			slot_lock_release
			continue
		}
		((polls < SLOT_LOCK_MAX_POLLS)) ||
			die "timed out waiting for the slot lock held by $(cat "$SLOT_LOCK_DIR/owner" 2>/dev/null); another 'wt create' is allocating (if not, remove ${SLOT_LOCK_DIR})"
		sleep "$SLOT_LOCK_POLL_SECONDS"
		polls=$((polls + 1))
	done
	printf '%s\n' "$$" >"$SLOT_LOCK_DIR/owner"
}

# slot_lock_release drops the lock. Idempotent, so it is safe to call from a trap that fires on a path
# which already released.
slot_lock_release() { rm -rf "$SLOT_LOCK_DIR"; }

# ── slot reservations ─────────────────────────────────────────────────────────────────────────────
#
# The lock alone is not enough: it can only be held for the allocation itself, because env.json cannot
# be written until the database exists — git and database work later. A reservation bridges that gap.
# It names the slot, records the creating process, and counts as "in use" for allocate_slot until
# state_write takes over. It is dropped when the create exits, however it exits.

slot_reservation_file() { printf '%s/%s\n' "$SLOT_RESERVE_DIR" "$1"; }

# slot_reserved reports whether a live create holds the given slot. A reservation whose owner is gone
# is stale: it is deleted and the slot treated as free, so a hard-killed create cannot burn a slot.
slot_reserved() {
	local slot=$1 file
	file=$(slot_reservation_file "$slot")
	[[ -f $file ]] || return 1
	owner_alive "$file" && return 0
	rm -f "$file"
	return 1
}

# slot_reserve claims a slot for this process. Callers must hold the slot lock: the check-then-claim in
# allocate_slot + slot_reserve is only atomic against other creates while the lock is held.
slot_reserve() {
	local slot=$1 slug=$2
	mkdir -p "$SLOT_RESERVE_DIR"
	printf '%s %s\n' "$$" "$slug" >"$(slot_reservation_file "$slot")"
}

# slot_release drops this process's reservation. Once env.json records the slot, the reservation is
# redundant; if the create failed before that, dropping it returns the slot to the pool.
slot_release() { rm -f "$(slot_reservation_file "$1")"; }

# slot_reserve_next prints the lowest free slot, reserved for this process, serialised against every
# other create by the slot lock. The reservation stands until the caller releases it — see
# wt_create_cleanup, which does so on every exit path.
slot_reserve_next() {
	local slug=$1 slot
	slot_lock_acquire
	slot=$(allocate_slot) || {
		slot_lock_release
		return 1
	}
	slot_reserve "$slot" "$slug"
	slot_lock_release
	printf '%s\n' "$slot"
}

# slot_in_use reports whether any recorded environment holds the given slot, or a create in flight has
# reserved it.
slot_in_use() {
	local slot=$1 file
	slot_reserved "$slot" && return 0
	for file in "$WT_STATE_ROOT"/*/env.json; do
		[[ -f $file ]] || continue
		[[ $(jq -r '.slot' "$file") == "$slot" ]] && return 0
	done
	return 1
}

# allocate_slot prints the lowest free slot in [1, MAX_SLOT]. Slots are reclaimed on `wt rm`, so the
# numbers stay small and the ports stay memorable. Call it through slot_reserve_next: on its own it
# only reads, and two concurrent readers get the same answer.
allocate_slot() {
	local slot
	for ((slot = PRIMARY_SLOT + 1; slot <= MAX_SLOT; slot++)); do
		slot_in_use "$slot" || {
			printf '%s\n' "$slot"
			return 0
		}
	done
	die "all ${MAX_SLOT} worktree slots are in use (free one with: wt rm <slug>)"
}

port_api() { printf '%s\n' "$((API_BASE + $1 * PORT_STRIDE))"; }
port_web() { printf '%s\n' "$((WEB_BASE + $1 * PORT_STRIDE))"; }

# ── status: where an environment's branch currently lives ─────────────────────────────────────────
#
# An environment is normally `worktree`: its branch is checked out in its own <primary>-<slug> sibling
# directory. `wt promote` moves that branch into the primary checkout, where the human's editor is
# pointed, and marks the environment `promoted` — git allows a branch in exactly one worktree at a
# time, so the directory has to go. Everything else the environment owns (slot, ports, database,
# bucket, rendered config, built binaries) survives, which is what makes `wt demote` cheap.
readonly STATUS_WORKTREE='worktree'
readonly STATUS_PROMOTED='promoted'

# ── env.json ──────────────────────────────────────────────────────────────────────────────────────

# state_write records a new environment. The database connection string is deliberately NOT stored
# here — it lives only in the rendered app.env, so there is exactly one copy of the credential on disk.
state_write() {
	local slug=$1 path=$2 branch=$3 slot=$4 database=$5 bucket=$6
	local dir
	dir=$(state_dir "$slug")
	mkdir -p "$dir/logs" "$dir/bin"
	chmod 700 "$dir"

	jq -n \
		--arg slug "$slug" \
		--arg path "$path" \
		--arg branch "$branch" \
		--argjson slot "$slot" \
		--argjson api "$(port_api "$slot")" \
		--argjson web "$(port_web "$slot")" \
		--arg database "$database" \
		--arg bucket "$bucket" \
		--arg status "$STATUS_WORKTREE" \
		--arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{
			slug: $slug, path: $path, branch: $branch, slot: $slot,
			ports: {api: $api, web: $web},
			resources: {database: $database, bucket: $bucket},
			pr: {state: null, number: null, url: null, checked_at: null},
			status: $status, promoted: null,
			session: {id: null, name: null, cwd: null, seen_at: null},
			created_at: $created_at
		}' >"$(state_file "$slug")"
}

state_get() { jq -r "$2" "$(state_file "$1")"; }

# state_set applies a jq assignment expression to an environment's record, in place. Trailing
# arguments are passed to jq ahead of the expression, so a value carrying quotes, backslashes or a
# newline goes in as `--arg name value` rather than being interpolated into the expression text.
state_set() {
	local slug=$1 expr=$2
	shift 2
	local file tmp
	file=$(state_file "$slug")
	tmp=$(mktemp)
	jq "$@" "$expr" "$file" >"$tmp" && mv "$tmp" "$file"
}

# state_status prints where an environment's branch lives, defaulting to a plain worktree.
state_status() { state_get "$1" ".status // \"$STATUS_WORKTREE\""; }

is_promoted() { [[ $(state_status "$1") == "$STATUS_PROMOTED" ]]; }

# promoted_slug prints the slug of the environment currently promoted into the primary checkout, if
# any. At most one can be: the primary holds one branch. Prints nothing and fails when none is.
promoted_slug() {
	local slug
	while IFS= read -r slug; do
		is_promoted "$slug" && {
			printf '%s\n' "$slug"
			return 0
		}
	done < <(state_slugs)
	return 1
}

# ── the agent session that last touched an environment ────────────────────────────────────────────
#
# Long-lived worktrees outlive the session that built them, and picking one back up means restarting
# the *right* session rather than a fresh, ignorant one. Matching by hand on a hopefully-meaningful
# session name is a weak link, so the environment records the session against itself.
#
# A live Claude Code session describes itself in $CLAUDE_SESSIONS_DIR/<pid>.json — session id, display
# name (what `claude -n` or `/rename` set, else an auto-derived one) and working directory — and
# exports CLAUDE_PID into every command it runs. That pid is the whole link between a shell command and
# the session that asked for it.
readonly CLAUDE_SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"

# session_identity prints `id<TAB>name<TAB>cwd` for the session running this command, and fails when
# there is none — a plain shell, which is not an error, just nothing to record.
#
# The pid file is preferred over CLAUDE_CODE_SESSION_ID because it is the only source of the *name*,
# and because it names the top-level interactive session rather than whichever nested context happens
# to be running the command. The env var is the fallback for when the file is absent (a headless run,
# or a CLI version that does not write one): an id with no name still resumes.
session_identity() {
	local file id='' name='' cwd=''
	file="$CLAUDE_SESSIONS_DIR/${CLAUDE_PID:-nopid}.json"
	[[ -f $file ]] && {
		id=$(jq -r '.sessionId // ""' "$file" 2>/dev/null)
		name=$(jq -r '.name // ""' "$file" 2>/dev/null)
		cwd=$(jq -r '.cwd // ""' "$file" 2>/dev/null)
	}
	[[ -n $id ]] || id=${CLAUDE_CODE_SESSION_ID:-}
	[[ -n $id ]] || return 1
	printf '%s\t%s\t%s\n' "$id" "$name" "$cwd"
}

# state_record_session stamps the calling session onto an environment, latest wins. Re-stamping on
# every touch is deliberate rather than recording once at create: a session is usually renamed (or
# auto-titled) well after it starts, so a create-time snapshot would preserve the throwaway derived
# name and never the meaningful one.
#
# Silent on every failure path. This runs on the way into ordinary commands, and no bookkeeping of
# ours is worth failing `wt up` over.
state_record_session() {
	local slug=$1 line id name cwd rest
	[[ -f $(state_file "$slug") ]] || return 0
	line=$(session_identity) || return 0

	id=${line%%$'\t'*}
	rest=${line#*$'\t'}
	name=${rest%%$'\t'*}
	cwd=${rest#*$'\t'}

	state_set "$slug" '.session = {id: $id, name: $name, cwd: $cwd, seen_at: $seen}' \
		--arg id "$id" --arg name "$name" --arg cwd "$cwd" \
		--arg seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
}

session_id() { state_get "$1" '.session.id // ""'; }
session_name() { state_get "$1" '.session.name // ""'; }
session_cwd() { state_get "$1" '.session.cwd // ""'; }

# state_slugs prints every recorded environment slug, one per line.
state_slugs() {
	local file
	for file in "$WT_STATE_ROOT"/*/env.json; do
		[[ -f $file ]] || continue
		jq -r '.slug' "$file"
	done
}

# read_slugs fills the global WT_SLUGS array with every recorded slug. macOS ships bash 3.2, which
# has no `mapfile`, and `set -u` rejects expanding an empty array, so callers must check WT_SLUGS_N
# before iterating.
read_slugs() {
	WT_SLUGS=()
	local slug
	while IFS= read -r slug; do
		WT_SLUGS+=("$slug")
	done < <(state_slugs)
	WT_SLUGS_N=${#WT_SLUGS[@]}
}

state_remove() { rm -rf "$(state_dir "$1")"; }

# state_resolve prints the slug of the environment an identifier names, accepting either the slug
# itself or the environment's branch. Branches are unique across environments, so the mapping back is
# unambiguous. A slug match is taken first: were an identifier both one environment's slug and
# another's branch, the slug is what the tool has always meant by it, and that must not change under
# anyone. Prints nothing and fails when the identifier names no environment.
state_resolve() {
	local ident=$1 file slug
	[[ -n $ident ]] || return 1
	[[ -f $(state_file "$ident") ]] && {
		printf '%s\n' "$ident"
		return 0
	}
	for file in "$WT_STATE_ROOT"/*/env.json; do
		[[ -f $file ]] || continue
		slug=$(jq -r --arg branch "$ident" 'select(.branch == $branch) | .slug' "$file")
		[[ -n $slug ]] && {
			printf '%s\n' "$slug"
			return 0
		}
	done
	return 1
}

# ── pull request state ────────────────────────────────────────────────────────────────────────────

# pr_sync refreshes an environment's cached pull request record — state, number and URL, which one
# `gh pr view` returns together — unless the cache is still within PR_STATE_TTL_SECONDS, so that
# `wt list` does not hammer the API. Pass a non-empty second argument to refresh regardless.
#
# The PR is identified by number once one has been seen, not by branch name. `gc` and `merge` act on
# its state, and a branch name can be reused: a new environment on `feature/x` must not be reaped
# because an older `feature/x` PR was merged. Until a number is recorded the branch is looked up, and
# a non-open PR created before this environment existed is ignored as belonging to an earlier use of
# the name. An open PR is always this branch's current one, which keeps `--adopt` of a branch with
# an existing PR working.
pr_sync() {
	local slug=$1 force=${2:-} cached checked_at now branch recorded pr state number url
	cached=$(state_get "$slug" '.pr.state // ""')
	checked_at=$(state_get "$slug" '.pr.checked_at // 0')
	now=$(date +%s)

	if [[ -z $force && -n $cached ]] && ((now - checked_at < PR_STATE_TTL_SECONDS)); then
		return 0
	fi

	branch=$(state_get "$slug" '.branch')
	recorded=$(state_get "$slug" '.pr.number // ""')
	# `gh` exits non-zero when no PR exists for the branch; that is a normal state, not an error. An
	# environment without a PR keeps a null number and URL, which is what `wt list` reads as "no link".
	if [[ -n $recorded ]]; then
		pr=$(gh pr view "$recorded" --json state,number,url,createdAt 2>/dev/null) || pr=''
	else
		pr=$(gh pr view "$branch" --json state,number,url,createdAt 2>/dev/null) || pr=''
		pr_predates_env "$slug" "$pr" && pr=''
	fi
	if [[ -n $pr ]]; then
		state=$(printf '%s' "$pr" | jq -r '.state')
		number=$(printf '%s' "$pr" | jq -r '.number')
		url=$(printf '%s' "$pr" | jq -r '.url')
	else
		state=$PR_STATE_NONE
		number=null
		url=''
	fi
	[[ -n $state ]] || state=$PR_STATE_NONE

	state_set "$slug" '.pr.state = $state | .pr.number = $number | .pr.url = $url | .pr.checked_at = $now' \
		--arg state "$state" --argjson number "$number" --arg url "$url" --argjson now "$now"
}

# pr_predates_env reports whether a looked-up PR is a stale one from an earlier use of the branch name:
# not open, and created before the environment. Both timestamps are UTC ISO-8601 (`...Z`), so they
# compare correctly as strings.
pr_predates_env() {
	local slug=$1 pr=$2 pr_state created env_created
	[[ -n $pr ]] || return 1
	pr_state=$(printf '%s' "$pr" | jq -r '.state')
	[[ $pr_state != OPEN ]] || return 1
	created=$(printf '%s' "$pr" | jq -r '.createdAt // ""')
	env_created=$(state_get "$slug" '.created_at // ""')
	[[ -n $created && -n $env_created && $created < $env_created ]]
}

# pr_state prints the GitHub PR state for an environment's branch (OPEN, MERGED, CLOSED or NONE).
pr_state() {
	pr_sync "$1" "${2:-}"
	state_get "$1" '.pr.state'
}

# pr_number and pr_url print the cached number and URL of an environment's pull request, empty when it
# has none. They read what pr_sync last cached rather than calling `gh` again, so a `wt list` row costs
# one API call, not three.
pr_number() { state_get "$1" '.pr.number // ""'; }
pr_url() { state_get "$1" '.pr.url // ""'; }
