#!/usr/bin/env bash
set -uo pipefail
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/task-lifecycle.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
source "$ROOT/scripts/lib/foundation.sh"
if [[ -f $ROOT/scripts/lib/lifecycle.sh ]]; then source "$ROOT/scripts/lib/lifecycle.sh"; fi
FAILURES=0

setup() {
    RUN_ROOT=$TEST_ROOT/$1
    mkdir -m 700 -p "$RUN_ROOT/runtime" || return 1
    export RUN_ROOT
    gm_container_lease_acquire && gm_container_begin
}

start() {
    gm_begin_operation sync || return $?
    gm_task_run_locked owner/repo sync result "$@"
}

test_second_container_refused() {
    setup second || return 1
    local status=0
    bash -c 'source "$1"; gm_container_lease_acquire' _ "$ROOT/scripts/lib/lifecycle.sh" || status=$?
    [[ $status == 75 ]]
}

test_stop_before_release_never_writes() {
    setup before || return 1
    local -A result=()
    gm_request_stop task cancel || return 1
    start touch "$RUN_ROOT/written" && return 1
    gm_task_finish_locked result || return 1
    [[ ! -e $RUN_ROOT/written && ${result[result]} == INTERRUPTED ]]
}

test_task_cancel_does_not_freeze() {
    setup cancel || return 1
    local -A result=() state=()
    start bash -c 'sleep 30' || return 1
    gm_request_stop task cancel || return 1
    gm_task_finish_locked result || return 1
    [[ ${result[result]} == INTERRUPTED && ! -e $RUN_ROOT/runtime/frozen ]] || return 1
    gm_repo_state_read owner/repo state || return 1
    [[ ${state[message]} == recovery_required ]] || return 1
    gm_begin_operation sync && gm_task_run_locked owner/other sync result true && gm_task_finish_locked result && [[ ${result[result]} == SUCCESS ]]
}

test_instance_stop_blocks_resume() {
    setup freeze || return 1
    local -A result=()
    start sleep 30 || return 1
    gm_request_stop instance shutdown || return 1
    gm_task_finish_locked result || return 1
    [[ -f $RUN_ROOT/runtime/frozen ]] || return 1
    gm_resume_instance "$RUN_ROOT" /nonexistent >/dev/null 2>&1 && return 1
    gm_begin_operation sync && return 1
    bash -c 'source "$1"; gm_container_begin' _ "$ROOT/scripts/lib/lifecycle.sh" && return 1
    [[ -f $RUN_ROOT/runtime/frozen ]]
}

test_delayed_grandchild_keeps_lock() {
    setup grandchild || return 1
    local -A result=()
    local status=0
    start bash -c 'bash -c '\''trap "" TERM; sleep 2; printf done > "$1"'\'' _ "$1" & exit 0' _ "$RUN_ROOT/done" || return 1
    sleep 0.2
    bash -c 'source "$1"; gm_lock_acquire sync exclusive' _ "$ROOT/scripts/lib/foundation.sh" || status=$?
    [[ $status == 75 ]] || return 1
    gm_task_finish_locked result || return 1
    [[ -f $RUN_ROOT/done && ${result[result]} == SUCCESS ]] || return 1
    bash -c 'source "$1"; gm_lock_acquire sync exclusive' _ "$ROOT/scripts/lib/foundation.sh"
}

test_repeated_term_keeps_deadline() {
    setup deadline || return 1
    local -A result=()
    local before after sender
    start bash -c 'trap "" TERM; printf ready > "$1"; while :; do sleep 1; done' _ "$RUN_ROOT/ready" || return 1
    until [[ -f $RUN_ROOT/ready ]]; do sleep 0.02; done
    trap 'gm_request_stop task term' TERM
    local supervisor=$BASHPID
    (sleep 1; kill -TERM "$supervisor"; sleep 1; kill -TERM "$supervisor") & sender=$!
    gm_monotonic_ms before
    gm_request_stop task term
    gm_task_finish_locked result || return 1
    gm_monotonic_ms after
    wait "$sender" || return 1
    [[ ${result[result]} == INTERRUPTED && $((after-before)) -ge 4900 && $((after-before)) -lt 7000 ]]
}

test_nonzero_exit_is_known() {
    setup nonzero || return 1
    local -A result=()
    start bash -c 'exit 127' || return 1
    gm_task_finish_locked result || return 1
    [[ ${result[result]} == RECOVERY_REQUIRED && ${result[raw_status]} == 127 && ! -e $RUN_ROOT/runtime/frozen ]]
}

test_worker_does_not_inherit_lease() {
    setup fd || return 1
    local -A result=()
    start bash -c 'for fd in /proc/$$/fd/*; do readlink "$fd"; done > "$1"' _ "$RUN_ROOT/fds" || return 1
    gm_task_finish_locked result || return 1
    ! grep -q 'container.lock\|dispatch.lock' "$RUN_ROOT/fds" || return 1
    grep -q 'sync.lock' "$RUN_ROOT/fds"
}

