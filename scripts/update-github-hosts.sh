#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 显式执行刷新前读取纯数据并完成预检，保留现有下载算法。
gm_hosts_main() (
    local snapshot url temporary install
    if [[ ${1-} == --help || ${1-} == -h ]]; then
        printf '%s\n' '用法：update-github-hosts.sh；运行配置来自 RUN_ROOT/config/mirror.env'
        return 0
    fi
    [[ $# == 0 ]] || { gm_error '刷新入口不接受此参数'; return 2; }
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]] || return 0
    gm_begin_operation hosts || return $?
    snapshot=$RUN_ROOT/hosts/github-hosts.snapshot
    url=${GM_CONFIG[HOSTS_URL]}
    mkdir -p "$(dirname "$snapshot")" || return 1
    temporary=${snapshot}.tmp
    curl --fail --silent --show-error --location "$url" -o "$temporary" || return 1
    mv -f "$temporary" "$snapshot" || return 1
    printf '%s\n' "$snapshot"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_hosts_main "$@"
fi
