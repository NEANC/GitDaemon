#!/usr/bin/env bash

# 容器实机集成检查：真实执行 docker build 与容器命令，核验非 root Alpine 镜像的构建与运行身份、
# 命名卷属主继承、依赖完整性以及无 SSH 组件；并在 compose 可用时基于 compose.yml 真实编排，
# 核验只读根、cap_drop ALL、no-new-privileges、命名卷挂载、卷内配置层、运行期全进程非 root、
# 实例数据落卷、数据重建保留、停止与信号回收、关键服务停止退出、非法配置启动失败、
# 调度真实派发、发布边界（export-ok/receive-pack）、自签名 HTTPS 地址刷新被拒绝、
# 显式环境变量对卷内配置的优先级以及强杀（SIGKILL）后同卷重建的真实可达性。
# docker 完全不可用时整段跳过并返回 77；仅 compose 缺失时 docker-only 覆盖照常执行。

set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=git-daemon:test
FAILURES=0
CHECKS=0
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-docker-it.XXXXXXXX") || exit 1
BUILD_LOG=$TEST_ROOT/build.log
VOLUME=git-daemon-it-$$
COMPOSE_FILE=$ROOT/compose.yml
COMPOSE_OVERRIDE=$TEST_ROOT/compose.override.yml
COMPOSE_TAG=it-$$
COMPOSE_IMAGE=ghcr.io/neanc/git-daemon:$COMPOSE_TAG
COMPOSE_PROJECT=gm-it-$$
COMPOSE_VOLUME=gm-it-$$-data
COMPOSE_PORT=$((40000 + ($$ % 10000)))
# 卷内配置层回归断言用的非默认值：容器内 daemon 必须实际生效这些值而非默认值。
COMPOSE_VOL_CONFIG_ADDR=127.0.0.1
COMPOSE_VOL_CONFIG_PORT=19418
# 显式环境变量优先断言的取值：与卷内配置（127.0.0.1:19418）刻意不同，宿主显式设置后必须生效该值。
# 0.0.0.0:19428 在内核监听表中为 00000000:4BE4。
COMPOSE_ENV_CONFIG_ADDR=0.0.0.0
COMPOSE_ENV_CONFIG_PORT=19428
# 上游占位仓库名刻意不存在于 GitHub：同步预期失败且快速返回，测试不依赖真实上游内容与体积。
TEST_REPO=octocat/Nonexistent-$COMPOSE_TAG
# 地址刷新夹具：与目标容器共享网络命名空间的自签名 HTTPS 服务名与端口。
TLS_FIXTURE_NAME=gm-it-tls-$$
TLS_FIXTURE_PORT=$((COMPOSE_PORT + 10000))
# 场景化 compose 透传环境变量（列表形式）；compose_up 负责导出后编排。
COMPOSE_ENV=()

# 测试通过 override 文件把 compose.yml 的固定全局卷名改写到测试作用域，
# 从而绝不触碰宿主上真实部署使用的 git-daemon-data 卷（即使它已存在）。
# 关闭重启策略（restart: "no"）仅为测试作用域策略：用于稳定观测“容器非零退出”类事件，
# 不代表真实部署行为；compose.yml 的生产策略为 restart: unless-stopped，由静态断言
# compose_production_restart_policy 单独核对，保证测试未改动生产重启语义。容器内安全选项不受影响。
write_compose_override() {
    cat > "$COMPOSE_OVERRIDE" <<EOF
services:
  git-daemon:
    restart: "no"
volumes:
  git-daemon-data:
    name: $COMPOSE_VOLUME
EOF
}

# 静态断言 compose.yml 的生产重启策略仍为 unless-stopped，避免读者把 override 的测试作用域
# restart: "no" 误解为真实部署行为。
compose_production_restart_policy() {
    grep -Eq '^[[:space:]]*restart:[[:space:]]*unless-stopped[[:space:]]*$' "$COMPOSE_FILE"
}

# 统一以测试项目名与 override 文件调用 compose，保证所有子命令作用域一致。
compose() {
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" -f "$COMPOSE_OVERRIDE" "$@"
}

# docker CLI 与守护进程均可用才算可用。
docker_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# docker compose 插件与守护进程均可用才算可用。
compose_available() {
    docker compose version >/dev/null 2>&1
}

# 仅清理本脚本创建的临时目录、测试作用域卷、compose 项目/网络、夹具容器与本脚本附加的镜像标签；
# 被检查镜像保留。绝不删除 compose.yml 绑定的全局卷 git-daemon-data。
cleanup() {
    if [[ -n ${TLS_FIXTURE_NAME:-} ]]; then
        docker rm -f "$TLS_FIXTURE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -f ${COMPOSE_OVERRIDE:-} ]]; then
        IMAGE_TAG=$COMPOSE_TAG REPOS=$TEST_REPO \
            compose down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    docker volume rm -f "$COMPOSE_VOLUME" >/dev/null 2>&1 || true
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
    IMAGE_TAG=$COMPOSE_TAG REPOS=$TEST_REPO \
        compose config >/dev/null 2>&1
}

