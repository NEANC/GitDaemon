#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 记录同步消息并同时输出到终端和日志。
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 根据已完成预检的配置设置完整镜像或限定分支的抓取 refspec。
configure_fetch() {
    local dir=$1 branches=$2 branch
    local -a branch_list=()
    git --git-dir="$dir" config --unset-all remote.origin.fetch 2>/dev/null || true
    if [ -z "$branches" ]; then
        git --git-dir="$dir" config remote.origin.mirror true
        git --git-dir="$dir" config --add remote.origin.fetch '+refs/*:refs/*'
    else
        git --git-dir="$dir" config remote.origin.mirror false
        git --git-dir="$dir" config remote.origin.tagOpt --no-tags
        IFS=, read -r -a branch_list <<< "$branches"
        for branch in "${branch_list[@]}"; do
            git --git-dir="$dir" config --add remote.origin.fetch "+refs/heads/$branch:refs/heads/$branch"
        done
    fi
}

# 同步单个仓库，失败时保留已有缓存且不发布新仓库。
sync_repo() {
    repo=$1; branches=$2; dir="$MIRROR_ROOT/$repo.git"; url="https://github.com/$repo.git"
    mkdir -p "$(dirname "$dir")"
    if [ ! -d "$dir" ]; then git init --bare --quiet "$dir"; git --git-dir="$dir" remote add origin "$url"; fi
    configure_fetch "$dir" "$branches"
    resolve_args=
    [ -n "$GITHUB_IP" ] && resolve_args="-c http.curloptResolve=$GITHUB_HOST:443:$GITHUB_IP"
    log "同步 $repo；分支：${branches:-全部 refs}"
    if git $resolve_args --git-dir="$dir" fetch --prune origin >>"$LOG_FILE" 2>&1; then
        : > "$dir/git-daemon-export-ok"
        report_branches "$repo" "$dir" "$branches" success
        return 0
    fi
    log "同步失败，保留已有缓存：$repo"
    report_branches "$repo" "$dir" "$branches" failed
    return 1
}

# 输出每个同步分支的提交摘要，失败时明确标记缓存状态。
report_branches() {
    local repo=$1 dir=$2 branches=$3 status=$4 branch commit
    local -a branch_list=()
    [ "$status" = success ] && log "本次同步成功：$repo" || log "本次同步失败：$repo（保留本地缓存）"
    if [ -n "$branches" ]; then
        IFS=, read -r -a branch_list <<< "$branches"
    else
        mapfile -t branch_list < <(git --git-dir="$dir" for-each-ref --format='%(refname:strip=2)' refs/heads 2>/dev/null || true)
    fi
    for branch in "${branch_list[@]}"; do
        commit=$(git --git-dir="$dir" log -1 --format='%h %s' "refs/heads/$branch" 2>/dev/null || true)
        [ -n "$commit" ] && log "  ↳ $branch: $commit" || log "  ↳ $branch: 本地不存在或无法读取提交"
    done
}

# 显式执行同步前读取纯数据并完成整组预检，不创建短链接。
gm_sync_main() (
    local index failed=0 install
    if [[ ${1-} == --help || ${1-} == -h ]]; then
        printf '%s\n' '用法：git-mirror-sync.sh；REPOS/SHORT_LINKS 仅来自当前环境'
        return 0
    fi
    [[ $# == 0 ]] || { gm_error '同步入口不接受此参数'; return 2; }
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    gm_begin_operation sync || return $?
    CONFIG_DIR=$RUN_ROOT/config
    MIRROR_ROOT=$RUN_ROOT/repos
    LOG_DIR=$RUN_ROOT/logs
    RUN_DIR=$RUN_ROOT/runtime
    LOG_FILE=$LOG_DIR/sync.log
    LOCK_FILE=$RUN_DIR/sync.lock
    GITHUB_HOST=${GITHUB_HOST:-github.com}
    GITHUB_IP=${GITHUB_IP:-}
    for index in "${!GM_REPOS[@]}"; do
        sync_repo "${GM_REPOS[$index]}" "${GM_BRANCHES[$index]}" || failed=1
    done
    return "$failed"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_sync_main "$@"
fi
