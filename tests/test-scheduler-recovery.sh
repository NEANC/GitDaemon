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

# 模拟取消收尾保留健康字段、标记待恢复并撤销导出的持久状态。
cancelled_fixture() {
    fixture || return 1
    local -A cancelled=()
    gm_begin_operation sync || return 1
    gm_repo_state_read owner/repo cancelled || return 1
    cancelled[observed]=error cancelled[message]=recovery_required
    gm_repo_state_commit_locked owner/repo cancelled || return 1
    gm_repo_export_remove_locked owner/repo || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    [[ ${cancelled[health]} == healthy ]]
}

# 待恢复消息必须入队并阻止同库写入，即使健康字段仍为 healthy。
test_cancelled_healthy_scan() (
    cancelled_fixture || return 1
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    gm_scheduler_queue_init
    gm_scheduler_enqueue sync owner/repo 0
    gm_scheduler_enqueue gc owner/repo 0
    gm_scheduler_scan "$(date +%s)" || return 1
    [[ ${GM_SCHEDULE_READY[recovery:owner/repo]+present} ]] || return 1
    GM_SCHEDULE_CURSOR=1
    gm_scheduler_take "$(date +%s)" || return 1
    [[ $GM_SCHEDULE_KIND == recovery && $GM_SCHEDULE_REPO == owner/repo ]]
)

# 仅替代监督调用边界，检查与发布仍执行真实状态读写及 fsck。
test_cancelled_healthy_entry() (
    cancelled_fixture || return 1
    local mode=$1 calls=
    local -A recovered=()
    gm_startup_run_repo() {
        calls+="$2 "
        if [[ $2 == sync ]]; then
            gm_repo_state_read "$1" recovered || return 1
            [[ ${recovered[message]} != recovery_required && -f $RUN_ROOT/repos/$1.git/git-daemon-export-ok ]]
            return $?
        fi
        [[ $2 == check ]] || return 1
        gm_begin_operation sync && gm_startup_check_one "$1" || return 1
        gm_lock_release sync && gm_lock_release instance
    }
    gm_recover_scheduled owner/repo "$mode" || return 1
    gm_repo_state_read owner/repo recovered || return 1
    [[ ${recovered[health]} == healthy && ${recovered[message]} == healthy && ${recovered[published]} == yes ]] || return 1
    [[ -f $RUN_ROOT/repos/owner/repo.git/git-daemon-export-ok ]] || return 1
    if [[ $mode == sync ]]; then [[ $calls == 'check sync ' ]]; else [[ $calls == 'check ' ]]; fi
)

for test in test_scheduled_recovery_keeps_config test_scheduled_sync_failure_status test_network_failure_keeps_publication test_scheduled_existing_repo_without_state test_cancelled_healthy_scan 'test_cancelled_healthy_entry recovery' 'test_cancelled_healthy_entry sync'; do
    if $test; then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf 'scheduler-recovery failures=%s\n' "$FAILURES"
(( FAILURES == 0 ))
