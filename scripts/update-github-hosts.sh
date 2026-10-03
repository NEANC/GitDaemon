#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 记录刷新消息并同时输出到终端与卷内日志。
hosts_log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$HOSTS_LOG_FILE"; }

# 下载并从单个来源校验数据，通过后以同文件系统原子替换发布卷内快照。
hosts_apply_source() {
    local url=$1 fetched=$2 snapshot=$3 temporary=$4 records
    gm_hosts_download "$url" "$temporary" || { rm -f -- "$temporary"; return 1; }
    records=$(gm_hosts_filter_records < "$temporary") || { rm -f -- "$temporary"; return 1; }
    gm_hosts_render_snapshot "$url" "$fetched" <<< "$records" > "$temporary" || { rm -f -- "$temporary"; return 1; }
    mv -f -- "$temporary" "$snapshot" || { rm -f -- "$temporary"; return 1; }
    return 0
}

# 依次尝试主备来源，成功即发布快照并清除陈旧标记；全部失败时保留旧快照并标记陈旧。
hosts_refresh_sources() {
    local primary=$1 fallback=$2 snapshot=$3 temporary=$4 stale=$5 fetched=$6 url
    for url in "$primary" "$fallback"; do
        [[ -n $url ]] || continue
        hosts_log "尝试数据源：$url"
        if hosts_apply_source "$url" "$fetched" "$snapshot" "$temporary"; then
            rm -f -- "$stale" || return 1
            hosts_log "地址快照更新成功：$url"
            return 0
        fi
        hosts_log "数据源失败：$url"
    done
    if [[ -e $snapshot ]]; then
        (umask 077; : > "$stale") || return 1
        hosts_log '全部数据源失败，保留旧快照并标记陈旧'
    else
        hosts_log '全部数据源失败且无旧快照，将使用系统 DNS'
    fi
    return 1
}

# 显式执行刷新前读取纯数据并完成预检，成功仅发布经校验的卷内快照。
gm_hosts_main() (
    local install fetched snapshot temporary stale
    if [[ ${1-} == --help || ${1-} == -h ]]; then
        printf '%s\n' '用法：update-github-hosts.sh；运行配置来自 RUN_ROOT/config/mirror.env'
        return 0
    fi
    [[ $# == 0 ]] || { gm_error '刷新入口不接受此参数'; return 2; }
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]] || return 0
    gm_begin_operation hosts || return $?
    HOSTS_LOG_FILE=$RUN_ROOT/logs/hosts.log
    snapshot=$RUN_ROOT/hosts/github-hosts.snapshot
    temporary=$RUN_ROOT/hosts/github-hosts.snapshot.tmp
    stale=$RUN_ROOT/hosts/github-hosts.stale
    mkdir -p "$(dirname "$snapshot")" || return 1
    fetched=$(date '+%Y-%m-%dT%H:%M:%S%z') || return 1
    hosts_refresh_sources "${GM_CONFIG[HOSTS_URL]}" "${GM_CONFIG[HOSTS_URL_FALLBACK]}" \
        "$snapshot" "$temporary" "$stale" "$fetched" || return 1
    printf '%s\n' "$snapshot"
    return 0
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_hosts_main "$@"
fi