# 缺少 IMAGE_TAG 时 compose 配置必须失败，且诊断指向 IMAGE_TAG。
compose_config_rejects_missing_tag() {
    local output status=0
    output=$( (unset IMAGE_TAG; REPOS=$TEST_REPO compose config) 2>&1 ) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output == *IMAGE_TAG* ]] || return 1
    return 0
}

# 在测试作用域命名卷内预置卷内配置：写入非默认 LISTEN_ADDRESS 与 GIT_PORT。
# 全部以 10001 身份完成，符合“不以 root 初始化/修卷权限”的约束。
compose_prepare_volume_config() {
    docker volume create "$COMPOSE_VOLUME" >/dev/null 2>&1 || return 1
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'mkdir -p /var/lib/git-daemon/config && printf "%s\n" "LISTEN_ADDRESS=127.0.0.1" "GIT_PORT=19418" > /var/lib/git-daemon/config/mirror.env'
}

# 在测试作用域命名卷内预置发布用卷内配置：显式 0.0.0.0:9418，与 compose.yml 的固定容器端口一致。
compose_prepare_publish_volume() {
    docker volume create "$COMPOSE_VOLUME" >/dev/null 2>&1 || return 1
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'mkdir -p /var/lib/git-daemon/config && printf "%s\n" "LISTEN_ADDRESS=0.0.0.0" "GIT_PORT=9418" > /var/lib/git-daemon/config/mirror.env'
}

# 以当前 COMPOSE_ENV 编排启动/重建一次；宿主机未在 COMPOSE_ENV 中显式给出 GIT_PORT/LISTEN_ADDRESS 时
# 清空这两个变量，使容器回退到卷内配置（验证卷内配置层可达）；显式给出时以环境变量优先。
compose_up() {
    local log=$TEST_ROOT/compose-up.log status=0
    (
        export IMAGE_TAG="$COMPOSE_TAG" PUBLISHED_PORT="$COMPOSE_PORT"
        unset GIT_PORT LISTEN_ADDRESS
        if [[ ${#COMPOSE_ENV[@]} -gt 0 ]]; then export "${COMPOSE_ENV[@]}"; fi
        compose up -d --force-recreate
    ) >"$log" 2>&1 || status=$?
    if (( status != 0 )); then
        printf 'compose up 失败（%s），输出：\n' "$status" >&2
        tail -n 20 "$log" >&2 2>&1 || true
        return 1
    fi
    return 0
}

# 兼容既有断言名称：以当前场景环境启动。
compose_start() {
    compose_up
}

# 等待容器完成实例初始化并进入前台就绪状态（入口首次同步失败属既有 best-effort 语义）。
compose_wait_running() {
    local id i
    for i in $(seq 1 120); do
        id=$(compose ps -q git-daemon 2>/dev/null) || id=
        if [[ -n $id && $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == true ]] \
            && compose logs --no-color 2>/dev/null | grep -q '容器前台就绪'; then
            return 0
        fi
        sleep 1
    done
    printf 'Compose 容器未就绪，日志尾部：\n' >&2
    compose ps -a --format '{{.Name}} {{.Status}}' >&2 2>&1 || true
    compose logs --no-color --tail 30 >&2 2>&1 || true
    return 1
}

# 返回 compose 服务容器 ID（含已退出容器），供后续断言使用。
compose_container_id() {
    compose ps -aq git-daemon 2>/dev/null | head -n 1
}

# 删除当前场景容器，保留命名卷与镜像标签；用于“停止并删除容器再重建”的保留性验证。
# 先优雅停止再删除：SIGTERM 让入口停止 OpenRC 用户服务并落定运行状态，这是“停止并删除”的正确语义；
# 已退出的容器忽略停止错误。强制删除（SIGKILL）后的残留状态由入口自愈，由强杀重建场景单独覆盖。
compose_remove_container() {
    local id
    id=$(compose_container_id) || id=
    if [[ -n $id ]]; then
        docker stop -t 30 "$id" >/dev/null 2>&1 || true
        docker rm -f "$id" >/dev/null 2>&1 || true
    fi
    return 0
}

# 以 SIGKILL（docker kill，不发送 SIGTERM）强制终止当前场景容器再删除，模拟断电/强杀后同卷重建；
# 此时入口信号处理不会执行，卷内会残留 OpenRC 用户态“已启动”状态与陈旧 pidfile。
compose_kill_container() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker kill "$id" >/dev/null 2>&1 || return 1
    docker rm -f "$id" >/dev/null 2>&1 || true
    return 0
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

# 唯一命名卷以 volume 类型挂载到 /var/lib/git-daemon；实际卷名为测试作用域名。
compose_named_volume_mounted() {
    local id json
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    json=$(docker inspect -f '{{json .Mounts}}' "$id") || return 1
    [[ $json == *'"Type":"volume"'* ]] || return 1
    [[ $json == *'"Destination":"/var/lib/git-daemon"'* ]] || return 1
    [[ $json == *"\"Name\":\"$COMPOSE_VOLUME\""* ]] || return 1
    return 0
}

# 命名卷以 10001 身份可写，应用数据落在卷内。
compose_volume_writable() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker exec "$id" sh -c 'touch /var/lib/git-daemon/it-probe' >/dev/null 2>&1
}

# 卷内配置层可达：宿主机未设置 GIT_PORT/LISTEN_ADDRESS 时，容器内交付配置入口解析出的生效值
# 必须来自卷内 mirror.env，而不是程序默认值 9418/0.0.0.0。
compose_volume_config_reachable() {
    local id output
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    output=$(docker exec -e HOME=/var/lib/git-daemon/home "$id" \
        /usr/local/lib/git-mirror/git-daemon-config.sh --token-state=empty 2>/dev/null) || return 1
    [[ $(printf '%s\n' "$output" | sed -n '1p') == "$COMPOSE_VOL_CONFIG_PORT" ]] || return 1
    [[ $(printf '%s\n' "$output" | sed -n '2p') == "$COMPOSE_VOL_CONFIG_ADDR" ]] || return 1
    return 0
}

# 真实运行行为：daemon 实际监听 127.0.0.1:19418（LE hex 0100007F:4BDA）。
compose_daemon_listens_from_volume() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker exec "$id" sh -c 'grep -q "0100007F:4BDA" /proc/net/tcp'
}

# 显式环境变量优先于卷内配置：卷内 mirror.env 为 127.0.0.1:19418，宿主机显式设置
# LISTEN_ADDRESS/GIT_PORT 后，交付配置入口解析出的生效端口/地址必须为环境变量值。
compose_env_overrides_volume_config() {
    local id output
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    output=$(docker exec -e HOME=/var/lib/git-daemon/home "$id" \
        /usr/local/lib/git-mirror/git-daemon-config.sh --token-state=empty 2>/dev/null) || return 1
    [[ $(printf '%s\n' "$output" | sed -n '1p') == "$COMPOSE_ENV_CONFIG_PORT" ]] || return 1
    [[ $(printf '%s\n' "$output" | sed -n '2p') == "$COMPOSE_ENV_CONFIG_ADDR" ]] || return 1
    return 0
}

# 显式环境变量在真实监听上生效：daemon 实际监听 0.0.0.0:19428（LE hex 00000000:4BE4），
# 而不是卷内配置的 127.0.0.1:19418。
compose_daemon_listens_from_env() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker exec "$id" sh -c 'grep -q "00000000:4BE4" /proc/net/tcp'
}

