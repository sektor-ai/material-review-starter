#!/usr/bin/env bash
#
# Tests for `require_one_env` — the rule that every command except `rebase` acts on exactly one
# environment, and that a list is an error rather than a batch.
#
# The habitual line after something lands is `wt rebase a b c d e f`. Typed with another verb, a parser
# that kept the last positional would act on an environment nobody chose — for `merge`, merging a pull
# request; for `rm` or `reset-db`, destroying a worktree or its data. So every command refuses a list.
#
# The cases run the real `wt.sh` against a throwaway MR_WT_HOME, which holds no environments — so a
# name that gets past the guard dies on a missing prerequisite or an unresolvable name instead, and
# nothing reaches git, gh or the database. That difference in failure is what separates "rejected as a list"
# from "accepted as one name"; the assertions turn on which error came back, not on reaching any
# particular one, because what runs first differs with what is installed on the machine.
#
# `create` carries the same guard with its own wording — its positional names an environment that does
# not exist yet. It is deliberately NOT exercised here: with the guard regressed, `wt create <slug>`
# would go on to build a worktree and a database for real, and a test that does damage when it fails
# is worse than the gap. `test_promote.sh` is the place for that, where PATH is stubbed.
#
# Run it directly:
#
#   tools/wt/test_env_args.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# Every command whose positional names an existing environment. `rebase` is absent on purpose: batching
# is its job. `create` is absent for the reason in the header. restart, logs and url take a second
# argument (a process or service), so they are covered separately below.
readonly SINGLE_ENV_COMMANDS=(merge rm reset-db promote demote resume up down recreate-config path)
readonly ENV_AND_NAME_COMMANDS=(restart logs url)
# Commands that need an environment, and must say so with a usage line rather than a bash error.
readonly NEEDS_ENV_COMMANDS=(up down recreate-config restart logs url)

MR_WT_HOME=$(mktemp -d)
export MR_WT_HOME
trap 'rm -rf "$MR_WT_HOME"' EXIT

failures=0

ok() { printf '  ok   %s\n' "$1"; }
bad() {
	printf '  FAIL %s\n' "$1"
	failures=$((failures + 1))
}

# wt_stderr runs a wt command and prints its stderr, prefixed with the exit status so a case can assert
# on both from one invocation. stdout is dropped: every outcome under test is a failure, and failures
# speak on stderr.
wt_stderr() {
	local status=0 output
	output=$("$SCRIPT_DIR/wt.sh" "$@" 2>&1 >/dev/null) || status=$?
	printf '%s|%s' "$status" "$output"
}

# rejects_list asserts that an argument list is refused by the guard rather than acted on.
rejects_list() {
	local what=$1 && shift
	local result status message
	result=$(wt_stderr "$@")
	status=${result%%|*}
	message=${result#*|}

	[[ $status != 0 ]] || {
		bad "${what}: exited 0, so the command was carried out"
		return
	}
	case $message in
	*'takes one environment'*'did you mean'*) ok "$what" ;;
	*) bad "${what}: rejected, but the message does not explain why: '${message}'" ;;
	esac
}

# Every single-environment command refuses a pair. `rm` and `reset-db` matter as much as `merge` here:
# both destroy something, and neither would have said so.
for cmd in "${SINGLE_ENV_COMMANDS[@]}"; do
	rejects_list "wt ${cmd} refuses two environments" "$cmd" glazing ktx2-textures
done

# The line that caused the incident, and the forms flags can take around it.
rejects_list 'the full rebase-style list is refused' merge \
	cinema-acoustics glazing gmail-receipts-fetch ktx2-textures opening-drag-handles thermal-uvalue
rejects_list 'a flag between two environments does not hide the second' merge glazing --squash ktx2-textures
rejects_list 'the guard fires however the flags are ordered' merge --no-advance glazing ktx2-textures
rejects_list 'a flag-bearing command still guards' rm glazing --force ktx2-textures

