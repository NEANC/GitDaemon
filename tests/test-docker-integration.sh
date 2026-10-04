#!/usr/bin/env bash

# 容器实机集成检查：真实执行 docker build 与容器命令，核验非 root Alpine 镜像的构建与运行身份、
# 命名卷属主继承、依赖完整性以及无 SSH 组件；并基于 compose.yml 真实编排一次，核验只读根、
# cap_drop ALL、no-new-privileges 与命名卷挂载。docker 或 compose 不可用时明确跳过并返回 77。

set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=git-daemon:test
FAILURES=0
CHECKS=0
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-docker-it.XXXXXXXX") || exit 1
BUILD_LOG=$TEST_ROOT/build.log
VOLUME=git-daemon-it-$$
COMPOSE_FILE=$ROOT/compose.yml
COMPOSE_TAG=it-$$
COMPOSE_IMAGE=ghcr.io/neanc/git-daemon:$COMPOSE_TAG
COMPOSE_PROJECT=gm-it-$$
COMPOSE_PORT=$((40000 + ($$ % 10000)))

# 仅清理本脚本创建的临时目录、命名卷、compose 项目与本脚本附加的镜像标签；被检查镜像保留。
cleanup() {
    IMAGE_TAG=$COMPOSE_TAG REPOS=octocat/Hello-World \
        docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
    docker image rm -f "$COMPOSE_IMAGE" >/dev/null 2>&1 || true
    if [[ -n ${VOLUME:-} ]]; then
        docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

# 以子 Shell 运行单项检查并累计通过/失败，输出只保留结果行。
check() {
    local label=$1
    shift
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 探测 docker 与 compose：命令缺失或守护进程不可用即明确跳过并返回 77，绝不伪报成功。
require_docker() {
    command -v docker >/dev/null 2>&1 || { printf 'SKIP：docker 不可用，未执行\n'; exit 77; }
    docker info >/dev/null 2>&1 || { printf 'SKIP：docker 不可用，未执行\n'; exit 77; }
    docker compose version >/dev/null 2>&1 || { printf 'SKIP：docker compose 不可用，未执行\n'; exit 77; }
    return 0
}

# 真实执行无缓存构建；失败时打印日志尾部便于定位根因。
build_image() {
    docker build --no-cache -t "$IMAGE" "$ROOT" >"$BUILD_LOG" 2>&1 || {
        printf '构建失败，日志尾部：\n' >&2
        tail -n 20 "$BUILD_LOG" >&2
        return 1
    }
    return 0
}

# 镜像默认运行身份为固定非零 UID 10001。
image_user_is_nonroot() {
    [[ $(docker image inspect "$IMAGE" --format '{{.Config.User}}' 2>/dev/null) == '10001:10001' ]]
}

# 镜像实际运行身份：真实 UID 与有效 UID 均为 10001。
run_identity_nonroot() {
    local output
    output=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'id -ru; id -u' 2>/dev/null) || return 1
    [[ $output == $'10001\n10001' ]]
}

# 构建步骤非 root 的证据：镜像内由 RUN 生成的路径属主为 10001，而不是 root。
build_paths_owned_by_app() {
    docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
        'for p in /etc/passwd /etc/group /usr/local/lib/git-mirror; do [ "$(stat -c %u "$p")" = 10001 ] || exit 1; done' \
        2>/dev/null
}

# 运行根存在、属主 10001、权限 755，供空命名卷首次挂载继承属主。
runtime_root_attributes() {
    local output
    output=$(docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
        'stat -c "%u %a %F" /var/lib/git-daemon' 2>/dev/null) || return 1
    [[ $output == '10001 755 directory' ]]
}

# 新建命名卷首次挂载后以 10001 可写入：空卷按镜像内属主初始化，且运行期无需 root 修卷权限。
named_volume_writable() {
    docker volume create "$VOLUME" >/dev/null 2>&1 || return 1
    docker run --rm --user 10001:10001 -v "$VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'touch /var/lib/git-daemon/probe && [ "$(stat -c %u /var/lib/git-daemon)" = 10001 ]' 2>/dev/null
}

# 运行时依赖命令可执行，CA 捆绑与本地时区文件存在。
runtime_dependencies_present() {
    docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
        'for c in bash git curl openssl flock; do command -v "$c" >/dev/null || exit 1; done; [ -f /etc/ssl/certs/ca-certificates.crt ] && [ -e /etc/localtime ]' \
        2>/dev/null
}

# 镜像不含任何 SSH 组件：既无可执行命令，也无对应文件。
no_ssh_components() {
    docker run --rm --entrypoint /bin/sh "$IMAGE" -c \
        'for c in ssh sshd scp dropbear sftp sftp-server git-remote-ssh; do command -v "$c" >/dev/null && exit 1; done; for p in /usr/bin/ssh /usr/bin/scp /usr/sbin/sshd /usr/bin/dropbear /usr/libexec/git-core/git-remote-ssh; do [ -e "$p" ] && exit 1; done; exit 0' \
        2>/dev/null
}

# 入口拒绝 UID 0：以 --user 0:0 运行必须非零退出且输出包含 root 拒绝诊断。
entry_rejects_root() {
    local output status=0
    output=$(docker run --rm --user 0:0 "$IMAGE" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output == *'禁止以 root'* ]]
}

# 为本地构建镜像附加 registry 前缀标签，供 compose 引用且无需拉取远端镜像。
compose_tag_local_image() {
    docker tag "$IMAGE" "$COMPOSE_IMAGE" 2>/dev/null
}

# 显式提供 IMAGE_TAG 时 compose 配置渲染成功。
compose_config_accepts_explicit_tag() {
    IMAGE_TAG=$COMPOSE_TAG REPOS=octocat/Hello-World \
        docker compose -f "$COMPOSE_FILE" config >/dev/null 2>&1
}

