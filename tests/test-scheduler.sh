#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FAILURES=0
CHECKS=0
source "$ROOT/scripts/git-mirror-scheduler.sh"

# 每个用例在独立子 Shell 中运行，避免全局集合与配置数组互相污染。
check() {
    local label=$1
    shift
    if [[ -n ${TEST_FILTER-} && $label != *"$TEST_FILTER"* ]]; then return 0; fi
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 缺少约定接口时返回明确失败，而不是调用不存在的命令。
require_function() {
    if ! declare -F "$1" >/dev/null; then
        printf '缺少调度接口：%s\n' "$1"
        return 1
    fi
}

# 验证合法五字段表达式被接受，且单字段展开命中预期取值。
cron_accepts() {
    require_function gm_validate_cron || return 1
    local expression
    for expression in '* * * * *' '0 * * * *' '0 3 * * *' '*/15 * * * *' '0 */2 * * *' \
        '5,10,15 * * * *' '0-30 1-5 * * *' '10-40/10 * * * *' '0 0 1,15 * *' '0 0 * * 0-7'; do
        gm_validate_cron "$expression" || { printf '合法表达式被拒绝：%s\n' "$expression"; return 1; }
    done
}

# 验证非法表达式在解析阶段明确失败，不静默接受。
cron_rejects() {
    require_function gm_validate_cron || return 1
    local expression
    for expression in '' '* * * *' '* * * * * *' '60 * * * *' '* 24 * * *' '* * 0 * *' \
        '* * 32 * *' '* * * 13 *' '* * * * 8' '*/0 * * * *' '5-1 * * * *' ',5 * * * *' \
        '5, * * * *' '5,,6 * * * *' 'a * * * *' '1-* * * *' '*/x * * * *'; do
        if gm_validate_cron "$expression"; then
            printf '非法表达式被接受：%s\n' "$expression"
            return 1
        fi
    done
}

# 验证单字段匹配覆盖通配、数值、列表、范围、步进与星期 0/7 等价。
cron_field_matches() {
    require_function gm_cron_matches || return 1
    gm_cron_matches '*' 0 59 37 || return 1
    gm_cron_matches '*' 0 59 0 || return 1
    gm_cron_matches '5' 0 59 5 || return 1
    if gm_cron_matches '5' 0 59 6; then return 1; fi
    gm_cron_matches '1,5,10' 0 59 5 || return 1
    if gm_cron_matches '1,5,10' 0 59 7; then return 1; fi
    gm_cron_matches '10-20' 0 59 10 || return 1
    gm_cron_matches '10-20' 0 59 20 || return 1
    if gm_cron_matches '10-20' 0 59 9; then return 1; fi
    if gm_cron_matches '10-20' 0 59 21; then return 1; fi
    gm_cron_matches '*/15' 0 59 0 || return 1
    gm_cron_matches '*/15' 0 59 30 || return 1
    if gm_cron_matches '*/15' 0 59 31; then return 1; fi
    gm_cron_matches '10-40/10' 0 59 30 || return 1
    gm_cron_matches '10-40/10' 0 59 20 || return 1
    if gm_cron_matches '10-40/10' 0 59 35; then return 1; fi
    gm_cron_matches '7' 0 7 0 || return 1
    gm_cron_matches '0' 0 7 0 || return 1
    if gm_cron_matches '1-5' 0 7 6; then return 1; fi
    return 0
}

# 在固定 TZ 下验证下次触发时间：分钟边界、逐时、同日与跨日。
cron_next_trigger_basic() {
    require_function gm_cron_next_trigger || return 1
    export TZ=UTC
    [[ $(gm_cron_next_trigger '* * * * *' 0) == 60 ]] || return 1
    [[ $(gm_cron_next_trigger '0 * * * *' 0) == 3600 ]] || return 1
    [[ $(gm_cron_next_trigger '0 * * * *' 3599) == 3600 ]] || return 1
    [[ $(gm_cron_next_trigger '0 * * * *' 3600) == 7200 ]] || return 1
    [[ $(gm_cron_next_trigger '0 3 * * *' 0) == 10800 ]] || return 1
    [[ $(gm_cron_next_trigger '0 3 * * *' 10800) == 97200 ]] || return 1
    [[ $(gm_cron_next_trigger '30 23 * * *' 0) == 84600 ]] || return 1
    [[ $(gm_cron_next_trigger '*/15 * * * *' 0) == 900 ]] || return 1
    [[ $(gm_cron_next_trigger '10-40/10 * * * *' 0) == 600 ]] || return 1
    return 0
}

# 验证跨月、跨年与闰日的触发计算。
cron_next_trigger_calendar() {
    require_function gm_cron_next_trigger || return 1
    export TZ=UTC
    [[ $(gm_cron_next_trigger '0 0 1 * *' 0) == 2678400 ]] || return 1
    [[ $(gm_cron_next_trigger '0 0 1 * *' 2678400) == 5097600 ]] || return 1
    [[ $(gm_cron_next_trigger '0 0 1 1 *' 0) == 31536000 ]] || return 1
    [[ $(gm_cron_next_trigger '0 0 29 2 *' 0) == 68169600 ]] || return 1
    [[ $(gm_cron_next_trigger '0 0 * * 0' 0) == 259200 ]] || return 1
    # 日与星期同时受限时按任一匹配：1970-01-02 00:00 为星期五。
    [[ $(gm_cron_next_trigger '0 0 13 * 5' 0) == 86400 ]] || return 1
    return 0
}

# 验证非法表达式在下次触发计算中明确失败。
cron_next_trigger_rejects() {
    require_function gm_cron_next_trigger || return 1
    export TZ=UTC
    local expression status=0
    for expression in '* * * *' '60 * * * *' '5-1 * * * *'; do
        status=0
        gm_cron_next_trigger "$expression" 0 >/dev/null 2>&1 || status=$?
        [[ $status == 1 ]] || { printf '非法表达式未失败：%s，status=%s\n' "$expression" "$status"; return 1; }
    done
    return 0
}

# 验证 ENABLE_CRON 与 ENABLE_HOSTS_UPDATE 开关决定被调度的任务集合。
scheduler_switches() {
    require_function gm_scheduler_plan || return 1
    declare -A GM_CONFIG=()
    GM_CONFIG[ENABLE_CRON]=no
    [[ -z $(gm_scheduler_plan) ]] || return 1
    GM_CONFIG[ENABLE_CRON]=yes
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    [[ $(gm_scheduler_plan) == $'recovery\nsync\nhosts\ngc' ]] || return 1
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=no
    [[ $(gm_scheduler_plan) == $'recovery\nsync\ngc' ]] || return 1
    return 0
}

# 验证调度器复用既有交付入口，不含自建同步、下载或第二套锁实现。
scheduler_reuses_entrypoints() {
    local script=$ROOT/scripts/git-mirror-scheduler.sh
    grep -Fq 'git-mirror-recover.sh" --repo "$repo" --sync' "$script" || { printf '未复用受监督同步入口\n'; return 1; }
    grep -Fq '/git-mirror-sync.sh' "$ROOT/scripts/git-mirror-recover.sh" || return 1
    grep -Fq 'update-github-hosts.sh' "$script" || { printf '未复用刷新入口\n'; return 1; }
    if grep -Eq 'git (fetch|init|remote|update-ref)|http\.curloptResolve|gm_hosts_download|curl ' "$script"; then
        printf '调度器不应自建同步或下载逻辑\n'
        return 1
    fi
    if grep -Eq 'gm_lock_acquire|\.lock' "$script"; then
        printf '调度器不应新建第二套锁\n'
        return 1
    fi
    return 0
}

# 验证调度服务定义指向调度脚本、使用实例运行目录并具备启动前校验。
scheduler_service_definition() {
    local service=$ROOT/scripts/openrc/git-mirror-scheduler
    grep -Fq '/sbin/openrc-run' "$service" || return 1
    grep -Fq 'git-mirror-scheduler.sh' "$service" || return 1
    grep -Fq 'XDG_RUNTIME_DIR' "$service" || return 1
    grep -Fq 'git-mirror-scheduler.pid' "$service" || return 1
    grep -Fq 'start_pre' "$service" || return 1
    command -v sh >/dev/null 2>&1 || return 1
    sh -n "$service"
}

# 验证 --help 不读取运行配置即可返回用法。
scheduler_help() {
    local output status=0
    output=$(gm_scheduler_main --help 2>&1) || status=$?
    [[ $status == 0 && $output == *'git-mirror-scheduler.sh'* ]]
}

# 验证 N/step 从起点 N 按步进递增到字段上限，与 */step、a-b/step 语义一致，且受各字段上限约束。
cron_step_start_expansion() {
    require_function gm_cron_matches || return 1
    gm_cron_matches '0/15' 0 59 0 || return 1
    gm_cron_matches '0/15' 0 59 15 || return 1
    gm_cron_matches '0/15' 0 59 30 || return 1
    gm_cron_matches '0/15' 0 59 45 || return 1
    if gm_cron_matches '0/15' 0 59 1; then return 1; fi
    gm_cron_matches '5/15' 0 59 5 || return 1
    gm_cron_matches '5/15' 0 59 50 || return 1
    if gm_cron_matches '5/15' 0 59 0; then return 1; fi
    local value
    for value in 0 15 30 45; do gm_cron_matches '*/15' 0 59 "$value" || return 1; done
    for value in 0 15 30 45; do gm_cron_matches '0-59/15' 0 59 "$value" || return 1; done
    # 小时字段上限 23：0/2 -> 0,2,...,22，不含 23。
    gm_cron_matches '0/2' 0 23 22 || return 1
    if gm_cron_matches '0/2' 0 23 23; then return 1; fi
    # 日期字段上限 31，起点 1：1/2 -> 1,3,...,31，不含 30。
    gm_cron_matches '1/2' 1 31 31 || return 1
    if gm_cron_matches '1/2' 1 31 30; then return 1; fi
    # 月份字段上限 12：1/3 -> 1,4,7,10，不含 11。
    gm_cron_matches '1/3' 1 12 10 || return 1
    if gm_cron_matches '1/3' 1 12 11; then return 1; fi
    # 星期字段上限 7：0/2 -> 0,2,4,6。
    gm_cron_matches '0/2' 0 7 6 || return 1
    if gm_cron_matches '0/2' 0 7 1; then return 1; fi
    return 0
}

# 验证 N/step 的下次触发时间符合标准语义。
cron_next_trigger_step_start() {
    require_function gm_cron_next_trigger || return 1
    export TZ=UTC
    [[ $(gm_cron_next_trigger '0/15 * * * *' 0) == 900 ]] || return 1
    [[ $(gm_cron_next_trigger '0/15 * * * *' 900) == 1800 ]] || return 1
    [[ $(gm_cron_next_trigger '5/15 * * * *' 0) == 300 ]] || return 1
    return 0
}

# 验证任务执行中收到停止信号后，本轮另一个到期任务不再被启动。
scheduler_stop_suppresses_due_task() {
    require_function gm_scheduler_main || return 1
    local work marker pid index content
    work=$(mktemp -d "$ROOT/.scheduler-test.XXXXXX") || return 1
    marker=$work/marker
    mkdir -p "$work/run/logs" "$work/install"
    : > "$marker"
    # 桩入口：刷新任务记录后长眠，同步任务仅记录，便于观察停止后是否仍被启动。
    printf '#!/usr/bin/env bash\necho hosts >> %q\nexec sleep 30\n' "$marker" > "$work/install/update-github-hosts.sh"
    printf '#!/usr/bin/env bash\necho sync >> %q\n' "$marker" > "$work/install/git-mirror-sync.sh"
    chmod +x "$work/install/update-github-hosts.sh" "$work/install/git-mirror-sync.sh"
    export RUN_ROOT=$work/run
    STUB_INSTALL=$work/install
    # 仅替换运行时准备与 cron 计算，进程组使用真实 setsid。
    gm_prepare_runtime() {
        INSTALL_ROOT=$STUB_INSTALL
        declare -gA GM_CONFIG=([ENABLE_CRON]=yes [ENABLE_HOSTS_UPDATE]=yes [CRON_SCHEDULE]='* * * * *' [HOSTS_CRON]='* * * * *')
        return 0
    }
    gm_cron_next_trigger() { printf '1\n'; }
    gm_scheduler_main >/dev/null 2>&1 &
    pid=$!
    for (( index = 0; index < 200; index++ )); do
        [[ -s $marker ]] && break
        sleep 0.05
    done
    kill -TERM "$pid" 2>/dev/null || true
    for (( index = 0; index < 100; index++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    content=$(cat "$marker")
    rm -rf "$work"
    [[ $content == hosts ]]
}

# 验证任务以独立进程组运行：停止信号按组回收多层子孙（任务脚本与其派生的长眠孙进程都被终止），
# 且停止后不再派发新任务。仅终止组长会让孙进程滞留，故该用例是进程组回收的回归守卫。
scheduler_stop_reclaims_task_group() {
    require_function gm_scheduler_main || return 1
    local work marker pid gpid index content alive=no
    work=$(mktemp -d "$ROOT/.scheduler-group.XXXXXX") || return 1
    marker=$work/marker
    mkdir -p "$work/run/logs" "$work/install"
    : > "$marker"
    # 桩任务：登记后派生一个长眠孙进程再等待；脚本经 setsid 成为独立进程组的组长。
    printf '#!/usr/bin/env bash\necho hosts >> %q\nsleep 300 &\necho $! > %q\nwait\n' \
        "$marker" "$work/grandchild" > "$work/install/update-github-hosts.sh"
    printf '#!/usr/bin/env bash\necho sync >> %q\n' "$marker" > "$work/install/git-mirror-sync.sh"
    chmod +x "$work/install/update-github-hosts.sh" "$work/install/git-mirror-sync.sh"
    export RUN_ROOT=$work/run
    STUB_INSTALL=$work/install
    gm_prepare_runtime() {
        INSTALL_ROOT=$STUB_INSTALL
        declare -gA GM_CONFIG=([ENABLE_CRON]=yes [ENABLE_HOSTS_UPDATE]=yes [CRON_SCHEDULE]='* * * * *' [HOSTS_CRON]='* * * * *')
        return 0
    }
    gm_cron_next_trigger() { printf '1\n'; }
    gm_scheduler_main >/dev/null 2>&1 &
    pid=$!
    for (( index = 0; index < 200; index++ )); do
        [[ -s $work/grandchild ]] && break
        sleep 0.05
    done
    gpid=$(cat "$work/grandchild" 2>/dev/null) || gpid=
    if [[ ! $gpid =~ ^[0-9]+$ ]] || ! kill -0 "$gpid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        rm -rf "$work"
        printf '未观察到任务派生的孙进程\n'
        return 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for (( index = 0; index < 100; index++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.05
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    # 孙进程必须随进程组一起被回收，且不再有第二个任务被启动。
    for (( index = 0; index < 60; index++ )); do
        if kill -0 "$gpid" 2>/dev/null; then alive=yes; else alive=no; break; fi
        sleep 0.05
    done
    content=$(cat "$marker")
    if [[ $alive == yes ]]; then kill -KILL "$gpid" 2>/dev/null || true; fi
    rm -rf "$work"
    [[ $alive == no && $content == hosts ]]
}

# 验证语法合法但永不触发的表达式在启动前校验中明确失败，而合法表达式仍通过。
scheduler_check_rejects_never_triggering() {
    require_function gm_scheduler_main || return 1
    local work status=0
    work=$(mktemp -d "$ROOT/.scheduler-check.XXXXXX") || return 1
    mkdir -p "$work/run/logs"
    export RUN_ROOT=$work/run
    gm_prepare_runtime() {
        declare -gA GM_CONFIG=([ENABLE_CRON]=yes [ENABLE_HOSTS_UPDATE]=no [CRON_SCHEDULE]='0 0 31 2 *' [HOSTS_CRON]='* * * * *')
        return 0
    }
    gm_scheduler_main --check >/dev/null 2>&1 || status=$?
    if [[ $status == 0 ]]; then rm -rf "$work"; return 1; fi
    gm_prepare_runtime() {
        declare -gA GM_CONFIG=([ENABLE_CRON]=yes [ENABLE_HOSTS_UPDATE]=no [CRON_SCHEDULE]='0/15 * * * *' [HOSTS_CRON]='* * * * *')
        return 0
    }
    gm_scheduler_main --check >/dev/null 2>&1 || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    return 0
}

# 连续到期的同步逐库让出机会，同种类同仓库只排队一次。
test_gc_fair_after_sync() {
    require_function gm_scheduler_enqueue || return 1
    require_function gm_scheduler_take || return 1
    gm_scheduler_queue_init
    gm_scheduler_enqueue sync a/one 0
    gm_scheduler_enqueue sync a/two 0
    gm_scheduler_enqueue sync a/one 0
    gm_scheduler_enqueue gc a/one 0
    gm_scheduler_take 100 || return 1
    [[ $GM_SCHEDULE_KIND == sync && $GM_SCHEDULE_REPO == a/one ]] || return 1
    gm_scheduler_take 100 || return 1
    [[ $GM_SCHEDULE_KIND == gc ]] || return 1
    gm_scheduler_take 100 || return 1
    [[ $GM_SCHEDULE_KIND == sync && $GM_SCHEDULE_REPO == a/two ]] || return 1
    ! gm_scheduler_take 100
}

# 恢复等待期间阻止同库写入，不阻止其他仓库与 hosts。
test_recovery_before_same_repo_write() {
    require_function gm_scheduler_enqueue || return 1
    gm_scheduler_queue_init
    gm_scheduler_enqueue sync a/one 0
    gm_scheduler_enqueue gc a/one 0
    gm_scheduler_enqueue recovery a/one 160
    gm_scheduler_enqueue sync a/two 0
    gm_scheduler_enqueue hosts instance 0
    gm_scheduler_take 100 || return 1
    [[ $GM_SCHEDULE_KIND == sync && $GM_SCHEDULE_REPO == a/two ]] || return 1
    gm_scheduler_take 100 || return 1
    [[ $GM_SCHEDULE_KIND == hosts ]] || return 1
    ! gm_scheduler_take 159 || return 1
    gm_scheduler_take 160 || return 1
    [[ $GM_SCHEDULE_KIND == recovery && $GM_SCHEDULE_REPO == a/one ]]
}

# 禁用自动计划时没有 GC，启用时必须登记恢复与 GC。
test_enable_cron_no_disables_gc() {
    declare -A GM_CONFIG=([ENABLE_CRON]=no [ENABLE_HOSTS_UPDATE]=yes)
    [[ -z $(gm_scheduler_plan) ]] || return 1
    GM_CONFIG[ENABLE_CRON]=yes
    [[ $(gm_scheduler_plan) == $'recovery\nsync\nhosts\ngc' ]]
}

# 派发返回忙锁按五秒重排，故障按六十秒重排且扫描不滑动下限。
test_scheduler_retry_bounds() {
    require_function gm_scheduler_dispatch || return 1
    gm_scheduler_queue_init
    INSTALL_ROOT=/fixture
    GM_SCHEDULER_STOP=0
    gm_scheduler_run_entry() { return 75; }
    date() { printf '100\n'; }
    gm_scheduler_dispatch gc a/one 100
    [[ ${GM_SCHEDULE_READY[gc:a/one]} == 105 ]] || return 1
    gm_scheduler_enqueue gc a/one 0
    [[ ${GM_SCHEDULE_READY[gc:a/one]} == 105 ]] || return 1
    gm_scheduler_run_entry() { return 1; }
    gm_scheduler_dispatch recovery a/two 100
    [[ ${GM_SCHEDULE_READY[recovery:a/two]} == 160 ]]
}

# 再次扫描发现持续阻塞时不能绕过上次完成后的六十秒复查间隔。
test_recovery_recheck_after_completion() {
    gm_scheduler_queue_init
    GM_SCHEDULER_STOP=0 INSTALL_ROOT=/fixture
    gm_scheduler_run_entry() { return 0; }
    date() { printf '100\n'; }
    gm_scheduler_dispatch recovery a/one 100 || return 1
    gm_scheduler_enqueue recovery a/one 0
    ! gm_scheduler_take 159 || return 1
    gm_scheduler_take 160
}

# 长任务的失败重查以下次可派发时刻为基准，不使用过期的开始时间。
test_retry_uses_completion_time() {
    gm_scheduler_queue_init
    GM_SCHEDULER_STOP=0 INSTALL_ROOT=/fixture
    gm_scheduler_run_entry() { return 1; }
    date() { printf '500\n'; }
    gm_scheduler_dispatch recovery a/one 100 || return 1
    [[ ${GM_SCHEDULE_READY[recovery:a/one]} == 560 ]]
}

# 在线扫描使用持久 due，保留未来下限并让恢复阻塞同库 GC。
test_online_scan_preserves_not_before() (
    source "$ROOT/scripts/lib/repository-recovery.sh"
    local work now
    work=$(mktemp -d) || return 1
    trap 'rm -rf "$work"' EXIT
    RUN_ROOT=$work
    mkdir -p "$work/state/repos/a" "$work/state/gc/a"
    printf fixture > "$work/state/repos/a/one.state"
    printf fixture > "$work/state/gc/a/one.state"
    GM_REPOS=(a/one)
    gm_repo_state_read() { local -n target=$2; target=([health]=healthy); }
    gm_gc_state_read() { local -n target=$2; target=([write_blocked]=no [status]=scheduled [schedule_timezone]=UTC [next_due_date]=2026-01-01 [not_before]=200); }
    gm_gc_due() { local -n target=$1; (( $2 >= target[not_before] )); }
    gm_gc_resume() { return 99; }
    gm_scheduler_queue_init
    gm_scheduler_scan 100 || return 1
    ! gm_scheduler_take 100 || return 1
    gm_scheduler_scan 200 || return 1
    gm_scheduler_take 200 || return 1
    [[ $GM_SCHEDULE_KIND == gc && $GM_SCHEDULE_REPO == a/one ]]
)

check 'test_online_scan_preserves_not_before' test_online_scan_preserves_not_before
check 'test_retry_uses_completion_time' test_retry_uses_completion_time
check 'test_recovery_recheck_after_completion' test_recovery_recheck_after_completion
check 'test_scheduler_retry_bounds' test_scheduler_retry_bounds
check 'test_gc_fair_after_sync' test_gc_fair_after_sync
check 'test_recovery_before_same_repo_write' test_recovery_before_same_repo_write
check 'test_enable_cron_no_disables_gc' test_enable_cron_no_disables_gc
check 'cron 表达式接受合法形式' cron_accepts
check 'cron 表达式拒绝非法形式' cron_rejects
check 'cron 单字段匹配（通配/数值/列表/范围/步进/星期）' cron_field_matches
check 'cron N/step 从起点展开到字段上限' cron_step_start_expansion
check 'cron 下次触发时间（分钟/小时边界）' cron_next_trigger_basic
check 'cron 下次触发时间（跨月/跨年/闰日/星期或语义）' cron_next_trigger_calendar
check 'cron N/step 下次触发时间' cron_next_trigger_step_start
check 'cron 非法表达式不参与触发计算' cron_next_trigger_rejects
check '调度开关决定任务集合（ENABLE_CRON/ENABLE_HOSTS_UPDATE）' scheduler_switches
check '调度停止后不再启动当轮到期任务' scheduler_stop_suppresses_due_task
check '调度任务按进程组回收多层子孙且停止后不再派发' scheduler_stop_reclaims_task_group
check '调度启动前校验拦截永不触发的表达式' scheduler_check_rejects_never_triggering
check '调度器复用既有同步与刷新入口且不新建锁' scheduler_reuses_entrypoints
check '调度服务定义指向调度脚本并可解析' scheduler_service_definition
check '调度入口 --help 不读取运行配置' scheduler_help
printf '用户态调度检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