# An empty first argument must not pose as "none seen yet" and let the second through. This is why the
# guard counts positionals instead of testing the stored name for emptiness.
rejects_list 'an empty first argument does not slip the guard' merge '' glazing

# Both offending names belong in the message: the point is to show which two were seen, so the human can
# tell at a glance that they meant `rebase`.
list_message=$(wt_stderr merge glazing ktx2-textures)
case ${list_message#*|} in
*"'glazing'"*"'ktx2-textures'"*) ok 'the message names both environments' ;;
*) bad "the message does not name both environments: '${list_message#*|}'" ;;
esac

# `rebase` is the one command that legitimately batches, and the guard must not have reached it. With an
# empty state root it dies resolving the first name — proof it tried to take the list, not refuse it.
batch=$(wt_stderr rebase glazing ktx2-textures)
case ${batch#*|} in
*'takes one environment'*) bad "rebase was refused a list, which is its whole purpose: '${batch#*|}'" ;;
*"no worktree environment with slug or branch 'glazing'"*) ok 'rebase still accepts a list' ;;
*) bad "rebase failed unexpectedly: '${batch#*|}'" ;;
esac

# The guard must not swallow the single-environment form. What it dies of next depends on the machine —
# a missing prerequisite, or the name resolving to nothing in an empty state root — so the assertion is
# only that it is not the list error.
for cmd in "${SINGLE_ENV_COMMANDS[@]}"; do
	single=$(wt_stderr "$cmd" glazing)
	case ${single#*|} in
	*'takes one environment'*) bad "wt ${cmd} refused a single environment as a list: '${single#*|}'" ;;
	'0|'*) bad "wt ${cmd} exited 0 against an empty state root" ;;
	*) ok "wt ${cmd} accepts a single environment" ;;
	esac
done

# restart, logs and url take an environment plus a name; a third argument is refused, not ignored.
for cmd in "${ENV_AND_NAME_COMMANDS[@]}"; do
	result=$(wt_stderr "$cmd" glazing api ktx2-textures)
	case ${result#*|} in
	*'takes at most 2 arguments'*) ok "wt ${cmd} refuses a third argument" ;;
	*) bad "wt ${cmd} should refuse a third argument, got: '${result#*|}'" ;;
	esac
	result=$(wt_stderr "$cmd" glazing api)
	case ${result#*|} in
	*'takes at most'* | *'takes one environment'*) bad "wt ${cmd} refused an environment and a name: '${result#*|}'" ;;
	*) ok "wt ${cmd} accepts an environment and a name" ;;
	esac
done

# A missing environment is a usage error, never bash's `unbound variable`.
for cmd in "${NEEDS_ENV_COMMANDS[@]}"; do
	result=$(wt_stderr "$cmd")
	case ${result#*|} in
	'0|'*) bad "wt ${cmd} with no environment exited 0" ;;
	*'unbound variable'*) bad "wt ${cmd} with no environment died with a shell error: '${result#*|}'" ;;
	*"usage: wt ${cmd}"*) ok "wt ${cmd} with no environment prints usage" ;;
	*) bad "wt ${cmd} with no environment should print usage, got: '${result#*|}'" ;;
	esac
done

# A flag these commands do not take is refused rather than read as an environment name.
result=$(wt_stderr up --force glazing)
case ${result#*|} in
*'unknown flag for up'*) ok 'an unknown flag is refused, not taken as a name' ;;
*) bad "an unknown flag should be refused, got: '${result#*|}'" ;;
esac

# No environment at all is still the usage error it always was, not the list error.
none=$(wt_stderr merge --no-advance)
case ${none#*|} in
*'usage: wt merge'*) ok 'no environment still prints usage' ;;
*) bad "no environment should print usage, got: '${none#*|}'" ;;
esac

printf '\n'
((failures == 0)) || {
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
}
printf 'all environment argument tests passed\n'
