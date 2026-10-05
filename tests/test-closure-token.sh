#!/usr/bin/env bash
# 验证同步私密凭据通路保存显式环境，隔离 OpenRC 过滤并保持卷配置字节不变。
set -uo pipefail
source "$(dirname "$0")/../scripts/lib/foundation.sh"
# 同步入口在加载时即声明空配置数组（git-mirror-sync.sh），再由 gm_load_config 填充；
# 直接调用凭据 helper 的夹具须复现该前置状态，否则 nounset 下数组下标按算术求值。
declare -A GM_CONFIG=()
[[ $UID != 0 && $EUID != 0 ]] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
RUN_ROOT=$work/instance
mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/config" "$RUN_ROOT/secrets"
chmod 700 "$RUN_ROOT" "$RUN_ROOT/runtime" "$RUN_ROOT/secrets"
printf 'TZ=UTC\n' > "$RUN_ROOT/config/mirror.env"
failed=0
# 仿真 OpenRC 只保留固定非凭据白名单后的同步读取，私密状态须恢复显式 Token。
token_channel() {
    export GITHUB_TOKEN=closure-fixture-token
    unset GITHUB_TOKEN_FILE
    gm_save_sync_credentials "$RUN_ROOT" || return 1
    [[ $(stat -c %a "$RUN_ROOT/runtime/sync-credentials") == 600 ]] || return 1
    unset GITHUB_TOKEN
    gm_load_sync_credentials "$RUN_ROOT" || return 1
    [[ $GITHUB_TOKEN == closure-fixture-token && ! -v GITHUB_TOKEN_FILE ]] || return 1
    [[ $(<"$RUN_ROOT/config/mirror.env") == TZ=UTC ]]
}
# 显式环境文件路径经私密通路仍高于卷内文件路径；不复制文件中的凭据值。
file_channel() {
    unset GITHUB_TOKEN
    printf file-token > "$RUN_ROOT/secrets/environment"
    printf volume-token > "$RUN_ROOT/secrets/volume"
    printf 'TZ=UTC\nGITHUB_TOKEN_FILE=%s\n' "$RUN_ROOT/secrets/volume" > "$RUN_ROOT/config/mirror.env"
    export GITHUB_TOKEN_FILE=$RUN_ROOT/secrets/environment
    gm_save_sync_credentials "$RUN_ROOT" || return 1
    unset GITHUB_TOKEN_FILE
    gm_load_sync_credentials "$RUN_ROOT" || return 1
    gm_load_config "$RUN_ROOT/config/mirror.env" || return 1
    [[ ${GM_CONFIG[GITHUB_TOKEN_FILE]} == "$RUN_ROOT/secrets/environment" ]] || return 1
    [[ $(<"$RUN_ROOT/runtime/sync-credentials") != *file-token* ]]
}
# 新实例启动不传环境凭据时，重建私密状态后卷内来源不再被历史显式凭据遮蔽。
volume_precedes_history() {
    unset GITHUB_TOKEN GITHUB_TOKEN_FILE
    printf volume-token > "$RUN_ROOT/secrets/volume"
    printf 'TZ=UTC\nGITHUB_TOKEN_FILE=%s\n' "$RUN_ROOT/secrets/volume" > "$RUN_ROOT/config/mirror.env"
    export GITHUB_TOKEN=history-token
    gm_save_sync_credentials "$RUN_ROOT" || return 1
    unset GITHUB_TOKEN
    gm_save_sync_credentials "$RUN_ROOT" || return 1
    gm_load_sync_credentials "$RUN_ROOT" || return 1
    gm_load_config "$RUN_ROOT/config/mirror.env" || return 1
    [[ ! -v GITHUB_TOKEN && ${GM_CONFIG[GITHUB_TOKEN_FILE]} == "$RUN_ROOT/secrets/volume" ]]
}
# 新实例启动不传环境凭据时清除旧临时状态，回退到卷内配置而非残留环境。
clear_channel() {
    unset GITHUB_TOKEN GITHUB_TOKEN_FILE
    gm_save_sync_credentials "$RUN_ROOT" || return 1
    gm_load_sync_credentials "$RUN_ROOT" || return 1
    [[ ! -v GITHUB_TOKEN && ! -v GITHUB_TOKEN_FILE ]]
}
# 独立统计各个凭据渠道行为。
check() {
    if ( "$1" ); then printf 'PASS %s\n' "$1";
    else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi
}
check token_channel
check file_channel
check volume_precedes_history
check clear_channel
printf 'checks=4 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
