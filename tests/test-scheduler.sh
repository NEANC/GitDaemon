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
    [[ $(gm_scheduler_plan) == $'sync\nhosts' ]] || return 1
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=no
    [[ $(gm_scheduler_plan) == sync ]] || return 1
    return 0
}

# 验证调度器复用既有交付入口，不含自建同步、下载或第二套锁实现。
scheduler_reuses_entrypoints() {
    local script=$ROOT/scripts/git-mirror-scheduler.sh
    grep -Fq 'git-mirror-sync.sh' "$script" || { printf '未复用同步入口\n'; return 1; }
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

check 'cron 表达式接受合法形式' cron_accepts
check 'cron 表达式拒绝非法形式' cron_rejects
check 'cron 单字段匹配（通配/数值/列表/范围/步进/星期）' cron_field_matches
check 'cron N/step 从起点展开到字段上限' cron_step_start_expansion
check 'cron 下次触发时间（分钟/小时边界）' cron_next_trigger_basic
check 'cron 下次触发时间（跨月/跨年/闰日/星期或语义）' cron_next_trigger_calendar
check 'cron N/step 下次触发时间' cron_next_trigger_step_start
check 'cron 非法表达式不参与触发计算' cron_next_trigger_rejects
check '调度开关决定任务集合（ENABLE_CRON/ENABLE_HOSTS_UPDATE）' scheduler_switches
check '调度器复用既有同步与刷新入口且不新建锁' scheduler_reuses_entrypoints
check '调度服务定义指向调度脚本并可解析' scheduler_service_definition
check '调度入口 --help 不读取运行配置' scheduler_help
printf '用户态调度检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
