#!/usr/bin/env bash
#
# Tests for the `wt promote` / `wt demote` cycle — the one pair of commands that reaches into the
# primary checkout and changes what is checked out there. That is someone's editor session, so the
# guards are the whole point: neither direction may switch a branch out from under unsaved work, and
# promote must never take the branch away with the worktree the way `rm` does.
#
# The cycle itself is the other half: promote keeps the environment (slot, ports, database, config)
# so that demote can hand the branch back to a worktree on the same everything, as many times round as
# the work needs. A promote that freed the slot would still pass every guard test and be useless.
#
# It builds a throwaway git repo to stand in for the primary checkout and points MR_WT_HOME at a
# throwaway state directory, so it touches neither the real environments nor the real checkout.
# `pnpm`, `go`, `process-compose` and `gh` are stubbed on PATH: demote's dependency install runs its
# real code path against a repo that has no dependencies, and the `go run ./cmd/devenv` calls that
# would create or drop a database answer from the stub instead — so no database is touched either.
# Run it directly:
#
#   tools/wt/test_promote.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly WT="$SCRIPT_DIR/wt.sh"

# wt.env would otherwise be sourced and clobber the throwaway state root with the real one.
export MR_WT_ENV_FILE=/nonexistent/wt.env
# CLAUDE_PID is inherited when this suite is run by an agent, and resolve_env would then stamp that
# session onto every throwaway environment. Harmless, but it makes the fixtures depend on who ran them.
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

MR_WT_HOME=$(mktemp -d)
export MR_WT_HOME

# Stubs for the tools env_install_deps runs. demote's install step is real code on the path under
# test; the fake repo just has nothing for it to install, and shelling out to the true pnpm/go would
# make the suite slow, network-dependent and dependent on this repo's lockfiles.
STUB_BIN=$(mktemp -d)
for stub in pnpm process-compose; do
	printf '#!/bin/sh\nexit 0\n' >"$STUB_BIN/$stub"
	chmod +x "$STUB_BIN/$stub"
done
# `gh` fails, which pr_sync reads as "this branch has no pull request" — the normal state for every
# fixture here, and far quicker and more predictable than letting the real gh probe a bare file remote.
# WT_TEST_GH_JSON, when set, is what `gh pr view` answers instead — the gc cases use it to report a
# merged PR.
cat >"$STUB_BIN/gh" <<'STUB'
#!/bin/sh
[ -n "${WT_TEST_GH_JSON:-}" ] || exit 1
printf '%s\n' "$WT_TEST_GH_JSON"
STUB
# `go` covers both the API build (nothing to do) and `go run ./cmd/devenv`, whose dotenv output
# resources.sh parses. The bare demote that adopts an unknown branch runs the real `wt create`, which
# creates a database, migrates and seeds — so the stub answers devenv `names`/`create` the way the
# real command does, and the create path is exercised end to end without Postgres.
cat >"$STUB_BIN/go" <<'STUB'
#!/bin/sh
case "$*" in
*cmd/devenv\ names\ *|*cmd/devenv\ create\ *)
	for arg; do slug=$arg; done
	printf 'DATABASE_NAME=doc_review_wt_%s\n' "$slug"
	printf 'DATABASE_URL=postgres://u:p@localhost/doc_review_wt_%s\n' "$slug"
	printf 'S3_BUCKET=documents-wt-%s\n' "$slug"
	;;
esac
exit 0
STUB
for stub in pnpm go process-compose gh; do chmod +x "$STUB_BIN/$stub"; done
export PATH="$STUB_BIN:$PATH"
# `pwd -P`, not a bare mktemp -d: on macOS mktemp hands back /var/…, a symlink to /private/var/…, but
# primary_root resolves through it. The recorded worktree path and primary_root would then disagree,
# and env_teardown's `rm -rf` guard — a prefix match against primary_root — would silently never fire.
# The destructive path this suite exists to pin down would go untested, and every case would pass for
# the wrong reason. Real checkouts live under an unsymlinked path, so resolve here to match them.
TMP_ROOT=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$MR_WT_HOME" "$TMP_ROOT" "$STUB_BIN"' EXIT

