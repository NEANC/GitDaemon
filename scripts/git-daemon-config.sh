#!/usr/bin/env bash

# 只从可信安装层加载共享配置与运行预检，不执行卷内数据。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 向 OpenRC 启动前钩子返回三个已校验的数据行，不导出其他消费者配置或凭据。
gm_daemon_config_main() {
    local install
    [[ $# == 0 ]] || { gm_error 'daemon 配置入口不接受此参数'; return 2; }
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    printf '%s\n' "${GM_CONFIG[GIT_PORT]}" "${GM_CONFIG[LISTEN_ADDRESS]}" "${GM_CONFIG[TZ]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_daemon_config_main "$@"
fi
