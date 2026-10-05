#!/usr/bin/env bash

# 隔离 HTTPS 测试夹具（测试私有，不进入生产镜像）：在自定义 Docker 网络上以 github.com 网络别名，
# 用 openssl s_server -WWW 提供 Git dumb HTTP over TLS 的静态上游，并以测试 CA（SAN=github.com）
# 供测试进程通过 GIT_SSL_CAINFO 信任，使产品保持 URL https://github.com/<owner>/<repo>.git 与 TLS 校验。
# 所有数据只落在 Docker 命名卷内，不使用 bind、匿名卷、宿主机路径映射或 Docker socket。
#
# 挂载点固定为 /var/lib/git-daemon（镜像内已存在且属主 10001），命名卷首次挂载即继承该属主，
# 因此夹具全部读写都在 UID 10001 下完成；443 通过 net.ipv4.ip_unprivileged_port_start 非特权绑定，
# 不新增 capability，也不以 root 运行夹具进程。
#
# 退出码：0 成功；80 夹具失败；2 用法错误。

set -uo pipefail

FIXTURE_MOUNT=/var/lib/git-daemon
FIXTURE_ROOT=$FIXTURE_MOUNT/fixture
FIXTURE_WEB=$FIXTURE_ROOT/web
FIXTURE_TLS=$FIXTURE_ROOT/tls
FIXTURE_CA=$FIXTURE_TLS/ca.crt
FIXTURE_CERT=$FIXTURE_TLS/srv.crt
FIXTURE_KEY=$FIXTURE_TLS/srv.key
FIXTURE_PORT=443
FIXTURE_FAILURE=80

# 输出夹具诊断到 stderr。
fail() {
    printf 'docker-https-fixture: %s\n' "$*" >&2
    return 0
}

# 输出用法并以用法错误码退出。
usage() {
    cat >&2 <<'EOF'
用法：
  docker-https-fixture.sh prepare   <volume> <image> <owner/name>
  docker-https-fixture.sh start     <volume> <image> <network> <name>
  docker-https-fixture.sh update    <volume> <image> <owner/name> <branch> <message>
  docker-https-fixture.sh rev-parse <volume> <image> <owner/name> <ref>
  docker-https-fixture.sh ca        <volume> <image>
  docker-https-fixture.sh stop      <name>
EOF
    exit 2
}

