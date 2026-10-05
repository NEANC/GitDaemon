#!/usr/bin/env bash

# 隔离 HTTPS 测试夹具（测试私有，不进入生产镜像）：在自定义 Docker 网络上以 github.com 网络别名，
# 用 openssl s_server -WWW 提供 Git dumb HTTP over TLS 的静态上游，并以测试 CA（SAN=github.com）
# 供测试进程通过 GIT_SSL_CAINFO 信任，使产品保持 URL https://github.com/<owner>/<repo>.git 与 TLS 校验。
# 夹具还提供测试私有的 HTTPS CONNECT 代理（TLS 终结 + CONNECT 计数 + 向夹具中继）与需要 HTTP Basic
# 凭据的认证上游，用于验证代理传输路径、传输顺序与凭据隔离。
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
FIXTURE_PROXY_CERT=$FIXTURE_TLS/proxy.crt
FIXTURE_PROXY_KEY=$FIXTURE_TLS/proxy.key
FIXTURE_PROXY_SCRIPT=$FIXTURE_ROOT/proxy.sh
FIXTURE_AUTH_SCRIPT=$FIXTURE_ROOT/auth.sh
FIXTURE_CONNECT_COUNT=$FIXTURE_ROOT/connect.count
FIXTURE_PORT=443
FIXTURE_PROXY_PORT=8443
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
  docker-https-fixture.sh prepare     <volume> <image> <owner/name>
  docker-https-fixture.sh start       <volume> <image> <network> <name>
  docker-https-fixture.sh update      <volume> <image> <owner/name> <branch> <message>
  docker-https-fixture.sh rev-parse   <volume> <image> <owner/name> <ref>
  docker-https-fixture.sh ca          <volume> <image>
  docker-https-fixture.sh proxy-start <volume> <image> <network> <name> [proxy-host]
  docker-https-fixture.sh auth-start  <volume> <image> <network> <name> <expected-authorization>
  docker-https-fixture.sh upstream-ip <name>
  docker-https-fixture.sh connects    <volume> <image>
  docker-https-fixture.sh connect-log <volume> <image>
  docker-https-fixture.sh stop        <name>
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

# 把一段脚本内容经标准输入写入夹具卷内固定路径并置为可执行，供代理/认证上游容器直接运行。
fixture_write_script() {
    local volume=$1 image=$2 path=$3 body=$4 status=0
    printf '%s\n' "$body" | docker run --rm -i --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" \
        --entrypoint /bin/sh "$image" -c "umask 022; cat > '$path' && chmod 755 '$path'" || status=$?
    [[ $status == 0 ]] || { fail "写入夹具脚本失败：$path"; return "$FIXTURE_FAILURE"; }
    return 0
}

