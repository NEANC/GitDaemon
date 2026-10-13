#!/bin/bash

# 容器前台入口：以非 root 身份完成命名卷内实例初始化，启动常驻服务并监督生命周期。
# 同步与地址刷新算法全部复用交付脚本，入口只负责编排、前台存活、信号转发与子进程回收。
# 首次任务以独立进程组（setsid）运行，停止信号按组终止整棵进程树并等待子孙退出，
# 使回收发生在 PID1 存活期间，而不依赖 PID1 退出后的内核清理。
# 计划中的入口逻辑说明：一次性工作服务（git-mirror-sync / git-mirror-hosts）经 rc-service 运行后
# 状态会显示 crashed（退出 32），属既有语义，因此入口只对常驻服务使用 OpenRC 状态，绝不据一次性
# 工作服务的状态判断成功；跨容器残留运行状态先以 zap 复位再启动，并以真实监听确认存活，
# 不把持久化 PID 或卷内残留的“已启动”状态当作存活服务。

set -uo pipefail

# 程序层与运行根的默认绝对路径；容器环境变量可覆盖，仍必须指向只读程序层与命名卷运行根。
INSTALL_ROOT=${INSTALL_ROOT:-/usr/local/lib/git-mirror}
RUN_ROOT=${RUN_ROOT:-/var/lib/git-daemon}

# 入口状态：停止标志、当前首次任务子进程与其已确认的进程组 ID、当前休眠子进程。
GM_ENTRYPOINT_STOP=0
GM_ENTRYPOINT_TASK=
GM_ENTRYPOINT_TASK_PGID=
GM_ENTRYPOINT_SLEEP=

# 输出不带凭据的入口日志。
log() {
    printf '[git-daemon] %s\n' "$*"
    return 0
}

# 输出诊断并立即失败退出。
die() {
    printf '[git-daemon] %s\n' "$*" >&2
    exit 1
}

# 拒绝实际或有效 UID 0；容器进程必须以相同且非零的 UID 运行。
require_non_root() {
    local actual effective
    actual=$(id -ru) || die '无法读取真实 UID'
    effective=$(id -u) || die '无法读取有效 UID'
    if [[ $actual == 0 || $effective == 0 || $UID == 0 || $EUID == 0 ]]; then
        die '容器禁止以 root（实际或有效 UID 0）运行'
    fi
    return 0
}

