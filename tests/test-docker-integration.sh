#!/usr/bin/env bash

# 容器实机集成检查：真实执行 docker build 与容器命令，核验非 root Alpine 镜像的构建与运行身份、
# 命名卷属主继承、依赖完整性以及无 SSH 组件；并在 compose 可用时基于 compose.yml 真实编排，
# 核验只读根、cap_drop ALL、no-new-privileges、命名卷挂载、卷内配置层、运行期全进程非 root、
# 实例数据落卷、数据重建保留、停止与信号回收、关键服务停止退出、非法配置启动失败、
# 调度真实派发、发布边界（export-ok/receive-pack）、自签名 HTTPS 地址刷新被拒绝、
# 显式环境变量对卷内配置的优先级以及强杀（SIGKILL）后同卷重建的真实可达性。
# 另在隔离 HTTPS 夹具（自定义网络 + github.com DNS 别名 + 测试 CA）下用真实 Git 客户端与真实网络请求
# 验证产品保持 https://github.com/<owner>/<repo>.git 与 TLS 校验时的首次/重复/指定分支同步、远端更新、
# 失败保留、未发布不可读、receive-pack 拒绝以及 /repo 与 /repo.git 双形式指向预期提交。
# 同一夹具网络内还以测试私有的 HTTPS CONNECT 代理验证代理传输路径（代理侧 CONNECT 计数）、
# 传输顺序（proxy → mapping → system）与非代理尝试不经过代理，并用受认证上游与合成 Token 验证
# 凭据只进入同步路径、常驻 daemon 进程环境不含 Token。
# docker 完全不可用时整段跳过并返回 77；仅 compose 缺失时 docker-only 覆盖照常执行。
# 另在 C-2 有界停止场景内用隔离网络与「快速失败/挂起」TCP 端点夹具，对首次同步、定时同步与
# 定时 hosts 刷新构造多层子孙并发送 TERM/INT，以共享 PID 命名空间的采样侧车证明子孙在 PID1 存活
# 期间被回收、锁被释放且不再派发；设置 IT_FILTER=c2 可只跑镜像静态检查与该场景。

set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${IT_PRODUCT_IMAGE:-git-daemon:test}
source "$ROOT/tests/docker-integration-startup.sh"
FAILURES=0
CHECKS=0
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-docker-it.XXXXXXXX") || exit 1
BUILD_LOG=$TEST_ROOT/build.log
VOLUME=gm-${IT_RUN_ID:-it-$$}-scratch
COMPOSE_FILE=$ROOT/compose.yml
COMPOSE_OVERRIDE=$TEST_ROOT/compose.override.yml
COMPOSE_TAG=it-$$
COMPOSE_IMAGE=ghcr.io/neanc/git-daemon:$COMPOSE_TAG
COMPOSE_PROJECT=gm-it-$$
COMPOSE_VOLUME=gm-${IT_RUN_ID:-it-$$}-compose-data
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
O1_NET=${IT_NETWORK:-gm-it-isolated-$$}
O1_VOL=gm-${IT_RUN_ID:-it-$$}-rejectvol
O1_CA_VOL=gm-${IT_RUN_ID:-it-$$}-ca
O1_UP=gm-${IT_RUN_ID:-it-$$}-reject
O1_CA=/ca/ca.crt

# 创建共享拒绝端点和独立只读 CA 卷；产品空数据卷不预填。
o1_prepare() {
    network_fixture_start || return $?
    docker volume create "$O1_VOL" >/dev/null || return 1
    docker volume create "$O1_CA_VOL" >/dev/null || return 1
    bash "$FIXTURE_SCRIPT" prepare "$O1_VOL" "$IMAGE" acme/reject || return 1
    bash "$FIXTURE_SCRIPT" ca "$O1_VOL" "$IMAGE" | docker run --rm -i --network none \
        --read-only --cap-drop ALL --security-opt no-new-privileges --user 10001:10001 \
        -v "$O1_CA_VOL:/var/lib/git-daemon" --entrypoint sh "$IMAGE" \
        -c 'cat > /var/lib/git-daemon/ca.crt' || return 1
    bash "$FIXTURE_SCRIPT" reject-start "$O1_VOL" "$IMAGE" "$O1_NET" "$O1_UP" || return 1
    container_networks_internal "$O1_UP"
}

# 返回端点实际收到的请求数量，不以产品日志代替上游观测。
o1_requests() {
    docker exec "$O1_UP" sh -c 'if [ -f /var/lib/git-daemon/fixture/reject.requests ]; then wc -l < /var/lib/git-daemon/fixture/reject.requests; else printf "0\n"; fi'
}
# 就绪判据探针端口：在一次性容器内构造真实 LISTEN 与「本地端口恰为该端口」的非 LISTEN 已建立连接；
# 容器使用独立网络命名空间，该端口只需在容器内空闲。
READINESS_PORT=19424
# 空命名卷正式启动校验使用的独立容器与卷名：检查内自清理，并由全局清理兜底。
EMPTY_CONTAINER=gm-it-empty-$$
EMPTY_VOLUME=gm-${IT_RUN_ID:-it-$$}-empty
# 阶段 D：TZ 覆盖与调度生效夹具。同一命名卷写入 TZ=Asia/Shanghai，run `-e TZ=UTC` 与 Compose 环境
# TZ=UTC 都必须使最终有效值为 UTC；不传 TZ 时读取卷内值，全新卷回退默认 Asia/Shanghai。
# 固定时间戳 TZ_FIXED_NOW 下，同步表达式与 hosts 表达式的下一次触发按最终有效时区各自独立推出。
TZ_CONTAINER=gm-it-tz-$$
TZ_VOLUME=gm-${IT_RUN_ID:-it-$$}-tz
TZ_MOUNT=/var/lib/git-daemon
TZ_CRON_SYNC='0 20 * * *'
TZ_CRON_HOSTS='15 20 * * *'
TZ_FIXED_NOW=1700000000
# 固定时间戳 1700000000 = 2023-11-14T22:13:20Z（同一瞬间 Asia/Shanghai 为 2023-11-15 06:13:20）。
# 下一次触发按各自墙钟独立推出，两时区相差 8 小时（28800 秒）。
TZ_SYNC_UTC=1700078400
TZ_SYNC_SHANGHAI=1700049600
TZ_HOSTS_UTC=1700079300
TZ_HOSTS_SHANGHAI=1700050500
TZ_RUN_READY=0
TZ_VOL_READY=0
TZ_DEF_READY=0
TZ_COMPOSE_READY=0
TZ_COMPOSE2_READY=0
# 地址刷新夹具：与目标容器共享网络命名空间的自签名 HTTPS 服务名与端口。
TLS_FIXTURE_NAME=gm-it-tls-$$
TLS_FIXTURE_PORT=$((COMPOSE_PORT + 10000))
# 隔离 HTTPS 同步夹具：独立命名卷、自定义网络、github.com DNS 别名与测试 CA；夹具失败独立计数。
FIXTURE_SCRIPT=$ROOT/tests/docker-https-fixture.sh
FIXTURE_NET=${IT_NETWORK:-gm-it-net-$$}
FIXTURE_FIX_VOL=gm-${IT_RUN_ID:-it-$$}-fixvol
FIXTURE_PROD_VOL=gm-${IT_RUN_ID:-it-$$}-prodvol
FIXTURE_NAME=gm-it-upstream-$$
FIXTURE_PROD=gm-it-sync-$$
FIXTURE_REPO=acme/demo
FIXTURE_MOUNT=/var/lib/git-daemon
FIXTURE_HOME=$FIXTURE_MOUNT/home
FIXTURE_CA_VOL=gm-${IT_RUN_ID:-it-$$}-fixture-ca
FIXTURE_CA=$FIXTURE_MOUNT/fixture/tls/ca.crt
FIXTURE_CHECKS=0
FIXTURE_FAILURES=0
FIXTURE_READY=0
# 隔离网络使用公开格式网段：地址映射快照必须是合法公开地址，流量只在 Docker 网络内到达夹具容器，
# 不会发往真实公网地址，也不把私网/元数据地址写进被校验的快照。
FIXTURE_SUBNET=140.82.112.0/24
# HTTPS CONNECT 代理夹具：网络别名 gm-proxy；8443 接受，8444 可达但拒绝目标 CONNECT（计数后回 403）。
FIXTURE_PROXY_URL=https://gm-proxy:8443
FIXTURE_REJECT_PROXY=https://gm-proxy:8444
FIXTURE_PROXY_NAME=gm-it-proxy-$$
FIXTURE_CONNECT_COUNT=$FIXTURE_MOUNT/fixture/connect.count
FIXTURE_GITCONFIG=$FIXTURE_MOUNT/fixture/gitconfig
FIXTURE_SNAPSHOT=$FIXTURE_MOUNT/hosts/github-hosts.snapshot
# 地址内容夹具：可信来源端点（测试 CA 签发，SAN=hosts-source.test）与错误证书端点
# （自签证书，SAN=hosts-badcert.test）。文件由夹具 hosts-put 发布，覆盖多地址/空/超限/备用内容。
FIXTURE_HOSTS_ALIAS=hosts-source.test
FIXTURE_HOSTS_BAD_ALIAS=hosts-badcert.test
FIXTURE_HOSTS_URL=https://hosts-source.test/hosts
FIXTURE_HOSTS_URL2=https://hosts-source.test/hosts2
FIXTURE_HOSTS_EMPTY_URL=https://hosts-source.test/empty
FIXTURE_HOSTS_BIG_URL=https://hosts-source.test/big
FIXTURE_HOSTS_BAD_URL=https://hosts-badcert.test/hosts
FIXTURE_HOSTS_NAME=gm-it-hosts-src-$$
FIXTURE_HOSTS_BAD_NAME=gm-it-hosts-bad-$$
HOSTS_READY=0
PROXY_READY=0
# 凭据隔离夹具：独立网络与产品卷；合成测试 Token（非真实私人 Token），只在容器环境变量中传递。
AUTH_TOKEN=ghp_SYNTHETICB2ATOKEN0000000000000000
AUTH_NET=${IT_NETWORK:-gm-it-authnet-$$}
AUTH_PROD_VOL=gm-${IT_RUN_ID:-it-$$}-authvol
AUTH_UP=gm-it-authup-$$
AUTH_PROD=gm-it-authsync-$$
AUTH_READY=0
# 产品容器就绪标志：入口前台就绪属夹具步骤，失败只在夹具计数并在本标志上 gate 依赖断言，避免级联。
AUTH_PROD_READY=0
# 场景化 compose 透传环境变量（列表形式）；compose_up 负责导出后编排。
COMPOSE_ENV=()
# 可选过滤：设置 IT_FILTER=c2 时只执行镜像静态检查与 C-2 有界停止场景，便于定向红绿取证；
# 不设置时行为不变（执行完整套件）。
IT_FILTER=${IT_FILTER-}

# o1 使用明确场景白名单；c2 保留历史共享空卷与 TZ 前置。
integration_group_selected() {
    case "${IT_FILTER:-}:$1" in
        :*) return 0 ;;
        o1:network|o1:empty|o1:tz|o1:compose-publish) return 0 ;;
        c2:network|c2:empty|c2:tz|c2:c2) return 0 ;;
        *) return 1 ;;
    esac
}

# 阶段 C-2 有界停止场景：独立命名网络 + 「快速失败/挂起」TCP 端点夹具 + 共享 PID 命名空间的采样侧车。
# 夹具在 443 上接受后立即关闭（使首次同步/首次刷新快速失败，容器能进入就绪）；
# 在 8443 上前 N 次同样立即关闭、之后挂起不响应（使首次任务或定时任务形成可控长进程与多层子孙）。
C2_NET=${IT_NETWORK:-gm-it-c2net-$$}
C2_FIX=gm-it-c2fix-$$
C2_PROD=gm-it-c2prod-$$
C2_SAMP=gm-it-c2samp-$$
C2_VOL=gm-${IT_RUN_ID:-it-$$}-c2vol
C2_LOG_VOL=gm-${IT_RUN_ID:-it-$$}-c2log
C2_MOUNT=/var/lib/git-daemon
# 采样侧车挂载产品运行卷的路径：仅用于在 PID1 存活窗口内尝试取操作锁，绝不写入产品卷。
C2_PROD_MOUNT=/prod
C2_SAMPLE=$C2_MOUNT/c2-sample.txt
C2_READY=0
C2_STOP_FILE=$TEST_ROOT/c2-stop-result
C2_TIMELINE=$TEST_ROOT/c2-timeline.txt
C2_FACT_FILE=$TEST_ROOT/c2-facts.txt
# 停止信号的卷内标记文件：采样侧车据此在信号后进入紧凑采样。
C2_SIGNAL_FILE=$C2_MOUNT/c2-signal
# 任务标记：出现在任务进程树中的可执行/脚本名，用于识别「多层子孙」并检查回收。
C2_MARKERS='git-mirror-sync\.sh|update-github-hosts\.sh|git-remote-(https|curl)|git .*fetch|tee -a [^ ]*sync\.log|curl '

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
    labels:
      gitdaemon.run: "$IT_RUN_ID"
    dns:
      - $IT_DNS_IP
    sysctls:
      net.ipv6.conf.all.disable_ipv6: "1"
    networks:
      default:
        ipv4_address: 172.30.243.4
    environment:
      - GIT_SSL_CAINFO=$O1_CA
    volumes:
      - type: volume
        source: test-ca
        target: /ca
        read_only: true
volumes:
  test-ca:
    external: true
    name: $O1_CA_VOL
  git-daemon-data:
    name: $COMPOSE_VOLUME
    labels:
      gitdaemon.run: "$IT_RUN_ID"
networks:
  default:
    external: true
    name: $O1_NET
EOF
}

# 在删除资源前保存日志与网络附件；证据目录必须位于 TEST_ROOT 清理范围之外。
archive_container() {
    local name=$1 network destination identity
    [[ -n ${IT_EVIDENCE_DIR:-} ]] || return 0
    identity=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || return 0
    destination=$IT_EVIDENCE_DIR/control/artifacts/$identity-$(date +%s%N)
    mkdir -p "$destination"
    docker inspect "$name" >"$destination/inspect.json" 2>/dev/null || return 0
    docker logs "$name" >"$destination/container.log" 2>&1 || true
    while IFS= read -r network; do
        [[ -n $network ]] || continue
        docker network inspect "$network" >"$destination/$network.network.json" 2>/dev/null || true
    done < <(docker inspect -f '{{range $name, $value := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$name")
    docker exec "$name" sh -c 'if [ -f /var/lib/git-daemon/fixture/reject.requests ]; then cat /var/lib/git-daemon/fixture/reject.requests; fi' \
        >"$destination/requests.log" 2>/dev/null || true
    return 0
}

# 核查全部网络附件及完整受控策略，非 internal 授权网络也必须通过。
container_networks_internal() {
    archive_container "$1"
    assert_container_network_policy "$1"
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
    local name
    for name in "$O1_UP" "$EMPTY_CONTAINER" "$TZ_CONTAINER" "$FIXTURE_NAME" "$FIXTURE_PROD" "$AUTH_UP" "$AUTH_PROD" "$C2_FIX" "$C2_PROD"; do
        archive_container "$name"
    done
    if [[ -n ${IT_EVIDENCE_DIR:-} ]]; then
        mkdir -p "$IT_EVIDENCE_DIR/control/artifacts"
        cp -R "$TEST_ROOT/." "$IT_EVIDENCE_DIR/control/artifacts/" || return 2
    fi
    if [[ -n ${C2_SAMP:-} ]]; then
        docker rm -f "$C2_SAMP" >/dev/null 2>&1 || true
    fi
    if [[ -n ${C2_PROD:-} ]]; then
        docker rm -f "$C2_PROD" >/dev/null 2>&1 || true
    fi
    if [[ -n ${C2_FIX:-} ]]; then
        docker rm -f "$C2_FIX" >/dev/null 2>&1 || true
    fi
    if [[ -n ${C2_VOL:-} || -n ${C2_LOG_VOL:-} ]]; then
        docker volume rm -f "$C2_VOL" "$C2_LOG_VOL" >/dev/null 2>&1 || true
    fi
    if [[ -n ${TLS_FIXTURE_NAME:-} ]]; then
        docker rm -f "$TLS_FIXTURE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${EMPTY_CONTAINER:-} ]]; then
        docker rm -f "$EMPTY_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n ${EMPTY_VOLUME:-} ]]; then
        docker volume rm -f "$EMPTY_VOLUME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${TZ_CONTAINER:-} ]]; then
        docker rm -f "$TZ_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n ${TZ_VOLUME:-} ]]; then
        docker volume rm -f "$TZ_VOLUME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_NAME:-} ]]; then
        docker rm -f "$FIXTURE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_PROD:-} ]]; then
        docker rm -f "$FIXTURE_PROD" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_PROXY_NAME:-} ]]; then
        docker rm -f "$FIXTURE_PROXY_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_HOSTS_NAME:-} ]]; then
        docker rm -f "$FIXTURE_HOSTS_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_HOSTS_BAD_NAME:-} ]]; then
        docker rm -f "$FIXTURE_HOSTS_BAD_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n ${AUTH_UP:-} ]]; then
        docker rm -f "$AUTH_UP" >/dev/null 2>&1 || true
    fi
    if [[ -n ${AUTH_PROD:-} ]]; then
        docker rm -f "$AUTH_PROD" >/dev/null 2>&1 || true
    fi
    if [[ -n ${FIXTURE_FIX_VOL:-} || -n ${FIXTURE_PROD_VOL:-} ]]; then
        docker volume rm -f "$FIXTURE_FIX_VOL" "$FIXTURE_PROD_VOL" "$FIXTURE_CA_VOL" >/dev/null 2>&1 || true
    fi
    if [[ -n ${AUTH_PROD_VOL:-} ]]; then
        docker volume rm -f "$AUTH_PROD_VOL" >/dev/null 2>&1 || true
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
    docker rm -f "$O1_UP" >/dev/null 2>&1 || true
    docker volume rm -f "$O1_VOL" "$O1_CA_VOL" >/dev/null 2>&1 || true
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

# 入口拒绝 UID 0：在非 root 容器内以 UID 查询测试替身（桩 id 返回 0）驱动正式入口启动路径，
# 断言身份守卫拒绝并给出 root 诊断。明确：这不是实际 root 容器验证，避免执行越界（真实 root）负例。
entry_rejects_root() {
    local output status=0 script
    script=$(cat <<'STUB'
set -uo pipefail
id() { echo 0; }
source /usr/local/bin/git-mirror-entrypoint
main
STUB
)
    output=$(docker run --rm --user 10001:10001 --read-only --cap-drop ALL \
        --security-opt no-new-privileges --entrypoint /bin/bash "$IMAGE" -c "$script" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output == *'禁止以 root'* ]]
}

