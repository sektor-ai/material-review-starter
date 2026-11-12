#!/usr/bin/env bash
#
# Tests for `wt`'s slot allocation — the one piece of the tool with a concurrency invariant: two
# environments must never share a slot, because a slot is a set of ports — and for the resolution of
# the state root the slots are recorded in, which is what makes the rest of this file safe to run.
#
# It runs against a throwaway MR_WT_HOME, so it touches neither the real state directory nor any
# cloud resource: no git, no database, no process-compose. Run it directly:
#
#   tools/wt/test_slots.sh
#
# The concurrency case is the regression test for the race that would put two environments on one slot:
# without the slot lock and reservations, parallel creates all scan the same unwritten state and pick
# the same lowest free slot.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR

# How many creates the concurrency case races against each other, and how long each one pretends to
# spend on the git and database work that separates its allocation from its state_write. The window has to
# be wide enough that every racer is inside it at once — that is precisely the race being tested.
readonly RACERS=5
readonly WORK_SECONDS=1

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

# record_env fakes a finished environment holding a slot, the way `wt create` leaves one behind.
record_env() {
	local slug=$1 slot=$2
	state_write "$slug" "/nonexistent/$slug" "test/$slug" "$slot" "db_wt_$slug" "documents-wt-$slug"
}

# reset_state empties the state root between cases, so each starts from no environments and no locks.
reset_state() {
	rm -rf "${MR_WT_HOME:?}"/* "${MR_WT_HOME:?}"/.slot.lock "${MR_WT_HOME:?}"/.slots
	mkdir -p "$MR_WT_HOME"
}

# dead_pid prints the pid of a process that has certainly exited — the owner of a stale lock or
# reservation, without having to guess a number that no live process happens to hold.
dead_pid() {
	sleep 0 &
	local pid=$!
	wait "$pid"
	printf '%s\n' "$pid"
}

printf 'state root resolution\n'
# wt.sh sources wt.env, which assigns MR_WT_HOME plainly — so it used to overwrite an override the
# caller had exported, and a run meant for a throwaway directory silently hit the user's real state
# root instead. `wt.sh help` is enough to exercise the resolution: it sources everything, then prints
# usage. The decoy wt.env stands in for the real one.
decoy_env="$MR_WT_HOME/decoy.wt.env"
decoy_home="$MR_WT_HOME/decoy-home"
printf 'MR_WT_HOME=%s\n' "$decoy_home" >"$decoy_env"

resolved_root() { MR_WT_ENV_FILE="$decoy_env" bash -c 'source "$1/wt.sh" help >/dev/null 2>&1; printf "%s\n" "$WT_STATE_ROOT"' -- "$SCRIPT_DIR"; }

# This harness exports MR_WT_HOME, so the no-override case has to unset it explicitly.
check_eq "$decoy_home" "$(unset MR_WT_HOME && resolved_root)" 'wt.env sets the state root when the environment does not'
check_eq "$MR_WT_HOME" "$(resolved_root)" 'an exported MR_WT_HOME overrides wt.env'
rm -f "$decoy_env"

printf 'sequential allocation\n'
reset_state
for i in 1 2 3; do
	slot=$(slot_reserve_next "seq-$i")
	check_eq "$i" "$slot" "create ${i} takes slot ${i}"
	record_env "seq-$i" "$slot"
	slot_release "$slot"
done
check_eq 'false' "$([[ -d $MR_WT_HOME/.slot.lock ]] && echo true || echo false)" 'the lock is released'

printf 'freed slots are reused\n'
reset_state
record_env keep-1 1
record_env drop-2 2
record_env keep-3 3
state_remove drop-2
check_eq 2 "$(slot_reserve_next refill)" 'the freed slot is handed out again'

printf 'reservations hold a slot before env.json exists\n'
reset_state
reserved=$(slot_reserve_next holder)
check_eq 1 "$reserved" 'the first create reserves slot 1'
check_eq 'in use' "$(slot_in_use 1 && echo 'in use' || echo free)" 'the reserved slot reads as in use'
check_eq 2 "$(slot_reserve_next follower)" 'the next create skips it, without any env.json'
slot_release "$reserved"
check_eq 'free' "$(slot_in_use 1 && echo 'in use' || echo free)" 'releasing returns the slot to the pool'

printf 'stale state does not burn a slot\n'
reset_state
mkdir -p "$MR_WT_HOME/.slots"
printf '%s crashed\n' "$(dead_pid)" >"$MR_WT_HOME/.slots/1"
check_eq 'free' "$(slot_in_use 1 && echo 'in use' || echo free)" 'a reservation whose owner died is ignored'

reset_state
mkdir -p "$MR_WT_HOME/.slot.lock"
printf '%s\n' "$(dead_pid)" >"$MR_WT_HOME/.slot.lock/owner"
check_eq 1 "$(slot_reserve_next after-crash 2>/dev/null)" 'a lock whose owner died is reclaimed'

printf 'concurrent creates get distinct slots\n'
reset_state
# Each racer is its own process, exactly as two `wt create`s in two terminals are: reserve a slot, take
# WORK_SECONDS over the work that in the real thing is git and the database, only then write env.json.
cat >"$MR_WT_HOME/racer.sh" <<'RACER'
set -euo pipefail
source "$1/lib/common.sh"
source "$1/lib/state.sh"
slug=$2
slot=$(slot_reserve_next "$slug")
sleep "$3"
state_write "$slug" "/nonexistent/$slug" "test/$slug" "$slot" "db_wt_$slug" "documents-wt-$slug"
slot_release "$slot"
RACER
for i in $(seq 1 "$RACERS"); do
	bash "$MR_WT_HOME/racer.sh" "$SCRIPT_DIR" "race-$i" "$WORK_SECONDS" &
done
wait

slots=$(for i in $(seq 1 "$RACERS"); do state_get "race-$i" '.slot'; done | sort -n | tr '\n' ' ')
distinct=$(printf '%s' "$slots" | tr ' ' '\n' | sort -u | grep -c .)
check_eq "$RACERS" "$distinct" "${RACERS} concurrent creates got ${RACERS} distinct slots (got: ${slots})"
check_eq 'false' "$([[ -d $MR_WT_HOME/.slot.lock ]] && echo true || echo false)" 'the lock is released'

printf '\n'
((failures == 0)) || {
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
}
printf 'all slot allocation tests passed\n'
