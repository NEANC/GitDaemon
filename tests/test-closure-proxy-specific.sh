#!/usr/bin/env bash
# 验证直连的具体 URL 与仓库级代理隔离，不依赖实际外网。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-sync.sh"
[[ $UID != 0 && $EUID != 0 ]] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
failed=0
# 检查真实 Git 的 URL 匹配优先级和 remote 配置。
check_direct() {
    local attempt=$1 url=https://github.com/fixture/repo actual
    git init --bare -q "$work/$attempt" || return 1
    git --git-dir="$work/$attempt" remote add origin "$url" || return 1
    git config --global "http.$url.proxy" http://127.0.0.1:1 || return 1
    git --git-dir="$work/$attempt" config remote.origin.proxy http://127.0.0.1:2 || return 1
    GM_RESOLVE_ARGS=() GM_CREDENTIAL_ARGS=()
    transport_args "$attempt" "$url" || return 1
    actual=$(git "${GM_TRANSPORT_ARGS[@]}" --git-dir="$work/$attempt" config --get-urlmatch http.proxy "$url") || return 1
    [[ -z $actual ]] || { printf 'URL_PROXY_NOT_EMPTY\n'; return 1; }
    actual=$(git "${GM_TRANSPORT_ARGS[@]}" --git-dir="$work/$attempt" config --get remote.origin.proxy) || return 1
    [[ -z $actual ]] || { printf 'REMOTE_PROXY_NOT_EMPTY\n'; return 1; }
}
for attempt in mapping system; do
    if check_direct "$attempt"; then printf 'PASS %s\n' "$attempt";
    else printf 'FAIL %s\n' "$attempt"; failed=$((failed+1)); fi
done
printf 'checks=2 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
