#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/foundation.sh"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# 拒绝必须发生在准备环境、停止服务和加锁之前，包含不存在的实例。
test_resume_no_effects() (
    local mode=$1 run=$TEST_ROOT/$1 output status=0
    if [[ $mode != absent ]]; then
        mkdir -p "$run/runtime"
        printf 'STOPPED=1\n' > "$run/runtime/stopped"
        if [[ $mode == frozen ]]; then printf 'FROZEN=1\n' > "$run/runtime/frozen"; fi
    fi
    gm_prepare_runtime() { : > "$TEST_ROOT/effect-$mode"; return 0; }
    gm_load_service_capabilities() { GM_SCHEDULER_CAPABILITY=present; }
    gm_stop_instance_service() { : > "$TEST_ROOT/effect-$mode"; return 0; }
    gm_lock_acquire() { : > "$TEST_ROOT/effect-$mode"; return 0; }
    output=$(gm_resume_instance "$run" "$ROOT/scripts" 2>&1) || status=$?
    [[ $status == 1 && ! -e $TEST_ROOT/effect-$mode ]] || return 1
    if [[ $mode == absent ]]; then [[ ! -e $run ]]; else [[ $(cat "$run/runtime/stopped") == STOPPED=1 ]]; fi
)

failures=0
for mode in absent stopped frozen; do
    if test_resume_no_effects "$mode"; then printf '[PASS] %s\n' "$mode"; else printf '[FAIL] %s\n' "$mode"; failures=$((failures+1)); fi
done
[[ $failures == 0 ]]
