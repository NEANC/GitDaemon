#!/usr/bin/env bash
# 验证直连配置代理隔离及报告失败不改变同步成功状态。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-sync.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
LOG_FILE=$work/log
failed=0
# 断言实际 Git 生效配置，而非只检查参数拼接。
proxy_isolation() {
    export GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_NOSYSTEM=1
    git config --global http.proxy http://127.0.0.1:1 || return 1
    GM_CREDENTIAL_ARGS=() GM_RESOLVE_ARGS=()
    local path actual
    for path in mapping system; do
        transport_args "$path" || return 1
        actual=$(git "${GM_TRANSPORT_ARGS[@]}" config --get http.proxy) || return 1
        [[ -z $actual ]] || return 1
    done
}
# 仅注入报告枚举失败，真实同步结果由已成功更新的仓库承载。
report_best_effort() {
    MIRROR_ROOT=$work/repos
    mkdir -p "$MIRROR_ROOT/fixture/repo.git"
    update_repo() { : > "$2/git-daemon-export-ok"; }
    git() { return 128; }
    sync_repo fixture/repo '' || return 1
    [[ -f $MIRROR_ROOT/fixture/repo.git/git-daemon-export-ok ]]
}
# 每个行为独立执行，避免配置和函数替身污染另一用例。
check() { local name=$1; if ( "$name" ); then printf 'PASS %s\n' "$name"; else printf 'FAIL %s\n' "$name"; failed=$((failed+1)); fi; }
check proxy_isolation
check report_best_effort
printf 'checks=2 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