# 以宿主侧 docker top 取容器全部 PID，逐个读取 /proc/<pid>/status 的 Uid 行；
# 断言项目进程实际 UID 全为 10001（无一为 0）。
compose_all_processes_nonroot() {
    local id pids pid uid count=0
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    pids=$(docker top "$id" -o pid 2>/dev/null | tail -n +2) || pids=
    [[ -n $pids ]] || return 1
    for pid in $pids; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$pid/status" 2>/dev/null) || uid=
        [[ $uid == 10001 ]] || return 1
        count=$((count + 1))
    done
    [[ $count -ge 1 ]]
}

# 运行期只读根：对 /、/etc、/tmp、/run、/var/log 的写入必须失败。
compose_readonly_runtime_paths() {
    local id p
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    for p in / /etc /tmp /run /var/log; do
        if docker exec "$id" sh -c "touch '$p/gm-it-probe' 2>/dev/null"; then
            return 1
        fi
    done
    return 0
}

# 实例数据目录 config/repos/logs/runtime/cache/tmp 均存在于运行根下、与运行根同设备（命名卷），
# 且以 10001 可写（写入探针后立即删除，避免污染后续校验）。
compose_instance_data_on_volume() {
    local id dev
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    dev=$(docker exec "$id" stat -c %d /var/lib/git-daemon 2>/dev/null) || return 1
    [[ -n $dev ]] || return 1
    docker exec "$id" sh -c '
        umask 022
        dev='"$dev"'
        for d in config repos logs runtime cache tmp; do
            [ -d "/var/lib/git-daemon/$d" ] || exit 1
            [ "$(stat -c %d "/var/lib/git-daemon/$d")" = "$dev" ] || exit 1
            printf x > "/var/lib/git-daemon/$d/gm-it-probe" || exit 1
            rm -f "/var/lib/git-daemon/$d/gm-it-probe" || exit 1
        done
    ' >/dev/null 2>&1
}

# 在卷内预置夹具：保留标记、带 export-ok 的已发布仓库、未标记的未发布仓库，
# 并在已发布仓库上刻意设置 daemon.receivepack=true，用于证明 daemon 仍拒绝 push。
compose_create_fixtures() {
    local id script
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    script='set -e
umask 022
R=/var/lib/git-daemon
mkdir -p "$R/repos/fixtures"
printf "retention-marker-ok\n" > "$R/logs/retention-marker"
work="$R/tmp/fixture-src"
rm -rf "$work"; mkdir -p "$work"; cd "$work"
git init -q
git config user.email t@example.com
git config user.name t
printf "hello\n" > file.txt
git add file.txt
git commit -qm init
git branch -M trunk
rm -rf "$R/repos/fixtures/pub.git"
git clone -q --bare "$work" "$R/repos/fixtures/pub.git"
git --git-dir="$R/repos/fixtures/pub.git" config daemon.receivepack true
: > "$R/repos/fixtures/pub.git/git-daemon-export-ok"
rm -rf "$R/repos/fixtures/secret.git"
git clone -q --bare "$work" "$R/repos/fixtures/secret.git"
rm -f "$R/repos/fixtures/secret.git/git-daemon-export-ok"
'
    docker exec "$id" sh -c "$script" >/dev/null 2>&1
}

