#!/usr/bin/env bash
#
# wt — manage per-worktree local environments.
#
# One environment = one git worktree + its own Postgres database and MinIO bucket + a local API and
# web dev server, all on ports derived from the environment's slot. Environments are created together,
# updated on commit, listed, and destroyed together when their pull request merges.
#
#   wt create <slug> [--type T] [--from R]  worktree + database + config, then deps, migrate, seed
#                                     branch = <type>/<slug> (type: feature|bugfix|refactor|docs|…)
#   wt create <slug> --adopt <branch> same, but on an existing local branch, taken as it is
#   wt up <slug>                      start api and web (detached); waits until the API serves
#   wt down <slug>                    stop them
#   wt restart <slug> [process]       restart one process (default: api)
#   wt rebase <slug>...               rebase each branch onto origin/main, push, restart; in order,
#                                     stopping at the first conflict
#   wt list|ls [--refresh]            show every environment, its URLs and its PR (state, number, link)
#   wt url <slug> [service]           print service URLs (api|web); bare URL if service given
#   wt path [slug]                    print a worktree's directory; the primary checkout if no slug
#   wt cd [slug]                      cd there (needs the shellrc function; `make wt cd` cannot work)
#   wt logs <slug> [process]          tail a process log
#   wt rm <slug> [--force]            stop, drop database and bucket, remove worktree
#   wt merge <slug> [--no-advance]    merge the PR (or accept one already merged from the web), prune the
#            [--keep-branch]          remote branch, advance main, then reap the env and delete the
#                                     local branch — merge + gc in one step
#   wt promote <slug>                 hand the branch to the primary checkout to work on by hand; the
#                                     environment (db, slot, ports, config) is kept, not destroyed
#   wt demote [slug]                  the return leg: take the branch back and rebuild its worktree.
#                                     Bare, it acts on whatever the primary is on, adopting a branch
#                                     that has no environment yet
#   wt resume <slug>                  restart the agent session that last worked on the environment
#   wt recreate-config <slug>         re-render app.env and process-compose.yml (after a template or
#                                     .env change)
#   wt reset-db <slug>                drop and recreate the environment's database and bucket, then
#                                     migrate and seed — discards the environment's data
#   wt gc [--dry-run]                 rm every environment whose PR is merged or closed
#   wt doctor                         check prerequisites
#   wt install-hooks                  install hooks: post-commit restarts the API, post-merge runs gc
#   wt uninstall-hooks                remove them, restoring any hooks they displaced
#
# Every <slug> above also takes the environment's branch — `wt up feature/foo` is `wt up foo`. Branches
# are unique across environments, so the two name the same thing. Only `wt create` is a slug and nothing
# else: it names an environment that does not exist yet.
#
# `rebase` is the only command that takes a list. The destructive single-environment commands (merge, rm,
# reset-db, promote, demote, resume, and create) refuse a second environment rather than batching it or
# letting the last one win — see require_one_env in lib/common.sh for why.
#
# Requires bash 3.2 (what macOS ships), git, jq, envsubst, gh, process-compose, pnpm, go, curl and nc,
# plus the docker-compose Postgres and MinIO running (make setup). See tools/wt/CLAUDE.md.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# Optional local settings (WT_BASE_REF, MR_WT_HOME).
readonly WT_ENV_FILE="${MR_WT_ENV_FILE:-$HOME/.material-review/wt.env}"

# MR_WT_HOME set in the environment is a deliberate, per-invocation override — it is how a test points
# the tool at a throwaway state directory. wt.env assigns it plainly, so sourcing the file would
# otherwise clobber the override with the user's own state root and the "test" would scribble on real
# environments. The environment wins: remember it across the source, and put it back afterwards.
readonly WT_HOME_OVERRIDE="${MR_WT_HOME:-}"
# shellcheck disable=SC1090
[[ -f $WT_ENV_FILE ]] && source "$WT_ENV_FILE"
[[ -n $WT_HOME_OVERRIDE ]] && MR_WT_HOME="$WT_HOME_OVERRIDE"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/resources.sh
source "$SCRIPT_DIR/lib/resources.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

readonly MANAGED_PROCESSES=(api web)

# How long `wt up` waits for the API to answer on its port before giving up.
readonly API_READY_TIMEOUT_SECONDS=180

# Lines of history shown by `wt logs`, both when following and when reading a stopped environment's
# log file. process-compose otherwise replays the entire log before following.
readonly LOG_TAIL_LINES=200

# Lines of the api log inlined when `wt up` detects the API crashed on boot — enough to show the
# fatal error without dumping the whole build.
readonly CRASH_LOG_PREVIEW_LINES=25

# `wt up` confirms the API actually serves (not just listens) by requesting this endpoint and
# expecting a 2xx. /healthz pings the database, so a 2xx means the API booted against its own DB.
readonly API_HEALTH_PATH='/healthz'
readonly API_HEALTH_TIMEOUT_SECONDS=10
readonly API_HEALTH_ATTEMPTS=5

# The git hooks we install. post-commit restarts the committing worktree's API; post-merge reaps
# environments whose PR has merged. An existing hook of either name is moved aside to <hook>.pre-wt
# and chain-called.
readonly WT_HOOKS=(post-commit post-merge)
readonly HOOK_CHAINED_SUFFIX='.pre-wt'

# Distinct exit code for `wt rebase` stopping on a merge conflict, so that case is tellable apart from
# any other failure (die's exit 1): a caller or an agent keys its escalation off it rather than scraping
# the message.
readonly WT_EXIT_REBASE_CONFLICT=3

# `wt cd` is not implemented here: only a shell can change its own directory, so a child process cannot
# do it on the shell's behalf. The `wt` function in tools/wt/shellrc intercepts the verb and cds itself,
# using `wt path` for the destination. Reaching this dispatcher therefore means wt.sh was invoked
# directly or through make, where the command cannot work — which is worth saying plainly, since "unknown
# command" would contradict the help text that lists it.
readonly CD_NEEDS_SHELL_FN_MSG='`wt cd` only works through the shell function: source tools/wt/shellrc from your profile. A script cannot change your shell directory. Otherwise: cd "$(wt path <slug>)"'

# `wt list` column headers. They double as the minimum width of their column, so they are named rather
# than spelled inline at both the sizing and printing sites.
readonly LIST_HDR_SLUG='SLUG' LIST_HDR_BRANCH='BRANCH' LIST_HDR_STATE='STATE'
readonly LIST_HDR_PR='PR' LIST_HDR_API='API' LIST_HDR_URLS='URLS'
readonly LIST_HDR_SESSION='SESSION'

# Placeholder for a column with nothing to show, so an empty cell cannot be mistaken for a misaligned
# row.
readonly LIST_EMPTY_CELL='-'

# Widest session name `wt list` prints to a terminal before eliding the middle. Piped output is never
# truncated — a pipe has no width to run out of, and `wt list | grep <session>` has to be able to match
# the whole name.
readonly LIST_SESSION_MAX_WIDTH=24

# ── process-compose plumbing ──────────────────────────────────────────────────────────────────────

# pc runs process-compose against one environment's Unix socket. The default is a TCP port (8080),
# which several environments would fight over, so -U is mandatory rather than a nicety.
pc() {
	local slug=$1
	shift
	(cd "$(state_dir "$slug")" && process-compose "$@" --use-uds --unix-socket "$PC_SOCKET_NAME")
}

env_running() {
	local slug=$1
	[[ -S $(socket_path "$slug") ]] || return 1
	pc "$slug" process list >/dev/null 2>&1
}

# api_running reports whether the api process is currently alive (building or serving). Used by
# `wt up` to fail fast when the API crashes on boot instead of waiting out the full port timeout.
api_running() {
	local slug=$1 running
	running=$(pc "$slug" process list -o json 2>/dev/null |
		jq -r '.[] | select(.name == "api") | .is_running' 2>/dev/null)
	[[ $running == 'true' ]]
}