failures=0
ok() { printf '  ok   %s\n' "$1"; }
bad() {
	printf '  FAIL %s\n' "$1"
	failures=$((failures + 1))
}
check_eq() {
	local want=$1 got=$2 what=$3
	if [[ $want == "$got" ]]; then ok "$what"; else bad "${what}: want '${want}', got '${got}'"; fi
}

# make_env builds a primary checkout with one worktree on `feature/<slug>`, and records the state `wt`
# would have written for it. Prints the primary's path. The worktree must be the `<primary>-<slug>`
# sibling that worktree_path computes, since env_teardown's rm -rf fallback is guarded on that shape.
make_env() {
	local name=$1 slug=$2 primary worktree
	primary=$(make_primary "$name")
	worktree="$TMP_ROOT/${name}-${slug}"

	git -C "$primary" worktree add -q -b "feature/$slug" "$worktree" >/dev/null 2>&1

	# The database and bucket names are only recorded; teardown's devenv call goes to the go stub.
	(
		# shellcheck source=lib/common.sh
		source "$SCRIPT_DIR/lib/common.sh"
		# shellcheck source=lib/state.sh
		source "$SCRIPT_DIR/lib/state.sh"
		state_write "$slug" "$worktree" "feature/$slug" 1 "doc_review_wt_$slug" "documents-wt-$slug"
	)
	printf '%s\n' "$primary"
}

# make_primary builds just the primary checkout — the shape every fixture starts from, and all a bare
# `wt demote` needs when the branch it finds has no environment at all. Prints its path.
make_primary() {
	local name=$1 primary
	primary="$TMP_ROOT/$name"

	git init -q -b main "$primary"
	git -C "$primary" config user.email t@t.t
	git -C "$primary" config user.name t
	printf 'seed\n' >"$primary/seed.txt"

	# The directory shape demote rebuilds into: env_install_deps cds into ts and go, and resources.sh
	# runs devenv from the primary's go. They are committed so `git worktree add` materialises them
	# again, and .env is gitignored exactly as it is in the real repo.
	mkdir -p "$primary/ts" "$primary/go"
	printf '.env\n' >"$primary/.gitignore"
	printf 'x\n' >"$primary/ts/.keep"
	printf 'x\n' >"$primary/go/.keep"
	git -C "$primary" add -A
	git -C "$primary" commit -qm seed

	# The source env every environment's app.env is copied from. Untracked, as in the real checkout.
	printf 'DATABASE_URL=postgres://u:p@localhost/doc_review\nS3_BUCKET=documents\n' >"$primary/.env"

	# `wt create` fetches origin before adopting, so the fixture needs one. A bare sibling repo is
	# enough: nothing here pushes, and the fetch only has to succeed.
	git init -q --bare "${primary}.git"
	git -C "$primary" remote add origin "${primary}.git"
	git -C "$primary" push -q origin main

	printf '%s\n' "$primary"
}

branch_of() { git -C "$1" branch --show-current; }
has_branch() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

# promote runs the command in a primary checkout and reports the outcome, never aborting the run.
# Bare `(cd … && wt promote …)` would trip `set -e` the moment a case regressed, so the suite would
# die silently on the first failure instead of printing which assertions broke.
promote() {
	local primary=$1 slug=$2
	shift 2
	(cd "$primary" && "$WT" promote "$slug" "$@" >/dev/null 2>&1) && return 0 || return 1
}
promote_ok() {
	promote "$@" || bad "promote unexpectedly failed (primary=$1 slug=$2)"
}

# An empty slug means the bare form, and is passed as *no argument at all* rather than as an empty
# string — `wt demote ""` would exercise the argument parser, not the no-argument path under test.
demote() {
	local primary=$1 slug=$2
	shift 2
	if [[ -z $slug ]]; then
		(cd "$primary" && "$WT" demote "$@" >/dev/null 2>&1) && return 0 || return 1
	fi
	(cd "$primary" && "$WT" demote "$slug" "$@" >/dev/null 2>&1) && return 0 || return 1
}
demote_ok() {
	demote "$@" || bad "demote unexpectedly failed (primary=$1 slug=$2)"
}
status_of() { jq -r '.status // "worktree"' "$MR_WT_HOME/$1/env.json"; }

echo 'wt promote'