# 等待具名夹具容器保持运行；短超时后返回夹具失败并打印日志尾部。
fixture_wait_running() {
    local name=$1 i
    for i in $(seq 1 20); do
        if [[ $(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]]; then return 0; fi
        sleep 0.5
    done
    fail "夹具容器启动后未保持运行：$name"
    docker logs "$name" 2>&1 | tail -n 5 >&2 2>/dev/null || true
    return "$FIXTURE_FAILURE"
}

# 在命名卷内创建 Git dumb HTTP 上游资产（src 工作仓库 main/dev/v1、bare 发布仓库与 update-server-info）、
# 测试 CA、SAN=github.com 的服务器证书（只放该测试卷，不写入镜像根或宿主信任库），以及代理证书
# （SAN=gm-proxy，同一测试 CA 签发）与代理/认证上游脚本。
cmd_prepare() {
    local volume=$1 image=$2 repo=$3 owner name script proxy_body auth_body
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
openssl req -newkey rsa:2048 -nodes -subj /CN=gm-proxy -keyout proxy.key -out proxy.csr >/dev/null 2>&1
printf 'subjectAltName=DNS:gm-proxy\n' > proxy.san
openssl x509 -req -in proxy.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile proxy.san -out proxy.crt >/dev/null 2>&1
EOF
)
    volume_run "$volume" "$image" "$script" || return "$FIXTURE_FAILURE"

    proxy_body=$(cat <<'PROXY'
#!/bin/bash
# 测试私有 HTTPS CONNECT 代理：openssl s_server 做 TLS 终结，bash 读取 CONNECT 请求、计数并回写 200，
# 再在客户端与夹具上游之间双向中继。仅用于隔离测试，不进入生产镜像。
# 参数：<监听端口> <证书> <私钥> <计数文件> <允许的上游主机>
set -u
PORT=${1:?}; CERT=${2:?}; KEY=${3:?}; COUNT=${4:?}; UPSTREAM=${5:?}
IN=$(mktemp -u /tmp/gmpx.in.XXXXXX)
OUT=$(mktemp -u /tmp/gmpx.out.XXXXXX)
mkfifo "$IN" "$OUT"
openssl s_server -quiet -accept "$PORT" -cert "$CERT" -key "$KEY" <"$IN" >"$OUT" 2>/dev/null &
exec 3>"$IN"
exec 0<"$OUT"
while IFS= read -r line; do
    line=${line%$'\r'}
    while IFS= read -r hdr; do
        hdr=${hdr%$'\r'}
        [ -z "$hdr" ] && break
    done
    case "$line" in
        CONNECT\ *) ;;
        *) printf 'HTTP/1.1 405 Method Not Allowed\r\n\r\n' >&3; continue ;;
    esac
    target=${line#CONNECT }
    target=${target%% *}
    host=${target%%:*}
    port=${target##*:}
    n=$(cat "$COUNT" 2>/dev/null)
    n=${n:-0}
    n=$((n + 1))
    printf '%s\n' "$n" >"$COUNT"
    printf 'CONNECT %s\n' "$target" >>"${COUNT}.log"
    if [ "$host" != "$UPSTREAM" ] || [ "$port" != 443 ]; then
        printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n' >&3
        continue
    fi
    printf 'HTTP/1.1 200 Connection Established\r\n\r\n' >&3
    exec 4<>"/dev/tcp/$host/$port"
    cat <&0 >&4 &
    pid=$!
    timeout 60 cat <&4 >&3
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exec 4<&-
    exec 4>&-
done
PROXY
)
    fixture_write_script "$volume" "$image" "$FIXTURE_PROXY_SCRIPT" "$proxy_body" || return "$FIXTURE_FAILURE"

    auth_body=$(cat <<'AUTH'
#!/bin/bash
# 测试私有认证上游：TLS 终结 + 要求 HTTP Basic 凭据的静态 dumb HTTP 服务（仅测试使用）。
# 参数：<端口> <证书> <私钥> <文档根> <期望的 Authorization 头值>
set -u
PORT=${1:?}; CERT=${2:?}; KEY=${3:?}; DOCROOT=${4:?}; EXPECT=${5:?}
IN=$(mktemp -u /tmp/gmauth.in.XXXXXX)
OUT=$(mktemp -u /tmp/gmauth.out.XXXXXX)
mkfifo "$IN" "$OUT"
openssl s_server -quiet -accept "$PORT" -cert "$CERT" -key "$KEY" <"$IN" >"$OUT" 2>/dev/null &
exec 3>"$IN"
exec 0<"$OUT"
while IFS= read -r reqline; do
    reqline=${reqline%$'\r'}
    rest=${reqline#* }
    path=${rest%% *}
    auth=
    while IFS= read -r hdr; do
        hdr=${hdr%$'\r'}
        [ -z "$hdr" ] && break
        case "$hdr" in
            Authorization:*) auth=${hdr#*:}; auth=${auth# } ;;
        esac
    done
    path=${path%%\?*}
    if [ "$auth" != "$EXPECT" ]; then
        printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="gm-auth"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' >&3
        continue
    fi
    case "$path" in
        *..*) printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' >&3; continue ;;
    esac
    file=${DOCROOT}${path}
    if [ -f "$file" ]; then
        size=$(wc -c <"$file" | tr -d ' ')
        printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$size" >&3
        cat -- "$file" >&3
    else
        printf 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' >&3
    fi
done
AUTH
)
    fixture_write_script "$volume" "$image" "$FIXTURE_AUTH_SCRIPT" "$auth_body" || return "$FIXTURE_FAILURE"
    return 0
}

