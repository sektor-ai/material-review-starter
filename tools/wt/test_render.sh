#!/usr/bin/env bash
#
# Tests for app.env rendering — the step that points an environment at its own database and bucket.
# If any spelling of DATABASE_URL in the primary's .env survived the rewrite, the environment would
# quietly run against the primary's data, so both the rewrite and the check that backs it up are
# pinned here. No services, no git. Run it directly:
#
#   tools/wt/test_render.sh

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

MR_WT_HOME=$(mktemp -d)
export MR_WT_HOME
trap 'rm -rf "$MR_WT_HOME"' EXIT

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

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

file="$MR_WT_HOME/app.env"
readonly WANT='postgres://u:p@localhost/db_wt_x'

printf 'rewrite_env_var covers every line shape the loader accepts\n'
for shape in \
	'DATABASE_URL=postgres://primary' \
	'DATABASE_URL = postgres://primary' \
	'export DATABASE_URL=postgres://primary' \
	'  export	DATABASE_URL="postgres://primary"'; do
	printf 'A=1\n%s\nB=2\n' "$shape" >"$file"
	rewrite_env_var "$file" DATABASE_URL "$WANT"
	check_eq "A=1|DATABASE_URL=\"$WANT\"|B=2" "$(paste -sd'|' "$file")" "rewrites: ${shape}"
done

printf 'A=1\nDATABASE_URL=one\nexport DATABASE_URL=two\n' >"$file"
rewrite_env_var "$file" DATABASE_URL "$WANT"
check_eq 0 "$(grep -c primary "$file" || true)" 'every duplicate definition is rewritten'
check_eq 2 "$(grep -c "^DATABASE_URL=\"$WANT\"" "$file")" '  ...each to the new value'

printf 'A=1\n' >"$file"
rewrite_env_var "$file" DATABASE_URL "$WANT"
check_eq "DATABASE_URL=\"$WANT\"" "$(tail -n1 "$file")" 'an absent key is appended'

printf 'DATABASE_URL_REPLICA=keep\n' >"$file"
rewrite_env_var "$file" DATABASE_URL "$WANT"
check_eq 'DATABASE_URL_REPLICA=keep' "$(head -n1 "$file")" 'a key that merely starts with the name is left alone'

printf 'require_env_var refuses anything but the expected value\n'
# require_env_var dies, so each case runs in a subshell and reports its exit status.
passes() { (require_env_var "$file" DATABASE_URL "$WANT") >/dev/null 2>&1 && echo pass || echo refuse; }

printf 'DATABASE_URL="%s"\n' "$WANT" >"$file"
check_eq pass "$(passes)" 'accepts the rewritten value'
printf 'DATABASE_URL="%s"\nexport DATABASE_URL=postgres://primary\n' "$WANT" >"$file"
check_eq refuse "$(passes)" 'refuses a surviving primary definition'
printf 'A=1\n' >"$file"
check_eq refuse "$(passes)" 'refuses a missing definition'

printf '\n'
((failures == 0)) || {
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
}
printf 'all render tests passed\n'
