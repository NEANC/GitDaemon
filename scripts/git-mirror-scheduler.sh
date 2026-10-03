#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 调度进程状态：终止标志、当前任务子进程与休眠子进程，供信号处理定向回收。
GM_SCHEDULER_STOP=0
GM_SCHEDULER_CHILD=
GM_SCHEDULER_SLEEP_CHILD=

# 记录调度消息并同时输出到终端与实例调度日志。
gm_scheduler_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$SCHEDULER_LOG_FILE"; }

# 将单个 cron 字段展开为取值集合，写入 GM_CRON_SET[value]=1；
# 仅接受数值、范围、列表和步进；星期日字段范围 0-7，同时登记 value%7 以统一 0 与 7。
gm_cron_expand() {
    local field=$1 minimum=$2 maximum=$3
    local part base step start end value
    local -a parts=()
    declare -gA GM_CRON_SET=()
    IFS=, read -r -a parts <<< "$field"
    for part in "${parts[@]}"; do
        step=1
        base=$part
        if [[ $part == */* ]]; then
            base=${part%%/*}
            step=${part#*/}
        fi
        if [[ $base == '*' ]]; then
            start=$minimum
            end=$maximum
        elif [[ $base == *-* ]]; then
            start=$(( 10#${base%%-*} ))
            end=$(( 10#${base#*-} ))
        else
            start=$(( 10#$base ))
            end=$start
            # N/step 语义：从 N 起按 step 递增到字段上限，等价 N-max/step。
            if [[ $part == */* ]]; then end=$maximum; fi
        fi
        for (( value = start; value <= end; value += 10#$step )); do
            GM_CRON_SET[$value]=1
            if (( maximum == 7 )); then
                GM_CRON_SET[$(( value % 7 ))]=1
            fi
        done
    done
    return 0
}

# 判断单个 cron 字段在给定取值下是否匹配，供解析断言与计划计算使用。
gm_cron_matches() {
    local field=$1 minimum=$2 maximum=$3 value=$4
    gm_cron_expand "$field" "$minimum" "$maximum" || return 1
    [[ ${GM_CRON_SET[$value]+present} ]]
}

# 将 1970-01-01 起的公历天数转换为年月日，写入 GM_CIVIL_YEAR/MONTH/DAY。
gm_civil_from_days() {
    local z=$(( $1 + 719468 ))
    local era=$(( (z >= 0 ? z : z - 146096) / 146097 ))
    local doe=$(( z - era * 146097 ))
    local yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    local year=$(( yoe + era * 400 ))
    local doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    local mp=$(( (5 * doy + 2) / 153 ))
    local day=$(( doy - (153 * mp + 2) / 5 + 1 ))
    local month=$(( mp + (mp < 10 ? 3 : -9) ))
    GM_CIVIL_YEAR=$(( year + (month <= 2 ? 1 : 0) ))
    GM_CIVIL_MONTH=$month
    GM_CIVIL_DAY=$day
    return 0
}

# 计算严格晚于给定时刻的下一次五字段 cron 触发时间（epoch 秒），字段按当前 TZ 解释；
# 月、日、星期、时、分逐级匹配，日期按公历天数推进以支持跨日跨月。
gm_cron_next_trigger() {
    local cron=$1 now=$2
    local -a fields=()
    local zone sign offset start limit day last dow base day_ok minutes hours k h m cand
    local -A doms=() months=() dows=()
    read -r -a fields <<< "$cron"
    [[ ${#fields[@]} == 5 ]] || return 1
    gm_validate_cron "$cron" || return 1
    zone=$(date '+%z') || return 1
    sign=${zone:0:1}
    offset=$(( 10#${zone:1:2} * 3600 + 10#${zone:3:2} * 60 ))
    if [[ $sign == - ]]; then offset=$(( -offset )); fi
    gm_cron_expand "${fields[0]}" 0 59 || return 1
    minutes=$(printf '%s\n' "${!GM_CRON_SET[@]}" | sort -n)
    gm_cron_expand "${fields[1]}" 0 23 || return 1
    hours=$(printf '%s\n' "${!GM_CRON_SET[@]}" | sort -n)
    gm_cron_expand "${fields[2]}" 1 31 || return 1
    for k in "${!GM_CRON_SET[@]}"; do doms[$k]=1; done
    gm_cron_expand "${fields[3]}" 1 12 || return 1
    for k in "${!GM_CRON_SET[@]}"; do months[$k]=1; done
    gm_cron_expand "${fields[4]}" 0 7 || return 1
    for k in "${!GM_CRON_SET[@]}"; do dows[$k]=1; done
    local dom_restricted=no dow_restricted=no
    if [[ ${fields[2]} != '*' ]]; then dom_restricted=yes; fi
    if [[ ${fields[4]} != '*' ]]; then dow_restricted=yes; fi
    start=$(( now + offset ))
    start=$(( start - start % 60 + 60 ))
    limit=$(( start + 1830 * 86400 ))
    day=$(( start / 86400 ))
    last=$(( limit / 86400 ))
    while (( day <= last )); do
        gm_civil_from_days "$day"
        dow=$(( (day % 7 + 11) % 7 ))
        day_ok=no
        if [[ $dom_restricted == yes && $dow_restricted == yes ]]; then
            if [[ ${doms[$GM_CIVIL_DAY]+present} || ${dows[$dow]+present} ]]; then day_ok=yes; fi
        elif [[ $dom_restricted == yes ]]; then
            if [[ ${doms[$GM_CIVIL_DAY]+present} ]]; then day_ok=yes; fi
        elif [[ $dow_restricted == yes ]]; then
            if [[ ${dows[$dow]+present} ]]; then day_ok=yes; fi
        else
            day_ok=yes
        fi
        if [[ $day_ok == yes && ${months[$GM_CIVIL_MONTH]+present} ]]; then
            base=$(( day * 86400 ))
            while IFS= read -r h; do
                while IFS= read -r m; do
                    cand=$(( base + h * 3600 + m * 60 ))
                    if (( cand >= start )); then
                        printf '%s\n' $(( cand - offset ))
                        return 0
                    fi
                done <<< "$minutes"
            done <<< "$hours"
        fi
        day=$(( day + 1 ))
    done
    gm_error 'cron 在可搜索范围内没有触发时间'
    return 1
}

# 输出当前有效配置下需要调度的任务，每行一个；ENABLE_CRON=no 时不输出任何任务。
gm_scheduler_plan() {
    if [[ ${GM_CONFIG[ENABLE_CRON]} != yes ]]; then return 0; fi
    printf '%s\n' sync
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then printf '%s\n' hosts; fi
    return 0
}

# 收到终止信号时置位停止标志，并定向终止当前任务进程组与休眠子进程，不遗留子进程。
gm_scheduler_on_stop_signal() {
    GM_SCHEDULER_STOP=1
    if [[ -n ${GM_SCHEDULER_CHILD-} ]]; then
        kill -TERM -"$GM_SCHEDULER_CHILD" 2>/dev/null || true
        kill -TERM "$GM_SCHEDULER_CHILD" 2>/dev/null || true
    fi
    if [[ -n ${GM_SCHEDULER_SLEEP_CHILD-} ]]; then
        kill -TERM "$GM_SCHEDULER_SLEEP_CHILD" 2>/dev/null || true
    fi
    return 0
}

# 短周期休眠到目标 epoch；收到停止信号立即返回非零，不因长休眠拖延停止。
gm_scheduler_sleep_until() {
    local target=$1
    while :; do
        if (( GM_SCHEDULER_STOP != 0 )); then return 1; fi
        if (( $(date +%s) >= target )); then return 0; fi
        sleep 1 &
        GM_SCHEDULER_SLEEP_CHILD=$!
        wait "$GM_SCHEDULER_SLEEP_CHILD" 2>/dev/null || true
        GM_SCHEDULER_SLEEP_CHILD=
    done
}

# 以独立进程组运行既有交付入口；记录结果后继续，单次失败不终止调度循环。
gm_scheduler_run_task() {
    local label=$1 script=$2 status=0
    gm_scheduler_log "开始$label：$(basename -- "$script")"
    setsid "$script" &
    GM_SCHEDULER_CHILD=$!
    wait "$GM_SCHEDULER_CHILD" || status=$?
    GM_SCHEDULER_CHILD=
    if (( GM_SCHEDULER_STOP != 0 )); then
        gm_scheduler_log "$label 因停止信号中断"
        return 1
    fi
    if (( status == 0 )); then
        gm_scheduler_log "$label 完成"
    else
        gm_scheduler_log "$label 失败（退出码 $status），继续下一轮"
    fi
    return 0
}

# 调度入口：校验实例配置后按 cron 计划运行既有同步与刷新入口；--check 只做启动前校验。
# 使用普通函数体而非子 Shell，确保信号处理与循环运行在服务跟踪的主进程内。
gm_scheduler_main() {
    local mode=run install now next next_sync next_hosts
    case "${1-}" in
        --help|-h)
            printf '%s\n' '用法：git-mirror-scheduler.sh [--check]；运行配置来自 RUN_ROOT/config/mirror.env'
            return 0 ;;
        --check) mode=check ;;
        '') ;;
        *) gm_error '调度入口不接受此参数'; return 2 ;;
    esac
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    SCHEDULER_LOG_FILE=$RUN_ROOT/logs/scheduler.log
    if [[ $mode == check ]]; then
        gm_scheduler_log '调度配置校验通过'
        return 0
    fi
    if [[ ${GM_CONFIG[ENABLE_CRON]} != yes ]]; then
        gm_scheduler_log 'ENABLE_CRON=no，调度器不执行任何后台任务'
        return 0
    fi
    gm_validate_cron "${GM_CONFIG[CRON_SCHEDULE]}" || { gm_error '配置值非法：CRON_SCHEDULE'; return 1; }
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then
        gm_validate_cron "${GM_CONFIG[HOSTS_CRON]}" || { gm_error '配置值非法：HOSTS_CRON'; return 1; }
    fi
    trap gm_scheduler_on_stop_signal TERM INT
    gm_scheduler_log "调度器启动；任务计划：$(gm_scheduler_plan | tr '\n' ' ')"
    while (( GM_SCHEDULER_STOP == 0 )); do
        now=$(date +%s)
        next_sync=$(gm_cron_next_trigger "${GM_CONFIG[CRON_SCHEDULE]}" "$now") || return 1
        next=$next_sync
        next_hosts=
        if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then
            next_hosts=$(gm_cron_next_trigger "${GM_CONFIG[HOSTS_CRON]}" "$now") || return 1
            if (( next_hosts < next )); then next=$next_hosts; fi
        fi
        if ! gm_scheduler_sleep_until "$next"; then break; fi
        now=$(date +%s)
        if [[ -n $next_hosts ]] && (( now >= next_hosts )); then
            gm_scheduler_run_task '地址刷新' "$INSTALL_ROOT/update-github-hosts.sh"
        fi
        if (( now >= next_sync )); then
            gm_scheduler_run_task '仓库同步' "$INSTALL_ROOT/git-mirror-sync.sh"
        fi
    done
    gm_scheduler_log '调度器收到停止信号，退出'
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_scheduler_main "$@"
fi
