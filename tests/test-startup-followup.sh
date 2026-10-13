#!/usr/bin/env bash
set -uo pipefail
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/test-startup-recovery.sh"

# 构造真实隔离旧库与悬空短链接，保持替换日志和 inode 证据一致。
setup_dangling_replay() {
    setup_startup "$1" || return 1
    gm_parse_repos 'owner/first;owner/second' 'owner/first short' || return 1
    local operation=12345678-1234-1234-1234-123456789abc
    local dir=$RUN_ROOT/repos/owner/first.git
    local -A replacement=([schema]=1 [repo]=owner/first [operation]="$operation" [phase]="${2-old_isolated}" [old_identity]="$(stat -c '%d-%i' "$dir")" [new_identity]=none [generation]=2 [config]="$(gm_repo_config_identity owner/first)" [boot]="$operation" [published_boot]=none [reason]=recovering)
    mkdir -p "$RUN_ROOT/quarantine/$operation" "$RUN_ROOT/config/managed-links" || return 1
    rm "$dir/git-daemon-export-ok" || return 1
    mv "$dir" "$RUN_ROOT/quarantine/$operation/repo.git" || return 1
    ln -s owner/first.git "$RUN_ROOT/repos/short.git" || return 1
    printf 'FORMAT=1\nTARGET=owner/first.git\n' > "$RUN_ROOT/config/managed-links/short.git"
    gm_repo_replacement_commit owner/first replacement
}

# 合法隔离窗口允许 replay，但不得恢复发布或修改链接。
test_startup_dangling_replay() {
    setup_dangling_replay dangling || return 1
    gm_startup_prepare || return 1
    [[ -L $RUN_ROOT/repos/short.git && ! -e $RUN_ROOT/repos/short.git && -f $RUN_ROOT/runtime/publication-gate ]] || return 1
    [[ ! -e $RUN_ROOT/repos/owner/second.git/git-daemon-export-ok ]]
}

# 拒绝缺失日志、伪造 inode、管理记录不匹配与路径逃逸。
test_startup_dangling_rejects_forgery() {
    local mode
    for mode in missing identity record outside unconfigured; do
        (
            setup_dangling_replay "forged-$mode" || exit 1
            case "$mode" in
                missing) rm "$RUN_ROOT/state/replacements/owner/first.state" ;;
                identity) local -A forged=(); gm_repo_replacement_read owner/first forged; forged[old_identity]=0-1; gm_repo_replacement_commit owner/first forged ;;
                record) printf 'FORMAT=1\nTARGET=owner/other.git\n' > "$RUN_ROOT/config/managed-links/short.git" ;;
                outside) rm "$RUN_ROOT/repos/short.git"; ln -s ../../outside "$RUN_ROOT/repos/short.git" ;;
                unconfigured) gm_parse_repos 'owner/second' '' ;;
            esac
            gm_startup_prepare && exit 1
            [[ ! -e $RUN_ROOT/runtime/publication-gate && -L $RUN_ROOT/repos/short.git ]]
        ) || return 1
    done
}

# 在代次写入期间收到 TERM，不能清除旧冻结或写入发布门。
test_prepare_stop_during_generation() {
    setup_startup generation-stop || return 1
    printf 'FROZEN=1\n' > "$RUN_ROOT/runtime/frozen"
    trap 'gm_request_stop instance test_signal' TERM
    gm_lifecycle_record() {
        if [[ $1 == "$RUN_ROOT/runtime/generation" ]]; then kill -TERM "$BASHPID"; fi
        printf '%s\n' "$2" > "$1"
    }
    gm_startup_prepare && return 1
    [[ -f $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/publication-gate ]]
}

# 已完成替换的历史记录不应阻止新启动通过真实 fetch 获取上游新对象。
test_completed_replacement_fetches() {
    setup_startup completed-fetch || return 1
    local dir=$RUN_ROOT/repos/owner/first.git upstream=$RUN_ROOT/upstream.git oid tree
    local operation=12345678-1234-1234-1234-123456789abc
    git init -q --bare "$upstream" || return 1
    tree=$(git --git-dir="$upstream" mktree < /dev/null) || return 1
    oid=$(printf 'new upstream\n' | git -c user.name=test -c user.email=test@example.invalid --git-dir="$upstream" commit-tree "$tree") || return 1
    git --git-dir="$upstream" update-ref refs/heads/main "$oid" || return 1
    git --git-dir="$dir" remote add origin "$upstream" || return 1
    local -A replacement=([schema]=1 [repo]=owner/first [operation]="$operation" [phase]=cleanup_complete [old_identity]=0-1 [new_identity]="$(stat -c '%d-%i' "$dir")" [generation]=1 [config]="$(gm_repo_config_identity owner/first)" [boot]="$operation" [published_boot]="$operation" [reason]=complete)
    mkdir -p "$RUN_ROOT/quarantine/$operation" || return 1
    gm_repo_replacement_commit owner/first replacement || return 1
    gm_startup_prepare && gm_startup_checks || return 1
    gm_startup_run_repo owner/first recovery || return 1
    [[ $(git --git-dir="$dir" rev-parse refs/heads/main) == "$oid" && -f $dir/git-daemon-export-ok ]] || return 1
    gm_repo_replacement_read owner/first replacement || return 1
    [[ ${replacement[phase]} == cleanup_complete && ${replacement[published_boot]} == "$operation" ]]
}

for test in test_completed_replacement_fetches test_startup_dangling_replay test_startup_dangling_rejects_forgery test_prepare_stop_during_generation; do
    CHECKS=$((CHECKS+1))
    if ( "$test" ); then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf '启动补充检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
