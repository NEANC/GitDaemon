#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CHECKS=0
FAILURES=0
if [[ -f $ROOT/scripts/lib/gc-schedule.sh ]]; then
    source "$ROOT/scripts/lib/gc-schedule.sh" || exit 1
fi

check() {
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$1"
    else
        printf '[FAIL] %s\n' "$1"
        FAILURES=$((FAILURES + 1))
    fi
}

epoch() {
    TZ=UTC date -d "$1" +%s
}

test_interfaces() {
    local name
    for name in gm_gc_init gm_gc_due gm_gc_advance gm_gc_retry gm_gc_resume; do
        declare -F "$name" >/dev/null || return 1
    done
}

test_calendar_dates() {
    local -A state=()
    local row anchor expected
    for row in '2026-01-25 2026-02-08' '2028-02-20 2028-03-05' '2026-12-25 2027-01-08'; do
        read -r anchor expected <<< "$row"
        gm_gc_init "$anchor" UTC state || return 1
        [[ ${state[anchor_date]} == "$anchor" && ${state[next_due_date]} == "$expected" && ${state[not_before]} == 0 ]] || return 1
        gm_gc_due state "$(epoch "$expected 02:00:00")" || return 1
        ! gm_gc_due state "$(epoch "$expected 01:59:59")" || return 1
    done
}

test_delayed_completion_keeps_anchor() {
    local -A state=()
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_advance state "$(epoch '2026-03-10 12:00:00')" || return 1
    [[ ${state[anchor_date]} == 2026-01-25 && ${state[next_due_date]} == 2026-03-22 && ${state[last_success_at]} == "$(epoch '2026-03-10 12:00:00')" && ${state[last_result]} == SUCCESS ]]
}

test_dst_missing_two() {
    local -A state=()
    gm_gc_init 2026-03-15 Europe/Berlin state || return 1
    ! gm_gc_due state "$(epoch '2026-03-29 00:59:59')" || return 1
    gm_gc_due state "$(epoch '2026-03-29 01:00:00')"
}

test_dst_repeated_two_uses_first() {
    local -A state=()
    gm_gc_init 2026-10-11 Europe/Berlin state || return 1
    ! gm_gc_due state "$(epoch '2026-10-24 23:59:59')" || return 1
    gm_gc_due state "$(epoch '2026-10-25 00:00:00')" || return 1
    gm_gc_advance state "$(epoch '2026-10-25 00:00:00')" || return 1
    [[ ${state[next_due_date]} == 2026-11-08 ]] || return 1
    ! gm_gc_due state "$(epoch '2026-10-25 01:00:00')"
}

test_half_hour_dst_gap() {
    local -A state=()
    gm_gc_init 2026-09-20 Australia/Lord_Howe state || return 1
    ! gm_gc_due state "$(epoch '2026-10-03 15:29:59')" || return 1
    gm_gc_due state "$(epoch '2026-10-03 15:30:00')"
}

test_retry_next_date_not_24_hours() {
    local -A state=()
    gm_gc_init 2026-03-01 Europe/Berlin state || return 1
    gm_gc_retry state "$(epoch '2026-03-28 22:30:00')" || return 1
    [[ ${state[next_due_date]} == 2026-03-15 && ${state[not_before]} == "$(epoch '2026-03-29 01:00:00')" && ${state[last_success_at]} == 0 && ${state[status]} == retry_wait ]] || return 1
    ! gm_gc_due state "$(epoch '2026-03-29 00:59:59')" || return 1
    gm_gc_due state "$(epoch '2026-03-29 01:00:00')"
}

