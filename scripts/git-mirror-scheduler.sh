#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 调度进程状态：终止标志、当前任务子进程与其已确认的进程组 ID、当前休眠子进程，供信号处理定向回收。
GM_SCHEDULER_STOP=0
GM_SCHEDULER_CHILD=
GM_SCHEDULER_CHILD_PGID=
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
    local sample wall actual earliest local_date
    local -A offsets=()
    local -A doms=() months=() dows=()
    read -r -a fields <<< "$cron"
    [[ ${#fields[@]} == 5 ]] || return 1
    gm_validate_cron "$cron" || return 1
    # 初始日期由给定时刻的当地墙钟决定，不使用执行当天的固定偏移。
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
    local_date=$(date -d "@$now" '+%Y-%m-%d') || return 1
    start=$(TZ=UTC date -d "$local_date 00:00:00" '+%s') || return 1
    limit=$(( start + 366 * 9 * 86400 ))
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
            offsets=()
            earliest=
            # 采样候选日期前后真实偏移，回转墙钟验证以跳过缺失分钟并保留重复分钟。
            for sample in $((base - 86400)) "$base" $((base + 86400)); do
                zone=$(date -d "@$sample" '+%z') || return 1
                offset=$((10#${zone:1:2} * 3600 + 10#${zone:3:2} * 60))
                [[ ${zone:0:1} != - ]] || offset=$((-offset))
                offsets[$offset]=1
            done
            while IFS= read -r h; do
                while IFS= read -r m; do
                    wall=$((base + h * 3600 + m * 60))
                    for offset in "${!offsets[@]}"; do
                        cand=$((wall - offset))
                        ((cand > now)) || continue
                        if [[ -n $earliest ]] && ((cand >= earliest)); then continue; fi
                        actual=$(date -d "@$cand" '+%Y-%m-%d %H:%M') || return 1
                        printf -v local_date '%04d-%02d-%02d %02d:%02d' "$GM_CIVIL_YEAR" "$GM_CIVIL_MONTH" "$GM_CIVIL_DAY" "$h" "$m"
                        [[ $actual == "$local_date" ]] || continue
                        if [[ -z $earliest ]] || ((cand < earliest)); then earliest=$cand; fi
                    done
                done <<< "$minutes"
            done <<< "$hours"
            if [[ -n $earliest ]]; then printf '%s\n' "$earliest"; return 0; fi
        fi
        day=$(( day + 1 ))
    done
    gm_error 'cron 在可搜索范围内没有触发时间'
    return 1
}

# 输出当前有效配置下需要调度的任务，每行一个；ENABLE_CRON=no 时不输出任何任务。
gm_scheduler_plan() {
    if [[ ${GM_CONFIG[ENABLE_CRON]} != yes ]]; then return 0; fi
    printf '%s\n' recovery sync
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then printf '%s\n' hosts; fi
    printf '%s\n' gc
    return 0
}

# 初始化种类轮转游标与按插入顺序去重的仓库队列。
gm_scheduler_queue_init() {
    declare -ga GM_SCHEDULE_KEYS=()
    declare -gA GM_SCHEDULE_READY=()
    declare -gA GM_SCHEDULE_COOLDOWN=()
    GM_SCHEDULE_CURSOR=0
}

# 已排队条目保留原重查时刻，扫描不能缩短忙锁或故障延迟。
gm_scheduler_enqueue() {
    local key=$1:$2 ready=$3
    if (( ${GM_SCHEDULE_COOLDOWN[$key]:-0} > ready )); then ready=${GM_SCHEDULE_COOLDOWN[$key]}; fi
    if [[ ! ${GM_SCHEDULE_READY[$key]+present} ]]; then
        GM_SCHEDULE_KEYS+=("$key")
        GM_SCHEDULE_READY[$key]=$ready
    fi
    return 0
}

# 每次领取一个就绪仓库，同库恢复尚在队列时不领取写任务。
gm_scheduler_take() {
    local now=$1 step cursor kind key repo index
    local -a kinds=(recovery sync hosts gc)
    for ((step=0; step<4; step++)); do
        cursor=$(((GM_SCHEDULE_CURSOR+step)%4))
        kind=${kinds[$cursor]}
        for index in "${!GM_SCHEDULE_KEYS[@]}"; do
            key=${GM_SCHEDULE_KEYS[$index]}
            [[ $key == "$kind:"* ]] || continue
            (( ${GM_SCHEDULE_READY[$key]} <= now )) || continue
            repo=${key#*:}
            if [[ $kind == sync || $kind == gc ]]; then
                [[ ! ${GM_SCHEDULE_READY[recovery:$repo]+present} ]] || continue
            fi
            GM_SCHEDULE_KIND=$kind GM_SCHEDULE_REPO=$repo
            unset 'GM_SCHEDULE_KEYS[index]' 'GM_SCHEDULE_READY[$key]'
            GM_SCHEDULE_CURSOR=$(((cursor+1)%4))
            return 0
        done
    done
    return 1
}

# 收到终止信号时置位停止标志，并定向终止当前任务进程组与休眠子进程，不遗留子进程；
# 尚未确认独立进程组时只终止直接子进程，绝不按未经校验的 PID 推断进程组。
gm_scheduler_on_stop_signal() {
    GM_SCHEDULER_STOP=1
    if [[ -n ${GM_SCHEDULER_CHILD-} ]]; then
        if [[ -n ${GM_SCHEDULER_CHILD_PGID-} ]]; then
            kill -TERM -"$GM_SCHEDULER_CHILD_PGID" 2>/dev/null || true
        fi
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

# 读取任务子进程的真实进程组 ID：以 /proc/<pid>/stat 的 pgrp 字段为准，并要求其等于子进程自身 PID
# （setsid 后子进程自成进程组与会话组长）。返回非零表示无法确认独立进程组——此时调用方不得声称
# 已回收进程组，避免把「组从未存在」当作回收成功。
gm_scheduler_task_group() {
    local pid=$1 i stat rest pgid
    for i in $(seq 1 50); do
        [[ -r /proc/$pid/stat ]] || return 1
        stat=$(cat "/proc/$pid/stat" 2>/dev/null) || stat=
        rest=${stat##*\) }
        read -r _ _ pgid _ <<< "$rest" || pgid=
        if [[ $pgid == "$pid" ]]; then
            printf '%s\n' "$pgid"
            return 0
        fi
        sleep 0.02
    done
    return 1
}

# 等待任务进程组内全部子孙退出；边界内未回收先按组强杀再等一轮。
# 任务可能形成多层进程树，仅终止组长会让子孙滞留到容器 PID1 退出后被内核清理，
# 此函数确保子孙回收发生在调度器（及 PID1）存活期间。
# 契约：仅当调用方已确认该进程组曾真实存在（gm_scheduler_task_group 成功）时才可调用，
# 因此组消失（kill -0 -pgid 失败）即代表回收完成，而非「组从未存在」的假成功。
gm_scheduler_wait_group_gone() {
    local pgid=$1 i
    for i in $(seq 1 50); do
        kill -0 -"$pgid" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL -"$pgid" 2>/dev/null || true
    for i in $(seq 1 20); do
        kill -0 -"$pgid" 2>/dev/null || return 0
        sleep 0.1
    done
    return 1
}

# 以独立进程组运行既有交付入口；记录结果后继续，单次失败不终止调度循环；
# 收到停止信号后按组回收任务整棵进程树并等待子孙退出再返回。
# 启动时即校验真实进程组 ID（不臆断 $! 等于 PGID），未确认到进程组时明确不声称回收。
gm_scheduler_run_task() {
    local label=$1 script=$2 status=0 pgid=
    gm_scheduler_log "开始$label：$(basename -- "$script")"
    setsid "$script" &
    GM_SCHEDULER_CHILD=$!
    if pgid=$(gm_scheduler_task_group "$GM_SCHEDULER_CHILD"); then
        GM_SCHEDULER_CHILD_PGID=$pgid
    else
        pgid=
        GM_SCHEDULER_CHILD_PGID=
        gm_scheduler_log "$label 未能确认任务独立进程组，停止时仅回收直接子进程"
    fi
    wait "$GM_SCHEDULER_CHILD" || status=$?
    if (( GM_SCHEDULER_STOP != 0 )); then
        if [[ -n $pgid ]] && gm_scheduler_wait_group_gone "$pgid"; then
            gm_scheduler_log "$label 已回收进程组全部子孙"
        elif [[ -n $pgid ]]; then
            gm_scheduler_log "$label 子孙回收超时，已按组强制终止"
        else
            gm_scheduler_log "$label 停止时未能确认任务进程组，未声称回收"
        fi
        GM_SCHEDULER_CHILD=
        GM_SCHEDULER_CHILD_PGID=
        gm_scheduler_log "$label 因停止信号中断"
        return 1
    fi
    GM_SCHEDULER_CHILD=
    GM_SCHEDULER_CHILD_PGID=
    if (( status == 0 )); then
        gm_scheduler_log "$label 完成"
    else
        gm_scheduler_log "$label 失败（退出码 $status），继续下一轮"
    fi
    return "$status"
}

# 调度入口：校验实例配置后按 cron 计划运行既有同步与刷新入口；--check 只做启动前校验。
# 使用普通函数体而非子 Shell，确保信号处理与循环运行在服务跟踪的主进程内。
gm_scheduler_freeze() {
    source "$INSTALL_ROOT/lib/lifecycle.sh" || return 1
    gm_request_stop instance scheduler_stopped
    gm_task_freeze
}

# 仓库入口自身监督写入组，调度器只向监督者请求取消并等待其收尾。
gm_scheduler_run_entry() {
    local status=0
    "$@" &
    GM_SCHEDULER_CHILD=$!
    wait "$GM_SCHEDULER_CHILD" || status=$?
    if (( GM_SCHEDULER_STOP != 0 )); then
        trap '' TERM INT
        gm_scheduler_freeze || return 1
        kill -TERM "$GM_SCHEDULER_CHILD" 2>/dev/null || true
        wait "$GM_SCHEDULER_CHILD" 2>/dev/null || true
        trap gm_scheduler_on_stop_signal TERM INT
    fi
    GM_SCHEDULER_CHILD=
    return "$status"
}

# 失败只调整内存重查队列，绝不改写 GC 的持久重试下限。
gm_scheduler_dispatch() {
    local kind=$1 repo=$2 now=$3 status=0
    case $kind in
        hosts) gm_scheduler_run_task hosts "$INSTALL_ROOT/update-github-hosts.sh" || status=$? ;;
        sync) gm_scheduler_run_entry "$INSTALL_ROOT/git-mirror-recover.sh" --repo "$repo" --sync || status=$? ;;
        recovery) gm_scheduler_run_entry "$INSTALL_ROOT/git-mirror-recover.sh" --repo "$repo" || status=$? ;;
        gc) gm_scheduler_run_entry "$INSTALL_ROOT/git-mirror-gc.sh" --repo "$repo" || status=$? ;;
    esac
    (( GM_SCHEDULER_STOP == 0 )) || return 1
    now=$(date +%s) || return 1
    if [[ $kind == recovery ]]; then GM_SCHEDULE_COOLDOWN[$kind:$repo]=$((now+60)); fi
    if (( status == 75 )); then
        GM_SCHEDULE_COOLDOWN[$kind:$repo]=$((now+5))
        gm_scheduler_enqueue "$kind" "$repo" "$((now+5))"
    elif (( status != 0 )); then
        gm_scheduler_enqueue "$kind" "$repo" "$((now+60))"
    fi
    return 0
}

# 在线扫描只检查 due，不调用离线 resume；恢复条目先于同库写入。
gm_scheduler_scan() {
    local now=$1 repo
    local -A state=() gc=()
    for repo in "${GM_REPOS[@]}"; do
        if [[ ! -e $RUN_ROOT/state/repos/$repo.state ]]; then
            gm_scheduler_enqueue recovery "$repo" 0
            continue
        fi
        gm_repo_state_read "$repo" state || return 1
        if [[ ${state[health]-} != healthy || ${state[message]-} == recovery_required ]]; then gm_scheduler_enqueue recovery "$repo" 0; fi
        if [[ -e $RUN_ROOT/state/gc/$repo.state || -L $RUN_ROOT/state/gc/$repo.state ]]; then
            gm_gc_state_read "$repo" gc || return 1
            if [[ ${gc[write_blocked]} == yes || ${gc[status]} == running ]]; then
                gm_scheduler_enqueue recovery "$repo" 0
            else
                gc[schedule_timezone]=${TZ:-UTC}
                if gm_gc_due gc "$now"; then gm_scheduler_enqueue gc "$repo" 0; fi
            fi
        fi
    done
    return 0
}

gm_scheduler_main() {
    local mode=run install now next_sync next_hosts repo
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
        # 语法合法但永不触发的表达式在启动前明确失败，避免后台启动成功却立即退出。
        if [[ ${GM_CONFIG[ENABLE_CRON]} == yes ]]; then
            gm_cron_next_trigger "${GM_CONFIG[CRON_SCHEDULE]}" "$(date +%s)" >/dev/null \
                || { gm_error '配置值无法触发：CRON_SCHEDULE'; return 1; }
            if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then
                gm_cron_next_trigger "${GM_CONFIG[HOSTS_CRON]}" "$(date +%s)" >/dev/null \
                    || { gm_error '配置值无法触发：HOSTS_CRON'; return 1; }
            fi
        fi
        gm_scheduler_log '调度配置校验通过'
        return 0
    fi
    if [[ ${GM_CONFIG[ENABLE_CRON]} != yes ]]; then
        gm_scheduler_log 'ENABLE_CRON=no，调度器不执行任何后台任务'
        return 0
    fi
    gm_validate_cron "${GM_CONFIG[CRON_SCHEDULE]}" || { gm_error '配置值非法：CRON_SCHEDULE'; return 1; }
    [[ ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    trap gm_scheduler_freeze EXIT
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then
        gm_validate_cron "${GM_CONFIG[HOSTS_CRON]}" || { gm_error '配置值非法：HOSTS_CRON'; return 1; }
    fi
    trap gm_scheduler_on_stop_signal TERM INT
    source "$install/lib/repository-recovery.sh" || return 1
    gm_scheduler_queue_init
    now=$(date +%s)
    next_sync=$(gm_cron_next_trigger "${GM_CONFIG[CRON_SCHEDULE]}" "$now") || return 1
    next_hosts=
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]; then
        next_hosts=$(gm_cron_next_trigger "${GM_CONFIG[HOSTS_CRON]}" "$now") || return 1
    fi
    gm_scheduler_log "调度器启动；任务计划：$(gm_scheduler_plan | tr '\n' ' ')"
    while (( GM_SCHEDULER_STOP == 0 )); do
        now=$(date +%s)
        [[ ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
        if (( now >= next_sync )); then
            for repo in "${GM_REPOS[@]}"; do gm_scheduler_enqueue sync "$repo" 0; done
            next_sync=$(gm_cron_next_trigger "${GM_CONFIG[CRON_SCHEDULE]}" "$now") || return 1
        fi
        if [[ -n $next_hosts ]] && (( now >= next_hosts )); then
            gm_scheduler_enqueue hosts instance 0
            next_hosts=$(gm_cron_next_trigger "${GM_CONFIG[HOSTS_CRON]}" "$now") || return 1
        fi
        gm_scheduler_scan "$now" || return 1
        if gm_scheduler_take "$now"; then
            gm_scheduler_dispatch "$GM_SCHEDULE_KIND" "$GM_SCHEDULE_REPO" "$now" || break
        else
            gm_scheduler_sleep_until "$((now+1))" || break
        fi
    done
    gm_scheduler_freeze || return 1
    gm_scheduler_log '调度器收到停止信号，退出'
    return 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_scheduler_main "$@"
fi