# ── the happy path ────────────────────────────────────────────────────────────────────────────────
primary=$(make_env happy lift ldev)
promote_ok "$primary" lift
check_eq 'feature/lift' "$(branch_of "$primary")" 'primary ends up on the promoted branch'
[[ -d "$TMP_ROOT/happy-lift" ]] && bad 'worktree directory removed' || ok 'worktree directory removed'
has_branch "$primary" 'feature/lift' && ok 'branch survives (rm would have deleted it)' ||
	bad 'branch survives (rm would have deleted it)'

# The environment is kept, not torn down: that is what makes the return leg cheap, and what a
# regression to the old one-way behaviour would silently undo.
[[ -f "$MR_WT_HOME/lift/env.json" ]] && ok 'the environment record is kept' ||
	bad 'the environment record is kept'
check_eq 'promoted' "$(status_of lift)" 'recorded as promoted'
check_eq 'main' "$(jq -r '.promoted.primary_prev_branch' "$MR_WT_HOME/lift/env.json")" \
	'records what the primary was on, so demote can put it back'
check_eq '1' "$(jq -r '.slot' "$MR_WT_HOME/lift/env.json")" 'the slot is still held'
check_eq 'doc_review_wt_lift' "$(jq -r '.resources.database' "$MR_WT_HOME/lift/env.json")" \
	'the database is still recorded (its data survives the round trip)'

# ── a promoted branch keeps its commits ───────────────────────────────────────────────────────────
primary=$(make_env carries work)
printf 'edit\n' >"$TMP_ROOT/carries-work/new.txt"
git -C "$TMP_ROOT/carries-work" add new.txt
git -C "$TMP_ROOT/carries-work" commit -qm 'the work'
promote_ok "$primary" work
check_eq 'the work' "$(git -C "$primary" log -1 --format=%s)" 'committed work is what the primary checks out'
[[ -f "$primary/new.txt" ]] && ok 'promoted files are present in the primary' ||
	bad 'promoted files are present in the primary'

# ── refuses to destroy uncommitted work in the worktree ───────────────────────────────────────────
primary=$(make_env dirtywt edits)
printf 'unsaved\n' >>"$TMP_ROOT/dirtywt-edits/seed.txt"
if promote "$primary" edits; then
	bad 'refuses when the worktree has uncommitted changes'
else
	ok 'refuses when the worktree has uncommitted changes'
fi
[[ -d "$TMP_ROOT/dirtywt-edits" ]] && ok '  ...and tears nothing down when it refuses' ||
	bad '  ...and tears nothing down when it refuses'

# ── untracked files count as work worth keeping ───────────────────────────────────────────────────
# Without this guard `git worktree remove` refuses, and env_teardown's fallback rm -rf eats them.
primary=$(make_env untracked scratch)
printf 'notes\n' >"$TMP_ROOT/untracked-scratch/scratch.txt"
if promote "$primary" scratch; then
	bad 'refuses when the worktree has untracked files'
else
	ok 'refuses when the worktree has untracked files'
fi
[[ -f "$TMP_ROOT/untracked-scratch/scratch.txt" ]] && ok '  ...and the untracked file survives' ||
	bad '  ...and the untracked file survives'

# ── never switches the branch under unsaved work in the primary ───────────────────────────────────
primary=$(make_env dirtyprimary safe)
printf 'editing\n' >>"$primary/seed.txt"
if promote "$primary" safe; then
	bad 'refuses when the primary has uncommitted changes'
else
	ok 'refuses when the primary has uncommitted changes'
fi
check_eq 'main' "$(branch_of "$primary")" '  ...and the primary stays on its branch'
[[ -d "$TMP_ROOT/dirtyprimary-safe" ]] && ok '  ...and the environment is left intact' ||
	bad '  ...and the environment is left intact'

# ── unknown slug ──────────────────────────────────────────────────────────────────────────────────
primary=$(make_env unknown real)
if promote "$primary" nosuchenv; then
	bad 'refuses an unknown slug'
else
	ok 'refuses an unknown slug'
fi

# ── flags are rejected rather than silently swallowed ─────────────────────────────────────────────
if promote "$primary" real --force; then
	bad 'rejects --force (there is deliberately no way to discard the work)'
else
	ok 'rejects --force (there is deliberately no way to discard the work)'
fi

