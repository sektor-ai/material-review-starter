#!/usr/bin/env bash
# Shared helpers for the `wt` worktree-environment tool.
#
# Sourced by wt.sh and the other lib/*.sh files. Never executed directly.

# Slot 0 is the primary checkout. Its ports are left untouched so the plain `make dev` workflow keeps
# working; worktree environments take slots 1..MAX_SLOT.
readonly PRIMARY_SLOT=0
readonly MAX_SLOT=9

# Port bases — the primary checkout's own ports. Each slot shifts every service by PORT_STRIDE, which
# keeps the service ranges disjoint for every slot in [0, MAX_SLOT].
readonly PORT_STRIDE=10
readonly API_BASE=8787
readonly WEB_BASE=5180

# How long a cached GitHub PR record — state, number and URL — stays fresh in env.json before
# `wt list` re-queries `gh`.
readonly PR_STATE_TTL_SECONDS=300

# The state recorded for a branch that has no pull request. Not an error: it is where every environment
# starts, and where it stays until /mk-pr runs.
readonly PR_STATE_NONE='NONE'

# Worktree directories are siblings of the primary checkout, named <primary>-<slug>.
readonly WORKTREE_DIR_SEPARATOR='-'

# Git ref new worktrees branch from and `wt rebase` rebases onto. This repo integrates on `main` (PRs
# target it). Override per-machine with WT_BASE_REF in wt.env, or per-invocation with
# `wt create --from`.
readonly DEFAULT_GIT_BASE_REF="${WT_BASE_REF:-origin/main}"

# Where bare `wt demote` returns the primary checkout when it takes a branch away and has no recorded
# branch to put it back on, and the branch `wt merge` fast-forwards. Derived from the base ref rather
# than hardcoded, so a machine that bases its worktrees somewhere else returns its primary there too.
readonly PRIMARY_DEFAULT_BRANCH="${DEFAULT_GIT_BASE_REF#origin/}"

# Branches bare `wt demote` refuses to act on. They are integration branches: whatever is checked out
# in the primary is only worth moving into a worktree if it is somebody's work in progress.
readonly WT_PROTECTED_BRANCHES=(main master)

# Branch type prefixes, matching the /mk-pr naming convention (`<type>/<short-description>`). The
# worktree's branch is `<type>/<slug>`; `feature` is the default when --type is omitted.
readonly WT_BRANCH_TYPES=(feature bugfix refactor docs chore test perf)
readonly WT_DEFAULT_BRANCH_TYPE=feature

# Minimum free space, in MiB, required on the volume holding the worktrees before `wt create` will
# proceed. A worktree costs a few hundred MiB once ts/node_modules is installed.
readonly MIN_FREE_MIB=1024

WT_STATE_ROOT="${MR_WT_HOME:-$HOME/.material-review/worktrees}"
readonly WT_STATE_ROOT

# ── output ────────────────────────────────────────────────────────────────────────────────────────

if [[ -t 2 ]]; then
	readonly C_RESET=$'\033[0m' C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_DIM=$'\033[2m'
else
	readonly C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_DIM=''
fi

# Whether stdout is a terminal, sampled once here rather than tested at each use: a `[[ -t 1 ]]` inside
# a function that runs in a command substitution sees the capturing pipe, not the real stdout, and so
# would always report false.
if [[ -t 1 ]]; then WT_TTY_STDOUT=1; else WT_TTY_STDOUT=0; fi
readonly WT_TTY_STDOUT

# hyperlink renders `label` as an OSC 8 terminal hyperlink pointing at `url`. The escapes are invisible
# and carry the URL out of band, so callers must gate on WT_TTY_STDOUT and emit something greppable
# themselves when stdout is not a terminal.
hyperlink() { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }

log() { printf '%s==>%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s==> %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
dim() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
die() {
	printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
	exit 1
}

# require_one_env dies when a command that acts on a single environment is handed a second one. `wt
# rebase` is the only command that batches, and its habitual form names every environment at once; typed
# with another verb, a parser that keeps the last positional acts on an environment nobody chose — and
# for `merge`, merges a pull request nobody meant to merge.
#
# `seen` counts the positionals taken so far rather than testing whether the first one was non-empty, so
# an empty argument cannot pose as "none yet" and let the second through. It is called as a plain command
# and never through $( ), because die inside a command substitution only exits the subshell.
require_one_env() {
	local cmd=$1 seen=$2 have=$3 got=$4
	((seen == 0)) ||
		die "${cmd} takes one environment, got '${have}' and '${got}'; one at a time (did you mean 'wt rebase'?)"
}

# ── repo layout ───────────────────────────────────────────────────────────────────────────────────

# primary_root prints the absolute path of the primary checkout, regardless of which worktree the
# caller is standing in. The common git dir always lives inside the primary checkout.
primary_root() {
	local common_dir
	common_dir=$(git rev-parse --path-format=absolute --git-common-dir) ||
		die 'not inside a git repository'
	dirname "$common_dir"
}

# worktree_path prints where the worktree for a slug lives: a sibling of the primary checkout.
worktree_path() {
	local slug=$1 primary
	primary=$(primary_root)
	printf '%s%s%s\n' "$primary" "$WORKTREE_DIR_SEPARATOR" "$slug"
}

# source_env_file prints the env file every environment's settings are derived from: the primary
# checkout's .env, unless MR_WT_SOURCE_ENV points elsewhere (the test suites do).
source_env_file() { printf '%s\n' "${MR_WT_SOURCE_ENV:-$(primary_root)/.env}"; }

# The socket's name inside the environment's state directory. process-compose is always run from that
# directory and handed this *relative* name: macOS caps a Unix socket path at 104 bytes, and an absolute
# path under a long home or MR_WT_HOME blows straight through it (bind: invalid argument).
readonly PC_SOCKET_NAME='pc.sock'

state_dir() { printf '%s/%s\n' "$WT_STATE_ROOT" "$1"; }
state_file() { printf '%s/env.json\n' "$(state_dir "$1")"; }
socket_path() { printf '%s/%s\n' "$(state_dir "$1")" "$PC_SOCKET_NAME"; }

# ── validation ────────────────────────────────────────────────────────────────────────────────────

# A slug becomes a directory name, a git branch component, a Postgres database name component and a
# bucket name component, so keep it to the intersection of what all of them accept — including that a
# bucket name must end in a letter or digit, so no trailing dash. go/cmd/devenv checks the same
# pattern. Named because a slug is also *derived* from a branch (slug_from_branch),
# which needs the same test but a different message.
readonly SLUG_PATTERN='^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$'

validate_slug() {
	local slug=$1
	[[ -n $slug ]] || die 'slug is required'
	[[ $slug =~ $SLUG_PATTERN ]] ||
		die "invalid slug '${slug}': lowercase letters, digits and dashes, starting and ending with a letter or digit (max 39 chars)"
}

# validate_branch_type keeps the branch prefix to the /mk-pr set, so a typo'd --type is caught rather
# than silently producing an off-convention branch.
validate_branch_type() {
	local type=$1 known
	for known in "${WT_BRANCH_TYPES[@]}"; do
		[[ $type == "$known" ]] && return 0
	done
	die "invalid --type '${type}' (one of: ${WT_BRANCH_TYPES[*]})"
}

# resolve_env is the guard every command naming an existing environment runs its argument through: it
# dies unless the argument names one, and prints the slug it resolved to. Callers accept either a slug
# or a branch by virtue of it — state_resolve holds the precedence between the two.
#
# It is called as `slug=$(resolve_env "$slug")`, so the die inside runs in a command substitution's
# subshell: the message still reaches the real stderr, the subshell exits 1, and `set -e` takes the
# script down on the assignment. Same message, same exit code, one frame later.
#
# It is also where an environment learns which agent session is working on it. Being the one guard
# every slug-bearing command already passes through makes it the only place that cannot be forgotten:
# a command added later records its session by construction, without its author knowing this exists.
# `wt create` is the one command that must do it explicitly, since it resolves nothing.
resolve_env() {
	local ident=$1 slug
	slug=$(state_resolve "$ident") ||
		die "no worktree environment with slug or branch '${ident}' (try: wt list)"
	state_record_session "$slug"
	printf '%s\n' "$slug"
}

# ── external tools ────────────────────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

require_tools() {
	local tool missing=()
	for tool in "$@"; do
		have "$tool" || missing+=("$tool")
	done
	((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]} (run: wt doctor)"
}

# free_mib prints the free space, in MiB, on the volume containing the given path.
free_mib() {
	df -m "$1" | awk 'NR==2 {print $4}'
}
