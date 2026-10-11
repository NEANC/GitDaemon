#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/repository-state.sh"
if [[ -f $ROOT/scripts/lib/repository-recovery.sh ]]; then source "$ROOT/scripts/lib/repository-recovery.sh"; fi
TEST_ROOT=$(mktemp -d) || exit 1
trap 'chmod -R u+rwX "$TEST_ROOT"; rm -rf -- "$TEST_ROOT"' EXIT
CHECKS=0 FAILURES=0

# 为每项检查建立独立裸库和真实状态记录。
setup_repo() {
    RUN_ROOT=$TEST_ROOT/$1
    mkdir -p "$RUN_ROOT/repos/owner" "$RUN_ROOT/runtime" "$RUN_ROOT/logs"
    GM_BOOT_GENERATION=12345678-1234-1234-1234-123456789abc
    printf '%s\n' "$GM_BOOT_GENERATION" > "$RUN_ROOT/runtime/generation"
    gm_parse_repos 'owner/repo' '' || return 1
    DIR=$RUN_ROOT/repos/owner/repo.git
    git init -q --bare "$DIR" || return 1
    git --git-dir="$DIR" remote add origin https://github.com/owner/repo.git || return 1
    local tree commit
    tree=$(git --git-dir="$DIR" mktree </dev/null) || return 1
    commit=$(printf 'seed\n' | git -c user.name=test -c user.email=test@example.invalid --git-dir="$DIR" commit-tree "$tree") || return 1
    git --git-dir="$DIR" update-ref refs/heads/main "$commit" || return 1
    git --git-dir="$DIR" symbolic-ref HEAD refs/heads/main || return 1
    STATE=([schema]=1 [repo]=owner/repo [generation]=1 [desired]=present [observed]=ready [published]=no [message]=unchecked)
    gm_repo_state_commit_locked owner/repo STATE
}

# 健康库及悬空对象均可检查，只有统一发布接口开放入口。
test_healthy_and_dangling() {
    setup_repo healthy || return 1
    printf 'dangling\n' | git --git-dir="$DIR" hash-object -w --stdin >/dev/null || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    [[ ${RESULT[health]} == healthy && ${RESULT[raw_status]} == 0 && ! -e $DIR/git-daemon-export-ok ]] || return 1
    gm_repo_publish_locked owner/repo 1 || return 1
    [[ -f $DIR/git-daemon-export-ok ]] || return 1
    gm_repo_unpublish_locked owner/repo || return 1
    [[ ! -e $DIR/git-daemon-export-ok ]]
}

# 删除可达对象与破坏对象内容必须确认为损坏。
test_missing_and_corrupt_object() {
    local mode oid file
    for mode in missing corrupt; do
        setup_repo "$mode" || return 1
        oid=$(git --git-dir="$DIR" rev-parse HEAD)
        file=$DIR/objects/${oid:0:2}/${oid:2}
        if [[ $mode == missing ]]; then rm -- "$file"; else chmod u+w "$file"; printf 'broken' > "$file"; fi
        gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
        [[ ${RESULT[health]} == corrupt && ${RESULT[raw_status]} != 0 ]] || { cat "${RESULT[log]}"; return 1; }
        if gm_repo_publish_locked owner/repo 1; then return 1; fi
    done
}

# 非 root 下不可读对象不得被误认成已确认损坏。
test_permission_is_not_corruption() {
    (( EUID != 0 )) || { printf '需要非 root Linux\n'; return 1; }
    setup_repo permission || return 1
    local oid file status=0
    oid=$(git --git-dir="$DIR" rev-parse HEAD)
    file=$DIR/objects/${oid:0:2}/${oid:2}
    chmod 000 "$file"
    gm_repo_check_locked owner/repo "$DIR" RESULT || status=1
    chmod 600 "$file"
    [[ $status == 0 && ${RESULT[health]} == recovery_required && ${RESULT[raw_status]} != 0 ]]
}