# 在自定义网络上以 github.com 别名启动 TLS 上游（非 root，静态 dumb HTTP）。
cmd_start() {
    local volume=$1 image=$2 network=$3 name=$4
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$network" --network-alias github.com \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$FIXTURE_PORT" \
        --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint /bin/sh "$image" \
        -c "cd $FIXTURE_WEB && exec openssl s_server -accept $FIXTURE_PORT -cert $FIXTURE_CERT -key $FIXTURE_KEY -WWW -quiet" \
        >/dev/null 2>&1 || { fail '无法启动 TLS 上游容器'; return "$FIXTURE_FAILURE"; }
    fixture_wait_running "$name" || return "$FIXTURE_FAILURE"
    return 0
}

# 启动需要 HTTP Basic 凭据的认证上游（github.com 别名，443），同一测试 CA 与仓库资产。
cmd_auth_start() {
    local volume=$1 image=$2 network=$3 name=$4 expect=$5
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$network" --network-alias github.com \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$FIXTURE_PORT" \
        --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint /bin/bash "$image" \
        "$FIXTURE_AUTH_SCRIPT" "$FIXTURE_PORT" "$FIXTURE_CERT" "$FIXTURE_KEY" "$FIXTURE_WEB" "$expect" \
        >/dev/null 2>&1 || { fail '无法启动认证上游容器'; return "$FIXTURE_FAILURE"; }
    fixture_wait_running "$name" || return "$FIXTURE_FAILURE"
    return 0
}

# 启动 HTTPS CONNECT 代理（非 root）；默认网络别名 gm-proxy，端口 8443。
cmd_proxy_start() {
    local volume=$1 image=$2 network=$3 name=$4 host=${5:-gm-proxy}
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$network" --network-alias "$host" \
        --user 10001:10001 -v "$volume:$FIXTURE_MOUNT" --entrypoint /bin/bash "$image" \
        "$FIXTURE_PROXY_SCRIPT" "$FIXTURE_PROXY_PORT" "$FIXTURE_PROXY_CERT" "$FIXTURE_PROXY_KEY" \
        "$FIXTURE_CONNECT_COUNT" github.com >/dev/null 2>&1 || { fail '无法启动 HTTPS CONNECT 代理容器'; return "$FIXTURE_FAILURE"; }
    fixture_wait_running "$name" || return "$FIXTURE_FAILURE"
    return 0
}

# 输出具名夹具容器在自定义网络上的 IPv4 地址，供合法公开地址快照使用。
cmd_upstream_ip() {
    local name=$1 ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null) || ip=
    [[ -n $ip ]] || { fail "无法读取夹具容器 IP：$name"; return "$FIXTURE_FAILURE"; }
    printf '%s\n' "$ip"
    return 0
}

# 输出代理侧观测到的 CONNECT 次数；计数文件缺失时输出 0（表示未观测到任何 CONNECT）。
cmd_connects() {
    local volume=$1 image=$2 status=0 count
    count=$(docker run --rm -v "$volume:$FIXTURE_MOUNT" --entrypoint cat "$image" "$FIXTURE_CONNECT_COUNT" 2>/dev/null) || status=$?
    if [[ $status != 0 ]]; then printf '0\n'; return 0; fi
    printf '%s\n' "$count"
    return 0
}

# 输出代理侧 CONNECT 明细日志（形如 "CONNECT github.com:443"），计数文件不存在时视为空。
cmd_connect_log() {
    local volume=$1 image=$2 status=0
    docker run --rm -v "$volume:$FIXTURE_MOUNT" --entrypoint cat "$image" "${FIXTURE_CONNECT_COUNT}.log" || status=$?
    [[ $status == 0 || $status == 1 ]] || return "$FIXTURE_FAILURE"
    return 0
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
        proxy-start) [[ $# == 4 || $# == 5 ]] || usage; cmd_proxy_start "$@" ;;
        auth-start) [[ $# == 5 ]] || usage; cmd_auth_start "$@" ;;
        upstream-ip) [[ $# == 1 ]] || usage; cmd_upstream_ip "$@" ;;
        connects) [[ $# == 2 ]] || usage; cmd_connects "$@" ;;
        connect-log) [[ $# == 2 ]] || usage; cmd_connect_log "$@" ;;
        stop) [[ $# == 1 ]] || usage; cmd_stop "$@" ;;
        *) usage ;;
    esac
}

main "$@"