test_registration_stop_never_releases() {
    setup registration || return 1
    local -A result=()
    gm_lifecycle_record() {
        if [[ $1 == "$RUN_ROOT/runtime/task" ]]; then gm_request_stop task cancel; fi
        printf '%s\n' "$2" > "$1"
    }
    start touch "$RUN_ROOT/written" && return 1
    gm_task_finish_locked result || return 1
    [[ ! -e $RUN_ROOT/written && ${result[result]} == INTERRUPTED && ! -e $RUN_ROOT/runtime/frozen ]]
}

test_unknown_wait_keeps_locks() {
    setup unknown || return 1
    local -A result=()
    start true || return 1
    wait "${result[wait_pid]}" || return 1
    result[wait_pid]=99999999
    gm_task_finish_locked result 2>/dev/null && return 1
    [[ ${result[result]} == UNSAFE && -e $RUN_ROOT/runtime/frozen && -n ${GM_LOCK_FDS[sync]-} ]]
}

test_finish_state_failure_keeps_locks() {
    setup statefailure || return 1
    local -A result=()
    start true || return 1
    GM_STATE_TEST_FAULT=write
    gm_task_finish_locked result && return 1
    [[ ${result[result]} == UNSAFE && -e $RUN_ROOT/runtime/frozen && -n ${GM_LOCK_FDS[sync]-} ]]
}

test_unreleased_worker_parent_disappears() {
    setup orphan || return 1
    local directory=$RUN_ROOT/runtime/orphan child status=0
    mkdir -m 700 "$directory" && mkfifo -m 600 "$directory/gate" || return 1
    gm_lock_acquire dispatch exclusive || return 1
    setsid bash "$ROOT/scripts/lib/lifecycle.sh" --worker "$directory" 99999999 1 "${GM_LOCK_FDS[container]}" "${GM_LOCK_FDS[dispatch]}" touch "$RUN_ROOT/written" & child=$!
    wait "$child" || status=$?
    [[ $status != 0 && ! -e $RUN_ROOT/written ]]
}

test_finished_channels_are_removed() {
    setup channels || return 1
    local -A result=()
    start true || return 1
    gm_task_finish_locked result || return 1
    [[ ! -e ${result[directory]} && ! -e $RUN_ROOT/runtime/task ]]
}

test_service_cannot_inherit_lease() {
    setup servicefd || return 1
    gm_without_container_lease bash -c 'for fd in /proc/$$/fd/*; do readlink "$fd" || true; done' > "$RUN_ROOT/fds" || return 1
    ! grep -q container.lock "$RUN_ROOT/fds"
}

test_recovery_required_blocks_write() {
    setup eligibility || return 1
    local -A result=() state=([schema]=1 [repo]=owner/repo [generation]=1 [desired]=present [observed]=error [published]=no [message]=recovery_required)
    gm_repo_state_commit_locked owner/repo state || return 1
    start touch "$RUN_ROOT/written" && return 1
    gm_task_finish_locked result || return 1
    [[ ${result[result]} == RECOVERY_REQUIRED && ! -e $RUN_ROOT/written ]]
}

test_late_term_at_journal() {
    setup latejournal || return 1
    local -A result=()
    start true || return 1
    trap 'gm_request_stop instance late_term' TERM
    local journal_definition
    journal_definition=$(declare -f gm_task_journal)
    eval "${journal_definition/gm_task_journal/original_journal}"
    gm_task_journal() {
        original_journal "$@" || return 1
        kill -TERM "$BASHPID"
    }
    gm_task_finish_locked result || return 1
    [[ ${GM_STOP_SCOPE-} == instance && -f $RUN_ROOT/runtime/frozen ]] || return 1
    gm_begin_operation sync && return 1
    return 0
}

test_late_term_at_cleanup() {
    setup latecleanup || return 1
    local -A result=()
    start true || return 1
    trap 'gm_request_stop instance late_term' TERM
    rmdir() {
        command rmdir "$@" || return 1
        kill -TERM "$BASHPID"
    }
    gm_task_finish_locked result || return 1
    [[ ${GM_STOP_SCOPE-} == instance && -f $RUN_ROOT/runtime/frozen ]] || return 1
    gm_begin_operation sync && return 1
    return 0
}

for test in test_second_container_refused test_stop_before_release_never_writes test_task_cancel_does_not_freeze test_instance_stop_blocks_resume test_delayed_grandchild_keeps_lock test_repeated_term_keeps_deadline test_nonzero_exit_is_known test_worker_does_not_inherit_lease test_registration_stop_never_releases test_unknown_wait_keeps_locks test_finish_state_failure_keeps_locks test_unreleased_worker_parent_disappears test_finished_channels_are_removed test_service_cannot_inherit_lease test_recovery_required_blocks_write test_late_term_at_journal test_late_term_at_cleanup; do
    if ( "$test" ); then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf 'FAILURES=%s\n' "$FAILURES"
exit "$FAILURES"