test_resume_does_not_slide_retry() {
    local -A state=()
    local saved
    gm_gc_init 2026-01-01 UTC state || return 1
    gm_gc_retry state "$(epoch '2026-02-10 18:00:00')" || return 1
    saved=${state[not_before]}
    gm_gc_resume state "$(epoch '2026-02-10 22:00:00')" || return 1
    gm_gc_resume state "$(epoch '2026-02-11 01:59:00')" || return 1
    [[ ${state[not_before]} == "$saved" ]] || return 1
    gm_gc_resume state "$saved" || return 1
    [[ ${state[not_before]} == "$saved" ]] || return 1
    gm_gc_due state "$saved" || return 1
    gm_gc_resume state "$(epoch '2026-02-12 12:00:00')" || return 1
    [[ ${state[not_before]} == "$saved" ]]
}

test_unknown_retry_initialized_once() {
    local -A state=()
    local saved
    gm_gc_init 2026-01-01 UTC state || return 1
    state[status]=running state[last_result]=UNKNOWN
    gm_gc_resume state "$(epoch '2026-02-10 01:00:00')" || return 1
    saved=$(epoch '2026-02-11 02:00:00')
    [[ ${state[not_before]} == "$saved" && ${state[next_due_date]} == 2026-01-15 ]] || return 1
    gm_gc_resume state "$(epoch '2026-02-10 23:00:00')" || return 1
    gm_gc_resume state "$(epoch '2026-02-12 23:00:00')" || return 1
    [[ ${state[not_before]} == "$saved" && ${state[last_result]} == UNKNOWN ]]
}

test_interrupted_retry_initialized_once() {
    local -A state=()
    gm_gc_init 2026-01-01 UTC state || return 1
    state[status]=blocked state[last_result]=INTERRUPTED
    gm_gc_resume state "$(epoch '2026-02-10 01:00:00')" || return 1
    [[ ${state[not_before]} == "$(epoch '2026-02-11 02:00:00')" && ${state[status]} == blocked ]]
}

test_timezone_change_keeps_completed_cycle() {
    local -A state=()
    local saved
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_advance state "$(epoch '2026-02-08 02:00:00')" || return 1
    gm_gc_retry state "$(epoch '2026-02-22 12:00:00')" || return 1
    saved=${state[not_before]}
    state[schedule_timezone]=Asia/Tokyo
    gm_gc_resume state "$(epoch '2026-02-22 13:00:00')" || return 1
    [[ ${state[anchor_date]} == 2026-01-25 && ${state[next_due_date]} == 2026-02-22 && ${state[last_success_at]} == "$(epoch '2026-02-08 02:00:00')" && ${state[not_before]} == "$saved" ]] || return 1
    ! gm_gc_due state "$((saved - 1))" || return 1
    gm_gc_due state "$saved"
}

test_timezone_reinterprets_unfinished_date() {
    local -A state=()
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_advance state "$(epoch '2026-02-08 02:00:00')" || return 1
    state[schedule_timezone]=America/New_York
    ! gm_gc_due state "$(epoch '2026-02-22 06:59:59')" || return 1
    gm_gc_due state "$(epoch '2026-02-22 07:00:00')"
}

test_backward_clock_no_duplicate() {
    local -A state=()
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_advance state "$(epoch '2026-03-10 12:00:00')" || return 1
    gm_gc_resume state "$(epoch '2026-02-08 02:00:00')" || return 1
    [[ ${state[next_due_date]} == 2026-03-22 ]] || return 1
    ! gm_gc_due state "$(epoch '2026-02-08 02:00:00')"
}

test_forward_clock_merges_once() {
    local -A state=()
    local now
    now=$(epoch '2027-02-01 12:00:00')
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_due state "$now" || return 1
    gm_gc_advance state "$now" || return 1
    [[ ${state[next_due_date]} == 2027-02-07 ]] || return 1
    ! gm_gc_due state "$now"
}

test_clock_rolls_back_during_completion() {
    local -A state=()
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_due state "$(epoch '2026-02-08 02:00:00')" || return 1
    gm_gc_advance state "$(epoch '2026-02-08 01:59:00')" || return 1
    [[ ${state[next_due_date]} == 2026-02-22 ]] || return 1
    ! gm_gc_due state "$(epoch '2026-02-08 02:00:00')"
}

