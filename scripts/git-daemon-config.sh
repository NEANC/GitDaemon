#!/usr/bin/env bash

# 只从可信安装层加载共享配置与运行预检，不执行卷内数据。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 向 OpenRC 启动前钩子返回三个已校验的数据行，不导出其他消费者配置或凭据。
gm_daemon_config_main() {
    local install
    local GITHUB_TOKEN=${GITHUB_TOKEN-}
    export -n GITHUB_TOKEN
    # 钩子只传非敏感状态；局部非导出标记复用原有互斥和控制字符校验。
    case "$#:${1-}" in
        0:) ;;
        1:--token-state=empty) GITHUB_TOKEN= ;;
        1:--token-state=present) GITHUB_TOKEN=present ;;
        1:--token-state=invalid) GITHUB_TOKEN=$'\n' ;;
        *) gm_error 'daemon 配置入口不接受此参数'; return 2 ;;
    esac
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    printf '%s\n' "${GM_CONFIG[GIT_PORT]}" "${GM_CONFIG[LISTEN_ADDRESS]}" "${GM_CONFIG[TZ]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_daemon_config_main "$@"
fi
