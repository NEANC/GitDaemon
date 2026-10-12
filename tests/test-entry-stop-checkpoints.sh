#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/git-mirror-recover.sh"
source "$ROOT/docker/docker-entrypoint.sh"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# 使用真实 TERM 在每个编排边界登记停止，后续阶段不得被调用。
test_entry_checkpoint() (
    local boundary=$1
    RUN_ROOT=$TEST_ROOT/$boundary INSTALL_ROOT=$ROOT/scripts
    mkdir -p "$RUN_ROOT/runtime"
    source() { return 0; }
    require_non_root() { return 0; }
    prepare_environment() { return 0; }
    gm_validate_path() { return 0; }
    gm_container_lease_acquire() { return 0; }
    shutdown_services() { return 0; }
    gm_task_freeze() { : > "$RUN_ROOT/frozen"; return 0; }
    visit() {
        [[ $GM_ENTRYPOINT_STOP == 0 ]] || { : > "$RUN_ROOT/after-stop"; return 1; }
        if [[ $1 == "$boundary" ]]; then kill -TERM "$BASHPID"; fi
        return 0
    }
    gm_without_container_lease() {
        if [[ $1 == *deploy-git-mirror.sh ]]; then visit init; else visit "start-$3"; fi
    }
    gm_prepare_runtime() { visit runtime; }
    gm_startup_prepare() { visit prepare; }
    reset_stale_service_state() { visit "reset-$1"; }
    confirm_daemon_listening() { visit listening; }
    gm_recover_main() { visit checks; }
    run_task_best_effort() { visit hosts; }
    gm_startup_network() { visit network; }
    scheduler_enabled() { visit scheduler-enabled; }
    supervise_loop() { visit supervise; }
    main || true
    [[ -f $RUN_ROOT/frozen && ! -e $RUN_ROOT/after-stop ]]
)

failures=0
for boundary in init runtime prepare reset-git-daemon start-git-daemon listening checks hosts network scheduler-enabled reset-git-mirror-scheduler start-git-mirror-scheduler; do
    if test_entry_checkpoint "$boundary"; then printf '[PASS] %s\n' "$boundary"; else printf '[FAIL] %s\n' "$boundary"; failures=$((failures+1)); fi
done
printf '入口停止检查点失败：%s\n' "$failures"
[[ $failures == 0 ]]