# daemon 在容器内确实监听 0.0.0.0:9418（LE hex 00000000:24CA），是发布端口可达的前提。
compose_publish_daemon_listens_9418() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    if docker exec "$id" sh -c 'grep -q "00000000:24CA" /proc/net/tcp'; then
        return 0
    fi
    printf '监听诊断（/proc/net/tcp 前若干行）：\n' >&2
    docker exec "$id" sh -c 'head -n 10 /proc/net/tcp' >&2 2>&1 || true
    return 1
}

# 宿主侧真实 git 客户端经容器发布端口访问：带 export-ok 的仓库可 ls-remote。
compose_publish_exported_readable() {
    local out status=0
    out=$(docker run --rm --network host --entrypoint git "$IMAGE" \
        ls-remote "git://127.0.0.1:$COMPOSE_PORT/fixtures/pub.git" 2>&1) || status=$?
    if [[ $status == 0 ]]; then return 0; fi
    printf 'ls-remote 失败诊断：%s\n' "$out" >&2
    return 1
}

# 未带 git-daemon-export-ok 的仓库必须被拒绝（非零退出）；先证明发布端口可达，避免把连接失败误判为拒绝。
compose_publish_unexported_rejected() {
    compose_publish_exported_readable || return 1
    local out status=0
    out=$(docker run --rm --network host --entrypoint git "$IMAGE" \
        ls-remote "git://127.0.0.1:$COMPOSE_PORT/fixtures/secret.git" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    case "$out" in *'not exported'*) return 0 ;; esac
    printf '未发布仓库拒绝诊断：%s\n' "$out" >&2
    return 1
}

# 即使夹具设置了 daemon.receivepack=true，daemon 以 --disable/--forbid-override 启动仍必须拒绝 push。
compose_publish_push_rejected() {
    compose_publish_exported_readable || return 1
    local script
    script='set -e
cd /tmp
rm -rf pushsrc; git init -q pushsrc; cd pushsrc
git config user.email t@example.com
git config user.name t
printf x > f
git add f
git commit -qm c
if git push "git://127.0.0.1:'"$COMPOSE_PORT"'/fixtures/pub.git" HEAD:refs/heads/gm-push >/dev/null 2>&1; then
    exit 1
fi
exit 0
'
    docker run --rm --network host --user 10001:10001 --entrypoint /bin/sh "$IMAGE" -c "$script" >/dev/null 2>&1
}

# 记录重建前卷内 mirror.env 的摘要，供“重建后字节不变”断言比对。
compose_record_mirror_env_sha() {
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/config/mirror.env' > "$TEST_ROOT/mirror.env.sha" 2>/dev/null || true
    return 0
}

# 容器重建后卷内 mirror.env 字节不变：既不被环境变量也不被默认值回写覆盖。
compose_mirror_env_unchanged() {
    local recorded now
    recorded=$(cat "$TEST_ROOT/mirror.env.sha" 2>/dev/null) || recorded=
    [[ -n $recorded ]] || return 1
    now=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/config/mirror.env' 2>/dev/null) || return 1
    [[ "$now" == "$recorded" ]]
}

# 重建后卷内保留标记仍在。
compose_retention_marker_present() {
    local content
    content=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'cat /var/lib/git-daemon/logs/retention-marker' 2>/dev/null) || return 1
    [[ $content == 'retention-marker-ok' ]]
}

# 重建后卷内预置仓库与其 refs、导出标记仍在。
compose_retention_repo_present() {
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" -c '
        d=/var/lib/git-daemon/repos/fixtures/pub.git
        [ -f "$d/git-daemon-export-ok" ] || exit 1
        git --git-dir="$d" rev-parse --verify refs/heads/trunk >/dev/null 2>&1 || exit 1
    ' >/dev/null 2>&1
}