# ── promote refuses to displace another promoted branch ───────────────────────────────────────────
# The primary holds one branch. Promoting a second while the first is still sitting there would leave
# the first with no worktree and no checkout — recoverable, but not something to do silently.
primary=$(make_env twoenvs first)
worktree_second="$TMP_ROOT/twoenvs-second"
git -C "$primary" worktree add -q -b feature/second "$worktree_second" >/dev/null 2>&1
(
	source "$SCRIPT_DIR/lib/common.sh"
	source "$SCRIPT_DIR/lib/state.sh"
	state_write second "$worktree_second" feature/second 2 doc_review_wt_second documents-wt-second
)
promote_ok "$primary" first
if promote "$primary" second; then
	bad 'refuses to promote a second environment over the first'
else
	ok 'refuses to promote a second environment over the first'
fi
check_eq 'feature/first' "$(branch_of "$primary")" '  ...and the primary still holds the first'
[[ -d "$worktree_second" ]] && ok '  ...and the second environment is untouched' ||
	bad '  ...and the second environment is untouched'

echo
echo 'wt demote (the return leg)'

# ── the cycle: out and back, twice ────────────────────────────────────────────────────────────────
primary=$(make_env cycle roam)
promote_ok "$primary" roam
demote_ok "$primary" roam
check_eq 'main' "$(branch_of "$primary")" 'primary is returned to the branch it was on'
check_eq 'worktree' "$(status_of roam)" 'recorded as a worktree again'
[[ -d "$TMP_ROOT/cycle-roam" ]] && ok 'the worktree directory is rebuilt' ||
	bad 'the worktree directory is rebuilt'
check_eq 'feature/roam' "$(branch_of "$TMP_ROOT/cycle-roam")" '  ...on its own branch'
check_eq 'null' "$(jq -r '.promoted' "$MR_WT_HOME/roam/env.json")" 'the promotion record is cleared'

# Round two is the whole point: the old promote was a one-way door, so a second lap is what proves
# the cycle rather than a single lucky trip.
promote_ok "$primary" roam
check_eq 'feature/roam' "$(branch_of "$primary")" 'second lap: promote works again'
demote_ok "$primary" roam
check_eq 'main' "$(branch_of "$primary")" 'second lap: demote works again'
check_eq '1' "$(jq -r '.slot' "$MR_WT_HOME/roam/env.json")" '  ...on the same slot throughout'

# ── work made in the primary comes back with the branch ───────────────────────────────────────────
primary=$(make_env carryback edits)
promote_ok "$primary" edits
printf 'by hand\n' >"$primary/handmade.txt"
git -C "$primary" add handmade.txt
git -C "$primary" commit -qm 'edited in the primary'
demote_ok "$primary" edits
[[ -f "$TMP_ROOT/carryback-edits/handmade.txt" ]] &&
	ok 'a commit made in the primary is in the rebuilt worktree' ||
	bad 'a commit made in the primary is in the rebuilt worktree'

# ── demote refuses to switch the primary under unsaved work ───────────────────────────────────────
primary=$(make_env dirtyback held)
promote_ok "$primary" held
printf 'editing\n' >>"$primary/seed.txt"
if demote "$primary" held; then
	bad 'refuses when the primary has uncommitted changes'
else
	ok 'refuses when the primary has uncommitted changes'
fi
check_eq 'feature/held' "$(branch_of "$primary")" '  ...and the primary keeps the branch'
check_eq 'promoted' "$(status_of held)" '  ...and the environment stays promoted'

# ── demoting something that was never promoted ────────────────────────────────────────────────────
primary=$(make_env notprom plain)
if demote "$primary" plain; then
	bad 'refuses to demote an environment that has its own worktree'
else
	ok 'refuses to demote an environment that has its own worktree'
fi

# ── promoting something already promoted ──────────────────────────────────────────────────────────
primary=$(make_env twice again)
promote_ok "$primary" again
if promote "$primary" again; then
	bad 'refuses to promote an already-promoted environment'
else
	ok 'refuses to promote an already-promoted environment'
fi

# ── bare `wt demote` acts on whatever the primary is holding ──────────────────────────────────────
echo
echo 'wt demote with no argument'

