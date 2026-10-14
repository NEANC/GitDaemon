#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT

# 在 STOP 判断已通过、GO 写入尚未执行的父进程指令边界注入真实信号。
test_gate_boundary() (
    local signal=$1 owner=$BASHPID injected=no yielded=no status=0 alive=0 group=
    source "$ROOT/scripts/lib/lifecycle.sh"
    source "$ROOT/docker/docker-entrypoint.sh"
    RUN_ROOT=$WORK/$signal
    mkdir -p "$RUN_ROOT/runtime"
    gm_task_freeze() { GM_LOCAL_FROZEN=yes; return 0; }
    trap on_stop_signal TERM INT
    inject() {
        if [[ $BASHPID != "$owner" ]]; then return 0; fi
        if [[ $injected == no && $BASH_COMMAND == printf* && $BASH_COMMAND == *'>&"$gate"'* ]]; then
            injected=yes
            group=$GM_ENTRYPOINT_TASK_PGID
            if [[ $signal != none ]]; then kill -"$signal" "$BASHPID"; fi
        elif [[ $injected == yes && $yielded == no && $BASH_COMMAND == 'exec {gate}>&-' ]]; then
            yielded=yes
            sleep 0.2
        fi
        return 0
    }
    set -T
    trap inject DEBUG
    run_task_best_effort hosts bash -c 'printf written > "$1/written"' _ "$RUN_ROOT" || status=$?
    trap - DEBUG
    gm_task_group_alive "$group" "$group" || alive=$?
    printf 'entry gate signal=%s injected=%s status=%s written=%s alive=%s\n' "$signal" "$injected" "$status" "$([[ -e $RUN_ROOT/written ]] && printf yes || printf no)" "$alive"
    [[ $injected == yes && $yielded == yes && $alive == 1 && -z $GM_ENTRYPOINT_TASK ]] || return 1
    if [[ $signal == none ]]; then [[ $status == 0 && -e $RUN_ROOT/written ]];
    else [[ $status == 130 && ! -e $RUN_ROOT/written ]]; fi
)

failures=0
for signal in none TERM INT; do
    test_gate_boundary "$signal" || failures=$((failures+1))
done
printf 'entry hosts gate failures=%s\n' "$failures"
[[ $failures == 0 ]]