# 把用户环境定向到命名卷与只读程序层，避免任何写入落在镜像层；不导出或打印凭据。
prepare_environment() {
    export INSTALL_ROOT RUN_ROOT
    export HOME=$RUN_ROOT/home
    export XDG_CONFIG_HOME=$RUN_ROOT/config
    export XDG_RUNTIME_DIR=$RUN_ROOT/runtime
    export XDG_CACHE_HOME=$RUN_ROOT/cache
    export TMPDIR=$RUN_ROOT/tmp
    export PATH=${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
    return 0
}

# 判定调度服务是否需要启动：环境变量优先于卷内配置，最后使用默认值 yes。
scheduler_enabled() {
    local file=$RUN_ROOT/config/mirror.env line value=
    if [[ -v ENABLE_CRON ]]; then
        [[ $ENABLE_CRON == yes ]]
        return
    fi
    if [[ -f $file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            case "$line" in
                ENABLE_CRON=*) value=${line#ENABLE_CRON=} ;;
            esac
        done < "$file"
    fi
    [[ ${value:-yes} == yes ]]
}

# 读取任务子进程的真实进程组 ID：以 /proc/<pid>/stat 的 pgrp 字段为准，并要求其等于子进程自身 PID
# （setsid 后子进程自成进程组与会话组长）。返回非零表示无法确认独立进程组——此时调用方不得声称
# 已回收进程组，避免把「组从未存在」当作回收成功。
task_process_group() {
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

# 等待指定进程组内全部子孙退出；边界内未回收先按组强杀再等一轮。
# 首次任务可能形成「脚本 → 子 Shell → 传输工具 → 更深子孙」多层进程树，
# 只终止直接子进程会让子孙滞留到 PID1 退出后被内核清理；此函数确保回收发生在 PID1 存活期间。
# 契约：仅当调用方已确认该进程组曾真实存在（task_process_group 成功）时才可调用，
# 因此组消失（kill -0 -pgid 失败）即代表回收完成，而非「组从未存在」的假成功。
wait_process_group_gone() {
    local pgid=$1 now start alive killed=no
    gm_monotonic_ms start || return 1
    kill -TERM -- "-$pgid" 2>/dev/null || true
    while :; do
        alive=0
        gm_task_group_alive "$pgid" "$pgid" || alive=$?
        (( alive == 1 )) && return 0
        (( alive == 0 )) || return 1
        gm_monotonic_ms now || return 1
        (( now-start < 7000 )) || return 1
        if (( now-start >= 5000 )) && [[ $killed == no ]]; then
            kill -KILL -- "-$pgid" 2>/dev/null || return 1
            killed=yes
        fi
        sleep 0.05
    done
}

# 信号回调仅登记停止意图，由主控制流执行冻结和回收。
on_stop_signal() {
    GM_ENTRYPOINT_STOP=1
    if declare -F gm_request_stop >/dev/null; then gm_request_stop instance container_signal; fi
    return 0
}

# 以前台子进程执行首次刷新或首次同步：任务以独立进程组（setsid）启动，停止信号可按组回收整棵树；
# 失败仅告警不终止读取服务；收到停止后先确认组内子孙真实退出再返回，不把回收推给 PID1 退出后的内核清理。
# 启动时即校验真实进程组 ID（不臆断 $! 等于 PGID），未确认到进程组时明确不声称回收。
run_task_best_effort() {
    local label=$1 status=0 pgid= unsafe=0 alive=0 directory gate start now
    shift
    directory=$(mktemp -d "$RUN_ROOT/runtime/hosts.XXXXXXXX") || return 1
    mkfifo -m 600 "$directory/gate" || return 1
    exec {gate}<> "$directory/gate" || return 1
    (if declare -F gm_lock_release >/dev/null; then gm_lock_release container; fi
        exec setsid bash -c 'gate=$1; shift; IFS= read -r -t 2 token <&"$gate" || exit 1; exec {gate}>&-; [[ $token == GO ]] || exit 1; exec "$@"' _ "$gate" "$@") &
    GM_ENTRYPOINT_TASK=$!
    local -A direct=() current=()
    gm_process_identity "$GM_ENTRYPOINT_TASK" direct || true
    if pgid=$(task_process_group "$GM_ENTRYPOINT_TASK"); then
        GM_ENTRYPOINT_TASK_PGID=$pgid
    else
        pgid=
        GM_ENTRYPOINT_TASK_PGID=
        log "$label 未能确认任务独立进程组，停止时仅回收直接子进程"
    fi
    if [[ -z $pgid ]]; then
        gm_task_freeze || true
        exec {gate}>&-
        gm_monotonic_ms start || return 1
        while gm_process_identity "$GM_ENTRYPOINT_TASK" current && [[ ${current[state]} != Z ]]; do
            [[ ${direct[start]-} == "${current[start]}" && ${current[ppid]} == "$BASHPID" ]] || return 1
            kill -TERM "$GM_ENTRYPOINT_TASK" 2>/dev/null || true
            gm_monotonic_ms now || return 1
            (( now-start < 2000 )) || return 1
            sleep 0.05
        done
        wait "$GM_ENTRYPOINT_TASK" 2>/dev/null || true
        rm -f "$directory/gate" && rmdir "$directory" || return 1
        return 1
    fi
    if [[ $GM_ENTRYPOINT_STOP == 0 && ${GM_LOCAL_FROZEN-} != yes ]]; then
        printf 'GO\n' >&"$gate" || unsafe=1
    fi
    exec {gate}>&-
    rm -f "$directory/gate" && rmdir "$directory" || unsafe=1
    while [[ $GM_ENTRYPOINT_STOP == 0 ]]; do
        kill -0 "$GM_ENTRYPOINT_TASK" 2>/dev/null || break
        sleep 0.05
    done
    if [[ $GM_ENTRYPOINT_STOP == 0 ]]; then wait "$GM_ENTRYPOINT_TASK" || status=$?; fi
    gm_task_group_alive "$pgid" "$pgid" || alive=$?
    if [[ $GM_ENTRYPOINT_STOP != 0 ]] || (( alive != 1 || unsafe != 0 )); then
        if [[ $GM_ENTRYPOINT_STOP == 0 ]]; then unsafe=1; fi
        gm_task_freeze || unsafe=1
        wait_process_group_gone "$pgid" || return 1
        wait "$GM_ENTRYPOINT_TASK" 2>/dev/null || true
        (( unsafe == 0 )) || return 1
        GM_ENTRYPOINT_TASK= GM_ENTRYPOINT_TASK_PGID=
        return 130
    fi
    GM_ENTRYPOINT_TASK=
    GM_ENTRYPOINT_TASK_PGID=
    if ((status == 0)); then
        log "$label 完成"
    else
        log "$label 失败（退出码 $status），保留已有数据并继续启动常驻服务"
    fi
    return 0
}

# 停止调度与读取服务并回收子进程；未运行的服务停止失败被忽略。
shutdown_services() {
    local status=$? freeze_status=0
    if declare -F gm_task_freeze >/dev/null; then gm_task_freeze || freeze_status=1; fi
    gm_without_container_lease rc-service --user git-mirror-scheduler stop >/dev/null 2>&1 || true
    gm_without_container_lease rc-service --user git-daemon stop >/dev/null 2>&1 || true
    if (( freeze_status != 0 )); then return 1; fi
    return "$status"
}

# 复位实例 OpenRC 用户态常驻服务的残留状态：卷内持久化的“已启动”记录与陈旧 pidfile 不代表真实存活，
# 新容器内残留活动使 start 被判为“已启动”而跳过真正启动；先 zap 清除状态，再移除陈旧 pidfile——
# start-stop-daemon 仅按 pidfile 中 PID 是否存活判断“已在运行”，不校验其可执行文件，
# 强杀重建后陈旧 PID 被新容器进程复用时会被误判，导致服务无法拉起。
reset_stale_service_state() {
    local name=$1 pidfile=$RUN_ROOT/runtime/$1.pid
    rc-service --user "$name" zap >/dev/null 2>&1 || true
    rm -f -- "$pidfile" 2>/dev/null || true
    return 0
}

# 在内核 TCP 表内按「本地地址端口字段匹配 + TCP 状态为 LISTEN（0A）」判定监听：
# 逐行读取，先确认状态为 0A，再比较本地地址（字段 2）冒号后的端口，绝不使用子串匹配，
# 从而不会把同端口的非 LISTEN 连接（本地端口恰为该端口的已建立/时间等待等连接）误判为就绪。
port_is_listening() {
    local hex=$1 table=$2 local_address state
    [[ -r $table ]] || return 1
    while read -r _ local_address _ state _; do
        [[ ${state^^} == 0A ]] || continue
        [[ ${local_address##*:} == "${hex^^}" ]] || continue
        return 0
    done < "$table"
    return 1
}

# 以真实监听为判据确认 git-daemon 已就绪：读取交付配置入口解析出的生效端口，
# 在内核监听表中确认该端口以 LISTEN 状态被本地地址占用；超时返回非零，不把持久化 PID 当作存活服务。
confirm_daemon_listening() {
    local output port hex i
    output=$("$INSTALL_ROOT/git-daemon-config.sh" --token-state=empty 2>/dev/null) || {
        log '无法读取 git-daemon 生效配置，判定常驻服务启动失败'
        return 1
    }
    port=${output%%$'\n'*}
    if [[ ! $port =~ ^[0-9]+$ ]]; then
        log 'git-daemon 生效端口非法，判定常驻服务启动失败'
        return 1
    fi
    hex=$(printf '%04X' "$((10#$port))")
    for i in $(seq 1 20); do
        if port_is_listening "$hex" /proc/net/tcp || port_is_listening "$hex" /proc/net/tcp6; then
            return 0
        fi
        sleep 0.5
    done
    log "git-daemon 启动后未在端口 $port 上监听，判定常驻服务启动失败"
    return 1
}

# 前台监督循环：可中断休眠并周期性确认常驻服务仍在运行，任一关键服务退出即返回非零。
supervise_loop() {
    local scheduler_supervised=$1
    while [[ $GM_ENTRYPOINT_STOP == 0 ]]; do
        (gm_lock_release container; exec sleep 5) &
        GM_ENTRYPOINT_SLEEP=$!
        wait "$GM_ENTRYPOINT_SLEEP" 2>/dev/null || true
        if [[ $GM_ENTRYPOINT_STOP != 0 ]]; then
            kill -TERM "$GM_ENTRYPOINT_SLEEP" 2>/dev/null || true
            wait "$GM_ENTRYPOINT_SLEEP" 2>/dev/null || true
        fi
        GM_ENTRYPOINT_SLEEP=
        if [[ $GM_ENTRYPOINT_STOP != 0 ]]; then
            break
        fi
        if ! gm_without_container_lease rc-service --user git-daemon status >/dev/null 2>&1; then
            log '关键服务 git-daemon 已停止，容器退出'
            return 1
        fi
        if [[ $scheduler_supervised == yes ]]; then
            if ! gm_without_container_lease rc-service --user git-mirror-scheduler status >/dev/null 2>&1; then
                log '调度服务 git-mirror-scheduler 已停止，容器退出'
                return 1
            fi
        fi
    done
    return 0
}

# 在编排边界持久化停止意图，冻结失败保留非零退出。
entry_checkpoint() {
    if [[ $GM_ENTRYPOINT_STOP == 0 && ${GM_STOP_SCOPE-} != instance && ${GM_LOCAL_FROZEN-} != yes ]]; then return 0; fi
    gm_task_freeze || return 1
    return 130
}

# 主流程：身份预检 → 环境准备 → 交付 CLI 初始化命名卷 → 首次刷新/同步 → 启动并监督服务。
main() {
    local scheduler_supervised=no status=0
    require_non_root
    prepare_environment
    [[ -x $INSTALL_ROOT/deploy-git-mirror.sh ]] || die "缺少交付安装入口：$INSTALL_ROOT/deploy-git-mirror.sh"
    source "$INSTALL_ROOT/git-mirror-recover.sh" || die '缺少启动恢复入口'
    log() { printf '[git-daemon] %s\n' "$*"; }
    unset GM_BOOT_GENERATION GM_CONTAINER_OWNER GM_STOP_SCOPE GM_LOCAL_FROZEN
    gm_validate_path "$RUN_ROOT" || return 1
    (umask 077; mkdir -p "$RUN_ROOT/runtime") || return 1
    gm_container_lease_acquire || return $?
    trap 'shutdown_services || exit $?' EXIT
    trap on_stop_signal TERM INT
    # 程序层已于构建期由交付安装器烘焙为只读；运行期只做实例初始化与恢复，避免只读根下写模式校验失败。
    log '初始化命名卷内实例'
    entry_checkpoint || return $?
    gm_without_container_lease "$INSTALL_ROOT/deploy-git-mirror.sh" --init --install-root "$INSTALL_ROOT" --run-root "$RUN_ROOT" || die '实例初始化失败'
    entry_checkpoint || return $?
    gm_prepare_runtime "$RUN_ROOT" "$INSTALL_ROOT" || return 1
    entry_checkpoint || return $?
    gm_startup_prepare || die '关闭旧发布或重放失败'
    log '启动 git-daemon'
    entry_checkpoint || return $?
    reset_stale_service_state git-daemon
    entry_checkpoint || return $?
    gm_without_container_lease rc-service --user git-daemon start || die 'git-daemon 启动失败'
    entry_checkpoint || return $?
    confirm_daemon_listening || die 'git-daemon 启动后未真实监听，容器退出'
    entry_checkpoint || return $?
    gm_recover_main --startup || return 1
    entry_checkpoint || return $?
    run_task_best_effort '首次地址刷新' "$INSTALL_ROOT/update-github-hosts.sh" || return $?
    entry_checkpoint || return $?
    gm_startup_network || return 1
    entry_checkpoint || return $?
    if scheduler_enabled; then
        log '启动调度服务'
        entry_checkpoint || return $?
        reset_stale_service_state git-mirror-scheduler
        entry_checkpoint || return $?
        gm_without_container_lease rc-service --user git-mirror-scheduler start || die '调度服务启动失败'
        entry_checkpoint || return $?
        scheduler_supervised=yes
    else
        log 'ENABLE_CRON=no，按配置不启动调度服务；首次刷新与首次同步已执行'
    fi
    log '容器前台就绪'
    entry_checkpoint || return $?
    supervise_loop "$scheduler_supervised" || status=$?
    log '收到停止信号，停止服务并回收子进程'
    return "$status"
}

# 直接执行时进入主流程；被测试脚本 source 时只加载函数与变量，不触发启动，直接执行行为不变。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