primary=$(make_env bare quiet)
promote_ok "$primary" quiet
demote_ok "$primary" ''
check_eq 'main' "$(branch_of "$primary")" 'demotes the branch the primary is on, unnamed'
check_eq 'worktree' "$(status_of quiet)" '  ...and the environment is back in its worktree'
[[ -d "$TMP_ROOT/bare-quiet" ]] && ok '  ...which exists again' || bad '  ...which exists again'

# ── it refuses the integration branches ───────────────────────────────────────────────────────────
# Bare demote reads whatever is checked out, so these have to be rejected explicitly: adopting one
# would build an environment for the branch everything else is based on.
#
# The message is asserted, not just the failure. `main` fails either way — the adopt path cannot
# release the primary from `main` *to* `main`, so `create --adopt` refuses a branch that is still
# checked out — but it fails deep in adoption with an error about the wrong thing. Testing only the
# exit status would pass with the guard deleted.
primary=$(make_primary protected)
for protected in main master; do
	git -C "$primary" checkout -q -B "$protected" >/dev/null 2>&1
	err=$( (cd "$primary" && "$WT" demote 2>&1) ) && bad "refuses to demote ${protected}" || true
	case $err in
	*'integration branch'*) ok "refuses to demote ${protected}, saying why" ;;
	*) bad "refuses to demote ${protected}, saying why (got: ${err})" ;;
	esac
done

# ── it refuses a dirty primary, before touching anything ──────────────────────────────────────────
primary=$(make_env baredirty messy)
promote_ok "$primary" messy
printf 'editing\n' >>"$primary/seed.txt"
if demote "$primary" ''; then
	bad 'refuses when the primary has uncommitted changes'
else
	ok 'refuses when the primary has uncommitted changes'
fi
check_eq 'feature/messy' "$(branch_of "$primary")" '  ...and leaves the primary on its branch'
check_eq 'promoted' "$(status_of messy)" '  ...and the environment stays promoted'

# ── a detached HEAD names no branch to act on ─────────────────────────────────────────────────────
primary=$(make_primary detached)
git -C "$primary" checkout -q --detach >/dev/null 2>&1
if demote "$primary" ''; then
	bad 'refuses on a detached HEAD'
else
	ok 'refuses on a detached HEAD'
fi

# ── a branch with no environment falls through to `create --adopt` ────────────────────────────────
# The point of the fallback: "give this branch a worktree" is one command whether or not the branch
# has ever had an environment.
primary=$(make_primary adopts)
git -C "$primary" checkout -q -b feature/loose >/dev/null 2>&1
printf 'work\n' >"$primary/loose.txt"
git -C "$primary" add loose.txt
git -C "$primary" commit -qm 'started by hand'
demote_ok "$primary" ''
[[ -f "$MR_WT_HOME/loose/env.json" ]] && ok 'adopts an unknown branch into a new environment' ||
	bad 'adopts an unknown branch into a new environment'
check_eq 'feature/loose' "$(jq -r '.branch' "$MR_WT_HOME/loose/env.json" 2>/dev/null)" \
	'  ...on the branch it found, named after it'
check_eq 'feature/loose' "$(branch_of "$TMP_ROOT/adopts-loose" 2>/dev/null)" \
	'  ...with a worktree checked out on it'
[[ -f "$TMP_ROOT/adopts-loose/loose.txt" ]] && ok '  ...carrying the work that was done by hand' ||
	bad '  ...carrying the work that was done by hand'
check_eq 'main' "$(branch_of "$primary")" '  ...and the primary is returned to main'
# The environment must run against its own data, never the primary's: app.env is the primary's .env
# with the database and bucket rewritten.
check_eq '"postgres://u:p@localhost/doc_review_wt_loose"' \
	"$(sed -n 's/^DATABASE_URL=//p' "$MR_WT_HOME/loose/app.env" 2>/dev/null)" \
	'  ...with app.env pointed at its own database'
check_eq '"documents-wt-loose"' "$(sed -n 's/^S3_BUCKET=//p' "$MR_WT_HOME/loose/app.env" 2>/dev/null)" \
	'  ...and its own bucket'

# ── the adopt path refuses a dirty primary ────────────────────────────────────────────────────────
# This is what the bare path's own dirty check is for. On a branch that *has* an environment the
# inner guard catches it anyway; on an unknown branch nothing else would, and adoption starts by
# checking the primary out somewhere else — carrying the uncommitted edits along with it.
primary=$(make_primary dirtyadopt)
git -C "$primary" checkout -q -b feature/unsaved >/dev/null 2>&1
printf 'editing\n' >>"$primary/seed.txt"
if demote "$primary" ''; then
	bad 'refuses to adopt an unknown branch while the primary is dirty'
