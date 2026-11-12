#!/usr/bin/env bash
#
# Tests for `state_resolve` — the lookup that lets `wt rm` name an environment by its branch as well
# as its slug. The interesting cases are the ambiguous ones: a string that is one environment's slug
# and another's branch must resolve to the slug, and a miss must fail rather than print a stray slug.
#
# It runs against a throwaway MR_WT_HOME, so it touches neither the real state directory nor any
# cloud resource: no git, no database, no process-compose. Run it directly:
#
#   tools/wt/test_resolve.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

MR_WT_HOME=$(mktemp -d)
export MR_WT_HOME
trap 'rm -rf "$MR_WT_HOME"' EXIT

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

# record_env fakes a finished environment, the way `wt create` leaves one behind.
record_env() {
	local slug=$1 branch=$2 slot=$3
	state_write "$slug" "/nonexistent/$slug" "$branch" "$slot" "db_wt_$slug" "documents-wt-$slug"
}

# resolve prints what state_resolve resolved, or the sentinel MISS when it failed — so a failure is a
# comparable value rather than an exit under `set -e`.
resolve() { state_resolve "$1" || printf 'MISS\n'; }

printf 'resolution by slug and by branch\n'
record_env glazing feature/glazing-scraper 1
record_env decking bugfix/decking-joists 2

check_eq glazing "$(resolve glazing)" 'a slug resolves to itself'
check_eq decking "$(resolve decking)" 'the other slug resolves to itself'
check_eq glazing "$(resolve feature/glazing-scraper)" 'a branch resolves to its slug'
check_eq decking "$(resolve bugfix/decking-joists)" 'the other branch resolves to its slug'

printf 'misses fail rather than resolve\n'
check_eq MISS "$(resolve nonesuch)" 'an unknown identifier misses'
check_eq MISS "$(resolve feature/never-existed)" 'an unknown branch misses'
check_eq MISS "$(resolve '')" 'an empty identifier misses'
check_eq MISS "$(resolve feature/glazing)" 'a branch prefix does not match — the compare is exact'

printf 'a slug wins over another environment holding it as a branch\n'
# The pathological collision: `wt rm dogfood` must remove the environment whose slug is dogfood, which
# is what the tool has always meant by that argument, not the one that happens to be branched on it.
record_env dogfood feature/dogfood-harness 3
record_env impostor dogfood 4
check_eq dogfood "$(resolve dogfood)" 'the slug match is taken ahead of the branch match'
# The cost of that precedence: `dogfood` names the slug, so the impostor cannot be reached by its
# branch at all. It is still reachable by its own slug, which is the escape hatch.
check_eq impostor "$(resolve impostor)" 'the shadowed environment is still reachable by its slug'
check_eq dogfood "$(resolve feature/dogfood-harness)" "the shadowing environment resolves by its branch too"

printf 'resolve_env, the guard the commands actually call\n'
# resolve_env prints the slug on a hit and dies on a miss. The miss runs in a subshell here, exactly as
# it does at every call site (`slug=$(resolve_env "$slug")`), so this pins that the message still gets
# out and the status is still non-zero from inside one.
check_eq glazing "$(resolve_env feature/glazing-scraper)" 'resolve_env prints the slug for a branch'
check_eq glazing "$(resolve_env glazing)" 'resolve_env prints the slug for a slug'

miss_status=0
miss_stderr=$(resolve_env nonesuch 2>&1 >/dev/null) || miss_status=$?
check_eq 1 "$miss_status" 'resolve_env fails on a miss'
case $miss_stderr in
*"no worktree environment with slug or branch 'nonesuch'"*) ok 'resolve_env names the bad identifier on stderr' ;;
*) bad "resolve_env's message is unhelpful: '${miss_stderr}'" ;;
esac

printf 'validate_slug\n'
# Every slug becomes a bucket name component, and a bucket name may not end in a dash: a slug like `foo-`
# used to pass validation and then fail seeding, after the worktree and database already existed.
slug_ok() { (validate_slug "$1") >/dev/null 2>&1 && echo valid || echo invalid; }
for good in a ab a-b a--b upload-form 9x "$(printf 'a%.0s' $(seq 1 39))"; do
	check_eq valid "$(slug_ok "$good")" "accepts '${good}'"
done
for badslug in '' a- -a A Ab foo_bar 'a b' "$(printf 'a%.0s' $(seq 1 40))"; do
	check_eq invalid "$(slug_ok "$badslug")" "rejects '${badslug}'"
done

printf '\n'
((failures == 0)) || {
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
}
printf 'all resolution tests passed\n'