# 容器内真实执行同步（上游仓库不存在，预期失败）：失败后必须保留已有 refs，且确实写入了新一轮同步日志。
compose_sync_failure_retains_cache() {
    local id dir before after before_count after_count script
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    dir="/var/lib/git-daemon/repos/octocat/Nonexistent-$COMPOSE_TAG.git"
    script='set -e
umask 022
R=/var/lib/git-daemon
work="$R/tmp/retain-src"
rm -rf "$work"; mkdir -p "$work"; cd "$work"
git init -q
git config user.email t@example.com
git config user.name t
printf x > f
git add f
git commit -qm c
git branch -M trunk
rm -rf '"$dir"'
git clone -q --bare "$work" '"$dir"'
git --git-dir='"$dir"' remote set-url origin https://github.com/octocat/Nonexistent-'"$COMPOSE_TAG"'.git
: > '"$dir"'/git-daemon-export-ok
'
    docker exec "$id" sh -c "$script" >/dev/null 2>&1 || return 1
    before=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "git --git-dir=$dir for-each-ref --format='%(refname) %(objectname)'" 2>/dev/null) || return 1
    [[ -n $before ]] || return 1
    before_count=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -c 'Nonexistent-$COMPOSE_TAG' /var/lib/git-daemon/logs/sync.log 2>/dev/null || echo 0" 2>/dev/null) || before_count=0
    before_count=${before_count:-0}
    if command -v timeout >/dev/null 2>&1; then
        timeout 90 docker exec -e HOME=/var/lib/git-daemon/home -e "REPOS=octocat/Nonexistent-$COMPOSE_TAG" "$id" \
            /usr/local/lib/git-mirror/git-mirror-sync.sh >/dev/null 2>&1 || true
    else
        docker exec -e HOME=/var/lib/git-daemon/home -e "REPOS=octocat/Nonexistent-$COMPOSE_TAG" "$id" \
            /usr/local/lib/git-mirror/git-mirror-sync.sh >/dev/null 2>&1 || true
    fi
    after=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "git --git-dir=$dir for-each-ref --format='%(refname) %(objectname)'" 2>/dev/null) || return 1
    after_count=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -c 'Nonexistent-$COMPOSE_TAG' /var/lib/git-daemon/logs/sync.log 2>/dev/null || echo 0" 2>/dev/null) || after_count=0
    after_count=${after_count:-0}
    if [[ "$before" != "$after" ]]; then
        printf '同步保留诊断：refs 发生变化\n%s\n-->\n%s\n' "$before" "$after" >&2
        return 1
    fi
    if [[ $after_count -le $before_count ]]; then
        printf '同步保留诊断：sync.log 行数未增加（before=%s after=%s）\n' "$before_count" "$after_count" >&2
        docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
            -c 'tail -n 8 /var/lib/git-daemon/logs/sync.log' >&2 2>&1 || true
        return 1
    fi
    return 0
}

# 记录停止前容器全部 PID，供停止后核对宿主机无残留项目进程。
compose_record_pids() {
    local id
    id=$(compose_container_id) || id=
    if [[ -n $id ]]; then
        docker top "$id" -o pid 2>/dev/null | tail -n +2 > "$TEST_ROOT/pids-before-stop" || true
    fi
    return 0
}

# docker stop 在 stop_grace_period（30s）内完成，且容器退出码不是 137（未被 SIGKILL 强杀）。
compose_stop_within_grace() {
    local id start elapsed code
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    start=$(date +%s)
    if ! docker stop -t 30 "$id" >/dev/null 2>&1; then return 1; fi
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= 30 )); then return 1; fi
    code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null) || return 1
    [[ "$code" != 137 ]] || return 1
    return 0
}

# 停止后宿主机不再存在停止前记录的任一容器项目进程（含同步/下载/调度子进程）。
compose_no_leftover_processes() {
    local pid file=$TEST_ROOT/pids-before-stop
    [[ -s $file ]] || return 1
    while IFS= read -r pid; do
        [[ -n $pid ]] || continue
        [[ $pid =~ ^[0-9]+$ ]] || continue
        if [[ -e /proc/$pid ]]; then return 1; fi
    done < "$file"
    return 0
}

# 调度场景：在就绪后（首次同步已完成）持续采样，等待调度器真实派发一次同步任务，
# 并捕获该 git-mirror-sync.sh 进程在宿主侧 /proc 中的实际 UID 必须为 10001。
compose_scheduler_dispatch_and_uid() {
    local id i pid pids cmd uid dispatched=no saw_uid=no
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    for i in $(seq 1 150); do
        if [[ $dispatched == no ]] && docker exec "$id" sh -c \
            'grep -q "开始仓库同步" /var/lib/git-daemon/logs/scheduler.log 2>/dev/null'; then
            dispatched=yes
        fi
        pids=$(docker top "$id" -o pid 2>/dev/null | tail -n +2) || pids=
        for pid in $pids; do
            [[ $pid =~ ^[0-9]+$ ]] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || cmd=
            case "$cmd" in
                *git-mirror-sync.sh*)
                    uid=$(sed -n 's/^Uid:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$pid/status" 2>/dev/null) || uid=
                    [[ $uid == 10001 ]] && saw_uid=yes
                    ;;
            esac
        done
        if [[ $dispatched == yes && $saw_uid == yes ]]; then return 0; fi
        sleep 0.5
    done
    return 1
}

# 调度任务失败不终止容器：容器仍处于运行状态。
compose_scheduler_container_alive() {
    local id
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == true ]]
}

# 在容器内以 10001 终止常驻 git-daemon；入口监督循环应检测到关键服务停止并使容器非零退出。
compose_kill_git_daemon_nonzero_exit() {
    local id pid i code
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    pid=$(docker exec "$id" sh -c 'cat /var/lib/git-daemon/runtime/git-daemon.pid 2>/dev/null') || return 1
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    docker exec "$id" sh -c "kill -TERM $pid" >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
        if [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == false ]]; then break; fi
        sleep 1
    done
    if [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) != false ]]; then return 1; fi
    code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null) || return 1
    [[ "$code" != 0 ]] || return 1
    compose logs --no-color 2>/dev/null | grep -q '关键服务 git-daemon 已停止'
}