else
	ok 'refuses to adopt an unknown branch while the primary is dirty'
fi
check_eq 'feature/unsaved' "$(branch_of "$primary")" '  ...leaving the primary on its branch'
[[ -f "$MR_WT_HOME/unsaved/env.json" ]] && bad '  ...and building nothing' ||
	ok '  ...and building nothing'

# ── the adopt fallback refuses a taken name, before moving the primary ─────────────────────────────
# Two distinct clashes. The directory is the one a normal environment presents; the state record is
# reachable only when the environment holding that name is promoted, so its directory is gone and the
# path check would wave it through.
# A stray sibling directory with no environment behind it — left by a hand-removed worktree, say.
# The state record check cannot see it, and `git worktree add` would fail on it after the primary had
# already been moved.
primary=$(make_primary strayclash)
mkdir -p "$TMP_ROOT/strayclash-stray"
git -C "$primary" checkout -q -b feature/stray >/dev/null 2>&1
if demote "$primary" ''; then
	bad 'refuses when the derived name has a directory in the way'
else
	ok 'refuses when the derived name has a directory in the way'
fi
check_eq 'feature/stray' "$(branch_of "$primary")" '  ...without stranding the primary off its branch'

primary=$(make_env clash lift)
git -C "$primary" checkout -q -b bugfix/lift >/dev/null 2>&1
if demote "$primary" ''; then
	bad 'refuses when the derived name belongs to an existing environment'
else
	ok 'refuses when the derived name belongs to an existing environment'
fi
check_eq 'bugfix/lift' "$(branch_of "$primary")" '  ...without stranding the primary off its branch'

primary=$(make_env clashprom hoist)
promote_ok "$primary" hoist
# The human moved the primary off the promoted branch by hand, so bare demote no longer resolves to
# the `hoist` environment — but the name it derives is still spoken for by that record.
git -C "$primary" checkout -q -b bugfix/hoist >/dev/null 2>&1
if demote "$primary" ''; then
	bad 'refuses when the derived name belongs to a promoted environment'
else
	ok 'refuses when the derived name belongs to a promoted environment'
fi
check_eq 'bugfix/hoist' "$(branch_of "$primary")" '  ...without stranding the primary off its branch'
check_eq 'promoted' "$(status_of hoist)" '  ...and leaving that environment alone'

# ── rm on a promoted environment must not delete the branch out from under the primary ────────────
echo
echo 'wt rm on a promoted environment'
primary=$(make_env rmprom parked)
promote_ok "$primary" parked
rm_output=$( (cd "$primary" && "$WT" rm parked 2>&1) ) || bad 'rm unexpectedly failed'
has_branch "$primary" 'feature/parked' && ok 'the branch is left alone (it is checked out)' ||
	bad 'the branch is left alone (it is checked out)'
# git refuses to delete a checked-out branch on its own, so the branch surviving proves nothing about
# our code. What the guard is actually for is the diagnostic: without it `rm` reaches the generic
# `git branch -D` failure path and blames "unmerged?", which is both wrong and unactionable here.
case $rm_output in
*'is checked out in'*) ok '  ...and rm says why, rather than guessing "unmerged?"' ;;
*) bad "  ...and rm says why, rather than guessing \"unmerged?\" (got: ${rm_output})" ;;
esac
check_eq 'feature/parked' "$(branch_of "$primary")" '  ...and the primary stays on it'
[[ -f "$MR_WT_HOME/parked/env.json" ]] && bad '  ...but the environment record is gone' ||
	ok '  ...but the environment record is gone'

# ── `rm` still does the opposite, which is the whole distinction ──────────────────────────────────
# promote and rm share env_teardown; the branch is the only thing they treat differently. Pin it, so
# a refactor of the shared path cannot quietly turn one into the other.
echo
echo 'wt rm (the contrast promote is defined against)'
primary=$(make_env removal gone)
(cd "$primary" && "$WT" rm gone >/dev/null 2>&1) || bad 'rm unexpectedly failed'
[[ -d "$TMP_ROOT/removal-gone" ]] && bad 'rm removes the worktree directory' ||
	ok 'rm removes the worktree directory'