# api_healthy reports whether the API serves a 2xx on its health endpoint — a stronger signal than a
# merely open port, catching a server that listens but cannot reach its database.
api_healthy() {
	local slug=$1 api status i
	api=$(state_get "$slug" '.ports.api')
	for ((i = 0; i < API_HEALTH_ATTEMPTS; i++)); do
		status=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$API_HEALTH_TIMEOUT_SECONDS" \
			"http://127.0.0.1:${api}${API_HEALTH_PATH}" 2>/dev/null)
		[[ $status == 2* ]] && return 0
		sleep 1
	done
	return 1
}

# service_url prints the localhost URL for one service (api|web) of an environment.
service_url() {
	local slug=$1 service=$2 port
	case $service in
	api) port=$(state_get "$slug" '.ports.api') ;;
	web) port=$(state_get "$slug" '.ports.web') ;;
	*) die "unknown service '${service}' (one of: ${MANAGED_PROCESSES[*]})" ;;
	esac
	printf 'http://localhost:%s\n' "$port"
}

# require_worktree dies when an environment is promoted, for the commands that need its directory to
# exist — starting a server, re-rendering config for it, restarting a process that builds from it.
# Promoting takes that directory away, so these would otherwise fail deep inside git, pnpm or
# process-compose with an error about a missing path and no hint of the actual cause.
require_worktree() {
	local slug=$1 verb=$2
	is_promoted "$slug" &&
		die "'${slug}' is promoted — its branch is checked out in $(primary_root) and it has no worktree to ${verb}; bring it back first: wt demote ${slug}"
	return 0
}

validate_process() {
	local process=$1 known
	for known in "${MANAGED_PROCESSES[@]}"; do
		[[ $process == "$known" ]] && return 0
	done
	die "unknown process '${process}' (one of: ${MANAGED_PROCESSES[*]})"
}

# ── commands ──────────────────────────────────────────────────────────────────────────────────────

cmd_doctor() {
	local ok=0

	printf 'tools\n'
	local tool
	for tool in git jq envsubst gh process-compose pnpm go curl nc docker; do
		if have "$tool"; then
			printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$tool"
		else
			printf '  %s✗%s %s — not on PATH\n' "$C_RED" "$C_RESET" "$tool"
			ok=1
		fi
	done

	printf '\nconfiguration\n'
	local src
	src=$(source_env_file)
	if [[ -f $src ]]; then
		printf '  %s✓%s %s (every environment is derived from it)\n' "$C_GREEN" "$C_RESET" "$src"
		if have go && devenv check >/dev/null 2>&1; then
			printf '  %s✓%s local Postgres and MinIO reachable\n' "$C_GREEN" "$C_RESET"
		else
			printf '  %s✗%s local Postgres or MinIO not reachable — run: make setup\n' "$C_RED" "$C_RESET"
			ok=1
		fi
	else
		printf '  %s✗%s %s missing — cp .env.example .env in the primary checkout\n' "$C_RED" "$C_RESET" "$src"
		ok=1
	fi

	if have gh && gh auth status >/dev/null 2>&1; then
		printf '  %s✓%s gh authenticated\n' "$C_GREEN" "$C_RESET"
	else
		printf '  %s✗%s gh not authenticated — run: gh auth login\n' "$C_RED" "$C_RESET"
		ok=1
	fi

	local name
	for name in "${WT_HOOKS[@]}"; do
		if hook_is_ours "$name"; then
			printf '  %s✓%s %s hook installed\n' "$C_GREEN" "$C_RESET" "$name"
		else
			printf '  %s!%s %s hook not installed — run: wt install-hooks\n' "$C_YELLOW" "$C_RESET" "$name"
		fi
	done

	printf '\ndisk\n'
	local free
	free=$(free_mib "$(primary_root)")
	if ((free >= MIN_FREE_MIB)); then
		printf '  %s✓%s %s MiB free\n' "$C_GREEN" "$C_RESET" "$free"
	else
		printf '  %s✗%s only %s MiB free, need %s — reclaim space before creating a worktree\n' \
			"$C_RED" "$C_RESET" "$free" "$MIN_FREE_MIB"
		ok=1
	fi

	return $ok
}

# adopt_require_branch checks that a branch named by `wt create --adopt` can actually be taken over,
# before the create reserves a slot or creates a database on the strength of it.
#
# The branch must already exist locally. A branch that is only on origin is not adopted implicitly: the
# point of adopting is to fold in work that is already on this machine, and silently materialising a
# local branch from a remote of the same name is a different, guessier operation — so say what to run
# instead. It must also not be checked out anywhere already, git allowing a branch in exactly one
# worktree at a time; git would refuse this itself a few steps later, but only after the slot had been
# taken, and it would not mention `wt promote`.
adopt_require_branch() {
	local branch=$1 root
	root=$(primary_root)

	if ! git -C "$root" show-ref --verify --quiet "refs/heads/${branch}"; then
		git -C "$root" show-ref --verify --quiet "refs/remotes/origin/${branch}" &&
			die "no local branch '${branch}' (it exists on origin — check it out first: git -C ${root} branch ${branch} origin/${branch})"
		die "no branch named '${branch}' to adopt (try: git -C ${root} branch --list)"
	fi

	local checked_out
	checked_out=$(git -C "$root" for-each-ref --format='%(worktreepath)' "refs/heads/${branch}")
	[[ -z $checked_out ]] ||
		die "'${branch}' is already checked out at ${checked_out}; a branch lives in one worktree at a time"
}

# The slot this create reserved, if it got that far. Global because wt_create_cleanup, running from a
# trap, has to see it.
WT_RESERVED_SLOT=''

# wt_create_cleanup releases the slot lock and this create's reservation on every exit path: a clean
# finish, a die(), or the database rollback. A leaked lock stalls the next create for ten seconds
# before it is reclaimed; a leaked reservation costs a slot. Neither is fatal — both are self-healing
# once the owning process is gone — but leaving them behind for the next run to clean up is sloppy.
wt_create_cleanup() {
	slot_lock_release
	[[ -n $WT_RESERVED_SLOT ]] && slot_release "$WT_RESERVED_SLOT"
	return 0
}