# 副本、启动代次及配置变动均使先前检查失效。
test_stale_generation_cannot_publish() {
    setup_repo stale || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    if gm_repo_publish_locked owner/repo 0; then return 1; fi
    GM_BOOT_GENERATION=22345678-1234-1234-1234-123456789abc
    if gm_repo_publish_locked owner/repo 1; then return 1; fi
    GM_BOOT_GENERATION=12345678-1234-1234-1234-123456789abc
    GM_BRANCHES=(dev)
    if gm_repo_publish_locked owner/repo 1; then return 1; fi
    [[ ! -e $DIR/git-daemon-export-ok ]]
}

# 发布状态落盘失败必须撤销刚创建的入口。
test_publish_commit_failure_revokes_export() {
    setup_repo failure || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    GM_STATE_TEST_FAULT=rename
    if gm_repo_publish_locked owner/repo 1; then return 1; fi
    [[ ! -e $DIR/git-daemon-export-ok ]]
}

# 不完整目录不可发布，合法空裸库可通过完整性检查。
test_incomplete_and_empty() {
    setup_repo empty || return 1
    git --git-dir="$DIR" update-ref -d refs/heads/main || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    [[ ${RESULT[health]} == healthy ]] || return 1
    gm_repo_publish_locked owner/repo 1 || return 1
    rm "$DIR/HEAD"
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    [[ ${RESULT[health]} == recovery_required ]] || return 1
    [[ ! -e $DIR/git-daemon-export-ok ]]
}

# 未知诊断与中断退出均不得借用旧健康记录发布。
test_unknown_and_interrupted() {
    setup_repo unknown || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    local injected_status=1
    git() {
        if [[ $* == *'fsck --full'* ]]; then printf 'unrecognized diagnostic\n'; return "$injected_status"; fi
        command git "$@"
    }
    for injected_status in 0 1 143; do
        gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
        [[ ${RESULT[health]} == recovery_required && ${RESULT[raw_status]} == "$injected_status" ]] || return 1
        if gm_repo_publish_locked owner/repo 1; then return 1; fi
    done
}

# 无法撤销已创建入口时必须冻结实例。
test_revoke_failure_is_unsafe() {
    setup_repo unsafe || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    gm_repo_state_commit_locked() { chmod 500 "$DIR"; return 1; }
    local status=0
    gm_repo_publish_locked owner/repo 1 || status=$?
    chmod 700 "$DIR"
    [[ $status == 2 && ${GM_REPO_RESULT-} == UNSAFE && ${GM_LOCAL_FROZEN-} == yes && -f $RUN_ROOT/runtime/frozen ]]
}

# 持久化副本代次变更或正式目录替换使旧验证失效。
test_replica_replaced() {
    setup_repo replaced || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    gm_repo_state_read owner/repo STATE || return 1
    STATE[generation]=2
    gm_repo_state_commit_locked owner/repo STATE || return 1
    if gm_repo_publish_locked owner/repo 2; then return 1; fi
    STATE[generation]=1
    gm_repo_state_commit_locked owner/repo STATE || return 1
    mv "$DIR" "$DIR.old" || return 1
    git init -q --bare "$DIR" || return 1
    if gm_repo_publish_locked owner/repo 1; then return 1; fi
}

for test in test_healthy_and_dangling test_missing_and_corrupt_object test_permission_is_not_corruption test_stale_generation_cannot_publish test_publish_commit_failure_revokes_export test_incomplete_and_empty test_unknown_and_interrupted test_revoke_failure_is_unsafe test_replica_replaced; do
    CHECKS=$((CHECKS+1))
    if (declare -A STATE=() RESULT=(); declare -F gm_repo_check_locked >/dev/null && "$test"); then
        printf '[PASS] %s\n' "$test"
    else
        printf '[FAIL] %s\n' "$test"
        FAILURES=$((FAILURES+1))
    fi
done
printf 'checks=%s failures=%s\n' "$CHECKS" "$FAILURES"
(( FAILURES == 0 ))