# 就绪判据探针：在正式镜像内以桩程序层（仅含 git-daemon-config.sh 输出指定端口）驱动正式入口的
# confirm_daemon_listening。mode=listen 时在容器内建立真实 LISTEN；mode=connect 时建立一条本地端口恰为
# 该端口的已建立（非 LISTEN）连接。
# 关键：调用目标函数之前先在探针内 grep 内核 TCP 表自证夹具成立——存在本地地址端口 == GM_PORT 且状态
# 符合模式（listen 为 0A；connect 为非 0A）的条目；缺失即视为夹具失效（返回码 2），绝不静默空转通过。
# 返回码约定：0 = 断言通过，1 = 产品断言不符预期，2 = 夹具失效（未建立预期条目 / 未执行到目标函数）。
readiness_probe() {
    local port=$1 mode=$2 expect=$3
    local script out rc=0 ok=0 fixture_line=
    script=$(cat <<'PROBE'
set -u
umask 022
stub=/var/lib/git-daemon/readiness-stub
peer=$((GM_PORT + 1))
port_hex=$(printf '%04X' "$GM_PORT")
if [ "$GM_MODE" = listen ]; then want=0A wantdesc='=0A'; else want=nonlisten wantdesc='≠0A'; fi
cleanup_probe() { rm -rf "$stub"; }
trap cleanup_probe EXIT
mkdir -p "$stub"
printf '#!/bin/sh\necho %s\n' "$GM_PORT" >"$stub/git-daemon-config.sh"
chmod 755 "$stub/git-daemon-config.sh"
if [ "$GM_MODE" = listen ]; then
    sleep 30 | busybox nc -l -p "$GM_PORT" >/dev/null 2>&1 &
else
    sleep 30 | busybox nc -l -p "$peer" >/dev/null 2>&1 &
    sleep 0.5
    sleep 30 | busybox nc -p "$GM_PORT" 127.0.0.1 "$peer" >/dev/null 2>&1 &
fi
sleep 1
tables=""
for f in /proc/net/tcp /proc/net/tcp6; do [ -r "$f" ] && tables="$tables $f"; done
observed=$(busybox awk -v p="$port_hex" -v want="$want" 'NR>1 { split($2,a,":"); st=toupper($4); if (a[2]==p && (want=="0A" ? st=="0A" : st!="0A")) { print st; exit } }' $tables)
if [ -z "$observed" ]; then
    printf '夹具失效：内核表无本地端口 %s（%s）且状态%s 的条目\n' "$GM_PORT" "$port_hex" "$wantdesc"
    busybox awk 'NR>1 { print "  " $1 " " $2 " " toupper($4) }' $tables
    exit 90
fi
printf '夹具自证：内核表存在 local_address 端口=%s（%s）状态=%s（mode=%s）\n' "$GM_PORT" "$port_hex" "$observed" "$GM_MODE"
INSTALL_ROOT="$stub" bash -c 'source /usr/local/bin/git-mirror-entrypoint; confirm_daemon_listening'
rc=$?
printf 'confirm_daemon_listening 返回码=%s（mode=%s port=%s）\n' "$rc" "$GM_MODE" "$GM_PORT"
exit "$rc"
PROBE
)
    out=$(docker run --rm --user 10001:10001 --read-only --cap-drop ALL \
        --security-opt no-new-privileges -v "$VOLUME:/var/lib/git-daemon" \
        -e "GM_PORT=$port" -e "GM_MODE=$mode" --entrypoint /bin/bash "$IMAGE" -c "$script" 2>&1) || rc=$?
    fixture_line=$(printf '%s\n' "$out" | grep -m1 '^夹具自证：' || true)
    [[ -n $fixture_line ]] && printf '    %s\n' "$fixture_line" >&2
    # 夹具失效：容器以 90 显式报告，或探针根本未执行到目标函数（入口被 source 时若仍进入 main，
    # 容器会提前退出，此时返回码没有意义）。两种情况都属夹具问题，必须与产品断言结果区分开。
    if [[ $rc == 90 || $out == *'夹具失效：'* || $out != *'confirm_daemon_listening 返回码='* ]]; then
        printf '就绪判据探针夹具失效（mode=%s port=%s，退出码 %s）：\n%s\n' \
            "$mode" "$port" "$rc" "$out" >&2
        return 2
    fi
    if [[ $expect == 0 ]]; then
        [[ $rc == 0 ]] && ok=1
    else
        [[ $rc != 0 ]] && ok=1
    fi
    [[ $ok == 1 ]] && return 0
    printf '就绪判据探针不符预期（mode=%s port=%s，期望 %s 实际 %s）：\n%s\n' \
        "$mode" "$port" "$expect" "$rc" "$out" >&2
    return 1
}

# 就绪判据断言：探针夹具失效（返回码 2）计入独立的夹具失败计数，不冒充产品断言结果；
# 其余情况按产品断言计入断言失败计数。
readiness_assert() {
    local label=$1 status=0
    shift
    "$@" || status=$?
    CHECKS=$((CHECKS + 1))
    if [[ $status == 2 ]]; then
        FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
        printf '[FIXTURE-FAIL] 夹具未就绪，未执行断言：%s\n' "$label"
        return 0
    fi
    if [[ $status == 0 ]]; then
        printf '[PASS] %s\n' "$label"
        return 0
    fi
    printf '[FAIL] %s\n' "$label"
    FAILURES=$((FAILURES + 1))
    return 0
}

# 正对照：内核监听表中真实 LISTEN 必须判定为就绪。
readiness_positive_control() { readiness_probe "$READINESS_PORT" listen 0; }

# 负例：同端口的非 LISTEN 连接（本地端口恰为该端口）不得判定为就绪。
readiness_rejects_nonlisten() { readiness_probe "$READINESS_PORT" connect 1; }

# 空命名卷正式启动：以正式入口在全新命名卷上完成实例初始化与配置生成并进入前台就绪；
# 断言生成的配置文件非空、实例目录与配置文件属主为 10001 且不含组/其他用户写位，
# 并以入口自身已修复的 confirm_daemon_listening 复核 daemon 确以内核真实 LISTEN 提供服务。
empty_volume_formal_startup() {
    local id=$EMPTY_CONTAINER i ready=0 ok=1
    docker rm -f "$EMPTY_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm -f "$EMPTY_VOLUME" >/dev/null 2>&1 || true
    docker volume create "$EMPTY_VOLUME" >/dev/null 2>&1 || return 1
    if ! docker run -d --name "$EMPTY_CONTAINER" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --user 10001:10001 --network "$O1_NET" \
        -v "$O1_CA_VOL:/ca:ro" -e "GIT_SSL_CAINFO=$O1_CA" \
        -v "$EMPTY_VOLUME:/var/lib/git-daemon" \
        -e "REPOS=$TEST_REPO" -e ENABLE_HOSTS_UPDATE=no -e ENABLE_CRON=no \
        "$IMAGE" >/dev/null 2>&1; then
        docker volume rm -f "$EMPTY_VOLUME" >/dev/null 2>&1 || true
        return 1
    fi
    for i in $(seq 1 120); do
        if docker logs "$id" 2>&1 | grep -q '容器前台就绪'; then ready=1; break; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == false ]]; then break; fi
        sleep 1
    done
    if [[ $ready == 1 ]]; then
        docker exec "$id" sh -c '
            umask 022
            [ -s /var/lib/git-daemon/config/mirror.env ] || exit 1
            for p in /var/lib/git-daemon/config/mirror.env \
                     /var/lib/git-daemon/config /var/lib/git-daemon/repos \
                     /var/lib/git-daemon/logs /var/lib/git-daemon/runtime \
                     /var/lib/git-daemon/cache /var/lib/git-daemon/tmp; do
                [ -e "$p" ] || exit 1
                [ "$(stat -c %u "$p")" = 10001 ] || exit 1
                [ $(( 0$(stat -c %a "$p") & 0022 )) -eq 0 ] || exit 1
            done
        ' >/dev/null 2>&1 || ok=0
        if [[ $ok == 1 ]]; then
            docker exec -e HOME=/var/lib/git-daemon/home "$id" \
                bash -c 'source /usr/local/bin/git-mirror-entrypoint; confirm_daemon_listening' \
                >/dev/null 2>&1 || ok=0
        fi
    else
        ok=0
    fi
    if [[ $ok != 1 ]]; then
        printf '空命名卷正式启动校验失败，日志尾部：\n' >&2
        docker logs "$id" 2>&1 | tail -n 20 >&2 2>&1 || true
    fi
    container_networks_internal "$id" || ok=0
    assert_product_egress "$id" empty || ok=0
    assert_dns_witness empty || ok=0
    docker rm -f "$id" >/dev/null 2>&1 || true
    docker volume rm -f "$EMPTY_VOLUME" >/dev/null 2>&1 || true
    [[ $ok == 1 ]]
}

# 阶段 D：在命名卷内写入卷内 TZ=Asia/Shanghai 与固定 cron 表达式（全部以 UID 10001 完成，不以 root 初始化）。
tz_prepare_volume() {
    local volume=$1
    docker volume rm -f "$volume" >/dev/null 2>&1 || true
    docker volume create "$volume" >/dev/null 2>&1 || return 1
    printf '%s\n' 'TZ=Asia/Shanghai' 'LISTEN_ADDRESS=0.0.0.0' 'GIT_PORT=9418' \
        "CRON_SCHEDULE=$TZ_CRON_SYNC" "HOSTS_CRON=$TZ_CRON_HOSTS" \
        'ENABLE_CRON=no' 'ENABLE_HOSTS_UPDATE=no' | \
        docker run --rm -i --user 10001:10001 -v "$volume:$TZ_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p $TZ_MOUNT/config && cat > $TZ_MOUNT/config/mirror.env"
}

