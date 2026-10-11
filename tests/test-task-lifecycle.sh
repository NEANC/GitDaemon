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

test_unready_child_is_reaped() {
    setup unready || return 1
    local -A result=() child=()
    local before after outcome=0 pid
    setsid() {
        exec bash -c 'trap "" TERM; while :; do :; done'
    }
    start touch "$RUN_ROOT/written" && return 1
    pid=${result[wait_pid]}
    gm_process_identity "$pid" child || return 1
    gm_monotonic_ms before
    gm_task_finish_locked result || outcome=1
    gm_monotonic_ms after
    if [[ -e /proc/$pid/stat ]]; then
        kill -KILL "$pid"
        wait "$pid" 2>/dev/null || true
        return 1
    fi
    [[ $outcome == 0 && ${result[result]} == INTERRUPTED && ${result[wait_start]-} == "${child[start]}" && ! -e $RUN_ROOT/written && $((after-before)) -ge 4900 && $((after-before)) -lt 7000 ]]
}

test_unsafe_blocks_local_entries() {
    local mode
    for mode in busy write; do
        (
            setup "unsafe-$mode" || exit 1
            local -A result=() rejected=()
            local holder= status=0 instance_fd sync_fd
            start true || exit 1
            instance_fd=${GM_LOCK_FDS[instance]} sync_fd=${GM_LOCK_FDS[sync]}
            if [[ $mode == busy ]]; then
                bash -c 'source "$1"; gm_lock_acquire dispatch exclusive || exit; touch "$RUN_ROOT/held"; while [[ ! -e $RUN_ROOT/release ]]; do sleep 0.02; done' _ "$ROOT/scripts/lib/foundation.sh" & holder=$!
                until [[ -f $RUN_ROOT/held ]]; do sleep 0.02; done
            else
                gm_lifecycle_record() { return 1; }
                GM_STATE_TEST_FAULT=write
            fi
            gm_task_finish_locked result && status=1
            [[ ${result[result]} == UNSAFE && ${GM_LOCK_FDS[instance]-} == "$instance_fd" && ${GM_LOCK_FDS[sync]-} == "$sync_fd" ]] || status=1
            if [[ -n $holder ]]; then touch "$RUN_ROOT/release"; wait "$holder" || status=1; fi
            unset GM_STATE_TEST_FAULT
            gm_begin_operation sync && status=1
            [[ ${GM_LOCK_FDS[instance]-} == "$instance_fd" && ${GM_LOCK_FDS[sync]-} == "$sync_fd" ]] || status=1
            gm_task_run_locked owner/other sync rejected touch "$RUN_ROOT/written" && status=1
            if [[ ${rejected[result]} == RUNNING ]]; then gm_task_finish_locked rejected || true; fi
            [[ ! -e $RUN_ROOT/written && ${GM_LOCAL_FROZEN-} == yes ]] || status=1
            exit "$status"
        ) || return 1
    done
}

test_operation_ids_are_unique() {
    setup operationids || return 1
    local -A result=()
    local first= current record_definition round registered
    record_definition=$(declare -f gm_lifecycle_record)
    eval "${record_definition/gm_lifecycle_record/original_record}"
    gm_lifecycle_record() {
        original_record "$@" || return 1
        if [[ $1 == "$RUN_ROOT/runtime/task" ]]; then
            [[ ! -e $RUN_ROOT/written ]] || return 1
            registered=$2
        fi
        return 0
    }
    for round in 1 2; do
        registered=
        start touch "$RUN_ROOT/written" || return 1
        current=${result[operation_id]-}
        gm_task_finish_locked result || return 1
        [[ $current =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ && $registered == *" $current" && $current != "$first" ]] || return 1
        first=$current
        rm -f "$RUN_ROOT/written"
    done
}

# 验证读取超时后仍保留已消费的 UUID 前缀，且完整放行前不运行命令。
test_partial_gate_survives_timeout() {
    setup partialgate || return 1
    local -A parent=()
    local directory=$RUN_ROOT/runtime/partial child gate status=0 before now
    mkdir -m 700 "$directory" && mkfifo -m 600 "$directory/gate" || return 1
    gm_lock_acquire dispatch exclusive || return 1
    gm_process_identity "$BASHPID" parent || return 1
    exec {gate}<> "$directory/gate" || return 1
    setsid bash "$GM_LIFECYCLE_SOURCE" --worker "$directory" "${parent[pid]}" "${parent[start]}" "${GM_LOCK_FDS[container]}" "${GM_LOCK_FDS[dispatch]}" touch "$RUN_ROOT/written" & child=$!
    gm_monotonic_ms before
    until [[ -s $directory/ready ]]; do
        gm_monotonic_ms now
        if (( now-before >= 2000 )); then kill -KILL "$child"; wait "$child" 2>/dev/null; return 1; fi
        sleep 0.01
    done
    printf '%s' "${GM_BOOT_GENERATION:0:18}" >&"$gate"
    sleep 0.15
    [[ ! -e $RUN_ROOT/written ]] || status=1
    printf '%s\n' "${GM_BOOT_GENERATION:18}" >&"$gate"
    wait "$child" || status=$?
    exec {gate}>&-
    printf 'partial gate: worker=%s written=%s\n' "$status" "$([[ -f $RUN_ROOT/written ]] && printf yes || printf no)"
    [[ $status == 0 && -f $RUN_ROOT/written && $(< "$directory/status") == 0 ]]
}

test_unready_immediate_exit() {
    setup immediate || return 1
    local -A result=()
    setsid() { exit 42; }
    start touch "$RUN_ROOT/written" && return 1
    gm_task_finish_locked result || return 1
    [[ ${result[result]} == INTERRUPTED && ! -e /proc/${result[wait_pid]}/stat && ! -e $RUN_ROOT/written ]]
}

for test in test_second_container_refused test_stop_before_release_never_writes test_task_cancel_does_not_freeze test_instance_stop_blocks_resume test_delayed_grandchild_keeps_lock test_repeated_term_keeps_deadline test_nonzero_exit_is_known test_worker_does_not_inherit_lease test_registration_stop_never_releases test_unknown_wait_keeps_locks test_finish_state_failure_keeps_locks test_unreleased_worker_parent_disappears test_finished_channels_are_removed test_service_cannot_inherit_lease test_recovery_required_blocks_write test_late_term_at_journal test_late_term_at_cleanup test_unready_child_is_reaped test_unready_immediate_exit; do
    if ( "$test" ); then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
if ( test_unsafe_blocks_local_entries ); then printf '[PASS] test_unsafe_blocks_local_entries\n'; else printf '[FAIL] test_unsafe_blocks_local_entries\n'; FAILURES=$((FAILURES+1)); fi
if ( test_operation_ids_are_unique ); then printf '[PASS] test_operation_ids_are_unique\n'; else printf '[FAIL] test_operation_ids_are_unique\n'; FAILURES=$((FAILURES+1)); fi
if ( test_partial_gate_survives_timeout ); then printf '[PASS] test_partial_gate_survives_timeout\n'; else printf '[FAIL] test_partial_gate_survives_timeout\n'; FAILURES=$((FAILURES+1)); fi
printf 'FAILURES=%s\n' "$FAILURES"
exit "$FAILURES"