test_offline_resume_next_two_once() {
    local -A state=()
    local saved
    gm_gc_init 2026-01-01 UTC state || return 1
    gm_gc_resume state "$(epoch '2026-03-10 01:00:00')" || return 1
    saved=$(epoch '2026-03-10 02:00:00')
    [[ ${state[not_before]} == "$saved" && ${state[next_due_date]} == 2026-01-15 ]] || return 1
    gm_gc_resume state "$(epoch '2026-03-10 01:50:00')" || return 1
    [[ ${state[not_before]} == "$saved" ]] || return 1
    gm_gc_due state "$saved" || return 1
    gm_gc_resume state "$(epoch '2026-03-10 12:00:00')" || return 1
    [[ ${state[not_before]} == "$(epoch '2026-03-11 02:00:00')" ]]
}

test_retry_preserves_later_floor() {
    local -A state=()
    local saved
    gm_gc_init 2026-01-01 UTC state || return 1
    saved=$(epoch '2026-03-20 02:00:00')
    state[not_before]=$saved
    gm_gc_retry state "$(epoch '2026-03-10 23:00:00')" || return 1
    gm_gc_resume state "$(epoch '2026-03-10 23:59:00')" || return 1
    [[ ${state[not_before]} == "$saved" ]]
}

test_advance_is_strict_and_clears_retry() {
    local -A state=()
    gm_gc_init 2026-01-25 UTC state || return 1
    gm_gc_retry state "$(epoch '2026-02-08 12:00:00')" || return 1
    gm_gc_advance state "$(epoch '2026-02-22 02:00:00')" || return 1
    [[ ${state[next_due_date]} == 2026-03-08 && ${state[not_before]} == 0 && ${state[status]} == scheduled ]]
}

test_invalid_input_keeps_state() {
    local -A state=([sentinel]=unchanged)
    ! gm_gc_init 2026-02-30 UTC state 2>/dev/null || return 1
    ! gm_gc_init 2026-01-01 No/Such_Zone state || return 1
    [[ ${state[sentinel]} == unchanged ]] || return 1
    gm_gc_init 2026-01-25 UTC state || return 1
    ! gm_gc_retry state invalid || return 1
    [[ ${state[next_due_date]} == 2026-02-08 && ${state[not_before]} == 0 ]]
}

test_calculation_is_pure() {
    local -A state=()
    local snapshot
    date() {
        [[ " $* " == *' -d '* ]] || return 1
        command date "$@"
    }
    git() { return 99; }
    flock() { return 99; }
    export TZ=Pacific/Honolulu
    gm_gc_init 2026-01-25 Europe/Berlin state || return 1
    snapshot=$(declare -p state)
    gm_gc_due state "$(epoch '2026-02-08 01:00:00')" || return 1
    [[ $(declare -p state) == "$snapshot" && $TZ == Pacific/Honolulu ]] || return 1
    gm_gc_retry state "$(epoch '2026-02-08 12:00:00')" || return 1
    gm_gc_resume state "$(epoch '2026-02-08 13:00:00')" || return 1
    gm_gc_advance state "$(epoch '2026-02-09 02:00:00')"
}

for test in test_interfaces test_calendar_dates test_delayed_completion_keeps_anchor \
    test_dst_missing_two test_dst_repeated_two_uses_first test_half_hour_dst_gap \
    test_retry_next_date_not_24_hours test_resume_does_not_slide_retry \
    test_unknown_retry_initialized_once test_interrupted_retry_initialized_once \
    test_timezone_change_keeps_completed_cycle test_timezone_reinterprets_unfinished_date \
    test_backward_clock_no_duplicate test_forward_clock_merges_once test_clock_rolls_back_during_completion \
    test_offline_resume_next_two_once test_retry_preserves_later_floor \
    test_advance_is_strict_and_clears_retry test_invalid_input_keeps_state test_calculation_is_pure; do
    check "$test"
done
printf 'CHECKS=%s FAILURES=%s\n' "$CHECKS" "$FAILURES"
(( FAILURES == 0 ))
