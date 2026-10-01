#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=${CONFIG_DIR:-/etc/git-mirror}
[ -f "$CONFIG_DIR/mirror.env" ] && . "$CONFIG_DIR/mirror.env"
: "${REPOS:?REPOS 必须设置}"
MIRROR_ROOT=${MIRROR_ROOT:-/srv/git-mirror}
LOG_DIR=${LOG_DIR:-/var/log/git-mirror}
RUN_DIR=${RUN_DIR:-/run/git-mirror}
LOG_FILE=${LOG_FILE:-$LOG_DIR/sync.log}
LOCK_FILE=${LOCK_FILE:-$RUN_DIR/sync.lock}
GITHUB_HOST=${GITHUB_HOST:-github.com}
GITHUB_IP=${GITHUB_IP:-}
mkdir -p "$MIRROR_ROOT" "$LOG_DIR" "$RUN_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || { printf '已有同步任务在运行，跳过\n'; exit 0; }

# 记录同步消息并同时输出到终端和日志。
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 解析并校验仓库项，结果写入 REPO 和 BRANCHES。
parse_repo_item() {
    REPO=${1%% *}; BRANCHES=${1#* }
    [ "$REPO" = "$1" ] && BRANCHES=
    case "$REPO" in
        [A-Za-z0-9]*/*) ;;
        *) return 1 ;;
    esac
    case "$REPO" in
        */*[^A-Za-z0-9._-]*) return 1 ;;
    esac
    [ -z "$BRANCHES" ] && return 0
    case "$BRANCHES" in
        *' '*|,*|*,|*,,*) return 1 ;;
    esac
    return 0
}

# 根据配置设置完整镜像或限定分支的抓取 refspec。
configure_fetch() {
    dir=$1; branches=$2
    git --git-dir="$dir" config --unset-all remote.origin.fetch 2>/dev/null || true
    if [ -z "$branches" ]; then
        git --git-dir="$dir" config remote.origin.mirror true
        git --git-dir="$dir" config --add remote.origin.fetch '+refs/*:refs/*'
    else
        git --git-dir="$dir" config remote.origin.mirror false
        git --git-dir="$dir" config remote.origin.tagOpt --no-tags
        oldIFS=$IFS; IFS=,; set -- $branches; IFS=$oldIFS
        for branch do git --git-dir="$dir" config --add remote.origin.fetch "+refs/heads/$branch:refs/heads/$branch"; done
    fi
}

# 创建相对短链接，并拒绝未声明或不安全的短名称。
create_short_links() {
    repo=$1; dir=$2
    [ -n "${SHORT_LINKS:-}" ] || return 0
    oldIFS=$IFS; IFS=';'; set -- $SHORT_LINKS; IFS=$oldIFS
    for item do
        name=${item#* }; target=${item%% *}
        [ "$target" = "$repo" ] || continue
        case "$name" in *[!A-Za-z0-9._-]*|'') return 1;; esac
        ln -sfn "${repo}.git" "$MIRROR_ROOT/$name"
    done
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
        create_short_links "$repo" "$dir"
        report_branches "$repo" "$dir" "$branches" success
        return 0
    fi
    log "同步失败，保留已有缓存：$repo"
    report_branches "$repo" "$dir" "$branches" failed
    return 1
}

# 输出每个同步分支的提交摘要，失败时明确标记缓存状态。
report_branches() {
    repo=$1; dir=$2; branches=$3; status=$4
    [ "$status" = success ] && log "本次同步成功：$repo" || log "本次同步失败：$repo（保留本地缓存）"
    if [ -n "$branches" ]; then oldIFS=$IFS; IFS=,; set -- $branches; IFS=$oldIFS
    else set -- $(git --git-dir="$dir" for-each-ref --format='%(refname:strip=2)' refs/heads 2>/dev/null || true); fi
    for branch do
        commit=$(git --git-dir="$dir" log -1 --format='%h %s' "refs/heads/$branch" 2>/dev/null || true)
        [ -n "$commit" ] && log "  ↳ $branch: $commit" || log "  ↳ $branch: 本地不存在或无法读取提交"
    done
}

oldIFS=$IFS; IFS=';'; set -- $REPOS; IFS=$oldIFS
failed=0
for item do
    parse_repo_item "$item" || { log "忽略非法仓库配置：$item"; failed=1; continue; }
    sync_repo "$REPO" "$BRANCHES" || failed=1
done
exit "$failed"