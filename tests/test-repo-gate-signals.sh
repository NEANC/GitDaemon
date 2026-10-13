#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT

# 在末次停止检查后的放行指令前发送真实信号，验证无业务写入。
test_gate_signal() (
    local signal=$1 injected=no injection_pid=$BASHPID status=0
    source "$ROOT/scripts/lib/lifecycle.sh"
    RUN_ROOT=$WORK/$signal
    export RUN_ROOT
    mkdir -p "$RUN_ROOT/runtime"
    gm_container_lease_acquire && gm_container_begin && gm_begin_operation sync || return 1
    local -A result=()
    trap 'gm_request_stop instance gate_signal' TERM INT
    inject() {
        if [[ $BASHPID == "$injection_pid" && $injected == no && $BASH_COMMAND == printf* && $BASH_COMMAND == *'>&"$gate"'* ]]; then
            injected=yes
            kill -"$signal" "$BASHPID"
        fi
        return 0
    }
    set -T
    trap inject DEBUG
    gm_task_run_locked owner/repo sync result bash -c 'printf written > "$RUN_ROOT/written"' || status=$?
    trap - DEBUG
    sleep 0.2
    gm_task_finish_locked result || status=$?
    printf 'repo gate signal=%s injected=%s written=%s result=%s\n' "$signal" "$injected" "$([[ -e $RUN_ROOT/written ]] && printf yes || printf no)" "${result[result]}"
    [[ $injected == yes && ! -e $RUN_ROOT/written && ${result[result]} == INTERRUPTED && -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/task ]]
)

failures=0
for signal in TERM INT; do
    test_gate_signal "$signal" || failures=$((failures+1))
done
printf 'repo gate signal failures=%s\n' "$failures"
[[ $failures == 0 ]]