has_branch "$primary" 'feature/gone' && bad 'rm deletes the branch (promote keeps it)' ||
	ok 'rm deletes the branch (promote keeps it)'
check_eq 'main' "$(branch_of "$primary")" 'rm leaves the primary where it was'

# ── rm and gc never destroy work that exists nowhere else ──────────────────────────────────────────
echo
echo 'wt rm / wt gc guards'

# Untracked files die with the worktree, so they block rm exactly as tracked edits do.
primary=$(make_env rmuntracked notes)
printf 'scratch\n' >"$TMP_ROOT/rmuntracked-notes/notes.txt"
# The message is asserted, not just the refusal: worktree_remove would also refuse later (git will not
# remove a worktree with untracked files), but only after teardown had already dropped the database.
# The up-front check is what keeps the environment whole.
err=$( (cd "$primary" && "$WT" rm notes 2>&1) ) && bad 'rm refuses a worktree holding untracked files' || {
	case $err in
	*'uncommitted or untracked changes'*) ok 'rm refuses a worktree holding untracked files, before teardown' ;;
	*) bad "rm refuses a worktree holding untracked files, before teardown (got: ${err})" ;;
	esac
}
[[ -f "$TMP_ROOT/rmuntracked-notes/notes.txt" ]] && ok '  ...and the file survives' || bad '  ...and the file survives'

# Commits that were never pushed would be gone with `branch -D`.
primary=$(make_env rmunpushed local)
printf 'work\n' >"$TMP_ROOT/rmunpushed-local/work.txt"
git -C "$TMP_ROOT/rmunpushed-local" add work.txt
git -C "$TMP_ROOT/rmunpushed-local" commit -qm 'never pushed'
err=$( (cd "$primary" && "$WT" rm local 2>&1) ) && bad 'rm refuses a branch with unpushed commits' || {
	case $err in
	*'1 commit(s) on no remote branch'*) ok 'rm refuses a branch with unpushed commits, saying how many' ;;
	*) bad "rm refuses a branch with unpushed commits, saying how many (got: ${err})" ;;
	esac
}
has_branch "$primary" feature/local && ok '  ...and the branch survives' || bad '  ...and the branch survives'
[[ -d "$TMP_ROOT/rmunpushed-local" ]] && ok '  ...and so does the worktree' || bad '  ...and so does the worktree'

(cd "$primary" && "$WT" rm local --force >/dev/null 2>&1) || bad 'rm --force unexpectedly failed'
has_branch "$primary" feature/local && bad '--force deletes it anyway' || ok '--force deletes it anyway'

# gc runs unattended from a hook: a merged environment with untracked files is kept, not reaped.
primary=$(make_env gcuntracked merged)
printf 'scratch\n' >"$TMP_ROOT/gcuntracked-merged/notes.txt"
WT_TEST_GH_JSON='{"state":"MERGED","number":1,"url":"https://example.test/pull/1","createdAt":"2999-01-01T00:00:00Z"}' \
	bash -c 'cd "$1" && "$2" gc >/dev/null 2>&1' -- "$primary" "$WT" || bad 'gc unexpectedly failed'
[[ -f "$TMP_ROOT/gcuntracked-merged/notes.txt" ]] && ok 'gc keeps a merged environment holding untracked files' ||
	bad 'gc keeps a merged environment holding untracked files'
[[ -f "$MR_WT_HOME/merged/env.json" ]] && ok '  ...and its record' || bad '  ...and its record'

primary=$(make_env gcclean tidy)
WT_TEST_GH_JSON='{"state":"MERGED","number":2,"url":"https://example.test/pull/2","createdAt":"2999-01-01T00:00:00Z"}' \
	bash -c 'cd "$1" && "$2" gc >/dev/null 2>&1' -- "$primary" "$WT" || bad 'gc unexpectedly failed'
[[ -f "$MR_WT_HOME/tidy/env.json" ]] && bad 'gc reaps a clean merged environment' || ok 'gc reaps a clean merged environment'

echo
if ((failures > 0)); then
	printf '%d failure(s)\n' "$failures"
	exit 1
fi
echo 'all passed'
