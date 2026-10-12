#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/git-mirror-gc.sh"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT
FAILURES=0

# 保留真实状态、监督及 fsck，只替代安装记录准备以定位调度接口。
fixture() {
    export RUN_ROOT=$TEST_ROOT/$BASHPID INSTALL_ROOT=$ROOT/scripts TZ=UTC
    mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/repos/owner" "$RUN_ROOT/logs"
    gm_parse_repos owner/repo '' || return 1
    gm_container_lease_acquire && gm_startup_prepare || return 1
    git init -q --bare "$RUN_ROOT/repos/owner/repo.git" || return 1
    gm_begin_operation sync || return 1
    gm_startup_check_one owner/repo || return 1
    gm_lifecycle_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION" || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    gm_prepare_runtime() { gm_parse_repos owner/repo ''; GM_CONFIG[TZ]=UTC; }
}

# 环境阻塞复核使用当前配置，成功后仍然保留 GC 周期与未来下限。
test_scheduled_recovery_keeps_config() (
    fixture || return 1
    local -A calendar=()
    gm_begin_operation sync || return 1
    gm_gc_state_read owner/repo calendar || return 1
    calendar[write_blocked]=yes calendar[status]=blocked calendar[reason]=environment
    calendar[not_before]=2000000000
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    gm_recover_scheduled owner/repo || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${GM_CONFIG[TZ]-} == UTC && ${calendar[write_blocked]} == no && ${calendar[not_before]} == 2000000000 ]]
)

# 同步入口必须将真实失败返回给调度器，不能把启动流程的容错当作成功。
test_scheduled_sync_failure_status() (
    fixture || return 1
    local status=0
    gm_startup_run_repo() { [[ $2 != sync ]]; }
    gm_recover_scheduled owner/repo sync || status=$?
    [[ $status == 1 ]]
)

# 网络失败保留健康缓存，监督者不能按通用非零结果撤销已确认的发布。
test_network_failure_keeps_publication() (
    fixture || return 1
    local status=0
    local -A convergence=([schema]=1 [repo]=owner/repo [generation]=1 [desired]=present [observed]=error [published]=no [message]=configuration_pending)
    gm_state_directory_prepare "$RUN_ROOT/state/sync/owner" || return 1
    gm_state_write_array_locked "$RUN_ROOT/state/sync/owner/repo.state" convergence || return 1
    gm_task_run_locked() { local -n result=$3; result=([result]=SUCCESS); return 0; }
    gm_task_finish_locked() { local -n result=$1; result=([result]=SUCCESS [raw_status]=0); return 0; }
    gm_startup_run_repo owner/repo sync || status=$?
    [[ $status == 1 && -f $RUN_ROOT/repos/owner/repo.git/git-daemon-export-ok ]]
)

test_scheduled_existing_repo_without_state() (
    fixture || return 1
    rm "$RUN_ROOT/state/repos/owner/repo.state" || return 1
    gm_startup_run_repo() {
        [[ $2 == check ]] || return 1
        gm_begin_operation sync && gm_startup_check_one "$1" || return 1
        gm_lock_release sync && gm_lock_release instance
    }
    gm_recover_scheduled owner/repo
)

for test in test_scheduled_recovery_keeps_config test_scheduled_sync_failure_status test_network_failure_keeps_publication test_scheduled_existing_repo_without_state; do
    if "$test"; then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf 'scheduler-recovery failures=%s\n' "$FAILURES"
(( FAILURES == 0 ))