cmd_create() {
	local slug='' base_ref="$DEFAULT_GIT_BASE_REF" branch_type="$WT_DEFAULT_BRANCH_TYPE"
	local adopt_branch='' from_given='' type_given='' slugs_seen=0
	while (($# > 0)); do
		case $1 in
		--from)
			base_ref=$2
			from_given=1
			shift 2
			;;
		--type)
			branch_type=$2
			type_given=1
			shift 2
			;;
		--adopt)
			adopt_branch=$2
			shift 2
			;;
		-*) die "unknown flag for create: $1" ;;
		*)
			# Same rule as require_one_env, worded for the one command whose positional names an
			# environment that does not exist yet rather than one that does.
			((slugs_seen == 0)) ||
				die "create takes one slug, got '${slug}' and '${1}'; create them one at a time"
			slug=$1
			slugs_seen=1
			shift
			;;
		esac
	done

	validate_slug "$slug"
	require_tools git jq envsubst process-compose pnpm go

	# --adopt takes an existing branch verbatim, so the flags that shape a *new* branch name have nothing
	# to act on. Rejecting them beats ignoring them: silently dropping a --type the caller bothered to
	# type would leave them believing the branch was renamed to match.
	local branch
	if [[ -n $adopt_branch ]]; then
		[[ -z $type_given ]] || die '--type does not apply with --adopt: the adopted branch keeps its own name'
		[[ -z $from_given ]] || die '--from does not apply with --adopt: the adopted branch keeps its own history'
		adopt_require_branch "$adopt_branch"
		branch=$adopt_branch
	else
		validate_branch_type "$branch_type"
		branch="${branch_type}/${slug}"
	fi

	local path
	path=$(worktree_path "$slug")
	[[ -e $path ]] && die "${path} already exists"
	[[ -f $(state_file "$slug") ]] && die "environment '${slug}' already exists (wt rm ${slug} first)"
	[[ -f $(source_env_file) ]] ||
		die "missing $(source_env_file) — copy .env.example to .env in the primary checkout first"

	local free
	free=$(free_mib "$(primary_root)")
	((free >= MIN_FREE_MIB)) ||
		die "only ${free} MiB free on the worktree volume, need ${MIN_FREE_MIB} MiB — reclaim space first"

	# Take the lowest free slot and reserve it, under the slot lock, so a create running in another
	# terminal cannot pick the same one while this environment is still being built.
	trap wt_create_cleanup EXIT
	local slot
	slot=$(slot_reserve_next "$slug")
	WT_RESERVED_SLOT=$slot

	git -C "$(primary_root)" fetch --quiet origin
	if [[ -n $adopt_branch ]]; then
		log "creating worktree ${path} on existing ${branch} (slot ${slot})"
		git -C "$(primary_root)" worktree add "$path" "$branch"
	else
		log "creating worktree ${path} on ${branch} (slot ${slot})"
		git -C "$(primary_root)" worktree add -b "$branch" "$path" "$base_ref"
	fi

	log "creating the environment database"
	local names
	# Roll the worktree back if the database cannot be created, rather than leaving a half-built
	# environment behind. Only delete the branch when this create is what brought it into existence: an
	# adopted branch predates us and carries the work being folded in, so rolling back must hand it back
	# intact, not destroy it.
	if ! names=$(resources_create "$slug"); then
		git -C "$(primary_root)" worktree remove --force "$path"
		[[ -n $adopt_branch ]] || git -C "$(primary_root)" branch -D "$branch"
		die "database creation failed (is Postgres up? make setup); worktree rolled back"
	fi

	state_write "$slug" "$path" "$branch" "$slot" \
		"$(dotenv_value "$names" DATABASE_NAME)" "$(dotenv_value "$names" S3_BUCKET)"

	log 'rendering app.env and process-compose.yml'
	render_config_files "$slug" "$names"

	env_install_deps "$slug" "$path" "wt rm ${slug}"
	resources_seed "$slug"

	# create is the one command that resolves no existing environment, so it is the one that has to
	# record its session by hand rather than getting it from resolve_env.
	state_record_session "$slug"

	log "environment ${slug} ready"
	cmd_list
	dim "start it with: wt up ${slug}"
}

# env_install_deps populates a freshly materialised worktree: the TS workspace install and an API build
# to the exact directory process-compose will exec from, so `wt up` starts from a warm cache rather than
# compiling cold.
#
# The steps run concurrently — they are independent, and in series they dominate the wall clock of
# both commands that need them: `wt create` and `wt demote`, which face the same empty directory for
# the same reason (git materialises tracked files only, and node_modules is not one of them).
#
# The third argument is the recovery command quoted at the caller if a step fails, since what to run
# differs between the two.
env_install_deps() {
	local slug=$1 path=$2 recovery=$3

	log 'installing dependencies and building the API (in parallel)'
	local -a pids=() labels=()
	(cd "$path/ts" && pnpm install --frozen-lockfile --reporter=append-only) &
	pids+=("$!")
	labels+=('ts deps')
	(cd "$path/go" && go build -o "$(state_dir "$slug")/bin/" ./cmd/api ./cmd/migrate) &
	pids+=("$!")
	labels+=('API build')

	local i failed=0
	for i in "${!pids[@]}"; do
		wait "${pids[$i]}" || {
			warn "setup step failed: ${labels[$i]}"
			failed=1
		}
	done
	((failed == 0)) || die "environment setup failed (see warnings); fix and rerun, or ${recovery}"
}

# render_config_files (re-)renders app.env and process-compose.yml for an environment from the current
# template and source .env, then validates the compose file. Shared by `create`, `recreate-config` and
# `reset-db`.
render_config_files() {
	local slug=$1 names=$2
	render_env "$slug" "$names" "$SCRIPT_DIR"
	# Catch a bad render now, rather than at `wt up` when the environment is half-built.
	process-compose --config "$(state_dir "$slug")/process-compose.yml" --disable-dotenv --dry-run >/dev/null ||
		die "the generated process-compose.yml is invalid"
}

# cmd_recreate_config re-renders an existing environment's config from the current template and the
# primary's current .env, without touching its worktree, database or installed dependencies. Use after
# changing the template, or after adding a key to .env that environments should see.
cmd_recreate_config() {
	local slug=$1
	slug=$(resolve_env "$slug")
	require_tools process-compose envsubst go
	require_worktree "$slug" 'render config for'

	log "re-rendering config for ${slug}"
	local names
	names=$(resources_names "$slug")
	render_config_files "$slug" "$names"

	log 'config regenerated'
	env_running "$slug" && dim "restart to apply: wt restart ${slug} api"
	return 0
}

# cmd_reset_db replaces an environment's database and bucket with fresh ones, migrated and seeded from
# the worktree's current code, keeping its worktree, branch, slot and ports. It is for when the data has
# drifted from the code — a migration was rewritten on the branch, or test data piled up — and a clean
# start is wanted.
#
# It only touches the data. Bringing the *code* up to date is `wt rebase`; run that first, so the
# migrations applied here are current.
#
# It is destructive by design and says so, but does not prompt: everything in the environment's
# database and bucket is discarded. That is the point of the command.
cmd_reset_db() {
	local ident='' slug='' seen=0
	while (($# > 0)); do
		case $1 in
		-*) die "unknown flag for reset-db: $1" ;;
		*)
			require_one_env reset-db "$seen" "$ident" "$1"
			ident=$1
			seen=1
			shift
			;;
		esac
	done
	slug=$(resolve_env "$ident")
	require_tools go process-compose envsubst curl nc
	require_worktree "$slug" 'reset'

	warn "resetting ${slug}: everything in its database and bucket is discarded"

	# Unlike teardown, a failed drop is fatal here: carrying on would "reset" onto the old database, and
	# report success over data that was never discarded.
	log 'dropping the database and bucket'
	devenv destroy "$slug" >/dev/null ||
		die "could not drop ${slug}'s database or bucket (are Postgres and MinIO up? make setup)"

	log 'creating a fresh database'
	local names
	names=$(resources_create "$slug") ||
		die "database creation failed; ${slug} has no database until this succeeds — rerun: wt reset-db ${slug}"
	render_config_files "$slug" "$names"
	resources_seed "$slug"

	# Wait for the API rather than just kicking it: it re-runs migrations on start, and "reset" over a
	# crashed boot would hide the failure behind the command meant to fix it.
	if env_running "$slug"; then
		log 'restarting the API onto the new database'
		pc "$slug" process restart api
		api_await_ready "$slug" 'it rebuilds and re-runs migrations'
	else
		dim "start it with: wt up ${slug}"
	fi

	log "environment ${slug} reset"
	return 0
}

# api_await_ready blocks until an environment's API is serving, and reports what it found. Shared by
# `up` (waiting on a cold start) and `reset-db` (waiting on a restart onto a brand new database) — for
# both, "done" means the API answers, not that a process was launched. The optional second argument is
# a note appended to the waiting message, explaining why this particular wait might be slow.
api_await_ready() {
	local slug=$1 note=${2:-} api dir
	api=$(state_get "$slug" '.ports.api')
	dir=$(state_dir "$slug")
	log "waiting for the API on :${api}${note:+ (${note})}"

	# Break as soon as any of three things happens: the port opens (success), the api process dies
	# (crash — show the tail rather than waiting out the timeout), or the timeout elapses. `seen_running`
	# latches once the process is confirmed alive, so a not-running read before launch is not mistaken
	# for a crash.
	local waited=0 seen_running=0
	while true; do
		if nc -z 127.0.0.1 "$api" 2>/dev/null; then
			if api_healthy "$slug"; then
				log "API is up and serving on :${api}"
			else
				warn "API :${api} is open but not serving a healthy response — check: wt logs ${slug} api"
			fi
			break
		fi
		if api_running "$slug"; then
			seen_running=1
		elif ((seen_running)); then
			warn "the API exited before opening :${api} — last ${CRASH_LOG_PREVIEW_LINES} log lines:"
			tail -n "$CRASH_LOG_PREVIEW_LINES" "$dir/logs/api.log" >&2 2>/dev/null || true
			warn "full log: wt logs ${slug} api"
			break
		fi
		((waited >= API_READY_TIMEOUT_SECONDS)) && {
			warn "API did not come up within ${API_READY_TIMEOUT_SECONDS}s — check: wt logs ${slug} api"
			break
		}
		sleep 2
		waited=$((waited + 2))
	done
}

