#!/bin/bash

# 容器前台入口：以非 root 身份完成命名卷内实例初始化，启动常驻服务并监督生命周期。
# 同步与地址刷新算法全部复用交付脚本，入口只负责编排、前台存活、信号转发与子进程回收。
# 计划中的入口逻辑说明：一次性工作服务（git-mirror-sync / git-mirror-hosts）经 rc-service 运行后
# 状态会显示 crashed（退出 32），属既有语义，因此入口只对常驻服务使用 OpenRC 状态，绝不据一次性
# 工作服务的状态判断成功；跨容器残留运行状态先以 zap 复位再启动，并以真实监听确认存活，
# 不把持久化 PID 或卷内残留的“已启动”状态当作存活服务。

set -uo pipefail

# 程序层与运行根的默认绝对路径；容器环境变量可覆盖，仍必须指向只读程序层与命名卷运行根。
INSTALL_ROOT=${INSTALL_ROOT:-/usr/local/lib/git-mirror}
RUN_ROOT=${RUN_ROOT:-/var/lib/git-daemon}

# 入口状态：停止标志、当前首次任务子进程、当前休眠子进程。
GM_ENTRYPOINT_STOP=0
GM_ENTRYPOINT_TASK=
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

# 收到停止信号时置位标志并定向终止首次任务与休眠子进程。
on_stop_signal() {
    GM_ENTRYPOINT_STOP=1
    if [[ -n ${GM_ENTRYPOINT_TASK-} ]]; then
        kill -TERM "$GM_ENTRYPOINT_TASK" 2>/dev/null || true
    fi
    if [[ -n ${GM_ENTRYPOINT_SLEEP-} ]]; then
        kill -TERM "$GM_ENTRYPOINT_SLEEP" 2>/dev/null || true
    fi
    return 0
}

# 以前台子进程执行首次刷新或首次同步：失败仅告警不终止读取服务，停止信号可中断并回收。
run_task_best_effort() {
    local label=$1 status=0
    shift
    "$@" &
    GM_ENTRYPOINT_TASK=$!
    wait "$GM_ENTRYPOINT_TASK" || status=$?
    GM_ENTRYPOINT_TASK=
    if [[ $GM_ENTRYPOINT_STOP != 0 ]]; then
        log "$label 因停止信号中断"
        return 130
    fi
    if ((status == 0)); then
        log "$label 完成"
    else
        log "$label 失败（退出码 $status），保留已有数据并继续启动常驻服务"
    fi
    return 0
}

# 停止调度与读取服务并回收子进程；未运行的服务停止失败被忽略。
shutdown_services() {
    rc-service --user git-mirror-scheduler stop >/dev/null 2>&1 || true
    rc-service --user git-daemon stop >/dev/null 2>&1 || true
    wait 2>/dev/null || true
    return 0
}

# 复位实例 OpenRC 用户态常驻服务的残留状态：卷内持久化的“已启动”记录与陈旧 pidfile 不代表真实存活，
# 新容器内残留活动使 start 被判为“已启动”而跳过真正启动；先 zap 清除状态，使 start 确实拉起服务。
reset_stale_service_state() {
    rc-service --user "$1" zap >/dev/null 2>&1 || true
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
        sleep 5 &
        GM_ENTRYPOINT_SLEEP=$!
        wait "$GM_ENTRYPOINT_SLEEP" 2>/dev/null || true
        GM_ENTRYPOINT_SLEEP=
        if [[ $GM_ENTRYPOINT_STOP != 0 ]]; then
            break
        fi
        if ! rc-service --user git-daemon status >/dev/null 2>&1; then
            log '关键服务 git-daemon 已停止，容器退出'
            return 1
        fi
        if [[ $scheduler_supervised == yes ]]; then
            if ! rc-service --user git-mirror-scheduler status >/dev/null 2>&1; then
                log '调度服务 git-mirror-scheduler 已停止，容器退出'
                return 1
            fi
        fi
    done
    return 0
}

# 主流程：身份预检 → 环境准备 → 交付 CLI 初始化命名卷 → 首次刷新/同步 → 启动并监督服务。
main() {
    local scheduler_supervised=no status=0
    require_non_root
    prepare_environment
    [[ -x $INSTALL_ROOT/deploy-git-mirror.sh ]] || die "缺少交付安装入口：$INSTALL_ROOT/deploy-git-mirror.sh"
    trap on_stop_signal TERM INT
    # 程序层已于构建期由交付安装器烘焙为只读；运行期只做实例初始化与恢复，避免只读根下写模式校验失败。
    log '初始化命名卷内实例'
    "$INSTALL_ROOT/deploy-git-mirror.sh" --init --install-root "$INSTALL_ROOT" --run-root "$RUN_ROOT" || die '实例初始化失败'
    if [[ -e $RUN_ROOT/runtime/stopped ]]; then
        log '检测到停止标记，按交付 CLI 解除'
        "$INSTALL_ROOT/deploy-git-mirror.sh" --resume --install-root "$INSTALL_ROOT" --run-root "$RUN_ROOT" || die '解除停止标记失败'
    fi
    if run_task_best_effort '首次地址刷新' "$INSTALL_ROOT/update-github-hosts.sh"; then
        :
    else
        shutdown_services
        return 0
    fi
    log '启动 git-daemon'
    reset_stale_service_state git-daemon
    rc-service --user git-daemon start || die 'git-daemon 启动失败'
    confirm_daemon_listening || die 'git-daemon 启动后未真实监听，容器退出'
    if run_task_best_effort '首次仓库同步' "$INSTALL_ROOT/git-mirror-sync.sh"; then
        :
    else
        shutdown_services
        return 0
    fi
    if scheduler_enabled; then
        log '启动调度服务'
        reset_stale_service_state git-mirror-scheduler
        rc-service --user git-mirror-scheduler start || die '调度服务启动失败'
        scheduler_supervised=yes
    else
        log 'ENABLE_CRON=no，按配置不启动调度服务；首次刷新与首次同步已执行'
    fi
    log '容器前台就绪'
    supervise_loop "$scheduler_supervised" || status=$?
    log '收到停止信号，停止服务并回收子进程'
    shutdown_services
    return "$status"
}

# 直接执行时进入主流程；被测试脚本 source 时只加载函数与变量，不触发启动，直接执行行为不变。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
