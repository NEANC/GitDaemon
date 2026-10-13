#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/lifecycle.sh"
source "$ROOT/docker/docker-entrypoint.sh"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# 在独立监督进程中注入重复停止与冻结失败，核对整组退出和上限。
test_hosts_stop() (
    local freeze=$1 status=0 start end timer child group
    RUN_ROOT=$TEST_ROOT/$freeze
    mkdir -p "$RUN_ROOT/runtime"
    gm_task_freeze() { GM_LOCAL_FROZEN=yes; [[ $freeze == success ]]; }
    trap on_stop_signal TERM INT
    local supervisor=$BASHPID
    (sleep 0.4; kill -TERM "$supervisor"; sleep 0.2; kill -TERM "$supervisor") & timer=$!
    gm_monotonic_ms start
    run_task_best_effort hosts bash -c 'trap "" TERM INT; printf "%s\n" "$BASHPID" > "$1/pid"; sleep 60 & printf "%s\n" "$!" > "$1/child"; wait' _ "$RUN_ROOT" || status=$?
    gm_monotonic_ms end
    wait "$timer" || true
    child=$(cat "$RUN_ROOT/child")
    group=$(cat "$RUN_ROOT/pid")
    local alive=0
    gm_task_group_alive "$group" "$group" || alive=$?
    if (( alive != 1 )); then kill -KILL -- "-$group" 2>/dev/null || true; fi
    printf 'hosts freeze=%s status=%s elapsed=%s group_alive=%s\n' "$freeze" "$status" "$((end-start))" "$alive"
    [[ $alive == 1 && $((end-start)) -lt 8500 ]] || return 1
    if [[ $freeze == success ]]; then [[ $status == 130 ]]; else [[ $status == 1 ]]; fi
)

# 直接子进程正常退出不代表其后台子孙已退出。
test_hosts_orphan() (
    RUN_ROOT=$TEST_ROOT/orphan
    mkdir -p "$RUN_ROOT/runtime"
    gm_task_freeze() { GM_LOCAL_FROZEN=yes; return 0; }
    local status=0 group alive=0
    run_task_best_effort hosts bash -c 'printf "%s\n" "$BASHPID" > "$1/pid"; (trap "" TERM INT; sleep 60) & sleep 0.2; exit 0' _ "$RUN_ROOT" || status=$?
    group=$(cat "$RUN_ROOT/pid")
    gm_task_group_alive "$group" "$group" || alive=$?
    if (( alive != 1 )); then kill -KILL -- "-$group" 2>/dev/null || true; fi
    printf 'hosts orphan status=%s group_alive=%s\n' "$status" "$alive"
    [[ $alive == 1 && $status == 1 ]]
)

# 无法确认组身份时不得放行业务，也不得用等待 PID 猜测组号。
test_hosts_unconfirmed() (
    RUN_ROOT=$TEST_ROOT/unconfirmed
    mkdir -p "$RUN_ROOT/runtime"
    gm_task_freeze() { GM_LOCAL_FROZEN=yes; return 0; }
    task_process_group() { sleep 0.2; return 1; }
    local status=0
    run_task_best_effort hosts bash -c 'printf written > "$1/written"; sleep 60' _ "$RUN_ROOT" || status=$?
    [[ $status == 1 && ! -e $RUN_ROOT/written ]]
)

# 在停止判断通过后的指令边界注入真实信号，避免随机延时掩盖丢唤醒。
test_hosts_wait_boundary() (
    local signal=$1 armed=no injected=no signaled=0 frozen=0 status=0
    RUN_ROOT=$TEST_ROOT/boundary-$signal
    mkdir -p "$RUN_ROOT/runtime"
    gm_task_freeze() { GM_LOCAL_FROZEN=yes; gm_monotonic_ms frozen; }
    trap on_stop_signal TERM INT
    inject_boundary() {
        if [[ $armed == yes && $injected == no ]]; then
            injected=yes
            while [[ ! -e $RUN_ROOT/ready ]]; do sleep 0.01; done
            gm_monotonic_ms signaled
            kill -"$signal" "$BASHPID"
        elif [[ -n $GM_ENTRYPOINT_TASK && $BASH_COMMAND == '[[ $GM_ENTRYPOINT_STOP == 0 ]]' ]]; then
            armed=yes
        fi
        return 0
    }
    set -T
    trap inject_boundary DEBUG
    run_task_best_effort hosts bash -c 'trap "exit 0" TERM INT; printf ready > "$1/ready"; for ((i=0;i<100;i++)); do sleep 0.05; done; printf expired > "$1/expired"' _ "$RUN_ROOT" || status=$?
    trap - DEBUG
    printf 'hosts boundary=%s injected=%s freeze_ms=%s status=%s\n' "$signal" "$injected" "$((frozen-signaled))" "$status"
    [[ $injected == yes && $status == 130 && $frozen -ge $signaled && $((frozen-signaled)) -lt 1000 && ! -e $RUN_ROOT/expired && -z $GM_ENTRYPOINT_TASK ]]
)

failures=0
for signal in TERM INT; do
    test_hosts_wait_boundary "$signal" || failures=$((failures+1))
done
for mode in success failure; do
    test_hosts_stop "$mode" || failures=$((failures+1))
done
test_hosts_orphan || failures=$((failures+1))
test_hosts_unconfirmed || failures=$((failures+1))
printf 'hosts 生命周期失败：%s\n' "$failures"
[[ $failures == 0 ]]