cmd_up() {
	local slug=$1
	slug=$(resolve_env "$slug")
	require_tools process-compose curl nc
	require_worktree "$slug" 'start'

	env_running "$slug" && die "environment '${slug}' is already up"

	local dir
	dir=$(state_dir "$slug")
	log "starting ${slug}"
	# --disable-dotenv: process-compose otherwise loads ./.env from the working directory. Every
	# process's environment is set explicitly (ENV_FILE points at the rendered app.env).
	pc "$slug" up \
		--config "$dir/process-compose.yml" \
		--detached --tui=false --disable-dotenv

	api_await_ready "$slug" 'first build can take a minute'

	cmd_list
}

cmd_down() {
	local slug=$1
	slug=$(resolve_env "$slug")
	env_running "$slug" || {
		dim "environment '${slug}' is not running"
		return 0
	}

	log "stopping ${slug}"
	pc "$slug" down
	rm -f "$(socket_path "$slug")"
}

cmd_restart() {
	local slug=$1 process=${2:-api}
	slug=$(resolve_env "$slug")
	validate_process "$process"
	require_worktree "$slug" 'restart'
	env_running "$slug" || die "environment '${slug}' is not running (wt up ${slug})"

	log "restarting ${process} in ${slug}"
	pc "$slug" process restart "$process"
}

