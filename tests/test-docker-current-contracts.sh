#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=contracts IT_NETWORK=gm-contracts-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

# 调度身份必须同时满足入口、父进程和真实及有效 UID。
test_scheduler_identity() {
    compose_scheduler_process_identity 'bash /app/git-mirror-recover.sh --repo acme/demo --sync' 'bash /app/git-mirror-scheduler.sh' 10001 10001 || return 1
    if compose_scheduler_process_identity 'bash /app/git-mirror-recover.sh --sync' 'docker-entrypoint.sh' 10001 10001; then return 1; fi
    if compose_scheduler_process_identity 'bash /app/git-mirror-recover.sh --sync-extra' 'git-mirror-scheduler.sh' 10001 10001; then return 1; fi
    if compose_scheduler_process_identity 'bash /app/git-mirror-recover.sh --sync' 'git-mirror-scheduler.sh' 10001 0; then return 1; fi
    if compose_scheduler_process_identity 'bash /app/git-mirror-recover.sh --sync' 'git-mirror-scheduler.sh' 0 10001; then return 1; fi
    return 0
}

# 成功退出与传输路径、代理计数证据不依赖已删除的展示日志。
test_proxy_success_contract() (
    fixture_exec_sync_scenario() { printf '同步传输路径：配置的 HTTPS 代理\n'; }
    fixture_record_count() { printf '2\n' > "$1"; }
    printf '1\n' > "$TEST_ROOT/proxy-baseline"
    fixture_proxy_path_succeeds || return 1
    printf '2\n' > "$TEST_ROOT/proxy-baseline"
    if fixture_proxy_path_succeeds; then return 1; fi
    return 0
)

# 同步停止辅助证据检查持久冻结及任务登记，不冒充进程回收行为证明。
test_sync_stop_contract() (
    docker() {
        local script=${!#}
        [[ $script == *'runtime/frozen'* && $script == *'runtime/task'* ]] || return 1
        bash -c "$script"
    }
    C2_MOUNT=$TEST_ROOT/stop
    mkdir -p "$C2_MOUNT/runtime"
    if c2_assert_reclaimed_log firstsync; then return 1; fi
    printf 'stopped\n' > "$C2_MOUNT/runtime/frozen"
    c2_assert_reclaimed_log firstsync && c2_assert_reclaimed_log timedsync || return 1
    printf 'registered\n' > "$C2_MOUNT/runtime/task"
    if c2_assert_reclaimed_log timedsync; then return 1; fi
    return 0
)

# 采样就绪同样必须拒绝耗尽预算后才出现的 PID1。
test_sampler_budget() (
    c2_scene_read_timeline() { sleep 2; printf 'pid=1 \n' > "$C2_TIMELINE"; }
    local started=$SECONDS status=0
    c2_scene_wait_sampler 1 || status=$?
    [[ $status != 0 && $((SECONDS-started)) -lt 4 ]]
)

check '调度入口父进程与双 UID 正反例' test_scheduler_identity
check '代理成功不依赖旧展示日志' test_proxy_success_contract
check '同步停止核对冻结与登记清理' test_sync_stop_contract
check '采样就绪拒绝过期结果' test_sampler_budget
[[ $FAILURES == 0 ]]