# 向卷内写入不受支持的配置键，用于验证启动失败且诊断准确。
compose_write_invalid_config() {
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'mkdir -p /var/lib/git-daemon/config && printf "%s\n" "UNSUPPORTED_SETTING=1" > /var/lib/git-daemon/config/mirror.env'
}

# 非法卷内配置下编排启动并等待容器退出（restart=no 下退出稳定可观测）。
compose_start_expect_failure() {
    local id i
    compose_up || return 1
    for i in $(seq 1 40); do
        id=$(compose_container_id) || id=
        if [[ -n $id ]] && [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == false ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# 非法配置诊断：容器非零退出且日志明确指向“不支持的键”。
compose_invalid_config_diagnostic() {
    local id code
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null) || return 1
    [[ "$code" != 0 ]] || return 1
    compose logs --no-color 2>/dev/null | grep -q '不支持的键'
}

# 在测试作用域卷内预置一个有效地址快照与默认兼容的卷内配置，供地址刷新场景使用。
compose_prepare_hosts_snapshot() {
    local script
    script='R=/var/lib/git-daemon
mkdir -p "$R/config" "$R/hosts"
printf "%s\n" "LISTEN_ADDRESS=0.0.0.0" "GIT_PORT=9418" > "$R/config/mirror.env"
printf "%s\n" "# FORMAT=1" "# SOURCE=https://fixture.invalid/hosts" "# FETCHED=2026-01-01T00:00:00+0000" "# DIGEST=sha256:fixture" "# COUNT=1" "140.82.112.3 github.com" > "$R/hosts/github-hosts.snapshot"
rm -f "$R/hosts/github-hosts.stale"
'
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" -c "$script"
}

# 记录刷新前快照摘要，供保留性断言比对。
compose_record_snapshot_sha() {
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/hosts/github-hosts.snapshot' > "$TEST_ROOT/snapshot.sha" 2>/dev/null || true
    return 0
}

# 启动与目标容器共享网络命名空间的自签名 HTTPS 夹具（openssl s_server），不关闭任何校验。
compose_start_tls_fixture() {
    local id i rc script
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    docker rm -f "$TLS_FIXTURE_NAME" >/dev/null 2>&1 || true
    script='cd /tmp
printf "%s\n" "140.82.112.3 github.com" > hosts
if [ ! -f cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 -keyout key.pem -out cert.pem -days 1 >/dev/null 2>&1
fi
exec openssl s_server -accept '"$TLS_FIXTURE_PORT"' -cert cert.pem -key key.pem -WWW -quiet
'
    docker run -d --rm --name "$TLS_FIXTURE_NAME" --network "container:$id" --user 10001:10001 \
        --entrypoint /bin/sh "$IMAGE" -c "$script" >/dev/null 2>&1 || return 1
    for i in $(seq 1 20); do
        rc=0
        docker exec "$id" sh -c "curl -sS --proto '=https' --tlsv1.2 --max-time 3 -o /dev/null 'https://127.0.0.1:$TLS_FIXTURE_PORT/hosts'" >/dev/null 2>&1 || rc=$?
        if [[ $rc != 7 ]]; then return 0; fi
        sleep 0.5
    done
    return 1
}

# 卷内已有有效快照时把 HOSTS_URL 指向自签名夹具：交付刷新入口在容器内执行，TLS 校验失败被拒绝。
compose_hosts_tls_rejected() {
    local id out status=0 rc=0
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    out=$(docker exec -e HOME=/var/lib/git-daemon/home -e ENABLE_HOSTS_UPDATE=yes -e HOSTS_URL_FALLBACK= \
        -e "HOSTS_URL=https://127.0.0.1:$TLS_FIXTURE_PORT/hosts" \
        "$id" /usr/local/lib/git-mirror/update-github-hosts.sh 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    case "$out" in
        *certificate*|*SSL*|*ssl*|*证书*) return 0 ;;
    esac
    docker exec "$id" sh -c "curl -sS --proto '=https' --tlsv1.2 --max-time 5 -o /dev/null 'https://127.0.0.1:$TLS_FIXTURE_PORT/hosts'" >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 ]]
}

# TLS 失败后旧快照字节不变，并出现陈旧标记。
compose_hosts_snapshot_retained() {
    local recorded now
    recorded=$(cat "$TEST_ROOT/snapshot.sha" 2>/dev/null) || recorded=
    [[ -n $recorded ]] || return 1
    now=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/hosts/github-hosts.snapshot' 2>/dev/null) || return 1
    [[ "$now" == "$recorded" ]] || return 1
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c '[ -e /var/lib/git-daemon/hosts/github-hosts.stale ]' >/dev/null 2>&1
}

# 刷新日志记录数据源失败告警。
compose_hosts_warning_logged() {
    docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -q '数据源失败' /var/lib/git-daemon/logs/hosts.log" >/dev/null 2>&1
}