# cmd_rebase brings one or more worktree branches up to date after something has merged into main,
# rebasing each in the order given. Every slug is checked to exist before any of them is touched, so a
# typo in the third slug cannot leave the first two rebased and the batch half-done.
#
# A conflict stops the whole run (rebase_one exits): the branches after it are left alone rather than
# rebased past a problem that already needs a decision.
cmd_rebase() {
	(($# > 0)) || die "usage: wt rebase <slug|branch>..."
	require_tools git

	local ident slug
	local -a slugs=()
	for ident in "$@"; do
		slug=$(resolve_env "$ident")
		slugs+=("$slug")
	done

	for slug in "${slugs[@]}"; do
		rebase_one "$slug"
	done
}

# rebase_one rebases a single worktree's branch onto DEFAULT_GIT_BASE_REF: it fetches, rebases,
# force-pushes the rewritten history with --force-with-lease, and — if the environment is up — restarts
# the API so it rebuilds (and migrates) from the rebased code; the web dev server hot-reloads on its own.
rebase_one() {
	local slug=$1 base_ref="$DEFAULT_GIT_BASE_REF"

	local path branch
	path=$(state_get "$slug" '.path')
	branch=$(state_get "$slug" '.branch')

	# A promoted branch is checked out in the primary, so that is the tree to rebase — keeping a branch
	# current matters just as much while it is being worked on by hand.
	is_promoted "$slug" && path=$(primary_root)

	# A rebase rewrites history, and git refuses it over a dirty tree anyway — fail early with a clearer
	# message than git's. Commit or stash first.
	git -C "$path" diff --quiet HEAD 2>/dev/null ||
		die "${path} has uncommitted changes; commit or stash them before rebasing"

	log "fetching origin"
	git -C "$path" fetch --quiet origin

	# Nothing to do if the branch already contains the base: skip the rebase and, more to the point, the
	# force-push, which would otherwise be pure noise on an unchanged branch.
	if git -C "$path" merge-base --is-ancestor "$base_ref" HEAD 2>/dev/null; then
		dim "${branch} already contains ${base_ref}; nothing to rebase"
		return 0
	fi

	log "rebasing ${branch} onto ${base_ref}"
	if ! git -C "$path" rebase "$base_ref"; then
		# Abort so the worktree is left in a clean, known state rather than a half-finished rebase — but
		# make the conflict loud and its exit code distinct. The branch is still behind and un-pushed, and
		# it needs a human decision, not a silent retry.
		git -C "$path" rebase --abort 2>/dev/null || true
		printf '%serror:%s rebase conflict — %s does not rebase cleanly onto %s\n' \
			"$C_RED" "$C_RESET" "$branch" "$base_ref" >&2
		warn "aborted the rebase; ${slug} is back to its previous state and nothing was pushed"
		warn "this needs a decision — leave the branch un-rebased for now, or resolve by hand:"
		warn "  cd ${path} && git rebase ${base_ref}   # then fix conflicts, git rebase --continue, git push --force-with-lease"
		exit "$WT_EXIT_REBASE_CONFLICT"
	fi

	# Force-push the rewritten history, but only when this branch already exists on origin — a branch
	# whose PR has not been pushed has nothing to update. The check is the branch's own remote ref, not
	# its @{upstream}: `wt create` branches from origin/main, which sets the upstream to origin/main from
	# birth, so an @{upstream} test would wrongly fire on a never-pushed branch. --force-with-lease
	# refuses to clobber commits that reached origin since our fetch.
	if git -C "$path" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
		log "force-pushing ${branch}"
		git -C "$path" push --force-with-lease origin "HEAD:${branch}"
	else
		dim "${branch} is not on origin yet; not pushing (push it with /mk-pr or 'git push -u')"
	fi

	if env_running "$slug"; then
		log "restarting the API to rebuild from rebased code"
		pc "$slug" process restart api
	else
		dim "${slug} is not running; its API will build fresh on next wt up"
	fi

	log "rebased ${slug} onto ${base_ref}"
}

cmd_logs() {
	local slug=$1 process=${2:-api}
	slug=$(resolve_env "$slug")
	validate_process "$process"
	env_running "$slug" || {
		# Fall back to the log file so a crashed environment can still be diagnosed.
		local file
		file="$(state_dir "$slug")/logs/${process}.log"
		[[ -f $file ]] || die "no log for ${process} in ${slug}"
		dim "${slug} is not running; showing ${file}"
		tail -n "$LOG_TAIL_LINES" "$file"
		return 0
	}
	pc "$slug" process logs "$process" --follow --tail "$LOG_TAIL_LINES"
}

cmd_list() {
	local refresh=''
	[[ ${1:-} == '--refresh' ]] && refresh='force'

	read_slugs
	((WT_SLUGS_N > 0)) || {
		dim 'no worktree environments (create one with: wt create <slug>)'
		return 0
	}

	# Rows are collected before anything is printed so each padded column can be sized to the widest
	# value actually present. bash 3.2 has no associative arrays, hence one plain array per column.
	local -a col_slug col_branch col_state col_session col_pr col_api col_urls
	local w_slug=${#LIST_HDR_SLUG} w_branch=${#LIST_HDR_BRANCH} w_state=${#LIST_HDR_STATE}
	local w_pr=${#LIST_HDR_PR} w_api=${#LIST_HDR_API} w_session=${#LIST_HDR_SESSION}

	local slug
	for slug in "${WT_SLUGS[@]}"; do
		local branch state session pr number link api api_port web_port urls
		branch=$(state_get "$slug" '.branch')
		api_port=$(state_get "$slug" '.ports.api')
		web_port=$(state_get "$slug" '.ports.web')
		if is_promoted "$slug"; then
			state=$STATUS_PROMOTED
		elif env_running "$slug"; then
			state=up
		else
			state=down
		fi

		session=$(session_name "$slug")
		# Fall back to the id when a session was recorded without a name: it is still what `wt resume`
		# takes, so showing it beats showing nothing.
		[[ -n $session ]] || session=$(session_id "$slug")
		[[ -n $session ]] || session=$LIST_EMPTY_CELL
		# Elided with ASCII dots rather than a `…`: printf pads %-Ns by bytes, so a multibyte marker
		# would make a nominally 24-wide cell 26 bytes long and shift every column after it.
		((WT_TTY_STDOUT)) && ((${#session} > LIST_SESSION_MAX_WIDTH)) &&
			session="${session:0:$((LIST_SESSION_MAX_WIDTH - 2))}.."

		# One pr_state call refreshes the cached record; the number and URL are then read from it.
		if have gh; then
			pr=$(pr_state "$slug" "$refresh")
			number=$(pr_number "$slug")
			link=$(pr_url "$slug")
		else
			pr='?'
			number=''
			link=''
		fi
		[[ -n $number ]] && pr="${pr} #${number}"
		api=":${api_port}"

		# On a terminal the URLs ride along as hyperlinks behind short labels, keeping the row narrow.
		# Piped output keeps the verbatim `name=url` form, so `wt list | grep github.com` still finds the PR.
		if ((WT_TTY_STDOUT)); then
			urls="$(hyperlink "http://localhost:${web_port}" web)"
			[[ -n $link ]] && urls="${urls} $(hyperlink "$link" "pr #${number}")"
		else
			urls="web=http://localhost:${web_port}"
			[[ -n $link ]] && urls="${urls} pr=${link}"
		fi

		col_slug+=("$slug")
		col_branch+=("$branch")
		col_state+=("$state")
		col_session+=("$session")
		col_pr+=("$pr")
		col_api+=("$api")
		col_urls+=("$urls")

		((${#slug} > w_slug)) && w_slug=${#slug}
		((${#branch} > w_branch)) && w_branch=${#branch}
		((${#state} > w_state)) && w_state=${#state}
		((${#session} > w_session)) && w_session=${#session}
		((${#pr} > w_pr)) && w_pr=${#pr}
		((${#api} > w_api)) && w_api=${#api}
	done

	# URLS is last and so is never padded — which is also what keeps the invisible hyperlink escapes in
	# it from being counted as width by printf and skewing the row.
	local fmt="%-${w_slug}s %-${w_branch}s %-${w_state}s %-${w_session}s %-${w_pr}s %-${w_api}s %s\n"
	# shellcheck disable=SC2059
	printf "$fmt" "$LIST_HDR_SLUG" "$LIST_HDR_BRANCH" "$LIST_HDR_STATE" \
		"$LIST_HDR_SESSION" "$LIST_HDR_PR" "$LIST_HDR_API" "$LIST_HDR_URLS"

	local i
	for ((i = 0; i < WT_SLUGS_N; i++)); do
		# shellcheck disable=SC2059
		printf "$fmt" \
			"${col_slug[$i]}" "${col_branch[$i]}" "${col_state[$i]}" "${col_session[$i]}" \
			"${col_pr[$i]}" "${col_api[$i]}" "${col_urls[$i]}"
	done
}

# cmd_path prints an environment's worktree directory, or the primary checkout when given no slug. It is
# what `wt cd` consumes. The slug case reads the path recorded in state, so it needs neither git nor a
# particular working directory; the no-slug case resolves the primary relative to the caller's cwd.
cmd_path() {
	local slug=${1:-}
	[[ -n $slug ]] || {
		primary_root
		return 0
	}

	slug=$(resolve_env "$slug")
	state_get "$slug" '.path'
}

# cmd_url prints service URLs for an environment. With a service argument it prints just that bare URL
# (scriptable, e.g. `open "$(wt url smoke web)"`); without one it prints every service as name<TAB>url.
cmd_url() {
	local slug=$1 service=${2:-}
	slug=$(resolve_env "$slug")

	[[ -n $service ]] && {
		service_url "$slug" "$service"
		return 0
	}

	local s
	for s in "${MANAGED_PROCESSES[@]}"; do
		printf '%s\t%s\n' "$s" "$(service_url "$slug" "$s")"
	done
}

# worktree_remove stops an environment's processes and removes its worktree directory, freeing the
# branch. It is the part of teardown that `promote` shares with `rm`: git allows a branch in exactly
# one worktree at a time, so handing it to the primary means giving up the directory — and only the
# directory. Everything else promote keeps.
worktree_remove() {
	local slug=$1 force=${2:-}

	local path
	path=$(state_get "$slug" '.path')

	env_running "$slug" && cmd_down "$slug"

	log "removing worktree ${path}"
	local remove_args=(worktree remove "$path")
	[[ -n $force ]] && remove_args+=(--force)
	if ! git -C "$(primary_root)" "${remove_args[@]}" 2>/dev/null; then
		# The worktree may already be half-removed — e.g. a manual `git worktree remove --force` that
		# deregistered it from git but left the directory because running processes held files open.
		# cmd_down has since stopped them, so clean the directory up directly and prune git's metadata.
		# Only under --force: without it, git refusing is exactly the signal that there is something
		# in there worth keeping, and a fallback that deletes it would defeat the refusal. The guard
		# keeps rm -rf strictly to a `<primary>-<slug>` sibling, never the primary or root.
		[[ -n $force ]] ||
			die "git could not remove ${path}; look inside, then rerun with --force to delete it regardless"
		warn "git worktree remove failed; cleaning up ${path} directly"
		[[ -n $path && $path == "$(primary_root)${WORKTREE_DIR_SEPARATOR}"* && -e $path ]] && rm -rf "$path"
		git -C "$(primary_root)" worktree prune
	fi
}

# env_teardown dismantles everything an environment owns except its branch and its recorded state: the
# running processes, the database and bucket, and the worktree directory. Only `rm`, `merge` and `gc`
# go this far; `promote` stops at worktree_remove, keeping the data it will want back.
env_teardown() {
	local slug=$1 force=${2:-}

	env_running "$slug" && cmd_down "$slug"

	log "dropping ${slug}'s database and bucket"
	resources_destroy "$slug"

	# A promoted environment has no worktree directory left to remove — promote already gave it up, and
	# its branch is checked out in the primary, which rm must not touch.
	is_promoted "$slug" || worktree_remove "$slug" "$force"
}

cmd_rm() {
	local ident='' slug='' force='' seen=0
	while (($# > 0)); do
		case $1 in
		--force)
			force=1
			shift
			;;
		-*) die "unknown flag for rm: $1" ;;
		*)
			require_one_env rm "$seen" "$ident" "$1"
			ident=$1
			seen=1
			shift
			;;
		esac
	done
	slug=$(resolve_env "$ident")

	local path branch
	path=$(state_get "$slug" '.path')
	branch=$(state_get "$slug" '.branch')

	# A promoted environment's work lives in the primary checkout, so that is where unsaved edits would
	# be — the recorded worktree path is gone, and testing it would report every promoted environment as
	# dirty and refuse to remove any of them. Untracked files count: they die with the worktree too.
	local dirty_at=$path
	is_promoted "$slug" && dirty_at=$(primary_root)
	if [[ -z $force ]] && has_local_work "$dirty_at"; then
		die "${dirty_at} has uncommitted or untracked changes; commit them or pass --force"
	fi

	# Deleting the branch below is `-D`, because a squash-merged branch never looks merged to git.
	# So without --force, refuse while the branch holds commits that exist nowhere else. A promoted
	# environment keeps its branch, so there is nothing to check.
	if [[ -z $force ]] && ! is_promoted "$slug"; then
		local unpushed
		unpushed=$(unpushed_commits "$branch")
		((unpushed == 0)) ||
			die "${branch} has ${unpushed} commit(s) on no remote branch (never pushed, or squash-merged with the branch deleted); push them, or pass --force to delete them"
	fi

	env_teardown "$slug" "$force"

	# Removing a promoted environment gives up the database, the slot and the record — never the branch.
	# It is checked out in the primary, which is where the human is working.
	if is_promoted "$slug"; then
		warn "'${branch}' is checked out in $(primary_root) and is left alone; delete it by hand when you are done with it"
	else
		git -C "$(primary_root)" branch -D "$branch" >/dev/null 2>&1 ||
			warn "local branch '${branch}' not deleted (unmerged?); remove it by hand"
	fi

	state_remove "$slug"
	log "environment ${slug} removed"
}

# ── the promote cycle ─────────────────────────────────────────────────────────────────────────────
#
# `promote` moves a branch from its worktree into the primary checkout, where the human's editor is
# pointed; `demote` moves it back. The pair is a cycle rather than a one-way door because a branch
# routinely needs handing over for a while and then handing back, and switching to another task in
# between must not cost the environment.
#
# So the branch changes hands but the environment does not die. Only the worktree directory goes, and
# only because git allows a branch in exactly one worktree at a time. The slot, ports, database, bucket,
# rendered config and built binaries all stay, so demote is a `git worktree add` plus a dependency
# install — on the same ports, against the same data.

# require_promotable dies unless the primary checkout can safely take (or give back) a branch. The
# primary is someone's editor session: switching what is checked out under unsaved edits loses them,
# so this is the guard both directions share.
require_promotable() {
	local primary=$1 verb=$2
	git -C "$primary" diff --quiet HEAD 2>/dev/null ||
		die "${primary} has uncommitted changes; commit or stash them, then ${verb}"
}

# cmd_promote hands a worktree's branch to the primary checkout, keeping the environment behind it.
cmd_promote() {
	local ident='' slug='' seen=0
	while (($# > 0)); do
		case $1 in
		-*) die "unknown flag for promote: $1" ;;
		*)
			require_one_env promote "$seen" "$ident" "$1"
			ident=$1
			seen=1
			shift
			;;
		esac
	done
	slug=$(resolve_env "$ident")

	local path branch primary
	path=$(state_get "$slug" '.path')
	branch=$(state_get "$slug" '.branch')
	primary=$(primary_root)

	is_promoted "$slug" &&
		die "'${slug}' is already promoted (${primary} holds ${branch}); send it back with: wt demote ${slug}"

	# Only one branch fits in the primary. Refuse only when the primary is actually still holding the
	# other promoted branch; an earlier promoted environment whose branch was since checked out of the
	# primary by hand is recoverable, so merely say so.
	local held other other_branch
	held=$(git -C "$primary" branch --show-current 2>/dev/null) || held=''
	if other=$(promoted_slug); then
		other_branch=$(state_get "$other" '.branch')
		[[ -n $held && $held == "$other_branch" ]] &&
			die "${primary} already holds promoted environment '${other}' (${other_branch}); send it back first: wt demote ${other}"
		warn "'${other}' is still marked promoted but ${primary} is not on ${other_branch}; demote it when you get to it"
	fi

	# Anything not committed dies with the worktree, and there is deliberately no --force that throws it
	# away. This checks untracked files too — `git worktree remove` refuses when it finds them, and
	# worktree_remove's fallback would then delete the directory outright.
	if [[ -d $path ]] && [[ -n $(git -C "$path" status --porcelain 2>/dev/null) ]]; then
		die "${path} has uncommitted or untracked changes; commit them, then promote"
	fi

	require_promotable "$primary" 'promote'

	worktree_remove "$slug"

	# Marked promoted before the checkout, not after: from the moment the directory is gone that is what
	# the environment *is*, and if the checkout below fails the record must already say so — it is what
	# tells `wt demote` there is a worktree to rebuild. `held` is recorded so demote can put the primary
	# back where it found it rather than guess at a default.
	state_set "$slug" '.status = $status | .promoted = {at: $at, primary_prev_branch: $prev}' \
		--arg status "$STATUS_PROMOTED" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg prev "$held"

	log "checking out ${branch} in ${primary}"
	if ! git -C "$primary" checkout "$branch" >/dev/null 2>&1; then
		die "worktree removed, but '${branch}' could not be checked out in ${primary};
     the branch and the environment are both intact — retry by hand with: git -C ${primary} checkout ${branch}
     or rebuild the worktree with: wt demote ${slug}"
	fi

	log "promoted ${slug}: ${primary} is now on ${branch}"
	dim "its database, slot and ports are held; send it back with: wt demote ${slug}"
}

# primary_release_branch moves the primary checkout off whatever it is holding, freeing that branch to
# be taken into a worktree. It returns to `prev` when that names a live local branch, and otherwise
# detaches HEAD — which always works and leaves the human somewhere obvious to choose from, where
# guessing at a branch could silently move them.
primary_release_branch() {
	local primary=$1 prev=$2
	if [[ -n $prev ]] && git -C "$primary" show-ref --verify --quiet "refs/heads/${prev}"; then
		log "returning ${primary} to ${prev}"
		git -C "$primary" checkout "$prev" >/dev/null 2>&1 && return 0
		die "could not return ${primary} to ${prev}; resolve by hand, then rerun"
	fi
	warn "no branch to return ${primary} to; detaching HEAD so the branch is free"
	git -C "$primary" checkout --detach >/dev/null 2>&1 ||
		die "could not free the branch in ${primary}; check something else out by hand, then rerun"
}

# slug_from_branch derives an environment name from a branch — `feature/upload-form` becomes
# `upload-form`. It refuses rather than mangling a name it cannot use: `wt create <slug> --adopt
# <branch>` is right there for the awkward cases.
slug_from_branch() {
	local branch=$1 slug=${branch##*/}
	[[ $slug =~ $SLUG_PATTERN ]] ||
		die "cannot derive an environment name from '${branch}' (lowercase letters, digits and dashes, max 39 chars); name one yourself: wt create <slug> --adopt ${branch}"
	printf '%s\n' "$slug"
}

# demote_current_branch prints the branch a bare `wt demote` should act on: whatever the primary
# checkout is holding. It reads the primary rather than the caller's directory because demote only
# ever moves a branch *out of* the primary.
demote_current_branch() {
	local primary=$1 branch protected
	branch=$(git -C "$primary" branch --show-current 2>/dev/null) || branch=''
	[[ -n $branch ]] ||
		die "${primary} has no branch checked out (detached HEAD); name an environment: wt demote <slug>"

	for protected in "${WT_PROTECTED_BRANCHES[@]}"; do
		[[ $branch == "$protected" ]] &&
			die "${primary} is on '${branch}', an integration branch rather than work to move into a worktree; name an environment: wt demote <slug>"
	done

	printf '%s\n' "$branch"
}

# demote_adopt handles a bare `wt demote` on a branch with no environment at all — work started by
# hand in the primary, or someone else's branch fetched to look at. That is exactly `wt create
# --adopt`, after moving the primary off the branch. Everything checkable is checked before the primary
# is moved, so a name clash fails with the human still standing on their branch.
demote_adopt() {
	local primary=$1 branch=$2 slug
	slug=$(slug_from_branch "$branch")

	[[ -f $(state_file "$slug") ]] &&
		die "'${branch}' has no environment, and the name '${slug}' it would take belongs to one already; pick another: wt create <slug> --adopt ${branch}"
	[[ -e $(worktree_path "$slug") ]] &&
		die "'${branch}' has no environment, and $(worktree_path "$slug") already exists; pick another name: wt create <slug> --adopt ${branch}"

	log "no environment for ${branch}; adopting it into a new one named '${slug}'"
	primary_release_branch "$primary" "$PRIMARY_DEFAULT_BRANCH"
	cmd_create "$slug" --adopt "$branch"
}

# cmd_demote is the return leg: it takes the branch back out of the primary checkout and rebuilds the
# environment's worktree around it, on the same path, slot, ports and database it had before. With no
# argument it acts on whatever the primary is holding, and falls through to `create --adopt` when that
# branch has no environment yet.
cmd_demote() {
	local ident='' slug='' seen=0
	while (($# > 0)); do
		case $1 in
		-*) die "unknown flag for demote: $1" ;;
		*)
			require_one_env demote "$seen" "$ident" "$1"
			ident=$1
			seen=1
			shift
			;;
		esac
	done
	require_tools git jq pnpm go

	if [[ -z $ident ]]; then
		local primary current
		primary=$(primary_root)
		current=$(demote_current_branch "$primary")

		# Checked before either path starts: both move the primary off this branch, and both would
		# carry unsaved edits away with it.
		require_promotable "$primary" 'demote'

		ident=$(state_resolve "$current") || {
			demote_adopt "$primary" "$current"
			return 0
		}
	fi

	slug=$(resolve_env "$ident")

	is_promoted "$slug" ||
		die "'${slug}' is not promoted; it already has its own worktree at $(state_get "$slug" '.path')"

	local path branch primary prev held
	path=$(state_get "$slug" '.path')
	branch=$(state_get "$slug" '.branch')
	primary=$(primary_root)
	prev=$(state_get "$slug" '.promoted.primary_prev_branch // ""')

	[[ -e $path ]] &&
		die "${path} already exists but '${slug}' is marked promoted; resolve by hand and rerun"

	# Only move the primary off the branch if it is actually still on it.
	held=$(git -C "$primary" branch --show-current 2>/dev/null) || held=''
	if [[ $held == "$branch" ]]; then
		require_promotable "$primary" 'demote'
		primary_release_branch "$primary" "$prev"
	fi

	log "recreating worktree ${path} on ${branch}"
	git -C "$(primary_root)" worktree add "$path" "$branch" ||
		die "could not recreate the worktree; ${primary} is off the branch and '${slug}' is still marked promoted — rerun: wt demote ${slug}"

	# app.env and process-compose.yml survived in the state directory and still describe this
	# environment exactly — same slot, same ports, same database — so only the dependencies need
	# reinstalling into the new directory.
	env_install_deps "$slug" "$path" "wt demote ${slug}"

	state_set "$slug" '.status = $status | .promoted = null' --arg status "$STATUS_WORKTREE"

	log "demoted ${slug}: ${branch} is back in ${path}"
	dim "start it with: wt up ${slug}"
}

# cmd_resume restarts the agent session that last worked on an environment, so a worktree that has
# been sitting is picked up with the context that built it instead of a fresh session.
cmd_resume() {
	local ident='' slug='' seen=0
	while (($# > 0)); do
		case $1 in
		-*) die "unknown flag for resume: $1" ;;
		*)
			require_one_env resume "$seen" "$ident" "$1"
			ident=$1
			seen=1
			shift
			;;
		esac
	done
	slug=$(resolve_env "$ident")

	local id name cwd
	id=$(session_id "$slug")
	name=$(session_name "$slug")
	cwd=$(session_cwd "$slug")

	[[ -n $id ]] ||
		die "no agent session recorded for '${slug}' — one is recorded the next time a wt command names it"

	# The recorded cwd can be a worktree that has since been removed (a promoted environment, say), and
	# the primary is where sessions driving worktrees run from anyway.
	[[ -n $cwd && -d $cwd ]] || cwd=$(primary_root)

	# Never launch a nested CLI from inside a session: it would fight the parent for the terminal. Print
	# the command instead.
	if [[ -n ${CLAUDECODE:-} ]]; then
		die "refusing to start a nested Claude session; run this by hand:
     (cd ${cwd} && claude --resume ${id})${name:+
     session: ${name}}"
	fi

	require_tools claude
	log "resuming ${name:-$id} in ${cwd}"
	cd "$cwd" || die "cannot enter ${cwd}"
	exec claude --resume "$id"
}

# has_uncommitted reports whether a tree has uncommitted *tracked* changes. Used only where untracked
# files are harmless: a fast-forward of the base branch leaves them alone. A gone directory has nothing
# to protect, so it returns false.
has_uncommitted() {
	local path=$1
	[[ -d $path ]] || return 1
	! git -C "$path" diff --quiet HEAD 2>/dev/null
}

# has_local_work reports whether a tree holds anything that removing it would lose: tracked changes
# *or* untracked files (ignored ones, like node_modules, do not count). This is the check every
# destructive path uses — `rm`, `gc`, `merge` — the same one `promote` has always used.
has_local_work() {
	local path=$1
	[[ -d $path ]] || return 1
	[[ -n $(git -C "$path" status --porcelain 2>/dev/null) ]]
}

# unpushed_commits prints how many commits on a local branch are reachable from no remote-tracking
# branch — work that would be gone for good if the branch were deleted.
unpushed_commits() {
	local branch=$1
	git -C "$(primary_root)" rev-list --count "refs/heads/${branch}" --not --remotes 2>/dev/null || printf '0\n'
}

# cmd_gc removes every environment whose pull request has merged or closed. It is safe to run
# unattended (from the post-merge hook): an environment with uncommitted changes is kept and flagged
# rather than force-deleted.
cmd_gc() {
	local dry_run=''
	[[ ${1:-} == '--dry-run' ]] && dry_run=1
	require_tools gh

	read_slugs
	((WT_SLUGS_N > 0)) || {
		dim 'nothing to collect'
		return 0
	}

	local slug pr path collected=0
	for slug in "${WT_SLUGS[@]}"; do
		pr=$(pr_state "$slug" force)
		case $pr in
		MERGED | CLOSED)
			collected=$((collected + 1))
			path=$(state_get "$slug" '.path')
			is_promoted "$slug" && path=$(primary_root)
			if [[ -n $dry_run ]]; then
				printf 'would remove %s (PR %s)\n' "$slug" "$pr"
			elif has_local_work "$path"; then
				warn "keeping ${slug} (PR ${pr}) — uncommitted or untracked changes; remove with: wt rm ${slug} --force"
			else
				log "PR for ${slug} is ${pr} — removing"
				cmd_rm "$slug" --force
			fi
			;;
		*) dim "keeping ${slug} (PR ${pr})" ;;
		esac
	done

	((collected > 0)) || dim 'no merged or closed environments'
}

# tree_holding_branch prints the path of the git worktree (the primary included) that currently has the
# named local branch checked out, or fails when none does.
tree_holding_branch() {
	local want=$1 line path=''
	while IFS= read -r line; do
		case $line in
		worktree\ *) path=${line#worktree } ;;
		branch\ refs/heads/*)
			[[ ${line#branch refs/heads/} == "$want" ]] && {
				printf '%s\n' "$path"
				return 0
			}
			;;
		esac
	done < <(git -C "$(primary_root)" worktree list --porcelain)
	return 1
}

# advance_base_branch fast-forwards the local base branch (main) to the just-merged origin/main. If it
# is checked out somewhere, that tree is fast-forwarded — skipped with a warning when it has
# uncommitted changes. When it is checked out nowhere, the ref is moved directly.
advance_base_branch() {
	local base=$PRIMARY_DEFAULT_BRANCH ref=$DEFAULT_GIT_BASE_REF primary tree
	primary=$(primary_root)

	if tree=$(tree_holding_branch "$base"); then
		if has_uncommitted "$tree"; then
			warn "${base} is checked out in ${tree} with uncommitted changes; not advancing it"
			return 0
		fi
		if git -C "$tree" merge --ff-only "$ref" >/dev/null 2>&1; then
			log "advanced ${base} in ${tree}"
		else
			warn "could not fast-forward ${base} in ${tree}; advance it by hand"
		fi
	elif git -C "$primary" branch -f "$base" "$ref" >/dev/null 2>&1; then
		log "advanced ${base} to ${ref}"
	else
		warn "could not advance ${base} to ${ref}"
	fi
}

# cmd_merge finishes a pull request from the wt side, so the whole GitHub round trip lives in one place.
# It merges the PR (or accepts one already merged from the web UI), prunes the deleted remote branch,
# advances local main, then reaps the environment and deletes the now-orphan local branch — merge and gc
# in a single step. --no-advance leaves main where it is; --keep-branch keeps the local branch ref.
cmd_merge() {
	local ident='' seen=0 advance=1 delete_branch=1 method='--squash'
	while (($# > 0)); do
		case $1 in
		--no-advance) advance='' && shift ;;
		--keep-branch) delete_branch='' && shift ;;
		# Repeated method flags last-win, deliberately: that is what every CLI does with a repetition of
		# one option, and unlike a second environment it discards a preference rather than a target.
		--squash | --merge | --rebase) method=$1 && shift ;;
		-*) die "unknown flag for merge: $1" ;;
		*)
			require_one_env merge "$seen" "$ident" "$1"
			ident=$1 && seen=1 && shift
			;;
		esac
	done
	[[ -n $ident ]] || die 'usage: wt merge <slug|branch> [--no-advance] [--keep-branch] [--squash|--merge|--rebase]'
	require_tools git gh

	local slug branch path promoted='' primary pr number
	slug=$(resolve_env "$ident")
	branch=$(state_get "$slug" '.branch')
	path=$(state_get "$slug" '.path')
	primary=$(primary_root)
	is_promoted "$slug" && {
		promoted=1
		path=$primary
	}

	# The environment's tree must be clean before we reap it: an uncommitted change or untracked file
	# there is not in the PR and would be lost with the worktree.
	has_local_work "$path" &&
		die "${path} has uncommitted or untracked changes; commit, stash or remove them before merging"

	pr=$(pr_state "$slug" force)
	number=$(pr_number "$slug")
	case $pr in
	OPEN)
		log "merging PR #${number} (${branch}) via ${method#--}"
		gh pr merge "$number" "$method" ||
			die "gh pr merge failed for #${number}; resolve it on GitHub, then re-run wt merge"
		;;
	MERGED) log "PR #${number} is already merged; cleaning up" ;;
	CLOSED) die "PR #${number} is closed without merging; discard the environment with: wt rm ${slug}" ;;
	*) die "no pull request for ${branch}; open one with /mk-pr, or discard with: wt rm ${slug}" ;;
	esac

	# Prune the deleted remote branch from local tracking, and delete it outright if the repo does not
	# auto-delete head branches.
	log 'fetching and pruning origin'
	git -C "$primary" fetch --all --prune --quiet
	if git -C "$primary" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
		dim "remote branch ${branch} still present; deleting it"
		git -C "$primary" push origin --delete "$branch" >/dev/null 2>&1 ||
			warn "could not delete remote branch ${branch}; delete it on GitHub"
	fi

	[[ -n $advance ]] && advance_base_branch

	env_teardown "$slug" force
	state_remove "$slug"

	if [[ -n $delete_branch ]]; then
		# A promoted branch is checked out in the primary; move it onto the base branch first so git will
		# let the branch go.
		if [[ -n $promoted ]]; then
			git -C "$primary" switch "$PRIMARY_DEFAULT_BRANCH" >/dev/null 2>&1 ||
				warn "could not switch ${primary} to ${PRIMARY_DEFAULT_BRANCH}; delete ${branch} by hand"
		fi
		if git -C "$primary" branch -D "$branch" >/dev/null 2>&1; then
			log "deleted local branch ${branch}"
		else
			warn "local branch ${branch} not deleted; remove it by hand"
		fi
	else
		dim "keeping local branch ${branch} (--keep-branch)"
	fi

	log "merged and cleaned up ${slug} (PR #${number})"
}

# hook_is_ours reports whether the named installed hook is our symlink. It compares by inode (-ef)
# rather than by the symlink's text, so it still recognises the hook when reached via a different but
# equivalent path (a symlinked home or volume).
hook_is_ours() {
	local name=$1 hook
	hook="$(primary_root)/.git/hooks/$name"
	[[ -L $hook && $hook -ef "$SCRIPT_DIR/hooks/$name" ]]
}

# install_one_hook symlinks one of our hooks into the shared hooks directory, preserving any
# pre-existing hook of that name as <hook>.pre-wt so ours can chain-call it rather than clobber it.
install_one_hook() {
	local name=$1 primary hook chained
	primary=$(primary_root)
	hook="$primary/.git/hooks/$name"
	chained="$hook$HOOK_CHAINED_SUFFIX"

	hook_is_ours "$name" && {
		log "already installed: ${name}"
		return 0
	}

	if [[ -e $hook ]]; then
		[[ -e $chained ]] &&
			die "both ${hook} and ${chained} exist; resolve by hand"
		log "preserving the existing ${name} hook as ${name}${HOOK_CHAINED_SUFFIX} (it will still run first)"
		mv "$hook" "$chained"
	fi

	# Worktrees share the primary checkout's hooks directory, so one symlink covers every environment.
	ln -sfn "$SCRIPT_DIR/hooks/$name" "$hook"
	log "installed ${hook}"
}

cmd_install_hooks() {
	local name
	for name in "${WT_HOOKS[@]}"; do install_one_hook "$name"; done
}

uninstall_one_hook() {
	local name=$1 primary hook chained
	primary=$(primary_root)
	hook="$primary/.git/hooks/$name"
	chained="$hook$HOOK_CHAINED_SUFFIX"

	hook_is_ours "$name" || {
		dim "${name} hook is not ours; leaving it alone"
		return 0
	}
	rm -f "$hook"
	[[ -e $chained ]] && mv "$chained" "$hook"
	log "removed our ${name} hook"
}

cmd_uninstall_hooks() {
	local name
	for name in "${WT_HOOKS[@]}"; do uninstall_one_hook "$name"; done
}

# cmd_on_commit is invoked by the post-commit hook with the committing worktree's root. It restarts
# that environment's API in the background (rebuild + migrate) — the web dev server hot-reloads.
cmd_on_commit() {
	local top=$1 slug found=''
	read_slugs
	((WT_SLUGS_N > 0)) || return 0

	for slug in "${WT_SLUGS[@]}"; do
		[[ $(state_get "$slug" '.path') == "$top" ]] && {
			found=$slug
			break
		}
	done
	[[ -n $found ]] || return 0
	env_running "$found" || return 0

	pc "$found" process restart api >/dev/null 2>&1 || true
}

# usage prints the header comment block, so the help text and the file's documentation cannot drift.
usage() {
	awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "${BASH_SOURCE[0]}"
}

main() {
	local cmd=${1:-}
	[[ $# -gt 0 ]] && shift

	mkdir -p "$WT_STATE_ROOT"

	case $cmd in
	create) cmd_create "$@" ;;
	up) cmd_up "$@" ;;
	down) cmd_down "$@" ;;
	restart) cmd_restart "$@" ;;
	rebase) cmd_rebase "$@" ;;
	list | ls) cmd_list "$@" ;;
	url) cmd_url "$@" ;;
	path) cmd_path "$@" ;;
	cd) die "$CD_NEEDS_SHELL_FN_MSG" ;;
	logs) cmd_logs "$@" ;;
	rm | remove) cmd_rm "$@" ;;
	merge) cmd_merge "$@" ;;
	promote) cmd_promote "$@" ;;
	demote) cmd_demote "$@" ;;
	resume) cmd_resume "$@" ;;
	recreate-config) cmd_recreate_config "$@" ;;
	reset-db) cmd_reset_db "$@" ;;
	gc) cmd_gc "$@" ;;
	doctor) cmd_doctor "$@" ;;
	install-hooks) cmd_install_hooks "$@" ;;
	uninstall-hooks) cmd_uninstall_hooks "$@" ;;
	on-commit) cmd_on_commit "$@" ;;
	'' | -h | --help | help) usage ;;
	*) die "unknown command '${cmd}' (try: wt help)" ;;
	esac
}

main "$@"
