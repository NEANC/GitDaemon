#!/usr/bin/env bash
# 以真实 Git HTTP 请求验证直连不使用具体 URL、仓库或环境代理。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-sync.sh"
[[ $UID != 0 && $EUID != 0 ]] || exit 1
work=$(mktemp -d)
server=
# 仅回收本用例创建的 HTTP 进程和临时目录。
cleanup() {
    [[ -z $server ]] || { kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; }
    rm -rf -- "$work"
}
trap cleanup EXIT
export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
port=$((31000 + $$ % 10000))
url=http://127.0.0.1:$port/source.git
mkdir -p "$work/www"
git init -q "$work/source" || exit 1
git -C "$work/source" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture || exit 1
git clone -q --bare "$work/source" "$work/www/source.git" || exit 1
git --git-dir="$work/www/source.git" update-server-info || exit 1
# 镜像内 busybox 未编译 httpd 小程序；改用 nc 持久监听 + 每连接静态文件处理器，
# 在测试容器内提供真实 TCP HTTP 服务，并在运行断言前显式探测就绪。
cat > "$work/handler" <<'HANDLER'
#!/bin/sh
DOCROOT=${DOCROOT:?}
read -r req
req=$(printf '%s' "$req" | tr -d '\r')
rest=${req#* }
path=${rest%% *}
while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [ -z "$line" ] && break
done
path=${path%%\?*}
case "$path" in
    *..*) path=/__forbidden__ ;;
esac
file=$DOCROOT$path
if [ -f "$file" ]; then
    size=$(wc -c < "$file" | tr -d ' ')
    printf 'HTTP/1.0 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$size"
    cat -- "$file"
else
    printf 'HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
fi
HANDLER
chmod 755 "$work/handler" || exit 1
export DOCROOT=$work/www
busybox nc -lk -s 127.0.0.1 -p "$port" -e "$work/handler" >"$work/server.log" 2>&1 &
server=$!
# 就绪探测：夹具未就绪必须明确报告失败，不得把连接拒绝当成代理断言结果。
ready=no
tries=0
while [[ $tries -lt 50 ]]; do
    if code=$(curl -s --noproxy '*' --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/source.git/info/refs" 2>/dev/null) && [[ $code == 200 ]]; then
        ready=yes
        break
    fi
    kill -0 "$server" 2>/dev/null || break
    tries=$((tries + 1))
    sleep 0.1
done
if [[ $ready != yes ]]; then
    printf 'FIXTURE FAILED：本地 HTTP 夹具未就绪（port=%s）\n' "$port" >&2
    cat -- "$work/server.log" >&2 || true
    printf 'checks=2 failed=2 fixture=1 uid=%s\n' "$UID"
    exit 2
fi
git config --global "http.$url.proxy" http://127.0.0.1:1 || exit 1
export http_proxy=http://127.0.0.1:3 HTTP_PROXY=http://127.0.0.1:3 all_proxy=http://127.0.0.1:3
unset no_proxy NO_PROXY
LOG_FILE=$work/sync.log
GM_CONFIG[PROXY_URL]=http://127.0.0.1:4
GM_CREDENTIAL_ARGS=() GM_RESOLVE_ARGS=()
failed=0
# 运行真实生产更新路径，同时确认实际 socket 到达本地源而非失效代理。
check_fetch() {
    local attempt=$1 dir=$work/$1.git expected actual
    git init -q --bare "$dir" || return 1
    git --git-dir="$dir" remote add origin "$url" || return 1
    git --git-dir="$dir" config remote.origin.proxy http://127.0.0.1:2 || return 1
    GM_TRANSPORT_SEQUENCE=("$attempt")
    clear_proxy_environment
    update_repo fixture/source "$dir" '' || return 1
    expected=$(git --git-dir="$work/www/source.git" rev-parse HEAD) || return 1
    actual=$(git --git-dir="$dir" rev-parse HEAD) || return 1
    [[ $actual == "$expected" && -f $dir/git-daemon-export-ok ]]
}
for attempt in mapping system; do
    if check_fetch "$attempt"; then printf 'PASS network_%s\n' "$attempt";
    else printf 'FAIL network_%s\n' "$attempt"; failed=$((failed+1)); fi
done
printf 'checks=2 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
