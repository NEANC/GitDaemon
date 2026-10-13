#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=timeline IT_NETWORK=gm-timeline-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

# 同一帧内真实调度监督入口及其传输子孙必须被识别。
test_recovery_sync_tree() {
    cat > "$C2_TIMELINE" <<'EOF'
S 1
  pid=1 ppid=0 pgid=1 ruid=10001 euid=10001 docker-entrypoint.sh
  pid=10 ppid=1 pgid=10 ruid=10001 euid=10001 bash git-mirror-scheduler.sh
  pid=20 ppid=10 pgid=10 ruid=10001 euid=10001 bash git-mirror-recover.sh --repo acme/demo --sync
  pid=30 ppid=20 pgid=30 ruid=10001 euid=10001 git-remote-https origin https://github.com/acme/demo.git
E
EOF
    c2_timeline_has_deep_tree timedsync || return 1
    local frames
    frames=$(<"$C2_TIMELINE")
    printf '%s\n' "${frames/ppid=10 /ppid=1 }" > "$C2_TIMELINE" || return 1
    if c2_timeline_has_deep_tree timedsync; then return 1; fi
    return 0
}

check '定时同步识别 recover --sync 且拒绝首次任务冒充' test_recovery_sync_tree

# 复制消耗预算后不得再扫描或接受过期成功结果。
test_poll_wall_clock_budget() (
    c2_scene_read_timeline() { sleep 2; }
    c2_timeline_has_deep_tree() { return 0; }
    local started=$SECONDS status=0
    c2_scene_wait_tree timedsync 1 || status=$?
    [[ $status != 0 && $((SECONDS-started)) -lt 4 ]]
)

check '时间线复制耗时计入轮询墙钟预算' test_poll_wall_clock_budget

# 真实外部复制与扫描阻塞时，剩余预算必须终止等待。
test_poll_blocked_command() (
    local command=$1 started=$SECONDS status=0
    mkdir -p "$TEST_ROOT/bin" || return 1
    printf '#!/bin/sh\nexec sleep 10\n' > "$TEST_ROOT/bin/$command" || return 1
    chmod +x "$TEST_ROOT/bin/$command" || return 1
    export PATH="$TEST_ROOT/bin:$PATH"
    if [[ $command == awk ]]; then c2_scene_read_timeline() { return 0; }; fi
    c2_scene_wait_tree timedsync 1 || status=$?
    [[ $status != 0 && $((SECONDS-started)) -lt 4 ]]
)

check '阻塞 docker cp 受剩余墙钟预算限制' test_poll_blocked_command docker
check '阻塞 awk 扫描受剩余墙钟预算限制' test_poll_blocked_command awk

# 两个等待入口均须在原截止内重试复制，并拒绝复制或扫描的超期成功。
test_poll_copy_retry() (
    local waiter=$1 scenario=$2 calls=0 scans=0 status=0
    local started=$SECONDS deadline=$((SECONDS+4))
    local -a budgets=()
    sleep() { SECONDS=$((SECONDS+1)); }
    timeout() {
        local budget=$1
        shift
        [[ $budget == $((deadline-SECONDS)) && $budget -gt 0 ]] || return 97
        if [[ $1 == docker ]]; then
            calls=$((calls+1))
            budgets+=("$budget")
            [[ $2 == cp && $3 == "$C2_SAMP:$C2_SAMPLE" && $4 == "$C2_TIMELINE" ]] || return 98
            if (( calls == 1 )) || [[ $scenario == persistent ]]; then return 1; fi
            cat > "$C2_TIMELINE" <<'EOF'
S 1
  pid=1 ppid=0 pgid=1 ruid=10001 euid=10001 docker-entrypoint.sh
  pid=10 ppid=1 pgid=10 ruid=10001 euid=10001 bash git-mirror-scheduler.sh
  pid=20 ppid=10 pgid=10 ruid=10001 euid=10001 bash git-mirror-recover.sh --repo acme/demo --sync
  pid=30 ppid=20 pgid=30 ruid=10001 euid=10001 git-remote-https origin https://github.com/acme/demo.git
E
EOF
            if [[ $scenario == late_copy ]]; then SECONDS=$deadline; fi
            return 0
        fi
        scans=$((scans+1))
        if [[ $scenario == late_scan ]]; then SECONDS=$deadline; fi
        command timeout "$budget" "$@"
    }
    if [[ $waiter == tree ]]; then
        c2_scene_wait_tree timedsync 4 || status=$?
    else
        c2_scene_wait_sampler 4 || status=$?
    fi
    case "$scenario" in
        recover) [[ $status == 0 && $calls == 2 && $scans == 1 && ${budgets[*]} == '4 3' ]] ;;
        persistent) [[ $status != 0 && $calls == 4 && $scans == 0 && ${budgets[*]} == '4 3 2 1' && $SECONDS == $deadline && ! -s $C2_TIMELINE ]] ;;
        late_copy) [[ $status != 0 && $calls == 2 && $scans == 0 && $SECONDS == $deadline ]] ;;
        late_scan) [[ $status != 0 && $calls == 2 && $scans == 1 && $SECONDS == $deadline ]] ;;
    esac
)

for waiter in tree sampler; do
    check "$waiter 首次复制失败后在剩余预算内成功" test_poll_copy_retry "$waiter" recover
    check "$waiter 持续复制失败重试至原截止且不扫描" test_poll_copy_retry "$waiter" persistent
    check "$waiter 拒绝截止时才完成的复制" test_poll_copy_retry "$waiter" late_copy
    check "$waiter 拒绝截止时才完成的扫描" test_poll_copy_retry "$waiter" late_scan
done
[[ $FAILURES == 0 ]]
