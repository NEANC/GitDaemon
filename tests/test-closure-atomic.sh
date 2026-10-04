#!/usr/bin/env bash
# 用真实 Git 多引用锁失败验证 fetch --atomic，不宣称整轮同步事务。
set -euo pipefail
source "$(dirname "$0")/../scripts/git-mirror-sync.sh"
[[ $UID != 0 && $EUID != 0 ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
LOG_FILE=$work/log
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
git init --bare -q "$work/upstream"
first=$(printf 'first\n' | git --git-dir="$work/upstream" commit-tree "$(git --git-dir="$work/upstream" mktree </dev/null)")
git --git-dir="$work/upstream" update-ref refs/heads/a "$first"
git --git-dir="$work/upstream" update-ref refs/heads/b "$first"
git clone --mirror -q "$work/upstream" "$work/mirror"
: > "$work/mirror/git-daemon-export-ok"
ln -s mirror "$work/short.git"
second=$(printf 'second\n' | git --git-dir="$work/upstream" commit-tree -p "$first" "$(git --git-dir="$work/upstream" mktree </dev/null)")
git --git-dir="$work/upstream" update-ref refs/heads/a "$second"
git --git-dir="$work/upstream" update-ref refs/heads/b "$second"
before=$(git --git-dir="$work/mirror" show-ref)
: > "$work/mirror/refs/heads/b.lock"
GM_CONFIG[PROXY_URL]=
GM_TRANSPORT_SEQUENCE=(system)
if update_repo fixture/repo "$work/mirror" ''; then
    printf 'FAIL expected lock failure\n'; exit 1
fi
[[ $(git --git-dir="$work/mirror" show-ref) == "$before" ]]
[[ -f $work/mirror/git-daemon-export-ok && $(readlink "$work/short.git") == mirror ]]
printf 'PASS atomic lock failure preserves both refs, existing publication and link uid=%s\n' "$UID"
rm "$work/mirror/refs/heads/b.lock"
update_repo fixture/repo "$work/mirror" ''
[[ $(git --git-dir="$work/mirror" rev-parse refs/heads/a) == "$second" ]]
[[ $(git --git-dir="$work/mirror" rev-parse refs/heads/b) == "$second" ]]
printf 'PASS retry updates both refs\n'