# 来源不可达时仍保留旧快照，且容器不退出。
compose_hosts_unreachable_retained() {
    local id recorded now status=0
    id=$(compose_container_id) || return 1
    [[ -n $id ]] || return 1
    recorded=$(cat "$TEST_ROOT/snapshot.sha" 2>/dev/null) || recorded=
    [[ -n $recorded ]] || return 1
    docker exec -e HOME=/var/lib/git-daemon/home -e ENABLE_HOSTS_UPDATE=yes -e HOSTS_URL_FALLBACK= \
        -e "HOSTS_URL=https://unreachable.invalid/hosts" \
        "$id" /usr/local/lib/git-mirror/update-github-hosts.sh >/dev/null 2>&1 || status=$?
    [[ $status != 0 ]] || return 1
    now=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/hosts/github-hosts.snapshot' 2>/dev/null) || return 1
    [[ "$now" == "$recorded" ]] || return 1
    [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == true ]]
}

# 停止并删除测试 compose 项目、网络与测试作用域卷，并移除本脚本附加的镜像标签；无残留。
compose_teardown() {
    docker rm -f "$TLS_FIXTURE_NAME" >/dev/null 2>&1 || true
    IMAGE_TAG=$COMPOSE_TAG REPOS=$TEST_REPO \
        compose down -v --remove-orphans >/dev/null 2>&1 || true
    docker volume rm -f "$COMPOSE_VOLUME" >/dev/null 2>&1 || true
    docker image rm -f "$COMPOSE_IMAGE" >/dev/null 2>&1 || true
    return 0
}

# docker 完全不可用（CLI 缺失或守护进程不可达）才整体跳过并返回 77。
if ! docker_available; then
    printf 'SKIP：docker 不可用，未执行\n'
    exit 77
fi

write_compose_override

COMPOSE_ENABLED=0
if compose_available; then
    COMPOSE_ENABLED=1
fi

check 'docker build --no-cache 退出码为 0' build_image
check '镜像默认运行身份为 10001:10001' image_user_is_nonroot
check '镜像实际运行身份真实与有效 UID 均为 10001' run_identity_nonroot
check '由 RUN 生成的路径属主为 10001（构建步骤非 root）' build_paths_owned_by_app
check '运行根属主 10001、权限 755' runtime_root_attributes
check '空命名卷首次挂载后以 10001 可写入' named_volume_writable
check '运行时依赖命令与 CA/时区文件齐备' runtime_dependencies_present
check '镜像不含 SSH 组件' no_ssh_components
check '入口拒绝 UID 0' entry_rejects_root

