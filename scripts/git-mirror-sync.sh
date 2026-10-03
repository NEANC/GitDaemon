#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 记录同步消息并同时输出到终端和日志。
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 删除指定 Git 配置键，仅把“键不存在”（退出码 5）视为已达成，其他错误显式返回。
configure_unset() {
    local dir=$1 key=$2 status
    if git --git-dir="$dir" config --unset-all "$key" 2>/dev/null; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 5 ] || return "$status"
    return 0
}

# 按完整镜像或限定分支设置 fetch refspec 与标签策略，每一步失败立即返回。
configure_fetch() {
    local dir=$1 branches=$2 branch
    local -a branch_list=()
    configure_unset "$dir" remote.origin.fetch || return $?
    if [ -z "$branches" ]; then
        git --git-dir="$dir" config remote.origin.mirror true || return 1
        configure_unset "$dir" remote.origin.tagOpt || return $?
        git --git-dir="$dir" config --add remote.origin.fetch '+refs/*:refs/*' || return 1
    else
        git --git-dir="$dir" config remote.origin.mirror false || return 1
        git --git-dir="$dir" config remote.origin.tagOpt --no-tags || return 1
        IFS=, read -r -a branch_list <<< "$branches"
        for branch in "${branch_list[@]}"; do
            git --git-dir="$dir" config --add remote.origin.fetch "+refs/heads/$branch:refs/heads/$branch" || return 1
        done
    fi
    return 0
}