# 记录命名卷内 mirror.env 的 SHA256，供「卷内配置逐字节不变」断言使用。
tz_record_volume_hash() {
    local volume=$1 out=$2 hash
    hash=$(docker run --rm --user 10001:10001 -v "$volume:$TZ_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "sha256sum $TZ_MOUNT/config/mirror.env" 2>/dev/null | awk '{print $1}') || return 1
    [[ $hash =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash" > "$out"
}

# 以正式入口启动 TZ 场景容器：只读根、cap_drop ALL、no-new-privileges、UID10001、仅命名卷。
# tz 非空时以显式 TZ 环境变量启动；为空时不注入 TZ，使卷内配置层可达。
# 显式 ENABLE_HOSTS_UPDATE=no 使入口的「首次地址刷新」在读取镜像默认 HOSTS_URL 前即短路返回，
# 本用例只验证默认 TZ 值，不向真实第三方 CDN 发起请求（不写入 TZ，保持默认时区层验证）。
tz_start_container() {
    local tz=$1 i
    local -a args=(-d --name "$TZ_CONTAINER" --read-only --cap-drop ALL --security-opt no-new-privileges \
        --user 10001:10001 --network "$O1_NET" -v "$O1_CA_VOL:/ca:ro" -e "GIT_SSL_CAINFO=$O1_CA" \
        -v "$TZ_VOLUME:$TZ_MOUNT" -e "REPOS=$TEST_REPO" -e ENABLE_HOSTS_UPDATE=no)
    [[ -z $tz ]] || args+=(-e "TZ=$tz")
    docker rm -f "$TZ_CONTAINER" >/dev/null 2>&1 || true
    docker run "${args[@]}" "$IMAGE" >/dev/null 2>&1 || return 1
    container_networks_internal "$TZ_CONTAINER" || return 1
    for i in $(seq 1 120); do
        if docker logs "$TZ_CONTAINER" 2>&1 | grep -q '容器前台就绪'; then return 0; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$TZ_CONTAINER" 2>/dev/null) == false ]]; then break; fi
        sleep 1
    done
    printf 'TZ 场景容器未就绪，日志尾部：\n' >&2
    docker logs "$TZ_CONTAINER" 2>&1 | tail -n 20 >&2 2>&1 || true
    return 1
}

# 夹具动作：全新空命名卷且不注入 TZ 启动，验证默认值层。
tz_prepare_fresh_volume_then_start() {
    docker rm -f "$TZ_CONTAINER" >/dev/null 2>&1 || true
    docker volume rm -f "$TZ_VOLUME" >/dev/null 2>&1 || true
    docker volume create "$TZ_VOLUME" >/dev/null 2>&1 || return 1
    tz_start_container ''
}

# 读取容器内交付配置入口解析出的最终有效时区（输出第三行），不只看环境变量本身。
tz_effective_timezone() {
    local name=$1
    docker exec -e HOME=$TZ_MOUNT/home "$name" \
        /usr/local/lib/git-mirror/git-daemon-config.sh --token-state=empty 2>/dev/null | sed -n '3p'
}

# 用容器内真实调度器库计算同步与 hosts 的下一次触发：经交付入口校验实例配置后，
# gm_prepare_runtime 导出的 TZ 即调度时钟来源，再按固定时间戳取两类调度的下一次触发。
tz_scheduler_next_triggers() {
    local name=$1
    docker exec -e HOME=$TZ_MOUNT/home "$name" bash -c '
        set -u
        export RUN_ROOT='"$TZ_MOUNT"' INSTALL_ROOT=/usr/local/lib/git-mirror
        source "$INSTALL_ROOT/git-mirror-scheduler.sh" || exit 1
        gm_prepare_runtime "$RUN_ROOT" "$INSTALL_ROOT" || exit 1
        printf "TZ=%s sync=%s hosts=%s" "$TZ" \
            "$(gm_cron_next_trigger "${GM_CONFIG[CRON_SCHEDULE]}" '"$TZ_FIXED_NOW"')" \
            "$(gm_cron_next_trigger "${GM_CONFIG[HOSTS_CRON]}" '"$TZ_FIXED_NOW"')"
    ' 2>/dev/null
}

# 断言：容器内交付配置入口解析出的最终有效时区等于期望值。
tz_assert_effective() {
    local expected=$1 name=$2
    [[ $(tz_effective_timezone "$name") == "$expected" ]]
}

# 断言：容器内调度器按最终有效时区计算同步与 hosts 的下一次触发。
tz_assert_scheduler() {
    local expected_zone=$1 expected_sync=$2 expected_hosts=$3 name=$4 actual
    actual=$(tz_scheduler_next_triggers "$name") || return 1
    [[ $actual == "TZ=$expected_zone sync=$expected_sync hosts=$expected_hosts" ]]
}

# 断言：卷内 mirror.env 摘要与记录一致（逐字节不变），而非只看进程内变量。
tz_assert_volume_unchanged() {
    local volume=$1 out=$2 current
    current=$(docker run --rm --user 10001:10001 -v "$volume:$TZ_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "sha256sum $TZ_MOUNT/config/mirror.env" 2>/dev/null | awk '{print $1}') || return 1
    [[ -n $current && -f $out && $current == "$(<"$out")" ]]
}

# 断言：TZ 默认值场景容器日志不含地址刷新外网行为标记，
# 证明该用例未向真实第三方 CDN 发起请求（首次地址刷新已被 ENABLE_HOSTS_UPDATE=no 短路）。
tz_assert_no_outbound_refresh() {
    local name=$1 log
    log=$(docker logs "$name" 2>&1) || return 1
    [[ $log != *'尝试数据源'* && $log != *'地址快照更新成功'* && $log != *'数据源失败'* ]]
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

# 以当前 COMPOSE_ENV 编排启动/重建一次；宿主机未在 COMPOSE_ENV 中显式给出 GIT_PORT/LISTEN_ADDRESS/TZ 时
# 清空这三个变量，使容器回退到卷内配置（验证卷内配置层可达且断言不依赖宿主时区）；显式给出时以环境变量优先。
compose_up() {
    local log=$TEST_ROOT/compose-up.log status=0
    (
        export IMAGE_TAG="$COMPOSE_TAG" PUBLISHED_PORT="$COMPOSE_PORT"
        unset GIT_PORT LISTEN_ADDRESS TZ PROXY_URL GITHUB_TOKEN GITHUB_TOKEN_FILE \
            HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
            HOSTS_URL HOSTS_URL_FALLBACK HOSTS_FALLBACK_URL ENABLE_HOSTS_UPDATE ENABLE_CRON CRON_SCHEDULE HOSTS_CRON REPOS SHORT_LINKS
        if [[ ${#COMPOSE_ENV[@]} -gt 0 ]]; then export "${COMPOSE_ENV[@]}"; fi
        compose config > "$TEST_ROOT/compose-rendered.yml" || exit 1
        compose up -d --force-recreate || exit 1
        if [[ ${1:-} == expected-exit ]]; then
            assert_container_network_configuration "$(compose_container_id)"
        else
            container_networks_internal "$(compose_container_id)"
        fi
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
        archive_container "$id"
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
    archive_container "$id"
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

# 宿主普通用户 Git 客户端使用同一冻结镜像提取的二进制及库，不创建 host 网络容器。
source "$ROOT/tests/docker-host-git.sh"
source "$ROOT/tests/docker-push-denial.sh"
# 宿主侧真实 git 客户端经容器发布端口访问：带 export-ok 的仓库可 ls-remote。
compose_publish_exported_readable() {
    local out status=0
    out=$(host_git ls-remote "git://127.0.0.1:$COMPOSE_PORT/fixtures/pub.git" 2>&1) || status=$?
    if [[ $status == 0 ]]; then return 0; fi
    printf 'ls-remote 失败诊断：%s\n' "$out" >&2
    return 1
}

# 未带 git-daemon-export-ok 的仓库必须被拒绝（非零退出）；先证明发布端口可达，避免把连接失败误判为拒绝。
compose_publish_unexported_rejected() {
    compose_publish_exported_readable || return 1
    local out status=0
    out=$(host_git ls-remote "git://127.0.0.1:$COMPOSE_PORT/fixtures/secret.git" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    case "$out" in *'not exported'*) return 0 ;; esac
    printf '未发布仓库拒绝诊断：%s\n' "$out" >&2
    return 1
}

# 即使夹具设置了 daemon.receivepack=true，daemon 以 --disable/--forbid-override 启动仍必须拒绝 push。
compose_publish_push_rejected() {
    compose_publish_exported_readable || return 1
    local directory=$TEST_ROOT/pushsrc status=0 out
    mkdir -p "$directory"
    host_git init -q "$directory" || return $?
    host_git -C "$directory" config user.email fixture@example.invalid
    host_git -C "$directory" config user.name fixture
    printf x > "$directory/file"
    host_git -C "$directory" add file
    host_git -C "$directory" commit -qm fixture
    out=$(host_git -C "$directory" push "git://127.0.0.1:$COMPOSE_PORT/fixtures/pub.git" HEAD:refs/heads/gm-push 2>&1) || status=$?
    printf 'HOST_PUSH_EXIT=%s OUTPUT=%s\n' "$status" "$out"
    host_push_denied "$status" "$out"
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

# 容器内真实执行拒绝上游同步，三代复用同一缓存且验证真实宿主发布。
compose_sync_failure_retains_cache() {
    local CACHE_GENERATION=$1
    local id dir before after before_count after_count script status=0 requests_before requests_after
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
    if [[ $CACHE_GENERATION == 1 ]]; then
        docker exec "$id" sh -c "$script" >/dev/null 2>&1 || return 1
    fi
    assert_product_egress "$id" "cache-$CACHE_GENERATION" || return 1
    assert_dns_witness "cache-$CACHE_GENERATION" || return 1
    before=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "git --git-dir=$dir for-each-ref --format='%(refname) %(objectname)'" 2>/dev/null) || return 1
    [[ -n $before ]] || return 1
    if [[ $CACHE_GENERATION == 1 ]]; then
        printf '%s\n' "$before" > "$TEST_ROOT/cache-original-refs"
    else
        [[ $before == "$(cat "$TEST_ROOT/cache-original-refs")" ]] || return 1
    fi
    host_git ls-remote "git://127.0.0.1:$COMPOSE_PORT/octocat/Nonexistent-$COMPOSE_TAG.git" > "$TEST_ROOT/cache-host-before-$CACHE_GENERATION" || return 1
    before_count=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -c 'Nonexistent-$COMPOSE_TAG' /var/lib/git-daemon/logs/sync.log 2>/dev/null || echo 0" 2>/dev/null) || before_count=0
    before_count=${before_count:-0}
    docker exec "$id" git ls-remote "git://127.0.0.1:9418/$TEST_REPO" >"$TEST_ROOT/cache-read-before.log" 2>&1 || return 1
    requests_before=$(o1_requests) || return 1
    timeout 90 docker exec -e HOME=/var/lib/git-daemon/home -e "REPOS=octocat/Nonexistent-$COMPOSE_TAG" "$id" \
        /usr/local/lib/git-mirror/git-mirror-sync.sh >"$TEST_ROOT/cache-sync-$CACHE_GENERATION.log" 2>&1 || status=$?
    requests_after=$(o1_requests) || return 1
    printf '缓存失败同步：generation=%s exit=%s requests=%s->%s\n' "$CACHE_GENERATION" "$status" "$requests_before" "$requests_after"
    [[ $status != 0 && $status != 124 && $status != 137 && $requests_after -gt $requests_before ]] || return 1
    grep -q '同步失败' "$TEST_ROOT/cache-sync-$CACHE_GENERATION.log" || return 1
    grep -q '503' "$TEST_ROOT/cache-sync-$CACHE_GENERATION.log" || return 1
    docker exec "$id" test -f "$dir/git-daemon-export-ok" || return 1
    docker exec "$id" git ls-remote "git://127.0.0.1:9418/$TEST_REPO" >"$TEST_ROOT/cache-read.log" 2>&1 || return 1
    cmp -s "$TEST_ROOT/cache-read-before.log" "$TEST_ROOT/cache-read.log" || return 1
    host_git ls-remote "git://127.0.0.1:$COMPOSE_PORT/octocat/Nonexistent-$COMPOSE_TAG.git" > "$TEST_ROOT/cache-host-after-$CACHE_GENERATION" || return 1
    cmp -s "$TEST_ROOT/cache-host-before-$CACHE_GENERATION" "$TEST_ROOT/cache-host-after-$CACHE_GENERATION" || return 1
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
    compose_up expected-exit || return 1
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
    script='mkdir -p /var/lib/git-daemon/tls-probe && cd /var/lib/git-daemon/tls-probe || exit 1
printf "%s\n" "140.82.112.3 github.com" > hosts
if [ ! -f cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 -keyout key.pem -out cert.pem -days 1 >/dev/null 2>&1
fi
exec openssl s_server -accept '"$TLS_FIXTURE_PORT"' -cert cert.pem -key key.pem -WWW -quiet
'
    docker volume create "gm-$IT_RUN_ID-tls-probe" >/dev/null || return 1
    docker run -d --name "$TLS_FIXTURE_NAME" --network "container:$id" --user 10001:10001 \
        -v "gm-$IT_RUN_ID-tls-probe:/var/lib/git-daemon" \
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
        -e "HOSTS_URL=https://github.com/hosts" \
        "$id" /usr/local/lib/git-mirror/update-github-hosts.sh >/dev/null 2>&1 || status=$?
    [[ $status != 0 ]] || return 1
    now=$(docker run --rm --user 10001:10001 -v "$COMPOSE_VOLUME:/var/lib/git-daemon" --entrypoint /bin/sh "$IMAGE" \
        -c 'sha256sum /var/lib/git-daemon/hosts/github-hosts.snapshot' 2>/dev/null) || return 1
    [[ "$now" == "$recorded" ]] || return 1
    [[ $(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null) == true ]]
}

# 夹具步骤：失败计入独立的夹具失败计数，避免把夹具不可用当作产品断言结果。
fixture_step() {
    local label=$1 status=0
    shift
    FIXTURE_CHECKS=$((FIXTURE_CHECKS + 1))
    "$@" >"$TEST_ROOT/fixture-step.log" 2>&1 || status=$?
    if (( status == 0 )); then
        printf '[PASS] %s\n' "$label"
        return 0
    fi
    printf '[FIXTURE-FAIL] %s（退出码 %s）\n' "$label" "$status"
    sed 's/^/    /' "$TEST_ROOT/fixture-step.log" >&2 2>/dev/null || true
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
    return 0
}

# 依赖夹具的产品断言：指定就绪标志未置位时记为夹具失败并且不执行，
# 既不冒充产品结论也不把连接错误当作断言结果。
check_gated() {
    local flag=$1 label=$2
    shift 2
    if [[ ${!flag} == 1 ]]; then
        check "$label" "$@"
        return 0
    fi
    CHECKS=$((CHECKS + 1))
    FIXTURE_FAILURES=$((FIXTURE_FAILURES + 1))
    printf '[FIXTURE-FAIL] 夹具未就绪，未执行断言：%s\n' "$label"
    return 0
}

# 三组夹具各自独立就绪标志：任一组夹具不可用只记夹具失败并阻止其依赖断言。
check_https_sync() { check_gated FIXTURE_READY "$@"; }
check_proxy_sync() { check_gated PROXY_READY "$@"; }

# 仅显式选择时延期依赖新增 NAT 的真实映射成功断言，不计为通过。
check_mapping_sync() {
    if [[ ${IT_DEFER_MAPPING:-0} == 1 ]]; then
        DEFERRED=$((${DEFERRED:-0} + 1))
        printf 'DEFER %s：用户延期新增 NAT 及依赖的真实 mapping 成功验证\n' "$1"
        return 0
    fi
    check_proxy_sync "$@"
}
check_auth_sync() { check_gated AUTH_READY "$@"; }
check_auth_prod() { check_gated AUTH_PROD_READY "$@"; }
check_hosts_content() { check_gated HOSTS_READY "$@"; }
# 阶段 D 各夹具组的独立就绪标志：任一组夹具不可用只记夹具失败并阻止其依赖断言。
check_tz_run() { check_gated TZ_RUN_READY "$@"; }
check_tz_vol() { check_gated TZ_VOL_READY "$@"; }
check_tz_def() { check_gated TZ_DEF_READY "$@"; }
check_tz_compose() { check_gated TZ_COMPOSE_READY "$@"; }
check_tz_compose2() { check_gated TZ_COMPOSE2_READY "$@"; }

# 创建夹具所需的自定义网络与两个命名卷（上游资产卷、产品运行卷），不使用 bind 或宿主机路径。
fixture_create_network_and_volumes() {
    docker volume create "$FIXTURE_FIX_VOL" >/dev/null 2>&1 || return 1
    docker volume create "$FIXTURE_PROD_VOL" >/dev/null 2>&1 || return 1
    [[ -n ${IT_NETWORK:-} && $FIXTURE_NET == "$IT_NETWORK" ]] || return 77
    return 0
}

# 仅导出公开证书到独立客户端信任卷；私钥始终留在上游资产卷。
fixture_prepare_client_ca() {
    docker volume create "$FIXTURE_CA_VOL" >/dev/null || return 1
    local cert
    for cert in ca.crt hosts-bad.crt; do
        docker run --rm -v "$FIXTURE_FIX_VOL:$FIXTURE_MOUNT:ro" --entrypoint sh "$IMAGE" \
            -c "cat $FIXTURE_MOUNT/fixture/tls/$cert" > "$TEST_ROOT/$cert" || return 1
        docker run --rm -i -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT" --entrypoint sh "$IMAGE" \
            -c "mkdir -p $FIXTURE_MOUNT/fixture/tls; cat > $FIXTURE_MOUNT/fixture/tls/$cert" \
            < "$TEST_ROOT/$cert" || return 1
    done
}

# 夹具就绪探测：用真实 TLS 客户端经 github.com DNS 别名取到静态 info/refs；连接失败即夹具失败。
fixture_wait_upstream() {
    local i rc=0 code
    for i in $(seq 1 30); do
        rc=0
        code=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" \
            --entrypoint /bin/sh "$IMAGE" -c \
            "curl -sS --cacert $FIXTURE_CA --max-time 5 -o /dev/null -w '%{http_code}' https://github.com/$FIXTURE_REPO.git/info/refs" \
            2>"$TEST_ROOT/upstream-probe.err") || rc=$?
        if [[ $rc == 0 && $code == 200 ]]; then return 0; fi
        sleep 1
    done
    printf '上游就绪探测失败（curl 退出码 %s，HTTP %s）：\n' "$rc" "$code" >&2
    cat "$TEST_ROOT/upstream-probe.err" >&2 2>/dev/null || true
    return 1
}

# 把测试 CA 从上游卷复制到产品卷：两个命名卷之间经标准输入传递，不落地宿主机路径映射。
fixture_copy_ca() {
    bash "$FIXTURE_SCRIPT" ca "$FIXTURE_FIX_VOL" "$IMAGE" >"$TEST_ROOT/fixture-ca.pem" || return 1
    docker run --rm -i --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p ${FIXTURE_CA%/*} && cat > $FIXTURE_CA" <"$TEST_ROOT/fixture-ca.pem"
}

# 以正式入口在产品卷上启动隔离同步场景：只读根、UID10001、cap_drop ALL、no-new-privileges、仅命名卷；
# ENABLE_HOSTS_UPDATE=no 走 system DNS 且不设 PROXY_URL，GIT_SSL_CAINFO 信任测试 CA（TLS 校验保持开启）。
# 上游为静态 dumb HTTP；以 GIT_SMART_HTTP=0 让 Git 跳过 smart 探测直接走 dumb HTTP（该变量仍被读取）。
fixture_start_product() {
    local i
    docker rm -f "$FIXTURE_PROD" >/dev/null 2>&1 || true
    docker run -d --name "$FIXTURE_PROD" --network "$FIXTURE_NET" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" \
        -e "REPOS=$FIXTURE_REPO" -e ENABLE_HOSTS_UPDATE=no -e ENABLE_CRON=no \
        -e GIT_SMART_HTTP=0 -e "GIT_SSL_CAINFO=$FIXTURE_CA" "$IMAGE" \
        >"$TEST_ROOT/fixture-up.log" 2>&1 || return 1
    container_networks_internal "$FIXTURE_PROD" || return 1
    for i in $(seq 1 150); do
        if docker logs "$FIXTURE_PROD" 2>&1 | grep -q '容器前台就绪'; then return 0; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$FIXTURE_PROD" 2>/dev/null) == false ]]; then
            printf '产品容器提前退出，日志尾部：\n' >&2
            docker logs "$FIXTURE_PROD" 2>&1 | tail -n 20 >&2 2>&1 || true
            return 1
        fi
        sleep 1
    done
    printf '产品容器未进入前台就绪，日志尾部：\n' >&2
    docker logs "$FIXTURE_PROD" 2>&1 | tail -n 20 >&2 2>&1 || true
    return 1
}

# 容器内自证：产品进程有效 UID 为 10001，且只读根的系统路径写入均失败
# （不依赖宿主侧 inspect 结论，直接在容器内以真实命令观察）。
fixture_identity_and_readonly_root() {
    local out p
    out=$(docker exec "$FIXTURE_PROD" id -u 2>/dev/null) || return 1
    [[ $out == 10001 ]] || return 1
    for p in / /etc /tmp /run /var/log; do
        if docker exec "$FIXTURE_PROD" sh -c "touch '$p/gm-s7-probe' 2>/dev/null"; then
            return 1
        fi
    done
    return 0
}

# 在产品容器内以 UID 10001 运行产品同步入口；docker exec 不继承入口导出的环境，故显式传入实例 HOME。
fixture_exec_sync() {
    local repos=$1
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 docker exec -e "REPOS=$repos" -e "HOME=$FIXTURE_HOME" -e GIT_SMART_HTTP=0 \
            -e "GIT_SSL_CAINFO=$FIXTURE_CA" "$FIXTURE_PROD" \
            /usr/local/lib/git-mirror/git-mirror-sync.sh
    else
        docker exec -e "REPOS=$repos" -e "HOME=$FIXTURE_HOME" -e GIT_SMART_HTTP=0 \
            -e "GIT_SSL_CAINFO=$FIXTURE_CA" "$FIXTURE_PROD" \
            /usr/local/lib/git-mirror/git-mirror-sync.sh
    fi
}

# 读取产品卷内已同步镜像仓库的完整引用清单（引用名与提交号）。
fixture_local_refs() {
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "git --git-dir=$FIXTURE_MOUNT/repos/$FIXTURE_REPO.git for-each-ref --format='%(refname) %(objectname)'" 2>/dev/null
}

# 统计产品同步日志内的本轮仓库同步条目数，用于验证重复同步确实重新执行。
fixture_sync_log_count() {
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -c '同步 $FIXTURE_REPO' $FIXTURE_MOUNT/logs/sync.log 2>/dev/null || true" 2>/dev/null
}

# 首次真实成功同步：引用齐全、main 提交与上游一致、已写入发布标记、传输路径为直连系统 DNS。
fixture_first_sync_succeeded() {
    local expected
    expected=$(bash "$FIXTURE_SCRIPT" rev-parse "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" refs/heads/main) || return 1
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" \
        -e "GM_EXPECT_MAIN=$expected" --entrypoint /bin/sh "$IMAGE" -c '
        set -e
        d='"$FIXTURE_MOUNT"'/repos/'"$FIXTURE_REPO"'.git
        [ "$(git --git-dir="$d" rev-parse refs/heads/main)" = "$GM_EXPECT_MAIN" ]
        git --git-dir="$d" rev-parse --verify refs/heads/dev >/dev/null
        git --git-dir="$d" rev-parse --verify refs/tags/v1 >/dev/null
        [ -f "$d/git-daemon-export-ok" ]
        grep -q "同步传输路径：直连系统 DNS" '"$FIXTURE_MOUNT"'/logs/sync.log
    '
}

# 用真实 Git 客户端经产品 git-daemon 验证 /repo 与 /repo.git 双形式都指向预期提交。
fixture_publish_both_forms() {
    local expected out path
    expected=$(bash "$FIXTURE_SCRIPT" rev-parse "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" refs/heads/main) || return 1
    for path in "$FIXTURE_REPO.git" "$FIXTURE_REPO"; do
        out=$(docker run --rm --network "container:$FIXTURE_PROD" --entrypoint git "$IMAGE" \
            ls-remote "git://127.0.0.1:9418/$path" 2>&1) || return 1
        [[ $out == *"$expected"$'\t'"HEAD"* ]] || return 1
        [[ $out == *"$expected"$'\t'"refs/heads/main"* ]] || return 1
    done
    return 0
}

# 未带 git-daemon-export-ok 的仓库必须不可读；先证明发布端口可达，避免把连接失败误判为拒绝。
fixture_unexported_rejected() {
    local out status=0
    fixture_publish_both_forms || return 1
    docker exec -e "HOME=$FIXTURE_HOME" "$FIXTURE_PROD" sh -c \
        'umask 022; R=/var/lib/git-daemon; rm -rf "$R/repos/acme/secret.git"; git clone -q --bare "$R/repos/acme/demo.git" "$R/repos/acme/secret.git"' || return 1
    out=$(docker run --rm --network "container:$FIXTURE_PROD" --entrypoint git "$IMAGE" \
        ls-remote "git://127.0.0.1:9418/acme/secret.git" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $out == *'not exported'* ]]
}

# 即使夹具在仓库上设置 daemon.receivepack=true，产品 daemon 仍必须拒绝 push（--forbid-override）。
# 只把「非零退出且输出含 receive-pack 拒绝文案」判为拒绝成功；连接中断、超时、DNS 失败等
# 其它非零退出不得冒充拒绝结果。
fixture_push_rejected() {
    local out rc=0
    fixture_publish_both_forms || return 1
    docker exec -e "HOME=$FIXTURE_HOME" "$FIXTURE_PROD" sh -c \
        "git --git-dir=$FIXTURE_MOUNT/repos/$FIXTURE_REPO.git config daemon.receivepack true" || return 1
    docker volume create "gm-$IT_RUN_ID-push-client" >/dev/null || return 1
    out=$(docker run --rm --network "container:$FIXTURE_PROD" --user 10001:10001 -e "HOME=$FIXTURE_HOME" \
        -v "gm-$IT_RUN_ID-push-client:/var/lib/git-daemon" \
        --entrypoint /bin/sh "$IMAGE" -c '
        set -e
        cd /var/lib/git-daemon; rm -rf pushsrc; git init -q pushsrc; cd pushsrc
        git config user.email fixture@example.invalid
        git config user.name fixture
        printf x > f; git add f; git commit -qm c
        git push git://127.0.0.1:9418/'"$FIXTURE_REPO"'.git HEAD:refs/heads/gm-push
    ' 2>&1) || rc=$?
    [[ $rc != 0 ]] || return 1
    grep -q 'service not enabled' <<<"$out"
}

# 重复同步：再次以产品入口同步，要求引用不变且同步日志确有一次新的执行记录。
fixture_repeat_sync_idempotent() {
    local before after before_count after_count
    before=$(fixture_local_refs) || return 1
    before_count=$(fixture_sync_log_count) || return 1
    fixture_exec_sync "$FIXTURE_REPO" >"$TEST_ROOT/fixture-resync.log" 2>&1 || return 1
    after=$(fixture_local_refs) || return 1
    after_count=$(fixture_sync_log_count) || return 1
    [[ $before == "$after" ]] || return 1
    (( after_count > before_count ))
}

# 远端更新后重新同步：镜像引用与 HEAD 必须反映上游新提交，且新提交号确实变化。
fixture_remote_update_reflected() {
    local old new
    old=$(bash "$FIXTURE_SCRIPT" rev-parse "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" refs/heads/main) || return 1
    new=$(bash "$FIXTURE_SCRIPT" update "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" main fixture-update) || return 1
    [[ -n $new && $new != "$old" ]] || return 1
    fixture_exec_sync "$FIXTURE_REPO" >"$TEST_ROOT/fixture-resync-update.log" 2>&1 || return 1
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" \
        -e "GM_NEW=$new" --entrypoint /bin/sh "$IMAGE" -c '
        set -e
        d='"$FIXTURE_MOUNT"'/repos/'"$FIXTURE_REPO"'.git
        [ "$(git --git-dir="$d" rev-parse refs/heads/main)" = "$GM_NEW" ]
        [ "$(git --git-dir="$d" symbolic-ref HEAD)" = "refs/heads/main" ]
    '
}

# 上游不可达时同步必须失败，且已有引用逐字节保留（失败不破坏缓存）。
fixture_failure_retains_refs() {
    local before after status=0 requests_before requests_after read_before read_after
    before=$(fixture_local_refs) || return 1
    read_before=$(docker exec "$FIXTURE_PROD" git ls-remote "git://127.0.0.1:9418/$FIXTURE_REPO") || return 1
    archive_container "$FIXTURE_NAME"
    bash "$FIXTURE_SCRIPT" reject-start "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_NAME" || return 1
    container_networks_internal "$FIXTURE_NAME" || return 1
    requests_before=$(docker exec "$FIXTURE_NAME" sh -c 'if [ -f /var/lib/git-daemon/fixture/reject.requests ]; then wc -l < /var/lib/git-daemon/fixture/reject.requests; else echo 0; fi') || return 1
    fixture_exec_sync "$FIXTURE_REPO" >"$TEST_ROOT/fixture-fail.log" 2>&1 || status=$?
    requests_after=$(docker exec "$FIXTURE_NAME" sh -c 'wc -l < /var/lib/git-daemon/fixture/reject.requests') || return 1
    printf 'HTTPS 拒绝同步：exit=%s requests=%s->%s\n' "$status" "$requests_before" "$requests_after"
    [[ $status != 0 && $status != 124 && $status != 137 && $requests_after -gt $requests_before ]] || return 1
    after=$(fixture_local_refs) || return 1
    read_after=$(docker exec "$FIXTURE_PROD" git ls-remote "git://127.0.0.1:9418/$FIXTURE_REPO") || return 1
    docker exec "$FIXTURE_PROD" test -f "$FIXTURE_MOUNT/repos/$FIXTURE_REPO.git/git-daemon-export-ok" || return 1
    [[ $before == "$after" && $read_before == "$read_after" ]] || return 1
    archive_container "$FIXTURE_NAME"
    grep -q '同步失败' "$TEST_ROOT/fixture-fail.log"
}

# 指定分支同步：只保留所选分支的引用，其余分支与标签被裁剪，HEAD 指向所选分支。
fixture_branch_scoped_sync() {
    local expected
    bash "$FIXTURE_SCRIPT" start "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_NAME" || return 1
    fixture_wait_upstream || return 1
    fixture_exec_sync "$FIXTURE_REPO main" >"$TEST_ROOT/fixture-branch.log" 2>&1 || return 1
    expected=$(bash "$FIXTURE_SCRIPT" rev-parse "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" refs/heads/main) || return 1
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" \
        -e "GM_NEW=$expected" --entrypoint /bin/sh "$IMAGE" -c '
        set -e
        d='"$FIXTURE_MOUNT"'/repos/'"$FIXTURE_REPO"'.git
        [ "$(git --git-dir="$d" for-each-ref --format="%(refname)" | sort | tr "\n" " ")" = "refs/heads/main " ]
        [ "$(git --git-dir="$d" rev-parse refs/heads/main)" = "$GM_NEW" ]
        [ "$(git --git-dir="$d" symbolic-ref HEAD)" = "refs/heads/main" ]
    '
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

# 串行交接固定产品地址和上游别名；保留认证仍需使用的夹具卷与共享网络。
fixture_release_shared_endpoints() {
    local name
    for name in "$@"; do archive_container "$name"; done
    docker rm -f "$@" >/dev/null 2>&1
}

# 读取代理侧 CONNECT 计数（夹具卷内计数文件；缺失时夹具脚本输出 0）。
fixture_connect_count() {
    bash "$FIXTURE_SCRIPT" connects "$FIXTURE_FIX_VOL" "$IMAGE" 2>/dev/null | tr -d '[:space:]'
}

# 把当前 CONNECT 计数写入测试目录文件，供跨子 Shell 的断言比对。
fixture_record_count() {
    local file=$1 value
    value=$(fixture_connect_count) || value=
    printf '%s\n' "${value:-0}" > "$file"
    return 0
}

# 读取此前记录的 CONNECT 计数。
fixture_read_count() {
    local value
    value=$(cat "$1" 2>/dev/null) || value=
    printf '%s' "${value:-0}"
}

# 启动 HTTPS CONNECT 代理容器（网络别名 gm-proxy，监听 8443，非 root）。
fixture_start_proxy() {
    bash "$FIXTURE_SCRIPT" proxy-start "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_PROXY_NAME"
}

# 代理就绪探测：以真实 TLS 客户端经代理取到静态 info/refs 且返回 200。
# 探测本身经过代理（计入计数），故代理基线在探测之后单独记录。
fixture_wait_proxy() {
    local i code
    [[ $(docker inspect -f '{{.State.Running}}' "$FIXTURE_PROXY_NAME" 2>/dev/null) == true ]] || {
        printf '代理容器未运行，判定代理夹具失败\n' >&2
        return 1
    }
    for i in $(seq 1 30); do
        code=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" \
            --entrypoint /bin/sh "$IMAGE" -c \
            "curl -sS --cacert $FIXTURE_CA --proxy $FIXTURE_PROXY_URL --proxy-cacert $FIXTURE_CA \
                -o /dev/null -w '%{http_code}' https://github.com/$FIXTURE_REPO.git/info/refs" \
            2>"$TEST_ROOT/proxy-probe.err") || code=
        if [[ $code == 200 ]]; then return 0; fi
        sleep 1
    done
    printf '代理就绪探测失败（HTTP %s）：\n' "$code" >&2
    cat "$TEST_ROOT/proxy-probe.err" >&2 2>/dev/null || true
    return 1
}

# 记录代理基线计数：仅在就绪探测之后调用，避免把探测自身计入断言基线。
fixture_record_proxy_baseline() {
    fixture_record_count "$TEST_ROOT/proxy-baseline"
}

# 在产品卷内预置映射路径与代理路径的输入：
# 一是合法公开地址快照（值为夹具容器在该隔离网络上的地址，请求只在 Docker 网络内到达夹具）；
# 二是仅用于信任测试代理 CA 的全局 Git 配置（http.proxySSLCAInfo），不关闭任何 TLS 校验。
fixture_prepare_proxy_inputs() {
    local ip
    ip=$(bash "$FIXTURE_SCRIPT" upstream-ip "$FIXTURE_NAME") || return 1
    [[ -n $ip ]] || return 1
    printf '%s\n' '# FORMAT=1' '# SOURCE=https://fixture.invalid/hosts' \
        '# FETCHED=2026-01-01T00:00:00+0000' '# DIGEST=sha256:fixture' '# COUNT=1' "$ip github.com" | \
        docker run --rm -i --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p $FIXTURE_MOUNT/hosts; cat > $FIXTURE_SNAPSHOT" || return 1
    printf '[http]\n\tproxySSLCAInfo = %s\n' "$FIXTURE_CA" | \
        docker run --rm -i --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p $FIXTURE_MOUNT/fixture; cat > $FIXTURE_GITCONFIG" || return 1
    return 0
}

# 在产品容器内以 UID 10001 执行一次同步：显式给出代理地址与映射开关，
# 输出（同时写入卷内 sync.log）供断言检查实际传输路径。
fixture_exec_sync_scenario() {
    local proxy=$1 hosts_update=$2 repos=$3
    docker exec -e "REPOS=$repos" -e "HOME=$FIXTURE_HOME" -e GIT_SMART_HTTP=0 \
        -e "GIT_SSL_CAINFO=$FIXTURE_CA" -e "GIT_CONFIG_GLOBAL=$FIXTURE_GITCONFIG" \
        -e "PROXY_URL=$proxy" -e "ENABLE_HOSTS_UPDATE=$hosts_update" \
        "$FIXTURE_PROD" /usr/local/lib/git-mirror/git-mirror-sync.sh 2>&1
}

# 代理成功路径：配置 PROXY_URL 时真实同步成功，日志记录使用配置代理，且代理侧计数确实增加。
fixture_proxy_path_succeeds() {
    local out before after
    out=$(fixture_exec_sync_scenario "$FIXTURE_PROXY_URL" "$([[ ${IT_DEFER_MAPPING:-0} == 1 ]] && printf no || printf yes)" "$FIXTURE_REPO") || { printf '%s\n' "$out" >&2; return 1; }
    printf '%s\n' "$out" > "$TEST_ROOT/proxy-run-output"
    fixture_record_count "$TEST_ROOT/proxy-after-run"
    [[ $out == *'本次同步成功'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    [[ $out == *'同步传输路径：配置的 HTTPS 代理'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    before=$(fixture_read_count "$TEST_ROOT/proxy-baseline")
    after=$(fixture_read_count "$TEST_ROOT/proxy-after-run")
    (( after > before )) || { printf '代理侧计数未增加（before=%s after=%s）\n' "$before" "$after" >&2; return 1; }
    return 0
}

# 代理计数证据：代理侧记录到对 github.com:443 的 CONNECT，且计数确实增加。
fixture_proxy_connect_evidence() {
    local before after log
    before=$(fixture_read_count "$TEST_ROOT/proxy-baseline")
    after=$(fixture_read_count "$TEST_ROOT/proxy-after-run")
    (( after > before )) || { printf '代理侧计数未增加（before=%s after=%s）\n' "$before" "$after" >&2; return 1; }
    log=$(bash "$FIXTURE_SCRIPT" connect-log "$FIXTURE_FIX_VOL" "$IMAGE" 2>/dev/null) || log=
    [[ $log == *'CONNECT github.com:443'* ]] || { printf '代理 CONNECT 日志：\n%s\n' "$log" >&2; return 1; }
    return 0
}

# 传输顺序：可达但拒绝 CONNECT 的代理失败后回退到动态地址映射。
# 代理端点可达且会计数，故本场景计数增长证明代理尝试确实发生（不是「不可达故无从计数」）；
# 随后的映射请求成功且不经代理（若经代理会被同一端点以 403 拒绝而失败）。
fixture_proxy_failure_falls_back_to_mapping() {
    local out before after
    before=$(fixture_connect_count)
    out=$(fixture_exec_sync_scenario "$FIXTURE_REJECT_PROXY" yes "$FIXTURE_REPO") || { printf '%s\n' "$out" >&2; return 1; }
    after=$(fixture_connect_count)
    printf '%s\n' "$out" > "$TEST_ROOT/proxy-mapping-output"
    printf '%s\n' "$before" > "$TEST_ROOT/proxy-mapping-before"
    printf '%s\n' "$after" > "$TEST_ROOT/proxy-mapping-after"
    [[ $out == *'传输失败：配置的 HTTPS 代理'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    [[ $out == *'同步传输路径：直连加动态地址映射'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    (( after > before )) || { printf '可达拒绝代理未被计数（before=%s after=%s）\n' "$before" "$after" >&2; return 1; }
    return 0
}

# 传输顺序：可达但拒绝 CONNECT 的代理失败且无映射时回退到直连系统 DNS。
fixture_proxy_failure_falls_back_to_system() {
    local out before after
    before=$(fixture_connect_count)
    out=$(fixture_exec_sync_scenario "$FIXTURE_REJECT_PROXY" no "$FIXTURE_REPO") || { printf '%s\n' "$out" >&2; return 1; }
    after=$(fixture_connect_count)
    printf '%s\n' "$out" > "$TEST_ROOT/proxy-system-output"
    printf '%s\n' "$before" > "$TEST_ROOT/proxy-system-before"
    printf '%s\n' "$after" > "$TEST_ROOT/proxy-system-after"
    [[ $out == *'传输失败：配置的 HTTPS 代理'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    [[ $out == *'同步传输路径：直连系统 DNS'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    (( after > before )) || { printf '可达拒绝代理未被计数（before=%s after=%s）\n' "$before" "$after" >&2; return 1; }
    return 0
}

# 非 proxy 尝试不经过代理：先确证计数机制在有代理尝试时确实增长（两次拒绝代理回退场景各增一次），
# 再以无 PROXY_URL 的纯直连映射场景证明同步成功而计数零增长。因同一映射传输在拒绝代理场景中
# 也未令计数增长，故「计数可能增长却未增长」可区分地证明直连旁路了代理，而非代理不可达。
fixture_direct_attempts_leave_proxy_untouched() {
    local out before after mapping system m_before m_after s_after
    mapping=$(cat "$TEST_ROOT/proxy-mapping-output" 2>/dev/null) || mapping=
    system=$(cat "$TEST_ROOT/proxy-system-output" 2>/dev/null) || system=
    [[ $mapping == *'同步传输路径：直连加动态地址映射'* ]] || return 1
    [[ $system == *'同步传输路径：直连系统 DNS'* ]] || return 1
    m_before=$(fixture_read_count "$TEST_ROOT/proxy-mapping-before")
    m_after=$(fixture_read_count "$TEST_ROOT/proxy-mapping-after")
    s_after=$(fixture_read_count "$TEST_ROOT/proxy-system-after")
    (( m_after > m_before )) || { printf '拒绝代理回退未计数（%s→%s）\n' "$m_before" "$m_after" >&2; return 1; }
    (( s_after > m_after )) || { printf '拒绝代理回退未计数（%s→%s）\n' "$m_after" "$s_after" >&2; return 1; }
    before=$(fixture_connect_count)
    out=$(fixture_exec_sync_scenario '' yes "$FIXTURE_REPO") || { printf '%s\n' "$out" >&2; return 1; }
    after=$(fixture_connect_count)
    printf '%s\n' "$out" > "$TEST_ROOT/proxy-direct-output"
    [[ $out == *'本次同步成功'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    [[ $out == *'同步传输路径：直连加动态地址映射'* ]] || { printf '%s\n' "$out" >&2; return 1; }
    [[ $before == "$after" ]] || { printf '直连尝试后代理计数变化（%s→%s）\n' "$before" "$after" >&2; return 1; }
    return 0
}

# 系统 DNS 直连仍独立验证成功与代理计数不变，不依赖延期的映射结果。
fixture_system_direct_leaves_proxy_untouched() {
    local out before after rejected_before rejected_after
    rejected_before=$(fixture_read_count "$TEST_ROOT/proxy-system-before")
    rejected_after=$(fixture_read_count "$TEST_ROOT/proxy-system-after")
    (( rejected_after > rejected_before )) || return 1
    before=$(fixture_connect_count)
    out=$(fixture_exec_sync_scenario '' no "$FIXTURE_REPO") || { printf '%s\n' "$out" >&2; return 1; }
    after=$(fixture_connect_count)
    printf '%s\n' "$out" > "$TEST_ROOT/proxy-system-direct-output"
    [[ $out == *'本次同步成功'* && $out == *'同步传输路径：直连系统 DNS'* && $before == "$after" ]]
}

# 凭据夹具：在独立网络上以 github.com 别名启动需要 Basic 凭据的认证上游；
# 就绪判据是未带凭据的真实请求得到 401，证明该夹具确实要求鉴权。
fixture_start_auth_upstream() {
    local expect i code
    expect="Basic $(printf 'x-access-token:%s' "$AUTH_TOKEN" | base64 | tr -d '\n')"
    [[ -n ${IT_NETWORK:-} && $AUTH_NET == "$IT_NETWORK" ]] || return 77
    bash "$FIXTURE_SCRIPT" auth-start "$FIXTURE_FIX_VOL" "$IMAGE" "$AUTH_NET" "$AUTH_UP" "$expect" || return 1
    [[ $(docker inspect -f '{{.State.Running}}' "$AUTH_UP" 2>/dev/null) == true ]] || {
        printf '认证上游容器未运行，判定凭据夹具失败\n' >&2
        return 1
    }
    for i in $(seq 1 30); do
        code=$(docker run --rm --network "$AUTH_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/sh "$IMAGE" -c \
            "curl -sS --cacert $FIXTURE_CA -o /dev/null -w '%{http_code}' https://github.com/$FIXTURE_REPO.git/info/refs" \
            2>/dev/null) || code=
        if [[ $code == 401 ]]; then return 0; fi
        sleep 1
    done
    printf '认证上游就绪探测未得到 401（HTTP %s）\n' "$code" >&2
    return 1
}

# 凭据夹具：创建产品卷并把测试 CA 复制进去（命名卷之间经标准输入传递，无宿主机路径映射）。
fixture_prepare_auth_product_volume() {
    docker volume create "$AUTH_PROD_VOL" >/dev/null 2>&1 || return 1
    bash "$FIXTURE_SCRIPT" ca "$FIXTURE_FIX_VOL" "$IMAGE" > "$TEST_ROOT/auth-ca.pem" || return 1
    docker run --rm -i --user 10001:10001 -v "$AUTH_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p ${FIXTURE_CA%/*}; cat > $FIXTURE_CA" < "$TEST_ROOT/auth-ca.pem"
}

# 带合成 Token 的产品容器：正式入口完成首次同步；Token 仅以容器环境变量形式提供。
fixture_start_auth_product() {
    local i
    docker rm -f "$AUTH_PROD" >/dev/null 2>&1 || true
    docker run -d --name "$AUTH_PROD" --network "$AUTH_NET" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --user 10001:10001 -v "$AUTH_PROD_VOL:$FIXTURE_MOUNT" \
        -e "REPOS=$FIXTURE_REPO" -e ENABLE_HOSTS_UPDATE=no -e ENABLE_CRON=no -e GIT_SMART_HTTP=0 \
        -e "GITHUB_TOKEN=$AUTH_TOKEN" -e "GIT_SSL_CAINFO=$FIXTURE_CA" "$IMAGE" \
        >"$TEST_ROOT/auth-product.log" 2>&1 || return 1
    container_networks_internal "$AUTH_PROD" || return 1
    container_networks_internal "$AUTH_UP" || return 1
    for i in $(seq 1 150); do
        if docker logs "$AUTH_PROD" 2>&1 | grep -q '容器前台就绪'; then return 0; fi
        if [[ $(docker inspect -f '{{.State.Running}}' "$AUTH_PROD" 2>/dev/null) == false ]]; then
            printf '认证同步容器提前退出，日志尾部：\n' >&2
            docker logs "$AUTH_PROD" 2>&1 | tail -n 20 >&2 2>&1 || true
            return 1
        fi
        sleep 1
    done
    printf '认证同步容器未进入前台就绪，日志尾部：\n' >&2
    docker logs "$AUTH_PROD" 2>&1 | tail -n 20 >&2 2>&1 || true
    return 1
}

# 合成 Token 访问受认证夹具成功：镜像引用与上游一致，已发布且同步日志记录成功。
fixture_auth_sync_with_token_succeeds() {
    local expected
    docker logs "$AUTH_PROD" 2>&1 | grep -q '本次同步成功' || return 1
    expected=$(bash "$FIXTURE_SCRIPT" rev-parse "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO" refs/heads/main) || return 1
    docker run --rm --user 10001:10001 -v "$AUTH_PROD_VOL:$FIXTURE_MOUNT" \
        -e "GM_EXPECT_MAIN=$expected" --entrypoint /bin/sh "$IMAGE" -c '
        set -e
        d='"$FIXTURE_MOUNT"'/repos/'"$FIXTURE_REPO"'.git
        [ "$(git --git-dir="$d" rev-parse refs/heads/main)" = "$GM_EXPECT_MAIN" ]
        git --git-dir="$d" rev-parse --verify refs/heads/dev >/dev/null
        [ -f "$d/git-daemon-export-ok" ]
    '
}

# 凭据隔离：容器内读取常驻 git-daemon 进程的 /proc/<pid>/environ，该环境既不含 GITHUB_TOKEN，
# 也不含合成 Token 值；同时要求读取结果包含 PATH，避免因读取失败而空转通过。
fixture_daemon_env_excludes_token() {
    local out
    out=$(docker exec "$AUTH_PROD" sh -c '
        pid=$(cat /var/lib/git-daemon/runtime/git-daemon.pid 2>/dev/null)
        case "$pid" in ""|*[!0-9]*) printf "NO_PIDFILE\n"; exit 1 ;; esac
        cmd=$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null)
        case "$cmd" in *"daemon --reuseaddr --base-path"*) ;; *) printf "NOT_DAEMON %s\n" "$cmd"; exit 1 ;; esac
        tr "\0" "\n" < "/proc/$pid/environ" 2>/dev/null
    ' 2>&1) || { printf '无法读取常驻 daemon 进程环境：%s\n' "$out" >&2; return 1; }
    [[ $out == *'PATH='* ]] || { printf 'daemon 进程环境读取结果异常：%s\n' "$out" >&2; return 1; }
    case "$out" in
        *"GITHUB_TOKEN="*) printf '常驻 daemon 进程环境包含 GITHUB_TOKEN\n' >&2; return 1 ;;
    esac
    case "$out" in
        *"$AUTH_TOKEN"*) printf '常驻 daemon 进程环境包含合成 Token 值\n' >&2; return 1 ;;
    esac
    return 0
}

# 对照：真实 Git 客户端不带凭据访问同一受认证夹具必须失败，证明鉴权断言非空转。
fixture_auth_requires_token() {
    local out status=0
    out=$(docker run --rm --network "$AUTH_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/sh "$IMAGE" -c \
        "GIT_TERMINAL_PROMPT=0 GIT_SMART_HTTP=0 git -c http.sslCAInfo=$FIXTURE_CA \
         ls-remote https://github.com/$FIXTURE_REPO.git" 2>&1) || status=$?
    [[ $status != 0 ]] || { printf '无凭据访问意外成功\n' >&2; return 1; }
    case "$out" in
        *401*|*'Authentication failed'*|*authentication*|*'could not read Username'*|*认证*) return 0 ;;
    esac
    printf '无凭据访问诊断：%s\n' "$out" >&2
    return 1
}

# 在正式产品容器内以 UID 10001 执行地址刷新入口：ENABLE_HOSTS_UPDATE/HOSTS_URL/回退由显式环境给出，
# CURL_CA_BUNDLE 仅指向测试 CA（建立对该测试 CA 的信任，不关闭 TLS 校验）；REPOS 等继承容器环境。
# 显式 umask 022 以对齐生产入口（docker run/入口进程 umask 022）；docker exec 自身 umask 为 0000，
# 会把卷内快照写成组/其他可写并被产品自身的文件校验拒绝，那是测试路径差异而非生产行为。
fixture_exec_hosts_refresh() {
    local hosts_url=$1 fallback=$2
    docker exec -e "HOME=$FIXTURE_HOME" -e ENABLE_HOSTS_UPDATE=yes \
        -e "HOSTS_URL=$hosts_url" -e "HOSTS_URL_FALLBACK=$fallback" \
        -e "CURL_CA_BUNDLE=$FIXTURE_CA" \
        "$FIXTURE_PROD" /bin/sh -c 'umask 022; exec /usr/local/lib/git-mirror/update-github-hosts.sh'
}

# 读取产品卷内地址快照的真实字节（断言读真实卷内快照，而非只看退出码）。
fixture_snapshot_bytes() {
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint cat "$IMAGE" "$FIXTURE_SNAPSHOT" 2>/dev/null
}

# 记录当前快照 sha256 到测试目录，供拒绝类断言的逐字节保留比对。
# 明确以 `|| return 1` 容错：在 set -e 下若快照缺失，返回失败由调用方记为可读的夹具失败，
# 而不是让失败的管道直接中止整套测试。
fixture_record_snapshot_sha() {
    fixture_snapshot_bytes | sha256sum | cut -d' ' -f1 > "$TEST_ROOT/hosts-snapshot.sha" || return 1
    [[ -s $TEST_ROOT/hosts-snapshot.sha ]]
}

# 读取此前记录的快照 sha256。
fixture_recorded_snapshot_sha() {
    cat "$TEST_ROOT/hosts-snapshot.sha" 2>/dev/null
}

# 陈旧标记是否存在。
fixture_stale_present() {
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "[ -e $FIXTURE_MOUNT/hosts/github-hosts.stale ]"
}

# 清除陈旧标记，用于构造「刷新成功应清除陈旧」的前置条件。
fixture_clear_stale() {
    docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "rm -f $FIXTURE_MOUNT/hosts/github-hosts.stale"
}

# 校验当前卷内快照等于多地址 hosts 文件的期望结果：格式/来源/记录数/摘要头自洽，
# 数据行为去重排序后的合法公网地址，被拒地址与通配符均不出现。
fixture_hosts_snapshot_matches_hosts() {
    local bytes want pay digest bad
    bytes=$(fixture_snapshot_bytes) || return 1
    [[ -n $bytes ]] || { printf '快照为空\n' >&2; return 1; }
    [[ $bytes == *'# FORMAT=1'* ]] || { printf '缺少格式头：\n%s\n' "$bytes" >&2; return 1; }
    [[ $bytes == *"# SOURCE=$FIXTURE_HOSTS_URL"* ]] || { printf '快照来源不符：\n%s\n' "$bytes" >&2; return 1; }
    [[ $bytes == *'# COUNT=2'* ]] || { printf '记录数头不符：\n%s\n' "$bytes" >&2; return 1; }
    want=$'140.82.112.3 github.com\n140.82.112.5 github.com'
    pay=$(printf '%s\n' "$want")
    digest=$(printf '%s\n' "$pay" | sha256sum); digest=${digest%% *}
    [[ $bytes == *"# DIGEST=sha256:$digest"* ]] || { printf '摘要头不符（期望 %s）：\n%s\n' "$digest" "$bytes" >&2; return 1; }
    [[ $(printf '%s\n' "$bytes" | grep -v '^#') == "$want" ]] || { printf '数据行不符：\n%s\n' "$bytes" >&2; return 1; }
    for bad in '10.0.0.1' '127.0.0.1' '169.254.169.254' '192.168.1.1' 'example.com' '*.github.com' '*'; do
        [[ $bytes != *"$bad"* ]] || { printf '被拒内容进入快照：%s\n%s\n' "$bad" "$bytes" >&2; return 1; }
    done
    return 0
}

# 夹具：发布地址内容文件（多地址混合、备用第二份、空、超上限），供可信端点提供。
fixture_publish_hosts_files() {
    local i
    printf '%s\n' \
        '# fixture hosts for github.com' \
        '140.82.112.3 github.com' \
        '140.82.112.5 github.com' \
        '140.82.112.3 github.com' \
        '10.0.0.1 github.com' \
        '127.0.0.1 github.com' \
        '169.254.169.254 github.com' \
        '192.168.1.1 github.com' \
        '140.82.112.3 example.com' \
        '* github.com' \
        '140.82.112.4 *.github.com' | \
        bash "$FIXTURE_SCRIPT" hosts-put "$FIXTURE_FIX_VOL" "$IMAGE" hosts || return 1
    printf '%s\n' '140.82.113.10 github.com' '140.82.113.11 github.com' '140.82.113.12 github.com' | \
        bash "$FIXTURE_SCRIPT" hosts-put "$FIXTURE_FIX_VOL" "$IMAGE" hosts2 || return 1
    : | bash "$FIXTURE_SCRIPT" hosts-put "$FIXTURE_FIX_VOL" "$IMAGE" empty || return 1
    # 超限夹具必须是「体积超限但内容合法」的记录：若产品缺少体积上限，过滤与渲染仍会成功并改写快照，
    # 从而使「体积上限拒绝」与「无有效记录拒绝」可区分（全零字节内容在这两种情形下都会失败）。
    # 逐行合法公网 140.82.0.0/16 内的 github.com 记录，整体远大于 GM_HOSTS_MAX_BYTES=1048576。
    for ((i = 1; i <= 65535; i++)); do
        printf '140.82.%d.%d github.com\n' "$((i / 256))" "$((i % 256))"
    done | bash "$FIXTURE_SCRIPT" hosts-put "$FIXTURE_FIX_VOL" "$IMAGE" big || return 1
    return 0
}

# 夹具：启动可信 hosts HTTPS 端点（SAN=来源主机名，测试 CA 签发）。
fixture_start_hosts_endpoint() {
    bash "$FIXTURE_SCRIPT" hosts-serve "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_HOSTS_NAME"
}

# 夹具：启动错误证书 hosts HTTPS 端点（自签证书，不受测试 CA 信任）。
fixture_start_hosts_bad_endpoint() {
    bash "$FIXTURE_SCRIPT" hosts-serve-bad "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_HOSTS_BAD_NAME"
}

# 夹具就绪探测：可信端点经测试 CA 取到 200 且不带信任锚时失败（证明需真实证书链）；
# /empty 经测试 CA 取到 200 且响应体长度为 0（证明空响应用例确为「200 空体」，而非 404/错误页）；
# 错误证书端点以 -k 可达并返回 200（证明端点确实在提供文件，失败只能归因于证书不受信）。
fixture_wait_hosts_endpoints() {
    local i rc code probe
    for i in $(seq 1 30); do
        rc=0
        code=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/sh "$IMAGE" -c \
            "curl -sS --cacert $FIXTURE_CA --max-time 5 -o /dev/null -w '%{http_code}' https://$FIXTURE_HOSTS_ALIAS/hosts" \
            2>"$TEST_ROOT/hosts-probe.err") || rc=$?
        if [[ $rc == 0 && $code == 200 ]]; then break; fi
        if (( i == 30 )); then
            printf '可信 hosts 端点未就绪（curl 退出码 %s，HTTP %s）：\n' "$rc" "$code" >&2
            cat "$TEST_ROOT/hosts-probe.err" >&2 2>/dev/null || true
            return 1
        fi
        sleep 1
    done
    rc=0
    probe=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/sh "$IMAGE" -c \
        "curl -sS --cacert $FIXTURE_CA --max-time 5 -o /dev/null -w '%{http_code} %{size_download}' https://$FIXTURE_HOSTS_ALIAS/empty" \
        2>"$TEST_ROOT/hosts-empty-probe.err") || rc=$?
    [[ $rc == 0 && $probe == '200 0' ]] || {
        printf '可信端点空响应文件未就绪（期望 HTTP 200 且响应体长度 0，实得 curl %s [%s]）：\n' "$rc" "$probe" >&2
        cat "$TEST_ROOT/hosts-empty-probe.err" >&2 2>/dev/null || true
        return 1
    }
    rc=0
    docker run --rm --network "$FIXTURE_NET" --entrypoint /bin/sh "$IMAGE" -c \
        "curl -sS --max-time 5 -o /dev/null https://$FIXTURE_HOSTS_ALIAS/hosts" >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 ]] || { printf '可信端点未校验证书却成功，夹具前提不成立\n' >&2; return 1; }
    rc=0
    code=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/sh "$IMAGE" -c \
        "curl -sS --cacert $FIXTURE_MOUNT/fixture/tls/hosts-bad.crt --max-time 5 -o /dev/null -w '%{http_code}' https://$FIXTURE_HOSTS_BAD_ALIAS/hosts" \
        2>"$TEST_ROOT/hosts-bad-probe.err") || rc=$?
    [[ $rc == 0 && $code == 200 ]] || {
        printf '错误证书端点不可达（独立信任探测失败，curl %s，HTTP %s）：\n' "$rc" "$code" >&2
        cat "$TEST_ROOT/hosts-bad-probe.err" >&2 2>/dev/null || true
        return 1
    }
    return 0
}

# 夹具：把并发读者脚本写入产品卷。读者对快照做单次读取并记录「整文件摘要」，
# 由宿主断言每次读取恰为旧或新的完整快照之一——半文件/撕裂读取会得到第三种摘要。
# 只用镜像内确实存在的 cat/sha256sum（镜像无 sed/awk），不依赖缺失工具。
fixture_write_hosts_reader() {
    docker run --rm -i --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "umask 022; mkdir -p $FIXTURE_MOUNT/tmp && cat > $FIXTURE_MOUNT/tmp/hosts-reader.sh" <<'READER'
#!/bin/sh
set -u
SNAP=${1:?}; SEEN=${2:?}; STOP=${3:?}
while [ ! -e "$STOP" ]; do
    if [ -f "$SNAP" ]; then
        h=$(sha256sum "$SNAP" 2>/dev/null) || continue
        printf '%s\n' "${h%% *}" >> "$SEEN"
    fi
done
READER
}

# 多地址处理：合法多地址保留去重排序；非法/私网/元数据/非白名单/通配符被拒绝且不入快照；
# 头信息（格式/来源/记录数/摘要）与真实卷内快照字节一致。
fixture_hosts_multi_address() {
    local out
    fixture_clear_stale || return 1
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_URL" '' 2>&1) || { printf '刷新失败：\n%s\n' "$out" >&2; return 1; }
    fixture_hosts_snapshot_matches_hosts
}

# 空响应：必须以非零退出（不发布），且旧有效快照逐字节保留并标记陈旧。
fixture_hosts_empty_fails_retains() {
    local out before now status=0
    before=$(fixture_recorded_snapshot_sha); [[ -n $before ]] || return 1
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_EMPTY_URL" '' 2>&1) || status=$?
    [[ $status != 0 ]] || { printf '空响应刷新未失败：\n%s\n' "$out" >&2; return 1; }
    now=$(fixture_snapshot_bytes | sha256sum | cut -d' ' -f1) || return 1
    [[ $now == "$before" ]] || { printf '空响应后旧快照被改写：%s -> %s\n' "$before" "$now" >&2; return 1; }
    fixture_stale_present
}

# 超上限响应：以真实超大响应触发体积拒绝，必须以非零退出、诊断指明体积上限，且旧有效快照逐字节保留。
fixture_hosts_oversize_fails_retains() {
    local out before now status=0
    before=$(fixture_recorded_snapshot_sha); [[ -n $before ]] || return 1
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_BIG_URL" '' 2>&1) || status=$?
    [[ $status != 0 ]] || { printf '超上限响应刷新未失败：\n%s\n' "$out" >&2; return 1; }
    case "$out" in
        *'file size'*|*'max-filesize'*|*'1048576'*) ;;
        *) printf '超上限诊断未指明体积上限：\n%s\n' "$out" >&2; return 1 ;;
    esac
    now=$(fixture_snapshot_bytes | sha256sum | cut -d' ' -f1) || return 1
    [[ $now == "$before" ]] || { printf '超上限响应后旧快照被改写：%s -> %s\n' "$before" "$now" >&2; return 1; }
    fixture_stale_present
}

# 可区分性对照：同一超限内容在撤除体积上限后仍能通过产品自身的过滤与渲染（记录数 > 0），
# 证明刷新失败只能归因于体积上限，而非「无有效记录」——这是与全零字节内容的判别依据。
fixture_hosts_oversize_content_valid_without_cap() {
    local out rc=0 count
    out=$(docker run --rm --network "$FIXTURE_NET" -v "$FIXTURE_CA_VOL:$FIXTURE_MOUNT:ro" --entrypoint /bin/bash "$IMAGE" -c "
        source /usr/local/lib/git-mirror/lib/foundation.sh
        curl -sS --cacert $FIXTURE_CA --max-time 30 -- 'https://$FIXTURE_HOSTS_ALIAS/big' \
            | gm_hosts_filter_records \
            | gm_hosts_render_snapshot 'https://$FIXTURE_HOSTS_ALIAS/big' 2026-01-01T00:00:00+0000 \
            | grep -m1 '^# COUNT='
        " 2>"$TEST_ROOT/hosts-big-control.err") || rc=$?
    [[ $rc == 0 && $out == '# COUNT='* ]] || {
        printf '超限内容对照：撤除体积上限后产品过滤/渲染未成功（curl/bash %s，输出 [%s]）：\n' "$rc" "$out" >&2
        cat "$TEST_ROOT/hosts-big-control.err" >&2 2>/dev/null || true
        return 1
    }
    count=${out#*# COUNT=}; count=${count%%[!0-9]*}
    [[ $count =~ ^[0-9]+$ ]] && (( count > 0 )) || { printf '超限内容对照记录数非正：%s\n' "$count" >&2; return 1; }
    return 0
}

# 主备来源：主源失败（空响应）时改用备用源成功发布，来源头指向备用源，且清除陈旧标记。
fixture_hosts_fallback_success() {
    local out bytes want pay digest
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_EMPTY_URL" "$FIXTURE_HOSTS_URL2" 2>&1) || { printf '回退刷新失败：\n%s\n' "$out" >&2; return 1; }
    bytes=$(fixture_snapshot_bytes) || return 1
    [[ $bytes == *"# SOURCE=$FIXTURE_HOSTS_URL2"* ]] || { printf '未使用备用来源：\n%s\n' "$bytes" >&2; return 1; }
    want=$'140.82.113.10 github.com\n140.82.113.11 github.com\n140.82.113.12 github.com'
    pay=$(printf '%s\n' "$want")
    digest=$(printf '%s\n' "$pay" | sha256sum); digest=${digest%% *}
    [[ $bytes == *"# DIGEST=sha256:$digest"* ]] || { printf '备用来源摘要不符：\n%s\n' "$bytes" >&2; return 1; }
    [[ $(printf '%s\n' "$bytes" | grep -v '^#') == "$want" ]] || { printf '备用来源数据行不符：\n%s\n' "$bytes" >&2; return 1; }
    ! fixture_stale_present
}

# 原子替换与并发读者：刷新期间持续读取快照整文件摘要，每次读取恰为旧或新完整快照之一，
# 无半文件/撕裂读取；同时观察到替换前后两种完整快照摘要，证明替换确实发生在读取窗口内；
# 替换后快照内容与摘要正确。
fixture_hosts_atomic_replace_readers() {
    local out seen oldh newh total distinct
    fixture_snapshot_bytes > "$TEST_ROOT/atomic-old" || return 1
    oldh=$(sha256sum < "$TEST_ROOT/atomic-old"); oldh=${oldh%% *}
    out=$(docker exec "$FIXTURE_PROD" sh -c '
        R=/var/lib/git-daemon
        w=$R/tmp/hosts-atomic
        mkdir -p "$w"
        : > "$w/seen"; rm -f "$w/stop"
        sh "$R/tmp/hosts-reader.sh" "$R/hosts/github-hosts.snapshot" "$w/seen" "$w/stop" &
        reader=$!
        umask 022
        ENABLE_HOSTS_UPDATE=yes HOSTS_URL='"$FIXTURE_HOSTS_URL"' HOSTS_URL_FALLBACK= \
            HOME='"$FIXTURE_HOME"' CURL_CA_BUNDLE='"$FIXTURE_CA"' \
            /usr/local/lib/git-mirror/update-github-hosts.sh
        status=$?
        sleep 1
        : > "$w/stop"
        wait "$reader"
        exit "$status"
    ' 2>&1) || { printf '并发读者场景刷新失败：\n%s\n' "$out" >&2; return 1; }
    fixture_snapshot_bytes > "$TEST_ROOT/atomic-new" || return 1
    newh=$(sha256sum < "$TEST_ROOT/atomic-new"); newh=${newh%% *}
    [[ $oldh != "$newh" ]] || { printf '替换前后快照字节相同，无法区分原子替换\n' >&2; return 1; }
    seen=$(docker run --rm --user 10001:10001 -v "$FIXTURE_PROD_VOL:$FIXTURE_MOUNT" --entrypoint cat "$IMAGE" \
        "$FIXTURE_MOUNT/tmp/hosts-atomic/seen" 2>/dev/null) || return 1
    total=$(printf '%s\n' "$seen" | grep -c . || true)
    distinct=$(printf '%s\n' "$seen" | sort -u | grep -c . || true)
    if printf '%s\n' "$seen" | grep -v -e "^$oldh$" -e "^$newh$" | grep -q .; then
        printf '并发读者见到非完整快照摘要（旧 %s / 新 %s）：\n%s\n' "$oldh" "$newh" "$seen" >&2
        return 1
    fi
    (( total >= 5 )) || { printf '完整读取样本不足（total=%s）：\n%s\n' "$total" "$seen" >&2; return 1; }
    (( distinct >= 2 )) || { printf '未观察到替换前后两种完整快照（distinct=%s）\n' "$distinct" >&2; return 1; }
    fixture_hosts_snapshot_matches_hosts
}

# 错误证书：必须以非零退出并给出证书类诊断，且旧有效快照逐字节保留、标记陈旧。
fixture_hosts_wrong_certificate_fails_retains() {
    local out before now status=0
    before=$(fixture_recorded_snapshot_sha); [[ -n $before ]] || return 1
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_BAD_URL" '' 2>&1) || status=$?
    [[ $status != 0 ]] || { printf '错误证书刷新未失败：\n%s\n' "$out" >&2; return 1; }
    case "$out" in
        *certificate*|*Certificate*|*SSL*|*ssl*|*证书*) ;;
        *) printf '错误证书诊断未指明证书问题：\n%s\n' "$out" >&2; return 1 ;;
    esac
    now=$(fixture_snapshot_bytes | sha256sum | cut -d' ' -f1) || return 1
    [[ $now == "$before" ]] || { printf '错误证书后旧快照被污染：%s -> %s\n' "$before" "$now" >&2; return 1; }
    fixture_stale_present
}

# 夹具：记录产品容器内 /etc/hosts 与 /etc/resolv.conf 基线（运行前后比对用）。
fixture_record_system_files() {
    docker exec "$FIXTURE_PROD" sha256sum /etc/hosts /etc/resolv.conf > "$TEST_ROOT/system-files.before" 2>/dev/null
    [[ -s $TEST_ROOT/system-files.before ]]
}

# 项目运行不修改系统 /etc/hosts 与 /etc/resolv.conf：以一次真实刷新为运行样本，前后字节摘要一致。
fixture_hosts_system_files_unchanged() {
    local before after out status=0
    before=$(cat "$TEST_ROOT/system-files.before" 2>/dev/null) || before=
    [[ -n $before ]] || { printf '缺少系统文件基线\n' >&2; return 1; }
    out=$(fixture_exec_hosts_refresh "$FIXTURE_HOSTS_URL" '' 2>&1) || status=$?
    [[ $status == 0 ]] || { printf '刷新失败，无法作为运行样本：\n%s\n' "$out" >&2; return 1; }
    after=$(docker exec "$FIXTURE_PROD" sha256sum /etc/hosts /etc/resolv.conf 2>/dev/null) || return 1
    [[ "$before" == "$after" ]] || {
        printf '项目运行改写了系统 hosts/resolv.conf：\n before=%s\n after=%s\n' "$before" "$after" >&2
        return 1
    }
    [[ $(docker inspect -f '{{.State.Running}}' "$FIXTURE_PROD" 2>/dev/null) == true ]]
}

# 依赖 C-2 夹具就绪的产品断言：夹具未就绪时只记夹具失败，不冒充产品结论。
check_c2() { check_gated C2_READY "$@"; }

# 销毁上一场 C-2 场景的网络、卷与容器；全部属测试作用域，绝不触碰全局命名卷。
c2_scene_teardown() {
    archive_container "$C2_FIX"
    archive_container "$C2_PROD"
    archive_container "$C2_SAMP"
    docker rm -f "$C2_SAMP" "$C2_PROD" "$C2_FIX" >/dev/null 2>&1 || true
    docker volume rm -f "$C2_VOL" "$C2_LOG_VOL" >/dev/null 2>&1 || true
    return 0
}

# 建立 C-2 隔离网络与两个命名卷（产品运行卷、采样日志卷），并启动「快速失败 + 挂起」TCP 端点夹具。
# hang_after 表示 8443 上前若干次连接接受后立即关闭，之后连接挂起不响应；8091 端口不涉及。
c2_scene_fixture() {
    local hang_after=$1 script
    c2_scene_teardown
    [[ -n ${IT_NETWORK:-} && $C2_NET == "$IT_NETWORK" ]] || return 77
    docker volume create "$C2_VOL" >/dev/null 2>&1 || return 1
    docker volume create "$C2_LOG_VOL" >/dev/null 2>&1 || return 1
    script=$(cat <<'EOS'
( while true; do busybox nc -l -p 443 < /dev/null > /dev/null 2>&1; done ) &
n=0
while true; do
    if [ "$n" -lt __HANG_AFTER__ ]; then
        busybox nc -l -p 8443 < /dev/null > /dev/null 2>&1
    else
        sleep 3600 | busybox nc -l -p 8443 > /dev/null 2>&1
    fi
    n=$((n + 1))
done
EOS
)
    script=${script/__HANG_AFTER__/$hang_after}
    docker run -d --name "$C2_FIX" --network "$C2_NET" --network-alias github.com --network-alias gm-hang \
        --user 10001:10001 --entrypoint /bin/sh "$IMAGE" -c "$script" >/dev/null 2>&1 || return 1
    return 0
}

# 启动产品容器：firstsync（首次同步经挂起代理）、timedsync（定时同步经挂起代理）、
# timedhosts（定时 hosts 刷新指向挂起端点）；均为只读根、cap_drop ALL、no-new-privileges、UID10001、仅命名卷。
c2_scene_start_product() {
    local mode=$1 e
    local -a envs=("REPOS=acme/demo") args=()
    case "$mode" in
        firstsync)
            envs+=("ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=no" "PROXY_URL=https://gm-hang:8443") ;;
        timedsync)
            envs+=("ENABLE_HOSTS_UPDATE=no" "ENABLE_CRON=yes" "CRON_SCHEDULE=* * * * *" "PROXY_URL=https://gm-hang:8443") ;;
        timedhosts)
            envs+=("ENABLE_HOSTS_UPDATE=yes" "ENABLE_CRON=yes" "CRON_SCHEDULE=0 0 1 1 *" \
                "HOSTS_CRON=* * * * *" "HOSTS_URL=https://gm-hang:8443/hosts" "HOSTS_URL_FALLBACK=") ;;
        *) return 1 ;;
    esac
    for e in "${envs[@]}"; do args+=(-e "$e"); done
    docker rm -f "$C2_PROD" >/dev/null 2>&1 || true
    docker run -d --name "$C2_PROD" --network "$C2_NET" --read-only --cap-drop ALL \
        --security-opt no-new-privileges --user 10001:10001 -v "$C2_VOL:$C2_MOUNT" \
        "${args[@]}" "$IMAGE" >/dev/null 2>&1 || return 1
    container_networks_internal "$C2_PROD" || return 1
    container_networks_internal "$C2_FIX"
}

# 判定本地时间线是否已出现目标模式的「多层任务树」：同步模式等传输助手（git-remote-*/fetch --progress），
# 刷新模式等 curl；且该进程的 ppid 既不是 0 也不是容器内 PID1（即确为任务的深层子孙）。
# 数据全部来自采样侧车（与产品共享 PID 命名空间），以容器内 PID1 语义判定，
# 不用宿主命名空间的 PID/ppid（宿主 PID1 与容器入口 PID1 不是同一进程，语义不同）。
# 按模式限定到真正挂起的传输助手，避免把「首次地址刷新」等短暂子进程误判为待观察的多层任务树。
c2_timeline_has_deep_tree() {
    C2_MARKERS="$C2_MARKERS" C2_MODE="$1" awk '
        BEGIN {
            mode = ENVIRON["C2_MODE"]
            if (mode == "timedhosts") {
                helper = "(^| )curl "
                taskpat = "update-github-hosts\\.sh"
            } else if (mode == "timedsync") {
                helper = "(git-remote-(https|curl)|fetch --progress)"
                taskpat = "git-mirror-sync\\.sh"
            } else {
                helper = "(git-remote-(https|curl)|fetch --progress)"
                taskpat = ""
            }
            sched = 0; found = 0
        }
        /^S[ ]/ { inframe=1; f_help=0; f_task=0; next }
        /^E$/ {
            if (inframe && f_help && (taskpat == "" || f_task)) found = 1
            inframe=0; next
        }
        {
            if (!inframe) next
            if ($0 !~ /^[[:space:]]*pid=[0-9]+[[:space:]]/) next
            line=$0; sub(/^[[:space:]]*/, "", line)
            split(line, a, " ")
            pid=a[1]; sub(/^pid=/,"",pid)
            ppid=a[2]; sub(/^ppid=/,"",ppid)
            cmd=$0
            sub(/^[[:space:]]*pid=[0-9]+[[:space:]]+ppid=[0-9]+[[:space:]]+pgid=[0-9]+[[:space:]]+ruid=[0-9]+[[:space:]]+euid=[0-9]+[[:space:]]*/, "", cmd)
            # 记录常驻调度器主进程的 PID（排除启动前 --check 调用），供识别其派发的任务。
            # 调度器进程名不在任务标记集合内，故必须在标记过滤之前识别，否则会被提前跳过。
            if (cmd ~ /git-mirror-scheduler\.sh/ && cmd !~ /--check/ && ppid == 1) sched = pid
            if (cmd !~ ENVIRON["C2_MARKERS"]) next
            if (cmd ~ helper && ppid != 0 && ppid != 1) f_help = 1
            # 定时模式要求同一帧内既存在「父进程为调度器 PID 的任务脚本」，
            # 也存在其深层传输助手，以排除启动阶段的首次任务或其后代被误当成待观察的定时任务。
            if (taskpat != "" && sched != 0 && cmd ~ taskpat && ppid == sched) f_task = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$C2_TIMELINE"
}

# 等待目标模式的多层任务树出现（夹具步骤）：数据取自采样侧车的容器命名空间时间线。
# 定时模式需等 Cron 到点（最多约一分钟），故等待上限设为约 120 秒。
c2_scene_wait_tree() {
    local mode=${1-} i
    for i in $(seq 1 480); do
        c2_scene_read_timeline
        if c2_timeline_has_deep_tree "$mode"; then return 0; fi
        sleep 0.25
    done
    return 1
}

# 采样侧车：共享产品容器 PID 命名空间，把 (pid ppid pgid ruid euid cmd) 按帧写入采样日志卷；
# 同时只读式挂载产品运行卷，仅在信号标记出现后尝试非阻塞取操作锁并把结果记入同一时间线，
# 使「锁在 PID1 存活期间被释放」有独立于 PID1 退出后内核清理的证据。
# 侧车与产品共享 PID 命名空间：产品 PID1 一退出，命名空间即销毁、侧车被终止，
# 因此侧车记下的每一帧都必然落在 PID1 存活窗口内。
c2_scene_start_sampler() {
    local mode=$1 lock script
    lock=$(c2_lock_file_name "$mode")
    docker rm -f "$C2_SAMP" >/dev/null 2>&1 || true
    docker run --rm -v "$C2_LOG_VOL:$C2_MOUNT" --user 10001:10001 --entrypoint /bin/sh "$IMAGE" \
        -c "rm -f $C2_SAMPLE" >/dev/null 2>&1 || true
    script=$(cat <<'EOS'
marked=0
while [ -d /proc/1 ]; do
    # 信号边界由采样侧车自身写入，保证采样文件只有一个写入者，
    # 避免边界行插入某帧中间而破坏帧分段（否则会把信号前的帧误判为信号后）。
    if [ "$marked" = 0 ] && [ -e __SIGNALFILE__ ]; then
        printf "SIGNAL %s\n" "$(date +%s.%N)" >> __SAMPLE__
        marked=1
    fi
    {
        printf "S %s\n" "$(date +%s.%N)"
        for d in /proc/[0-9]*; do
            p=${d#/proc/}
            [ "$p" = "$$" ] && continue
            cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null || true)
            stat=$(cat "$d/stat" 2>/dev/null || true)
            rest=${stat##*\) }
            set -- $rest
            ppid=${2-}
            pgid=${3-}
            uids=$(busybox awk "/^Uid:/{print \$2, \$3}" "$d/status" 2>/dev/null || true)
            # 进程可能在本帧读取过程中退出；读取失败时跳过该行，避免以空值伪造出 root 进程。
            [ -n "$ppid" ] || continue
            [ -n "$pgid" ] || continue
            [ -n "$uids" ] || continue
            set -- $uids
            # 同时记录实际 UID 与有效 UID，任一非 10001 都视为出现非 root 身份偏差。
            printf "  pid=%s ppid=%s pgid=%s ruid=%s euid=%s %s\n" "$p" "$ppid" "$pgid" "$1" "$2" "$cmd"
        done
        # 仅在信号标记出现后观测锁：取锁成功即证明持锁进程已退出，且此刻 PID1 仍存活。
        if [ -e __SIGNALFILE__ ]; then
            if flock -n -x __LOCK__ true 2>/dev/null; then
                printf "  lock=free\n"
            else
                printf "  lock=busy\n"
            fi
        fi
        printf "E\n"
    } >> __SAMPLE__
    # 停止信号出现后缩短休眠，以更高频率采样，尽量捕捉 PID1 存活期间的回收窗口。
    if [ -e __SIGNALFILE__ ]; then sleep 0.01; else sleep 0.05; fi
done
printf "SAMPLER-EXIT %s\n" "$(date +%s.%N)" >> __SAMPLE__
EOS
)
    script=${script//__SAMPLE__/$C2_SAMPLE}
    script=${script//__SIGNALFILE__/$C2_SIGNAL_FILE}
    script=${script//__LOCK__/$C2_PROD_MOUNT/runtime/$lock}
    docker run -d --name "$C2_SAMP" --pid "container:$C2_PROD" -v "$C2_LOG_VOL:$C2_MOUNT" \
        -v "$C2_VOL:$C2_PROD_MOUNT:ro" --user 10001:10001 --entrypoint /bin/sh "$IMAGE" \
        -c "$script" >/dev/null 2>&1
}

# 等待采样侧车确实写入至少一个含 PID1 的进程行：避免在侧车尚未开始记录时就发出停止信号，
# 使「子孙在 PID1 存活期间被回收」的判定建立在真实时间线之上。
c2_scene_wait_sampler() {
    local i
    for i in $(seq 1 100); do
        c2_scene_read_timeline
        if grep -qE '(^| )pid=1 ' "$C2_TIMELINE"; then return 0; fi
        sleep 0.2
    done
    return 1
}

# 返回目标模式在停止时应被持有的操作锁文件名：hosts 刷新用 hosts.lock，同步用 sync.lock。
c2_lock_file_name() {
    case "$1" in
        timedhosts) printf 'hosts.lock' ;;
        *) printf 'sync.lock' ;;
    esac
}

# 记录信号前状态（动作，非断言）：在同一命名卷上以新实例尝试非阻塞取操作锁，
# 判定停止前锁是否确实被持有（该观测发生在 PID1 存活期间，作为锁释放判据的前置条件）。
c2_scene_record_prestate() {
    local mode=$1 lock
    lock=$(c2_lock_file_name "$mode")
    if docker run --rm --user 10001:10001 -v "$C2_VOL:$C2_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "flock -n -x $C2_MOUNT/runtime/$lock true" >/dev/null 2>&1; then
        printf 'no\n' > "$TEST_ROOT/c2-lock-busy"
    else
        printf 'yes\n' > "$TEST_ROOT/c2-lock-busy"
    fi
    return 0
}

# 创建卷内信号标记文件；信号边界行由采样侧车在看到该文件后自行写入采样时间线
# （保持采样文件单一写入者）。失败不使整个套件中止：由后续基于时间线的断言给出可读的失败归因。
c2_scene_mark_signal() {
    docker run --rm -v "$C2_LOG_VOL:$C2_MOUNT" --user 10001:10001 --entrypoint /bin/sh "$IMAGE" \
        -c ": > $C2_SIGNAL_FILE" >/dev/null 2>&1 || true
    return 0
}

# 行为判据（回收主判据）：停止信号后含 PID1 的末帧内已无「深层子孙」任务标记（last_post_deep=0），
# 且至少存在一帧信号后含 PID1 的采样（post_frames>=1）以排除空判据。
# 采样侧车与产品共享 PID 命名空间，PID1 退出即侧车终止，故信号后的帧必然发生在 PID1 存活期间；
# 末帧无深层子孙即直接测量到「多层子孙已在 PID1 存活期间被回收」，不依赖产品日志。
# 只计深层子孙（父进程非 0/1），避免任务组长在拆除瞬间尚未退出造成与回收无关的误判。
c2_assert_reclaimed_behavior() {
    local f n m
    f=$(cat "$C2_FACT_FILE" 2>/dev/null)
    n=${f#*post_frames=}; n=${n%% *}
    [[ $n =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 )) || return 1
    m=${f#*last_post_deep=}; m=${m%% *}
    [[ $m =~ ^-?[0-9]+$ ]] || return 1
    (( m == 0 ))
}

# 代理判据（辅助）：产品自证「已回收进程组全部子孙」日志（首次任务由入口输出，定时任务由调度器写入实例调度日志）。
# 该判据衡量的是产品声明而非直接测量：缺少该日志时对旧产品失败，但存在该日志不证明子孙确实已回收。
c2_assert_reclaimed_log() {
    local mode=$1 label
    case "$mode" in
        firstsync) label='首次仓库同步' ;;
        timedsync) label='仓库同步' ;;
        timedhosts) label='地址刷新' ;;
        *) return 1 ;;
    esac
    if [[ $mode == firstsync ]]; then
        docker logs "$C2_PROD" 2>&1 | grep -q "$label 已回收进程组全部子孙"
        return
    fi
    docker run --rm --user 10001:10001 -v "$C2_VOL:$C2_MOUNT" --entrypoint /bin/sh "$IMAGE" \
        -c "grep -q '$label 已回收进程组全部子孙' $C2_MOUNT/logs/scheduler.log" >/dev/null 2>&1
}

# 发送停止信号并记录结果（动作，非断言）：TERM 用 docker stop -t 30；INT 用 docker kill -s INT，
# 两者都最多等待 30 秒（与 Compose stop_grace_period 对齐），记录容器是否退出与退出码。
c2_scene_signal() {
    local sig=$1 start i running
    start=$(date +%s)
    if [[ $sig == INT ]]; then
        docker kill -s INT "$C2_PROD" >/dev/null 2>&1 || true
        for i in $(seq 1 60); do
            running=$(docker inspect -f '{{.State.Running}}' "$C2_PROD" 2>/dev/null) || running=
            [[ $running != true ]] && break
            sleep 0.5
        done
    else
        docker stop -t 30 "$C2_PROD" >/dev/null 2>&1 || true
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$C2_PROD" 2>/dev/null) || running=
    printf '%s %s %s\n' "$(( $(date +%s) - start ))" \
        "$(docker inspect -f '{{.State.ExitCode}}' "$C2_PROD" 2>/dev/null || echo '?')" "$running" \
        > "$C2_STOP_FILE"
    return 0
}

# 把采样侧车容器内的采样时间线复制到测试临时目录；不额外启动容器，避免污染被测 PID 命名空间。
# 侧车容器即便已随 PID1 退出而停止，docker cp 仍可读取其文件系统快照。
c2_scene_read_timeline() {
    docker cp "$C2_SAMP:$C2_SAMPLE" "$C2_TIMELINE" >/dev/null 2>&1 || : > "$C2_TIMELINE"
    return 0
}

# 解析时间线，输出信号前最后一帧与信号后帧的判定事实：
#   pre_haspid1 信号前末帧含 PID1；pre_mark 该帧任务标记进程数；pre_deep 其中存在父非 0/1 的多层证据；
#   post_frames 信号后含 PID1 的帧数；last_post_mark/post_min_mark 末帧/最小帧的任务标记进程数；
#   last_post_deep/post_min_deep 同上但只计「深层子孙」（父进程非 0/1）——行为回收主判据用它，
#     以免任务组长（PID1 直接子进程）在末帧尚未退出的拆除瞬间造成误判；
#   new_after_signal 信号后出现了信号前不存在的任务标记 PID；
#   lock_free_pid1 信号后含 PID1 的帧内观测到操作锁可被获取（锁已释放）；
#   uid_bad 全时间线存在实际或有效 UID 非 10001 的进程。
# 时间线全部来自共享 PID 命名空间的采样侧车，故 post 帧必然落在 PID1 存活窗口内。
c2_scene_analyze() {
    local facts
    facts=$(C2_MARKERS="$C2_MARKERS" awk '
        BEGIN { phase="pre"; pre_haspid1=0; pre_mark=0; pre_deep=0; pre_pids=""; post_frames=0; last_post_mark=-1; post_min_mark=-1; last_post_deep=-1; post_min_deep=-1; new_after=0; lock_free=0; uid_bad=0 }
        /^SIGNAL/ { phase="post"; next }
        /^S[ ]/ { ts=$2; haspid1=0; nmark=0; ndeep=0; pids=""; lock="none"; inframe=1; next }
        /^E$/ {
            if (inframe) {
                if (phase=="pre") {
                    if (haspid1) { pre_haspid1=1; pre_mark=nmark; pre_deep=(ndeep>0)?1:0; pre_pids=(pre_pids pids) }
                } else if (haspid1) {
                    post_frames++
                    last_post_mark=nmark
                    if (post_min_mark < 0 || nmark < post_min_mark) post_min_mark=nmark
                    last_post_deep=ndeep
                    if (post_min_deep < 0 || ndeep < post_min_deep) post_min_deep=ndeep
                    if (lock == "free") lock_free=1
                }
            }
            inframe=0; next
        }
        {
            if (!inframe) next
            if ($0 ~ /^[[:space:]]*lock=/) {
                lock=$0
                sub(/^[[:space:]]*lock=/, "", lock)
                sub(/[[:space:]].*$/, "", lock)
                next
            }
            if ($0 !~ /^[[:space:]]*pid=[0-9]+[[:space:]]/) next
            line=$0; sub(/^[[:space:]]*/, "", line)
            split(line, a, " ")
            pid=a[1]; sub(/^pid=/, "", pid)
            ppid=a[2]; sub(/^ppid=/, "", ppid)
            ruid=a[4]; sub(/^ruid=/, "", ruid)
            euid=a[5]; sub(/^euid=/, "", euid)
            if (ruid != "10001" || euid != "10001") uid_bad=1
            cmd=$0
            sub(/^[[:space:]]*pid=[0-9]+[[:space:]]+ppid=[0-9]+[[:space:]]+pgid=[0-9]+[[:space:]]+ruid=[0-9]+[[:space:]]+euid=[0-9]+[[:space:]]*/, "", cmd)
            if (pid == 1) haspid1=1
            if (cmd ~ ENVIRON["C2_MARKERS"]) {
                nmark++
                pids = pids pid ","
                if (ppid != 0 && ppid != 1) ndeep++
                if (phase=="post" && index("," pre_pids, "," pid ",") == 0) new_after=1
            }
        }
        END {
            printf "pre_haspid1=%d pre_mark=%d pre_deep=%d post_frames=%d last_post_mark=%d post_min_mark=%d last_post_deep=%d post_min_deep=%d new_after_signal=%d lock_free_pid1=%d uid_bad=%d\n",
                pre_haspid1, pre_mark, pre_deep, post_frames, last_post_mark, post_min_mark, last_post_deep, post_min_deep, new_after, lock_free, uid_bad
        }
    ' "$C2_TIMELINE")
    printf '%s\n' "$facts" > "$C2_FACT_FILE"
    printf '%s\n' "$facts"
}

# 断言：信号前最后一帧确实存在由多层子孙构成的整棵任务树。
c2_assert_tree() {
    local f n
    f=$(cat "$C2_FACT_FILE" 2>/dev/null)
    [[ $f == *'pre_haspid1=1'* && $f == *'pre_deep=1'* ]] || return 1
    n=${f#*pre_mark=}; n=${n%% *}
    [[ $n =~ ^[0-9]+$ ]] || return 1
    (( n >= 2 ))
}

# 断言：全时间线每个进程的实际/有效 UID 均为 10001，无一为 root。
c2_assert_uid_nonroot() {
    local f n
    f=$(cat "$C2_FACT_FILE" 2>/dev/null)
    [[ $f == *'uid_bad=0'* ]] || return 1
    n=${f#*pre_mark=}; n=${n%% *}
    [[ $n =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 ))
}

# 断言：停止在 30 秒宽限期内完成、容器已退出且退出码不是 137（未被 SIGKILL 强杀）。
c2_assert_bounded() {
    local elapsed exit running
    [[ -s $C2_STOP_FILE ]] || return 1
    read -r elapsed exit running < "$C2_STOP_FILE"
    [[ $running == false ]] || return 1
    [[ $exit != 137 ]] || return 1
    [[ $elapsed =~ ^[0-9]+$ ]] || return 1
    (( elapsed < 30 ))
}

# 行为判据：停止后不再派发新任务——信号后的采样中不再出现信号前不存在的任务标记 PID。
# 采样侧车仅在 PID1 存活期间记录，故该判据覆盖的是停止信号后的宽限窗口本身，
# 不是「容器退出后日志不再增长」这类恒真观察。
c2_assert_no_dispatch() {
    local f n
    f=$(cat "$C2_FACT_FILE" 2>/dev/null)
    n=${f#*post_frames=}; n=${n%% *}
    [[ $n =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 )) || return 1
    [[ $f == *'new_after_signal=0'* ]]
}

# 断言：停止前记录到操作锁被持有（同卷新实例不可获取）；该观测发生在 PID1 存活期间。
c2_assert_lock_busy() {
    [[ $(tr -d '[:space:]' < "$TEST_ROOT/c2-lock-busy" 2>/dev/null) == yes ]]
}

# 行为判据：信号后含 PID1 的帧内观测到操作锁可被获取（lock_free_pid1=1）。
# 采样侧车在信号后持续非阻塞取锁，取到即证明持锁进程已退出且此刻 PID1 仍存活，
# 与 PID1 退出后的内核清理无关，也避免以「容器退出后 flock 必然释放」充当证据。
c2_assert_lock_free() {
    local f
    f=$(cat "$C2_FACT_FILE" 2>/dev/null)
    [[ $f == *'lock_free_pid1=1'* ]]
}

# C-2 定向用例：复位陈旧服务状态必须移除陈旧 pidfile。
# 仅 zap OpenRC 状态不够：start-stop-daemon 只按 pidfile 中 PID 是否存活判断「已在运行」，
# 强杀重建后陈旧 PID 被新容器进程复用时会被误判，服务无法拉起。
# 在隔离子 Shell 中桩掉 rc-service 后直接调用入口函数，以「pidfile 是否仍存在」的行为结果判定，
# 不依赖 S6（compose 强杀重建）是否被执行。
c2_reset_removes_stale_pidfile() {
    local dir=$TEST_ROOT/c2-stale-pidfile out status=0
    mkdir -p "$dir/runtime" || return 1
    printf '4242\n' > "$dir/runtime/git-daemon.pid" || return 1
    out=$(RUN_ROOT="$dir" bash -c '
        rc-service() { return 0; }
        source "$1"
        reset_stale_service_state git-daemon
        if [ -e "$RUN_ROOT/runtime/git-daemon.pid" ]; then printf "PRESENT\n"; else printf "ABSENT\n"; fi
    ' _ "$ROOT/docker/docker-entrypoint.sh" 2>&1) || status=$?
    printf 'C-2 陈旧 pidfile 复位观测：status=%s out=%s\n' "$status" "$(tr -d '\n' <<<"$out")"
    [[ $out == *ABSENT* ]]
}

# 执行一场 C-2 场景：夹具 → 产品启动 → 采样侧车 → 采样命名空间就绪 → 停止信号 → 断言。
c2_run_scenario() {
    local mode=$1 hang=$2 sig=$3 base
    base=$FIXTURE_FAILURES
    C2_READY=0
    fixture_step "C-2[$mode/$sig] 夹具：隔离网络与快速失败+挂起端点" c2_scene_fixture "$hang"
    fixture_step "C-2[$mode/$sig] 夹具：产品容器启动" c2_scene_start_product "$mode"
    fixture_step "C-2[$mode/$sig] 夹具：共享 PID 命名空间采样侧车" c2_scene_start_sampler "$mode"
    fixture_step "C-2[$mode/$sig] 夹具：采样侧车已记录到 PID1" c2_scene_wait_sampler
    fixture_step "C-2[$mode/$sig] 夹具：容器命名空间已形成多层任务树" c2_scene_wait_tree "$mode"
    if [[ $FIXTURE_FAILURES == $base ]]; then C2_READY=1; fi
    c2_scene_record_prestate "$mode"
    c2_scene_mark_signal "$sig"
    c2_scene_signal "$sig"
    c2_scene_read_timeline
    printf 'C-2[%s/%s] 采样事实：%s\n' "$mode" "$sig" "$(c2_scene_analyze)"
    check_c2 "C-2[$mode/$sig] 停止在 30 秒宽限期内完成且未被 SIGKILL" c2_assert_bounded
    check_c2 "C-2[$mode/$sig] 多层子孙在 PID1 存活期间被回收（行为采样）" c2_assert_reclaimed_behavior
    check_c2 "C-2[$mode/$sig] 产品自证已回收进程组日志（代理判据）" c2_assert_reclaimed_log "$mode"
    check_c2 "C-2[$mode/$sig] 停止后不再派发新任务（行为采样）" c2_assert_no_dispatch
    check_c2 "C-2[$mode/$sig] 停止前捕获到多层任务树" c2_assert_tree
    check_c2 "C-2[$mode/$sig] 全树实际/有效 UID 均为 10001（无 root 业务进程）" c2_assert_uid_nonroot
    check_c2 "C-2[$mode/$sig] 停止前操作锁被持有" c2_assert_lock_busy
    check_c2 "C-2[$mode/$sig] 锁在 PID1 存活期间被释放（行为采样）" c2_assert_lock_free
    c2_scene_teardown
}

# 定向契约探针只加载函数，不启动业务、构建镜像或发出上游请求。
if [[ ${IT_SOURCE_ONLY:-0} == 1 ]]; then
    return 0
fi

# docker 完全不可用（CLI 缺失或守护进程不可达）才整体跳过并返回 77。
[[ ${IT_NETWORK_GUARD_READY:-} == 1 && $(id -u) != 0 ]] || exit 77
case "$IT_FILTER" in ''|o1|c2) ;; *) exit 64 ;; esac
if ! docker_available; then
    printf 'SKIP：docker 不可用，未执行\n'
    exit 77
fi

write_compose_override

COMPOSE_ENABLED=0
if compose_available; then
    COMPOSE_ENABLED=1
elif [[ $IT_FILTER != c2 ]]; then
    printf 'FAIL：必需的 Docker Compose 不可用，未执行集成业务\n' >&2
    exit 1
fi

if [[ -n ${IT_PRODUCT_IMAGE:-} ]]; then
    check '已冻结产品镜像可用（构建由非 root 预备阶段完成）' docker image inspect "$IMAGE"
else
    check 'docker build --no-cache 退出码为 0' build_image
fi
check '镜像默认运行身份为 10001:10001' image_user_is_nonroot
check '镜像实际运行身份真实与有效 UID 均为 10001' run_identity_nonroot
check '由 RUN 生成的路径属主为 10001（构建步骤非 root）' build_paths_owned_by_app
check '运行根属主 10001、权限 755' runtime_root_attributes
check '空命名卷首次挂载后以 10001 可写入' named_volume_writable
check '运行时依赖命令与 CA/时区文件齐备' runtime_dependencies_present
check '镜像不含 SSH 组件' no_ssh_components
check '入口拒绝 UID 0（UID 查询替身，非实际 root 容器）' entry_rejects_root

# 就绪判据：正式入口按内核 LISTEN 状态与本地地址端口判定，同端口非 LISTEN 连接不得算就绪。
readiness_assert '就绪判据：真实 LISTEN 判定为就绪（正对照）' readiness_positive_control
readiness_assert '就绪判据：同端口非 LISTEN 连接不判为就绪' readiness_rejects_nonlisten

fixture_step 'O1 共享受控网络与可信 HTTPS 拒绝端点' o1_prepare
[[ $FIXTURE_FAILURES == 0 ]] || exit 1

# 正常启动路径：正式入口在空命名卷上生成配置、初始目录权限正确、进入前台就绪且 daemon 真实监听。
check '空命名卷正式启动：配置生成、初始目录权限正确且 daemon 真实监听' empty_volume_formal_startup

# 阶段 D（run 场景，仅需 Docker）：同一命名卷写入 TZ=Asia/Shanghai，run `-e TZ=UTC` 必须使最终有效值为
# UTC、两类调度按 UTC 计算且卷内配置不变；不传 TZ 时读取卷内值；全新卷回退默认 Asia/Shanghai。
# 夹具失败独立计数并 gate 依赖断言，不把连接或启动错误当作时区断言结果。
TZ_RUN_BASE=$FIXTURE_FAILURES
fixture_step 'TZ[run] 夹具：卷内写入 TZ=Asia/Shanghai 与固定 cron' tz_prepare_volume "$TZ_VOLUME"
fixture_step 'TZ[run] 夹具：记录卷内配置摘要' tz_record_volume_hash "$TZ_VOLUME" "$TEST_ROOT/tz-run-hash"
fixture_step 'TZ[run] 夹具：以 -e TZ=UTC 启动正式入口并进入就绪' tz_start_container UTC
TZ_RUN_READY=0
if [[ $FIXTURE_FAILURES == $TZ_RUN_BASE ]]; then TZ_RUN_READY=1; fi
check_tz_run 'TZ[run] -e TZ=UTC 覆盖卷内 Asia/Shanghai（配置入口有效值）' tz_assert_effective UTC "$TZ_CONTAINER"
check_tz_run 'TZ[run] 调度器按最终有效时区 UTC 计算同步与 hosts 触发' \
    tz_assert_scheduler UTC "$TZ_SYNC_UTC" "$TZ_HOSTS_UTC" "$TZ_CONTAINER"
check_tz_run 'TZ[run] 卷内配置逐字节不变' tz_assert_volume_unchanged "$TZ_VOLUME" "$TEST_ROOT/tz-run-hash"

TZ_VOL_BASE=$FIXTURE_FAILURES
fixture_step 'TZ[volume] 夹具：不注入 TZ 启动正式入口并进入就绪' tz_start_container ''
TZ_VOL_READY=0
if [[ $FIXTURE_FAILURES == $TZ_VOL_BASE ]]; then TZ_VOL_READY=1; fi
check_tz_vol 'TZ[volume] 未传 TZ 时读取卷内 Asia/Shanghai（配置入口有效值）' tz_assert_effective Asia/Shanghai "$TZ_CONTAINER"
check_tz_vol 'TZ[volume] 调度器按卷内 Asia/Shanghai 计算同步与 hosts 触发' \
    tz_assert_scheduler Asia/Shanghai "$TZ_SYNC_SHANGHAI" "$TZ_HOSTS_SHANGHAI" "$TZ_CONTAINER"
check_tz_vol 'TZ[volume] 卷内配置逐字节不变' tz_assert_volume_unchanged "$TZ_VOLUME" "$TEST_ROOT/tz-run-hash"

TZ_DEF_BASE=$FIXTURE_FAILURES
fixture_step 'TZ[default] 夹具：全新命名卷且不注入 TZ 启动并进入就绪' tz_prepare_fresh_volume_then_start
TZ_DEF_READY=0
if [[ $FIXTURE_FAILURES == $TZ_DEF_BASE ]]; then TZ_DEF_READY=1; fi
check_tz_def 'TZ[default] 全新卷未传 TZ 时默认 Asia/Shanghai（配置入口有效值）' tz_assert_effective Asia/Shanghai "$TZ_CONTAINER"
check_tz_def 'TZ[default] 首次地址刷新被禁用，未向真实公网发起请求' tz_assert_no_outbound_refresh "$TZ_CONTAINER"
docker rm -f "$TZ_CONTAINER" >/dev/null 2>&1 || true
docker volume rm -f "$TZ_VOLUME" >/dev/null 2>&1 || true

if integration_group_selected compose-publish && [[ $COMPOSE_ENABLED == 1 ]]; then
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

    # 场景 S0c：Compose 环境 TZ 覆盖卷内 TZ（run 路径的编排等价物）。卷内写入 TZ=Asia/Shanghai，
    # 环境 TZ=UTC 时容器最终有效值必须为 UTC 且两类调度按 UTC 计算；不注入 TZ 时读取卷内 Asia/Shanghai。
    # 卷内配置逐字节不变；夹具失败独立计数并 gate 依赖断言。
    TZ_COMPOSE_BASE=$FIXTURE_FAILURES
    fixture_step 'TZ[compose] 夹具：卷内写入 TZ=Asia/Shanghai 与固定 cron' tz_prepare_volume "$COMPOSE_VOLUME"
    fixture_step 'TZ[compose] 夹具：记录卷内配置摘要' tz_record_volume_hash "$COMPOSE_VOLUME" "$TEST_ROOT/tz-compose-hash"
    COMPOSE_ENV=("REPOS=$TEST_REPO" "TZ=UTC")
    fixture_step 'TZ[compose] 夹具：环境 TZ=UTC 编排启动' compose_up
    fixture_step 'TZ[compose] 夹具：环境 TZ=UTC 场景就绪' compose_wait_running
    TZ_COMPOSE_READY=0
    if [[ $FIXTURE_FAILURES == $TZ_COMPOSE_BASE ]]; then TZ_COMPOSE_READY=1; fi
    check_tz_compose 'TZ[compose] 环境 TZ=UTC 覆盖卷内 Asia/Shanghai（配置入口有效值）' \
        tz_assert_effective UTC "$(compose_container_id)"
    check_tz_compose 'TZ[compose] 调度器按环境最终有效时区 UTC 计算同步与 hosts 触发' \
        tz_assert_scheduler UTC "$TZ_SYNC_UTC" "$TZ_HOSTS_UTC" "$(compose_container_id)"
    check_tz_compose 'TZ[compose] 卷内配置逐字节不变' \
        tz_assert_volume_unchanged "$COMPOSE_VOLUME" "$TEST_ROOT/tz-compose-hash"
    compose_remove_container

    TZ_COMPOSE2_BASE=$FIXTURE_FAILURES
    COMPOSE_ENV=("REPOS=$TEST_REPO")
    fixture_step 'TZ[compose] 夹具：不注入 TZ 编排启动' compose_up
    fixture_step 'TZ[compose] 夹具：不注入 TZ 场景就绪' compose_wait_running
    TZ_COMPOSE2_READY=0
    if [[ $FIXTURE_FAILURES == $TZ_COMPOSE2_BASE ]]; then TZ_COMPOSE2_READY=1; fi
    check_tz_compose2 'TZ[compose] 未注入 TZ 时读取卷内 Asia/Shanghai（配置入口有效值）' \
        tz_assert_effective Asia/Shanghai "$(compose_container_id)"
    check_tz_compose2 'TZ[compose] 调度器按卷内 Asia/Shanghai 计算同步与 hosts 触发' \
        tz_assert_scheduler Asia/Shanghai "$TZ_SYNC_SHANGHAI" "$TZ_HOSTS_SHANGHAI" "$(compose_container_id)"
    check_tz_compose2 'TZ[compose] 无 TZ 时卷内配置逐字节不变' \
        tz_assert_volume_unchanged "$COMPOSE_VOLUME" "$TEST_ROOT/tz-compose-hash"
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
    check '同步失败保留已有缓存（容器内真实同步）' compose_sync_failure_retains_cache 1
    compose_remove_container
    check 'Compose 停止并删除容器后重建（保留命名卷）' compose_start
    check '数据保留：重建后容器就绪' compose_wait_running
    check '重建代拒绝上游且保留同一缓存与宿主发布' compose_sync_failure_retains_cache 2
    check '数据保留：卷内标记文件仍在' compose_retention_marker_present
    check '数据保留：卷内预置仓库与导出标记仍在' compose_retention_repo_present
    check '数据保留：daemon 重建后仍对外提供该仓库' compose_publish_exported_readable
    check '卷内配置：重建后 mirror.env 字节不变' compose_mirror_env_unchanged
    compose_remove_container

    if integration_group_selected compose-runtime; then
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

    fi
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
    check '强杀重建代拒绝上游且保留同一缓存与宿主发布' compose_sync_failure_retains_cache 3
    check '强杀重建后 daemon 真实监听 9418' compose_publish_daemon_listens_9418
    check '强杀重建后发布端口真实可达（非仅 State.Running）' compose_publish_exported_readable
    compose_remove_container

    compose_teardown
else
    printf '注意：docker compose 不可用，Compose 编排实机检查未执行\n'
fi

# 隔离夹具组（S7/S8/S10/S9）：设置 IT_FILTER=c2 时跳过，便于只跑 C-2 有界停止场景。
if integration_group_selected https; then
fixture_step 'TLS 夹具：释放前序 github.com 拒绝端点' fixture_release_shared_endpoints "$O1_UP"
# 场景 S7：隔离 HTTPS 夹具（自定义网络 + github.com DNS 别名 + 测试 CA）下的真实成功同步。
# 夹具不在生产镜像内；夹具准备/就绪失败记为独立的夹具失败并阻止依赖断言，
# 依赖断言只在夹具就绪后以真实 Git 客户端与真实网络请求的观察结果判定。
TLS_FIXTURE_BASE=$FIXTURE_FAILURES
fixture_step 'TLS 夹具：创建隔离网络与命名卷' fixture_create_network_and_volumes
fixture_step 'TLS 夹具：生成 Git dumb HTTP 上游与测试 CA' \
    bash "$FIXTURE_SCRIPT" prepare "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_REPO"
fixture_step 'TLS 夹具：仅导出公开证书至客户端信任卷' fixture_prepare_client_ca
fixture_step 'TLS 夹具：启动 github.com:443 TLS 上游' \
    bash "$FIXTURE_SCRIPT" start "$FIXTURE_FIX_VOL" "$IMAGE" "$FIXTURE_NET" "$FIXTURE_NAME"
fixture_step 'TLS 夹具：上游 HTTPS 就绪探测' fixture_wait_upstream
fixture_step 'TLS 夹具：把测试 CA 复制进产品卷' fixture_copy_ca
# TLS 夹具就绪只看本组夹具步骤是否全部成功：与进入本组前的夹具失败数基线比较，
# 避免与就绪判据探针等无关夹具的失败耦合而误gate本组断言。
if [[ $FIXTURE_FAILURES == $TLS_FIXTURE_BASE ]]; then FIXTURE_READY=1; fi
check_https_sync 'TLS 夹具：正式入口启动并进入前台就绪' fixture_start_product
check_https_sync 'TLS 夹具：容器内自证 UID 10001 且只读根拒绝写入' fixture_identity_and_readonly_root
check_https_sync 'TLS 夹具：首次同步引用、HEAD 与 export-ok 正确' fixture_first_sync_succeeded
check_https_sync 'TLS 夹具：/repo 与 /repo.git 双形式指向预期提交' fixture_publish_both_forms
check_https_sync 'TLS 夹具：未带 export-ok 的仓库不可读' fixture_unexported_rejected
check_https_sync 'TLS 夹具：即使 receivepack=true 也拒绝 push' fixture_push_rejected
check_https_sync 'TLS 夹具：重复同步幂等（引用不变且日志递增）' fixture_repeat_sync_idempotent
check_https_sync 'TLS 夹具：远端更新后引用与 HEAD 变化' fixture_remote_update_reflected
check_https_sync 'TLS 夹具：上游不可达时保留旧引用' fixture_failure_retains_refs
check_https_sync 'TLS 夹具：指定分支同步仅保留所选分支' fixture_branch_scoped_sync

# 场景 S8：HTTPS CONNECT 代理路径与传输顺序（proxy → mapping → system）。
# 代理夹具不在生产镜像内；代理启动/就绪失败记独立夹具失败并阻止依赖断言，
# 断言只用真实网络请求的观察结果与代理侧 CONNECT 计数，不以 git config 输出代替。
S8_BASE=$FIXTURE_FAILURES
fixture_step 'HTTPS 代理：启动 TLS 终结的 CONNECT 代理' fixture_start_proxy
fixture_step 'HTTPS 代理：经代理取到静态 info/refs（就绪）' fixture_wait_proxy
fixture_step 'HTTPS 代理：预置公开地址快照与代理 CA 信任配置' fixture_prepare_proxy_inputs
fixture_step 'HTTPS 代理：记录代理基线计数' fixture_record_proxy_baseline
if [[ $FIXTURE_FAILURES == $S8_BASE ]]; then PROXY_READY=1; fi
check_proxy_sync 'HTTPS 代理：配置 PROXY_URL 时真实同步成功（代理路径）' fixture_proxy_path_succeeds
check_proxy_sync 'HTTPS 代理：代理侧观测到 github.com:443 的 CONNECT 且计数增加' fixture_proxy_connect_evidence
check_mapping_sync '传输顺序：代理可达但拒绝 CONNECT 后回退到动态地址映射' fixture_proxy_failure_falls_back_to_mapping
check_proxy_sync '传输顺序：代理可达但拒绝 CONNECT 且无映射时回退到直连系统 DNS' fixture_proxy_failure_falls_back_to_system
check_mapping_sync '传输顺序：非 proxy 映射直连尝试不增加代理计数' fixture_direct_attempts_leave_proxy_untouched
check_proxy_sync '传输顺序：非 proxy 系统 DNS 直连尝试不增加代理计数' fixture_system_direct_leaves_proxy_untouched

# 场景 S10：正式镜像内地址快照内容级校验与证书失败（多地址/拒绝/空/超限/主备/原子替换/错误证书/系统文件）。
# 端点与内容文件属测试私有夹具；夹具未就绪记独立夹具失败并阻止依赖断言；断言读真实卷内快照字节。
S10_BASE=$FIXTURE_FAILURES
fixture_step '地址内容：发布来源文件（多地址/备用/空/超限）' fixture_publish_hosts_files
fixture_step '地址内容：启动可信来源 HTTPS 端点' fixture_start_hosts_endpoint
fixture_step '地址内容：启动错误证书 HTTPS 端点' fixture_start_hosts_bad_endpoint
fixture_step '地址内容：端点就绪探测（可信需证书链、错误证书端点 -k 可达）' fixture_wait_hosts_endpoints
fixture_step '地址内容：写入产品卷内并发读者脚本' fixture_write_hosts_reader
# 系统文件基线属夹具步骤：置于就绪门控之前，其失败只记夹具失败并使 HOSTS_READY 保持未置位，
# 而不是让依赖它的断言以「缺少基线」被计为断言失败。
fixture_step '地址内容：记录产品容器 /etc/hosts 与 /etc/resolv.conf 运行前基线' fixture_record_system_files
if [[ $FIXTURE_FAILURES == $S10_BASE && $FIXTURE_READY == 1 ]]; then HOSTS_READY=1; fi
check_hosts_content '地址内容：多地址保留且非法/私网/元数据/通配符被拒不入快照' fixture_hosts_multi_address
# 摘要基线记录属夹具步骤：纳入夹具计数，避免在 set -e 下以整体中止代替可读的失败归因。
fixture_step '地址内容：记录快照摘要基线（空响应/超上限用例）' fixture_record_snapshot_sha
check_hosts_content '地址内容：空响应刷新失败且旧快照逐字节保留并标记陈旧' fixture_hosts_empty_fails_retains
check_hosts_content '地址内容：超上限响应刷新失败且旧快照逐字节保留' fixture_hosts_oversize_fails_retains
check_hosts_content '地址内容：超限内容对照（撤除体积上限后产品仍可过滤渲染，故失败归因于体积上限）' fixture_hosts_oversize_content_valid_without_cap
check_hosts_content '地址内容：主源失败改用备用源成功并清除陈旧标记' fixture_hosts_fallback_success
check_hosts_content '地址内容：原子替换下并发读者不见半文件且替换后内容/摘要正确' fixture_hosts_atomic_replace_readers
fixture_step '地址内容：记录快照摘要基线（错误证书用例）' fixture_record_snapshot_sha
check_hosts_content '地址内容：错误证书刷新失败且不污染快照' fixture_hosts_wrong_certificate_fails_retains
check_hosts_content '地址内容：项目运行不修改系统 hosts/resolv.conf' fixture_hosts_system_files_unchanged

# 场景 S9：合成 Token 访问受认证夹具与常驻 daemon 进程的凭据隔离。
# 使用独立网络与产品卷（github.com 别名冲突），Token 为合成测试值，仅以容器环境变量提供。
S9_BASE=$FIXTURE_FAILURES
fixture_step '凭据夹具：释放前序产品地址和上游别名并保留认证依赖卷' \
    fixture_release_shared_endpoints "$FIXTURE_PROD" "$FIXTURE_NAME"
fixture_step '凭据夹具：在共享网络启动受认证上游（未带凭据为 401）' fixture_start_auth_upstream
fixture_step '凭据夹具：准备产品卷并信任测试 CA' fixture_prepare_auth_product_volume
if [[ $FIXTURE_FAILURES == $S9_BASE ]]; then AUTH_READY=1; fi
# 入口前台就绪属夹具步骤：因夹具/网络原因起不来只记夹具失败，不冒充产品断言，也不级联牵连后续断言。
S9_PROD_BASE=$FIXTURE_FAILURES
fixture_step '凭据夹具：带合成 Token 的正式入口启动并进入前台就绪' fixture_start_auth_product
if [[ $FIXTURE_FAILURES == $S9_PROD_BASE ]]; then AUTH_PROD_READY=1; fi
check_auth_prod '凭据隔离：合成 Token 访问受认证夹具成功' fixture_auth_sync_with_token_succeeds
check_auth_prod '凭据隔离：常驻 daemon 进程环境不含 Token' fixture_daemon_env_excludes_token
check_auth_sync '凭据夹具：真实 Git 客户端无凭据访问被拒绝（鉴权非空转）' fixture_auth_requires_token
fixture_step '凭据夹具：释放产品地址和上游别名' fixture_release_shared_endpoints "$AUTH_PROD" "$AUTH_UP"
fi

# 场景 S11 前置：强杀重建相关产品改动的定向行为用例（无需 Compose），
# 使「复位陈旧服务状态移除陈旧 pidfile」具备独立于 S6 的红绿覆盖。
if integration_group_selected c2; then
if [[ $IT_FILTER == c2 ]]; then
    fixture_step 'C-2：释放共享 github.com 拒绝端点' fixture_release_shared_endpoints "$O1_UP"
fi
check 'C-2 复位陈旧服务状态移除陈旧 pidfile（PID 复用不误判）' c2_reset_removes_stale_pidfile

# 场景 S11：有界停止（C-2）。首次同步、定时同步、定时 hosts 刷新分别构造可控长进程与多层子孙，
# 发送 TERM 与 INT；在 PID1 存活期间观察子孙回收、锁释放与不再派发，并核对全树非 root UID。
# 不依赖 Compose 与 TLS 夹具，只使用命名卷与 Docker 网络；夹具失败只记夹具失败，不冒充断言结果。
c2_run_scenario firstsync 0 TERM
c2_run_scenario firstsync 0 INT
c2_run_scenario timedsync 1 TERM
c2_run_scenario timedsync 1 INT
c2_run_scenario timedhosts 1 TERM
c2_run_scenario timedhosts 1 INT
fi

printf '容器实机集成检查：%s；断言失败：%s；夹具失败：%s；显式延期：%s\n' "$CHECKS" "$FAILURES" "$FIXTURE_FAILURES" "${DEFERRED:-0}"
[[ $FAILURES == 0 && $FIXTURE_FAILURES == 0 ]]
