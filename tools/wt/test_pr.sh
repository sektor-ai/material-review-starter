#!/usr/bin/env bash
#
# Tests for `pr_sync` — how an environment finds its pull request. `gc` and `merge` act on that PR's
# state, so it must be *this* environment's PR: a branch name can be reused, and a new environment on
# `feature/x` must never be reaped because an older `feature/x` PR merged.
#
# `gh` is a stub that answers `gh pr view <branch-or-number>` from fixtures and logs what it was asked,
# so the cases can assert both the outcome and that a recorded number is what gets looked up. Runs
# against a throwaway MR_WT_HOME; nothing reaches GitHub. Run it directly:
#
#   tools/wt/test_pr.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

MR_WT_HOME=$(mktemp -d)
export MR_WT_HOME
STUB_BIN=$(mktemp -d)
trap 'rm -rf "$MR_WT_HOME" "$STUB_BIN"' EXIT

# The stub prints $STUB_BIN/pr-<arg>.json for `gh pr view <arg>`, and fails (no PR) when there is none.
cat >"$STUB_BIN/gh" <<'STUB'
#!/bin/sh
dir=$(dirname "$0")
[ "$1 $2" = "pr view" ] || exit 1
printf '%s\n' "$3" >>"$dir/asked.log"
key=$(printf '%s' "$3" | tr '/' '_')
[ -f "$dir/pr-$key.json" ] || exit 1
cat "$dir/pr-$key.json"
STUB
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"

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

# fixture makes `gh pr view <arg>` answer with a PR. Created times are absolute, so "before the
# environment" and "after it" do not depend on when the suite runs.
fixture() {
	local arg=$1 state=$2 number=$3 created=$4
	printf '{"state":"%s","number":%s,"url":"https://example.test/pull/%s","createdAt":"%s"}\n' \
		"$state" "$number" "$number" "$created" >"$STUB_BIN/pr-$(printf '%s' "$arg" | tr '/' '_').json"
}
clear_fixtures() { rm -f "$STUB_BIN"/pr-*.json "$STUB_BIN/asked.log"; }

# env_at records an environment created at a fixed time.
env_at() {
	local slug=$1 branch=$2 created=$3
	state_write "$slug" "/nonexistent/$slug" "$branch" 1 "db_$slug" "bucket-$slug"
	state_set "$slug" '.created_at = $c' --arg c "$created"
}

readonly BEFORE='2026-01-01T00:00:00Z' ENV_CREATED='2026-06-01T00:00:00Z' AFTER='2026-09-01T00:00:00Z'

printf 'a stale PR from an earlier use of the branch name is ignored\n'
clear_fixtures
env_at reuse feature/reuse "$ENV_CREATED"
fixture feature/reuse MERGED 3 "$BEFORE"
check_eq NONE "$(pr_state reuse force)" 'a merged PR created before the environment is not its PR'
check_eq '' "$(pr_number reuse)" '  ...and no number is recorded from it'

clear_fixtures
fixture feature/reuse CLOSED 4 "$BEFORE"
check_eq NONE "$(pr_state reuse force)" 'a closed PR created before the environment is ignored too'

printf 'the environment'"'"'s own PR is found and pinned\n'
clear_fixtures
fixture feature/reuse OPEN 9 "$AFTER"
check_eq OPEN "$(pr_state reuse force)" 'an open PR on the branch is found'
check_eq 9 "$(pr_number reuse)" '  ...and its number recorded'

# From now on the number is what gets looked up, so the branch fixture can say anything.
clear_fixtures
fixture feature/reuse MERGED 3 "$BEFORE"
fixture 9 MERGED 9 "$AFTER"
check_eq MERGED "$(pr_state reuse force)" 'once recorded, the PR is followed by number'
check_eq 9 "$(cat "$STUB_BIN/asked.log")" '  ...gh is asked for #9, not the branch'

printf 'an adopted branch keeps the PR it already had\n'
clear_fixtures
env_at adopted feature/adopted "$ENV_CREATED"
fixture feature/adopted OPEN 5 "$BEFORE"
check_eq OPEN "$(pr_state adopted force)" 'an open PR created before the environment is still its PR'
check_eq 5 "$(pr_number adopted)" '  ...and pinned'

printf 'a PR merged after the environment was created is its PR\n'
clear_fixtures
env_at fresh feature/fresh "$ENV_CREATED"
fixture feature/fresh MERGED 7 "$AFTER"
check_eq MERGED "$(pr_state fresh force)" 'a merged PR created after the environment counts'

printf 'no PR at all\n'
clear_fixtures
env_at bare feature/bare "$ENV_CREATED"
check_eq NONE "$(pr_state bare force)" 'no PR reads as NONE'
check_eq '' "$(pr_url bare)" '  ...with no URL'

printf '\n'
((failures == 0)) || {
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
}
printf 'all pull request tests passed\n'