# 仅隐藏格式明确的常规引用更新行，其他输出与回车进度即时透传。
filter_fetch_output() {
    local char buffer="" at_start=yes candidate=no
    local new_ref='^[[:blank:]]\*[[:blank:]]+\[new (branch|tag|ref)\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local fast_forward='^[[:blank:]]+[[:xdigit:]]+\.\.[[:xdigit:]]+[[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local forced='^[[:blank:]]\+[[:blank:]]+[[:xdigit:]]+\.\.\.[[:xdigit:]]+[[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]+\(forced update\)[[:blank:]]*$'
    local deleted='^[[:blank:]]-[[:blank:]]+\[deleted\][[:blank:]]+\(none\)[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local unchanged='^[[:blank:]]=[[:blank:]]+\[up to date\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local tag_update='^[[:blank:]]t[[:blank:]]+\[tag update\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    while IFS= read -r -N 1 char; do
        if [ "$candidate" = yes ]; then
            if [ "$char" = $'\n' ]; then
                if [[ ! "$buffer" =~ $new_ref && ! "$buffer" =~ $fast_forward && ! "$buffer" =~ $forced && ! "$buffer" =~ $deleted && ! "$buffer" =~ $unchanged && ! "$buffer" =~ $tag_update ]]; then
                    printf '%s\n' "$buffer"
                fi
                buffer=""
                candidate=no
                at_start=yes
            elif [ "$char" = $'\r' ]; then
                # 回车刷新不是引用明细，不等待换行或进程结束。
                printf '%s\r' "$buffer"
                buffer=""
                candidate=no
                at_start=yes
            else
                buffer+="$char"
            fi
        elif [ "$at_start" = yes ] && [[ "$char" == ' ' || "$char" == $'\t' ]]; then
            candidate=yes
            buffer="$char"
        else
            printf '%s' "$char"
            if [[ "$char" == $'\n' || "$char" == $'\r' ]]; then
                at_start=yes
            else
                at_start=no
            fi
        fi
    done
    # 未以换行结束的内容原样保留，不猜测其是否为完整明细。
    printf '%s' "$buffer"
    return 0
}

# 先追加完整日志，再筛选终端展示；保留 Git 原命令的退出状态。
run_cmd() {
    "$@" 2>&1 | tee -a "$LOG_FILE" | filter_fetch_output
    return "${PIPESTATUS[0]}"
}

# 仅在成功拉取后删除范围外引用，并把 HEAD 指向首个所选分支。
prune_unselected_refs() {
    local dir=$1 branches=$2 ref branch keep refs
    local -a selected=()
    if [ -z "$branches" ]; then
        return 0
    fi
    IFS=, read -r -a selected <<< "$branches"
    for branch in "${selected[@]}"; do
        git --git-dir="$dir" show-ref --verify --quiet "refs/heads/$branch" || return 1
    done
    refs=$(git --git-dir="$dir" for-each-ref --format='%(refname)') || return 1
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        keep=no
        for branch in "${selected[@]}"; do
            if [ "$ref" = "refs/heads/$branch" ]; then
                keep=yes
                break
            fi
        done
        if [ "$keep" = no ]; then
            git --git-dir="$dir" update-ref -d "$ref" || return 1
        fi
    done <<< "$refs"
    git --git-dir="$dir" symbolic-ref HEAD "refs/heads/${selected[0]}" || return 1
    return 0
}

# 拉取单个仓库，成功后缩减范围、跟随默认 HEAD 并写入发布标记。
update_repo() {
    local repo=$1 dir=$2 branches=$3 remote_head line
    local -a resolve_args=()
    if [ -n "$GITHUB_IP" ]; then
        resolve_args=(-c "http.curloptResolve=$GITHUB_HOST:443:$GITHUB_IP")
    fi
    configure_fetch "$dir" "$branches" || return 1
    log "同步 $repo；分支：${branches:-全部 refs}"
    run_cmd git "${resolve_args[@]}" --git-dir="$dir" fetch --progress --atomic --prune origin || return 1
    prune_unselected_refs "$dir" "$branches" || return 1
    if [ -z "$branches" ]; then
        if remote_head=$(git "${resolve_args[@]}" --git-dir="$dir" ls-remote --symref origin HEAD 2>>"$LOG_FILE"); then
            while IFS= read -r line; do
                if [[ $line == 'ref: refs/heads/'* ]]; then
                    remote_head=${line#ref: }
                    remote_head=${remote_head%%[[:space:]]*}
                    git --git-dir="$dir" symbolic-ref HEAD "$remote_head" || return 1
                    break
                fi
            done <<< "$remote_head"
        else
            log "无法查询上游默认分支，保留当前 HEAD：$repo"
        fi
    fi
    : > "$dir/git-daemon-export-ok" || return 1
    return 0
}

# 报告每个同步分支的提交头；无本地分支或枚举失败时明确提示。
report_branches() {
    local repo=$1 dir=$2 branches=$3 status=$4 branch branch_list details short_hash commit_time subject
    local -a selected=()
    if [ "$status" = success ]; then
        log "$repo 分支提交（本次同步成功）"
    else
        log "$repo 分支提交（本次同步失败；仅本地缓存，未确认上游最新）"
    fi
    if [ -n "$branches" ]; then
        IFS=, read -r -a selected <<< "$branches"
    else
        if ! branch_list=$(git --git-dir="$dir" for-each-ref --sort=refname --format='%(refname:strip=2)' refs/heads/ 2>>"$LOG_FILE"); then
            log "  无法读取本地分支列表"
            return 1
        fi
        if [ -z "$branch_list" ]; then
            log "  没有本地分支可报告"
            return 0
        fi
        while IFS= read -r branch; do
            selected+=("$branch")
        done <<< "$branch_list"
    fi
    for branch in "${selected[@]}"; do
        if details=$(git --git-dir="$dir" log -1 --abbrev=12 --format='%h%n%cI%n%s' "refs/heads/$branch" -- 2>>"$LOG_FILE") && [ -n "$details" ]; then
            short_hash=${details%%$'\n'*}
            details=${details#*$'\n'}
            commit_time=${details%%$'\n'*}
            subject=${details#*$'\n'}
            log "  ↳ $branch: $short_hash $subject"
            log "    提交时间：$commit_time"
        else
            log "  ↳ $branch: 本地不存在或无法读取提交"
        fi
    done
    return 0
}

# 同步单个仓库，失败时保留已有缓存且不发布新仓库。
sync_repo() {
    local repo=$1 branches=$2 dir url
    dir="$MIRROR_ROOT/$repo.git"
    url="https://github.com/$repo.git"
    mkdir -p "$(dirname "$dir")" || return 1
    if [ ! -d "$dir" ]; then
        git init --bare --quiet "$dir" || return 1
        git --git-dir="$dir" remote add origin "$url" || return 1
    fi
    if update_repo "$repo" "$dir" "$branches"; then
        report_branches "$repo" "$dir" "$branches" success || return 1
        return 0
    fi
    log "同步失败，保留已有缓存：$repo"
    report_branches "$repo" "$dir" "$branches" failed
    return 1
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