# 缺少 IMAGE_TAG 时 compose 配置必须失败，且诊断指向 IMAGE_TAG。
compose_config_rejects_missing_tag() {
    local output status=0
    output=$(env -u IMAGE_TAG REPOS=octocat/Hello-World docker compose -f "$COMPOSE_FILE" config 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output == *IMAGE_TAG* ]] || return 1
    return 0
}

# 以独立项目名与空闲高位端口真实编排启动一次；关闭外网依赖并给出占位仓库。
compose_start() {
    IMAGE_TAG=$COMPOSE_TAG REPOS=octocat/Hello-World ENABLE_HOSTS_UPDATE=no ENABLE_CRON=no \
        PUBLISHED_PORT=$COMPOSE_PORT \
        docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d >/dev/null 2>&1
}

# 等待 compose 容器进入运行状态（入口首次同步失败属既有 best-effort 语义，不影响常驻）。
# 超时未运行则打印日志尾部到标准错误，便于定位容器退出原因。
compose_wait_running() {
    local id i
    for i in $(seq 1 40); do
        id=$(docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps -q git-daemon 2>/dev/null) || id=
        if [[ -n $id && $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == true ]]; then
            return 0
        fi
        sleep 1
    done
    printf 'Compose 容器未运行，日志尾部：\n' >&2
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" logs --no-color --tail 30 >&2 2>&1 || true
    return 1
}

# 返回 compose 服务容器 ID，供后续断言使用。
compose_container_id() {
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" ps -q git-daemon 2>/dev/null
}

# 容器以固定的非 root 身份 10001 运行。
compose_runs_as_nonroot() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    [[ $(docker inspect -f '{{.Config.User}}' "$id") == '10001:10001' ]] || return 1
    [[ $(docker exec "$id" id -u) == '10001' ]] || return 1
    return 0
}

# 根文件系统只读：HostConfig 标记为真且容器内无法在 / 下写入。
compose_readonly_rootfs() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    [[ $(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$id") == true ]] || return 1
    docker exec "$id" sh -c 'touch /git-daemon-rootfs-probe' >/dev/null 2>&1 && return 1
    return 0
}

# 已丢弃全部 Linux 能力。
compose_cap_drop_all() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    [[ $(docker inspect -f '{{json .HostConfig.CapDrop}}' "$id") == '["ALL"]' ]] || return 1
    return 0
}

# 安全选项包含 no-new-privileges。
compose_no_new_privileges() {
    local id json
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    json=$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$id") || return 1
    [[ $json == *'"no-new-privileges:true"'* || $json == *'"no-new-privileges"'* ]] || return 1
    return 0
}

# 唯一命名卷 git-daemon-data 以 volume 类型挂载到 /var/lib/git-daemon。
compose_named_volume_mounted() {
    local id json
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    json=$(docker inspect -f '{{json .Mounts}}' "$id") || return 1
    [[ $json == *'"Type":"volume"'* ]] || return 1
    [[ $json == *'"Destination":"/var/lib/git-daemon"'* ]] || return 1
    [[ $json == *'"Name":"git-daemon-data"'* ]] || return 1
    return 0
}

# 命名卷以 10001 身份可写，应用数据落在卷内。
compose_volume_writable() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker exec "$id" sh -c 'touch /var/lib/git-daemon/it-probe' >/dev/null 2>&1
}

# 停止并删除 compose 项目、网络与卷，并移除本脚本附加的镜像标签；无残留。
compose_teardown() {
    IMAGE_TAG=$COMPOSE_TAG REPOS=octocat/Hello-World \
        docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
    docker image rm -f "$COMPOSE_IMAGE" >/dev/null 2>&1 || true
    return 0
}

require_docker
check 'docker build --no-cache 退出码为 0' build_image
check '镜像默认运行身份为 10001:10001' image_user_is_nonroot
check '镜像实际运行身份真实与有效 UID 均为 10001' run_identity_nonroot
check '由 RUN 生成的路径属主为 10001（构建步骤非 root）' build_paths_owned_by_app
check '运行根属主 10001、权限 755' runtime_root_attributes
check '空命名卷首次挂载后以 10001 可写入' named_volume_writable
check '运行时依赖命令与 CA/时区文件齐备' runtime_dependencies_present
check '镜像不含 SSH 组件' no_ssh_components
check '入口拒绝 UID 0' entry_rejects_root
# 后续所有 compose 子命令（ps/logs/down）都需成功渲染镜像引用与环境变量插值，故在此统一导出。
export IMAGE_TAG=$COMPOSE_TAG
export REPOS=octocat/Hello-World
export ENABLE_HOSTS_UPDATE=no
export ENABLE_CRON=no
export PUBLISHED_PORT=$COMPOSE_PORT
check 'Compose 为本地镜像附加 registry 标签' compose_tag_local_image
check 'Compose 显式 IMAGE_TAG 时 config 有效' compose_config_accepts_explicit_tag
check 'Compose 缺少 IMAGE_TAG 时 config 失败' compose_config_rejects_missing_tag
check 'Compose 独立项目名与空闲端口启动' compose_start
check 'Compose 容器进入运行状态' compose_wait_running
check 'Compose 容器以 UID 10001 运行' compose_runs_as_nonroot
check 'Compose 根文件系统只读' compose_readonly_rootfs
check 'Compose 丢弃全部能力' compose_cap_drop_all
check 'Compose 禁止提权' compose_no_new_privileges
check 'Compose 命名卷挂载到 /var/lib/git-daemon' compose_named_volume_mounted
check 'Compose 命名卷内可写' compose_volume_writable
compose_teardown
printf '容器实机集成检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