# 校验仓库为 owner/name 两段安全分量，避免夹具路径拼接被越界输入影响。
validate_repo() {
    local repo=$1
    [[ $repo =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    return 0
}

# 在指定命名卷内以 UID 10001 执行一段 POSIX sh 脚本；失败统一映射为夹具失败退出码。
volume_run() {
    local volume=$1 image=$2 script=$3 status=0
    docker run --rm --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint /bin/sh "$image" -c "$script" || status=$?
    [[ $status == 0 ]] || { fail "卷内夹具命令失败（退出码 $status）"; return "$FIXTURE_FAILURE"; }
    return 0
}

# 在命名卷内创建 Git dumb HTTP 上游资产：src 工作仓库（main/dev/v1）、bare 发布仓库与 update-server-info，
# 以及测试 CA 与 SAN=github.com 的服务器证书（只放该测试卷，不写入镜像根或宿主信任库）。
cmd_prepare() {
    local volume=$1 image=$2 repo=$3 owner name script
    validate_repo "$repo" || { fail "仓库名必须为 owner/name：$repo"; return 2; }
    owner=${repo%%/*}
    name=${repo##*/}
    script=$(cat <<EOF
set -e
umask 022
R=$FIXTURE_ROOT
src=\$R/src/$owner/$name
web=\$R/web/$owner/$name.git
mkdir -p "\$R/src/$owner" "\$R/web/$owner" "\$R/tls"
rm -rf "\$src" "\$web"
git init -q "\$src"
cd "\$src"
git config user.email fixture@example.invalid
git config user.name fixture
printf 'hello\n' > file.txt
git add file.txt
git commit -qm 'init'
git branch -M main
git checkout -q -b dev
printf 'dev\n' > dev.txt
git add dev.txt
git commit -qm 'dev'
git checkout -q main
git tag v1
git clone -q --bare "\$src" "\$web"
git --git-dir="\$web" symbolic-ref HEAD refs/heads/main
git --git-dir="\$web" update-server-info
cd "\$R/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=GM-Fixed-Test-CA -keyout ca.key -out ca.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=github.com -keyout srv.key -out srv.csr >/dev/null 2>&1
printf 'subjectAltName=DNS:github.com\n' > san.ext
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext -out srv.crt >/dev/null 2>&1
EOF
)
    volume_run "$volume" "$image" "$script" || return "$FIXTURE_FAILURE"
    return 0
}

# 在自定义网络上以 github.com 别名启动 TLS 上游（非 root，静态 dumb HTTP）；随后确认进程仍在运行。
cmd_start() {
    local volume=$1 image=$2 network=$3 name=$4 i
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$network" --network-alias github.com \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$FIXTURE_PORT" \
        --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint /bin/sh "$image" \
        -c "cd $FIXTURE_WEB && exec openssl s_server -accept $FIXTURE_PORT -cert $FIXTURE_CERT -key $FIXTURE_KEY -WWW -quiet" \
        >/dev/null 2>&1 || { fail '无法启动 TLS 上游容器'; return "$FIXTURE_FAILURE"; }
    for i in $(seq 1 20); do
        if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then return 0; fi
        sleep 0.5
    done
    fail 'TLS 上游容器启动后未保持运行'
    docker logs "$name" 2>&1 | tail -n 5 >&2 2>/dev/null || true
    return "$FIXTURE_FAILURE"
}

# 在已发布 bare 上游追加一次提交并刷新 dumb HTTP 索引，输出新的提交号供断言比对。
cmd_update() {
    local volume=$1 image=$2 repo=$3 branch=$4 message=$5 owner name script
    validate_repo "$repo" || { fail "仓库名必须为 owner/name：$repo"; return 2; }
    owner=${repo%%/*}
    name=${repo##*/}
    script=$(cat <<EOF
set -e
umask 022
R=$FIXTURE_ROOT
src=\$R/src/$owner/$name
web=\$R/web/$owner/$name.git
cd "\$src"
git checkout -q "$branch"
git config user.email fixture@example.invalid
git config user.name fixture
printf '%s\n' "$message" >> file.txt
git add file.txt
git commit -qm "$message"
git push -q "\$web" "$branch"
git --git-dir="\$web" update-server-info
git --git-dir="\$web" rev-parse "refs/heads/$branch"
EOF
)
    volume_run "$volume" "$image" "$script" || return "$FIXTURE_FAILURE"
    return 0
}

# 读取上游 bare 仓库指定引用的提交号。
cmd_rev_parse() {
    local volume=$1 image=$2 repo=$3 ref=$4 owner name script
    validate_repo "$repo" || { fail "仓库名必须为 owner/name：$repo"; return 2; }
    owner=${repo%%/*}
    name=${repo##*/}
    script="git --git-dir=$FIXTURE_WEB/$owner/$name.git rev-parse '$ref'"
    volume_run "$volume" "$image" "$script" || return "$FIXTURE_FAILURE"
    return 0
}

# 输出测试 CA 证书（PEM），供调用方放入产品卷并由测试进程信任。
cmd_ca() {
    local volume=$1 image=$2 status=0
    docker run --rm --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint cat "$image" "$FIXTURE_CA" || status=$?
    [[ $status == 0 ]] || { fail '无法读取测试 CA'; return "$FIXTURE_FAILURE"; }
    return 0
}

# 停止并删除夹具容器。
cmd_stop() {
    local name=$1
    docker rm -f "$name" >/dev/null 2>&1 || true
    return 0
}

# 分派子命令；未知子命令按用法错误处理。
main() {
    local command=${1-}
    [[ -n $command ]] || usage
    shift
    case "$command" in
        prepare) [[ $# == 3 ]] || usage; cmd_prepare "$@" ;;
        start) [[ $# == 4 ]] || usage; cmd_start "$@" ;;
        update) [[ $# == 5 ]] || usage; cmd_update "$@" ;;
        rev-parse) [[ $# == 4 ]] || usage; cmd_rev_parse "$@" ;;
        ca) [[ $# == 2 ]] || usage; cmd_ca "$@" ;;
        stop) [[ $# == 1 ]] || usage; cmd_stop "$@" ;;
        *) usage ;;
    esac
}

main "$@"