if [[ $COMPOSE_ENABLED == 1 ]]; then
    # 后续所有 compose 子命令（ps/logs/down）都需成功渲染镜像引用，故在此统一导出 IMAGE_TAG。
    export IMAGE_TAG=$COMPOSE_TAG
    check 'Compose 为本地镜像附加 registry 标签' compose_tag_local_image
    check 'Compose 显式 IMAGE_TAG 时 config 有效' compose_config_accepts_explicit_tag
    check 'Compose 缺少 IMAGE_TAG 时 config 失败' compose_config_rejects_missing_tag
    check 'Compose 生产重启策略未被测试改动（unless-stopped）' compose_production_restart_policy

    # 场景 S0：卷内非默认配置回归（沿用既有断言）。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no")
    check 'Compose 预置卷内 mirror.env 配置' compose_prepare_volume_config
    check 'Compose 独立项目名与空闲端口启动' compose_start
    check 'Compose 容器进入运行状态' compose_wait_running
    check 'Compose 容器以 UID 10001 运行' compose_runs_as_nonroot
    check 'Compose 根文件系统只读' compose_readonly_rootfs
    check 'Compose 丢弃全部能力' compose_cap_drop_all
    check 'Compose 禁止提权' compose_no_new_privileges
    check 'Compose 命名卷挂载到 /var/lib/git-daemon' compose_named_volume_mounted
    check 'Compose 命名卷内可写' compose_volume_writable
    check 'Compose 卷内配置覆盖默认值（配置入口）' compose_volume_config_reachable
    check 'Compose 卷内配置在真实监听上生效' compose_daemon_listens_from_volume
    compose_remove_container

    # 场景 S0b：显式环境变量优先于卷内配置。卷内 mirror.env 为 127.0.0.1:19418，
    # 宿主机显式设置 LISTEN_ADDRESS=0.0.0.0 与 GIT_PORT=19428，容器必须实际生效环境变量值。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no" \
        "LISTEN_ADDRESS=$COMPOSE_ENV_CONFIG_ADDR" "GIT_PORT=$COMPOSE_ENV_CONFIG_PORT")
    check 'Compose 环境变量覆盖场景启动' compose_start
    check 'Compose 环境变量覆盖场景就绪' compose_wait_running
    check '显式环境变量覆盖卷内配置（配置入口）' compose_env_overrides_volume_config
    check '显式环境变量覆盖卷内配置（真实监听）' compose_daemon_listens_from_env
    compose_remove_container

    # 场景 S1：运行期只读根与全进程非 root、实例数据落卷、发布边界、失败保留、数据重建保留。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no")
    check 'Compose 预置发布用卷内配置' compose_prepare_publish_volume
    check 'Compose 发布场景启动' compose_start
    check 'Compose 发布场景就绪' compose_wait_running
    check '运行期容器内全部进程 UID 均为 10001（无一为 0）' compose_all_processes_nonroot
    check '运行期只读根：/ /etc /tmp /run /var/log 写入均失败' compose_readonly_runtime_paths
    check '实例数据目录均位于命名卷且以 10001 可写' compose_instance_data_on_volume
    check '发布边界：daemon 监听 0.0.0.0:9418（发布端口前提）' compose_publish_daemon_listens_9418
    check '卷内预置夹具（保留标记/已发布/未发布仓库）' compose_create_fixtures
    check '发布边界：带 export-ok 仓库可 ls-remote' compose_publish_exported_readable
    check '发布边界：未带 export-ok 仓库被拒绝' compose_publish_unexported_rejected
    check '发布边界：即使 receivepack=true 也拒绝 push' compose_publish_push_rejected
    compose_record_mirror_env_sha
    check '同步失败保留已有缓存（容器内真实同步）' compose_sync_failure_retains_cache
    compose_remove_container
    check 'Compose 停止并删除容器后重建（保留命名卷）' compose_start
    check '数据保留：重建后容器就绪' compose_wait_running
    check '数据保留：卷内标记文件仍在' compose_retention_marker_present
    check '数据保留：卷内预置仓库与导出标记仍在' compose_retention_repo_present
    check '数据保留：daemon 重建后仍对外提供该仓库' compose_publish_exported_readable
    check '卷内配置：重建后 mirror.env 字节不变' compose_mirror_env_unchanged
    compose_remove_container

    # 场景 S2：调度真实派发与以非 root 执行；随后 docker stop 宽限期内退出且无残留进程。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=yes" "CRON_SCHEDULE=* * * * *")
    check 'Compose 调度场景启动' compose_start
    check 'Compose 调度场景就绪' compose_wait_running
    check '调度场景容器内全部进程 UID 均为 10001' compose_all_processes_nonroot
    check '调度：真实派发同步任务且同步进程 UID=10001' compose_scheduler_dispatch_and_uid
    check '调度：单次任务失败不终止容器' compose_scheduler_container_alive
    compose_record_pids
    check '停止：docker stop 在宽限期内退出且退出码非 137' compose_stop_within_grace
    check '停止：宿主机无残留容器项目进程' compose_no_leftover_processes
    compose_remove_container

    # 场景 S3：容器内终止常驻 git-daemon，入口监督循环应使容器非零退出。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no")
    check 'Compose 关键服务停止检测场景启动' compose_start
    check 'Compose 关键服务停止检测场景就绪' compose_wait_running
    check '关键服务 git-daemon 被终止后容器非零退出' compose_kill_git_daemon_nonzero_exit
    compose_remove_container

    # 场景 S4：卷内非法配置使容器启动失败并以非零退出、诊断准确。
    check '卷内写入非法配置键' compose_write_invalid_config
    check '非法配置：容器启动失败退出' compose_start_expect_failure
    check '非法配置：诊断明确指向不支持的键' compose_invalid_config_diagnostic
    compose_remove_container

    # 场景 S5：自签名 HTTPS 夹具下地址刷新被拒绝、旧快照保留；不可达来源同样保留且容器不退出。
    check 'Compose 预置有效地址快照与卷内配置' compose_prepare_hosts_snapshot
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no")
    check 'Compose 地址刷新场景启动' compose_start
    check 'Compose 地址刷新场景就绪' compose_wait_running
    check '自签名 HTTPS 夹具启动（共享容器网络命名空间）' compose_start_tls_fixture
    compose_record_snapshot_sha
    check '地址刷新：自签名 TLS 校验失败被拒绝' compose_hosts_tls_rejected
    check '地址刷新：旧快照保留且标记陈旧' compose_hosts_snapshot_retained
    check '地址刷新：刷新日志记录数据源失败告警' compose_hosts_warning_logged
    check '地址刷新：来源不可达仍保留旧快照且容器不退出' compose_hosts_unreachable_retained
    compose_remove_container

    # 场景 S6：docker kill（SIGKILL）终止容器后同卷重建。SIGKILL 不触发入口信号处理，
    # 卷内残留 OpenRC 用户态“已启动”状态与陈旧 pidfile；重建后 daemon 必须真实恢复监听，
    # 并通过发布端口对外可达（而非仅 .State.Running 为真）。
    COMPOSE_ENV=("REPOS=$TEST_REPO" "ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no")
    check 'Compose 强杀重建场景预置发布用卷内配置' compose_prepare_publish_volume
    check 'Compose 强杀重建场景启动' compose_start
    check 'Compose 强杀重建场景就绪' compose_wait_running
    check '卷内预置夹具（强杀重建场景）' compose_create_fixtures
    check '强杀重建场景：强杀前发布端口真实可达' compose_publish_exported_readable
    check '强杀重建场景：docker kill（SIGKILL）并删除容器' compose_kill_container
    check 'Compose 强杀后同卷重建启动' compose_start
    check 'Compose 强杀后同卷重建就绪' compose_wait_running
    check '强杀重建后 daemon 真实监听 9418' compose_publish_daemon_listens_9418
    check '强杀重建后发布端口真实可达（非仅 State.Running）' compose_publish_exported_readable
    compose_remove_container

    compose_teardown
else
    printf '注意：docker compose 不可用，Compose 编排实机检查未执行\n'
fi

printf '容器实机集成检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
