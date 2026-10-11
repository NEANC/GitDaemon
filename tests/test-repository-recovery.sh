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
    local status=0
    gm_repo_publish_locked owner/repo 1 || status=$?
    [[ $status == 1 && ${GM_STATE_COMMIT_RESULT-} == failed && ! -e $DIR/git-daemon-export-ok && ! -e $RUN_ROOT/runtime/frozen && ${GM_LOCAL_FROZEN-} != yes ]]
}

# 仅状态目录同步失败时确认 rename 已完成，撤销成功仍必须保留不确定结果并冻结。
test_publish_directory_sync_is_unsafe() {
    setup_repo directory-sync || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    gm_begin_operation sync || return 1
    local status=0
    sync() {
        if [[ $* == "-- $RUN_ROOT/state/repos/owner" ]]; then
            printf 'injected\n' > "$RUN_ROOT/directory-sync-hit"
            return 1
        fi
        command sync "$@"
    }
    gm_repo_publish_locked owner/repo 1 || status=$?
    printf 'directory-sync status=%s commit=%s result=%s frozen=%s\n' "$status" "${GM_STATE_COMMIT_RESULT-}" "${GM_REPO_RESULT-}" "${GM_LOCAL_FROZEN-}"
    gm_repo_state_read owner/repo STATE || return 1
    [[ -f $RUN_ROOT/directory-sync-hit && ${STATE[published]} == yes && ! -e $DIR/git-daemon-export-ok ]] || return 1
    [[ $status == 2 && ${GM_STATE_COMMIT_RESULT-} == indeterminate && ${GM_REPO_RESULT-} == UNSAFE ]] || return 1
    [[ ${GM_LOCAL_FROZEN-} == yes && ${GM_STOP_SCOPE-} == instance && -f $RUN_ROOT/runtime/frozen ]] || return 1
    [[ -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} ]] || return 1
    if gm_repo_publish_locked owner/repo 1; then return 1; fi
    local -A task_result=()
    if gm_task_run_locked owner/repo sync task_result touch "$RUN_ROOT/written"; then return 1; fi
    [[ ! -e $RUN_ROOT/written && ! -e $DIR/git-daemon-export-ok ]]
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

setup_replacement() {
    setup_repo "$1" || return 1
    source "$ROOT/scripts/git-mirror-sync.sh" || return 1
    LOG_FILE=$RUN_ROOT/logs/sync.log
    GM_TRANSPORT_SEQUENCE=(system)
    UPSTREAM=$RUN_ROOT/upstream.git
    git clone -q --bare --no-local "$DIR" "$UPSTREAM" || return 1
    git() {
        local -a args=("$@")
        local index
        for index in "${!args[@]}"; do
            if [[ ${args[$index]} == https://github.com/owner/repo.git ]]; then args[$index]=$UPSTREAM; fi
        done
        command git "${args[@]}"
    }
    local oid
    oid=$(git --git-dir="$DIR" rev-parse HEAD) || return 1
    rm -- "$DIR/objects/${oid:0:2}/${oid:2}" || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    [[ ${RESULT[health]} == corrupt ]]
}

restart_replacement() {
    GM_BOOT_GENERATION=22345678-1234-1234-1234-123456789abc
    printf '%s\n' "$GM_BOOT_GENERATION" > "$RUN_ROOT/runtime/generation"
    if [[ -d $DIR ]]; then gm_repo_export_remove_locked owner/repo || return 1; fi
    unset GM_REPLACE_TEST_STOP
    gm_repo_replay_locked owner/repo RESULT
}

test_restart_each_replace_phase() {
    local phase old
    for phase in detected unpublished old_isolated candidate_building candidate_verified installed published cleanup_complete; do
        setup_replacement "restart-$phase" || return 1
        old=$(stat -c '%d-%i' "$DIR") || return 1
        GM_REPLACE_TEST_STOP=$phase
        if gm_repo_rebuild_locked owner/repo '' RESULT; then return 1; fi
        local -A journal=()
        gm_repo_replacement_read owner/repo journal || return 1
        [[ ${journal[phase]} == "$phase" ]] || return 1
        if [[ $phase != cleanup_complete ]]; then
            [[ $(stat -c '%d-%i' "$DIR" 2>/dev/null) == "$old" || $(stat -c '%d-%i' "$RUN_ROOT/quarantine/${journal[operation]}/repo.git" 2>/dev/null) == "$old" ]] || return 1
        fi
        printf 'phase=%s old=%s operation=%s\n' "$phase" "$old" "${journal[operation]}"
        restart_replacement || return 1
        gm_repo_rebuild_locked owner/repo '' RESULT || return 1
        [[ -f $DIR/git-daemon-export-ok && ! -e $RUN_ROOT/quarantine/${journal[operation]}/repo.git ]] || return 1
        command git --git-dir="$DIR" fsck --full || return 1
    done
}

test_live_reader_defers_move() {
    setup_repo readers || return 1
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    gm_repo_publish_locked owner/repo 1 || return 1
    local old oid
    old=$(stat -c '%d-%i' "$DIR")
    oid=$(git --git-dir="$DIR" rev-parse HEAD)
    rm -- "$DIR/objects/${oid:0:2}/${oid:2}"
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    if gm_repo_rebuild_locked owner/repo '' RESULT; then return 1; fi
    [[ ${RESULT[reason]-} == readers_unknown && $(stat -c '%d-%i' "$DIR") == "$old" && ! -e $DIR/git-daemon-export-ok ]] || return 1
    local -A journal=()
    gm_repo_replacement_read owner/repo journal || return 1
    [[ ${journal[phase]} == unpublished ]]
}

test_failed_candidate_keeps_old() {
    setup_replacement failed-candidate || return 1
    local old
    old=$(stat -c '%d-%i' "$DIR")
    update_repo() { return 1; }
    if gm_repo_rebuild_locked owner/repo '' RESULT; then return 1; fi
    local -A journal=()
    gm_repo_replacement_read owner/repo journal || return 1
    [[ $(stat -c '%d-%i' "$RUN_ROOT/quarantine/${journal[operation]}/repo.git") == "$old" && ! -e $DIR/git-daemon-export-ok ]]
}

test_cleanup_failure_keeps_new() {
    setup_replacement cleanup-failure || return 1
    local -A journal=()
    GM_REPLACE_TEST_STOP=published
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    unset GM_REPLACE_TEST_STOP
    gm_repo_replacement_read owner/repo journal || return 1
    chmod 500 "$RUN_ROOT/quarantine/${journal[operation]}"
    local status=0
    gm_repo_cleanup_old_locked owner/repo || status=$?
    chmod 700 "$RUN_ROOT/quarantine/${journal[operation]}"
    [[ $status != 0 && -f $DIR/git-daemon-export-ok && -d $RUN_ROOT/quarantine/${journal[operation]}/repo.git ]] || return 1
    gm_repo_cleanup_old_locked owner/repo
}

test_old_published_needs_current_fsck() {
    setup_replacement old-published || return 1
    GM_REPLACE_TEST_STOP=published
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    local -A journal=()
    gm_repo_replacement_read owner/repo journal || return 1
    restart_replacement || return 1
    if gm_repo_cleanup_old_locked owner/repo; then return 1; fi
    [[ -d $RUN_ROOT/quarantine/${journal[operation]}/repo.git && ! -e $DIR/git-daemon-export-ok ]] || return 1
    local oid
    oid=$(git --git-dir="$DIR" rev-parse HEAD)
    rm -- "$DIR/objects/${oid:0:2}/${oid:2}"
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    if gm_repo_rebuild_locked owner/repo '' RESULT; then return 1; fi
    [[ -d $RUN_ROOT/quarantine/${journal[operation]}/repo.git ]]
}

test_alias_transition_requires_journal() {
    setup_replacement alias || return 1
    gm_parse_repos 'owner/repo' 'owner/repo short' || return 1
    mkdir -p "$RUN_ROOT/config/managed-links"
    ln -s owner/repo.git "$RUN_ROOT/repos/short.git"
    gm_write_link_record "$RUN_ROOT/config/managed-links/short.git" owner/repo.git || return 1
    GM_REPLACE_TEST_STOP=old_isolated
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    gm_repo_validate_aliases_locked owner/repo || return 1
    local record=$RUN_ROOT/state/replacements/owner/repo.state
    mv "$record" "$record.saved"
    if gm_repo_validate_aliases_locked owner/repo; then return 1; fi
    mv "$record.saved" "$record"
    rm "$RUN_ROOT/repos/short.git"
    ln -s ../outside "$RUN_ROOT/repos/short.git"
    if gm_repo_validate_aliases_locked owner/repo; then return 1; fi
    rm "$RUN_ROOT/repos/short.git"
    ln -s owner/repo.git "$RUN_ROOT/repos/short.git"
    restart_replacement || return 1
    gm_repo_rebuild_locked owner/repo '' RESULT || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/short.git"
}

test_scan_failure_blocks_cleanup() {
    setup_replacement scan-failure || return 1
    GM_REPLACE_TEST_STOP=published
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    unset GM_REPLACE_TEST_STOP
    local -A journal=()
    gm_repo_replacement_read owner/repo journal || return 1
    find() { return 1; }
    if gm_repo_cleanup_old_locked owner/repo; then return 1; fi
    [[ -d $RUN_ROOT/quarantine/${journal[operation]}/repo.git ]]
}

test_cleanup_checks_durable_boot() {
    setup_replacement durable-boot || return 1
    GM_REPLACE_TEST_STOP=published
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    unset GM_REPLACE_TEST_STOP
    printf '%s\n' 22345678-1234-1234-1234-123456789abc > "$RUN_ROOT/runtime/generation"
    if gm_repo_cleanup_old_locked owner/repo; then return 1; fi
}

test_candidate_rejects_sharing_and_scope() {
    local mode
    for mode in alternate hardlink symlink scope head; do
        setup_replacement "candidate-$mode" || return 1
        GM_REPLACE_TEST_STOP=candidate_verified
        gm_repo_rebuild_locked owner/repo '' RESULT && return 1
        unset GM_REPLACE_TEST_STOP
        local -A journal=()
        gm_repo_replacement_read owner/repo journal || return 1
        local dir=$RUN_ROOT/staging/${journal[operation]}/repo.git
        case $mode in
            alternate) printf '%s\n' "$UPSTREAM/objects" > "$dir/objects/info/alternates" ;;
            hardlink) ln "$dir/HEAD" "$RUN_ROOT/shared-head" ;;
            symlink) mv "$dir/objects" "$RUN_ROOT/shared-objects"; ln -s "$RUN_ROOT/shared-objects" "$dir/objects" ;;
            scope) git --git-dir="$dir" config remote.origin.fetch '+refs/heads/other:refs/heads/other' ;;
            head) git --git-dir="$dir" symbolic-ref HEAD refs/heads/absent ;;
        esac
        if gm_repo_rebuild_locked owner/repo '' RESULT; then return 1; fi
        [[ -d $RUN_ROOT/quarantine/${journal[operation]}/repo.git && ! -e $DIR ]] || return 1
    done
}

test_replacement_rename_windows() {
    local phase
    for phase in unpublished candidate_verified; do
        setup_replacement "rename-$phase" || return 1
        GM_REPLACE_TEST_STOP=$phase
        gm_repo_rebuild_locked owner/repo '' RESULT && return 1
        local -A journal=()
        gm_repo_replacement_read owner/repo journal || return 1
        if [[ $phase == unpublished ]]; then
            mkdir -p "$RUN_ROOT/quarantine/${journal[operation]}"
            mv "$DIR" "$RUN_ROOT/quarantine/${journal[operation]}/repo.git"
        else
            mv "$RUN_ROOT/staging/${journal[operation]}/repo.git" "$DIR"
        fi
        restart_replacement || return 1
        gm_repo_rebuild_locked owner/repo '' RESULT || return 1
        [[ -f $DIR/git-daemon-export-ok ]] || return 1
    done
}

test_candidate_empty_and_selected() {
    local mode branches
    for mode in empty selected; do
        setup_replacement "valid-$mode" || return 1
        branches=
        if [[ $mode == empty ]]; then
            git --git-dir="$UPSTREAM" update-ref -d refs/heads/main || return 1
        else
            branches=main
            gm_parse_repos 'owner/repo main' '' || return 1
            git --git-dir="$UPSTREAM" update-ref refs/heads/extra HEAD || return 1
        fi
        gm_repo_rebuild_locked owner/repo "$branches" RESULT || return 1
        [[ -f $DIR/git-daemon-export-ok ]] || return 1
        if [[ $mode == selected ]]; then
            [[ $(git --git-dir="$DIR" for-each-ref --format='%(refname)') == refs/heads/main ]] || return 1
        fi
    done
}

test_candidate_creation_window() {
    setup_replacement creation-window || return 1
    GM_REPLACE_TEST_STOP=old_isolated
    gm_repo_rebuild_locked owner/repo '' RESULT && return 1
    local -A journal=()
    gm_repo_replacement_read owner/repo journal || return 1
    mkdir -p "$RUN_ROOT/staging/${journal[operation]}/repo.git"
    restart_replacement || return 1
    gm_repo_rebuild_locked owner/repo '' RESULT || return 1
}

test_second_replacement_after_completion() {
    setup_replacement second-replacement || return 1
    gm_repo_rebuild_locked owner/repo '' RESULT || return 1
    restart_replacement || return 1
    local oid old
    oid=$(git --git-dir="$DIR" rev-parse HEAD)
    old=$(stat -c '%d-%i' "$DIR")
    rm -- "$DIR/objects/${oid:0:2}/${oid:2}"
    gm_repo_check_locked owner/repo "$DIR" RESULT || return 1
    gm_repo_rebuild_locked owner/repo '' RESULT || return 1
    [[ -f $DIR/git-daemon-export-ok && $(stat -c '%d-%i' "$DIR") != "$old" ]]
}

for test in ${GM_RECOVERY_TESTS:-test_healthy_and_dangling test_missing_and_corrupt_object test_permission_is_not_corruption test_stale_generation_cannot_publish test_publish_commit_failure_revokes_export test_publish_directory_sync_is_unsafe test_incomplete_and_empty test_unknown_and_interrupted test_revoke_failure_is_unsafe test_replica_replaced test_restart_each_replace_phase test_alias_transition_requires_journal test_live_reader_defers_move test_failed_candidate_keeps_old test_cleanup_failure_keeps_new test_old_published_needs_current_fsck test_scan_failure_blocks_cleanup test_cleanup_checks_durable_boot test_candidate_rejects_sharing_and_scope test_replacement_rename_windows test_candidate_empty_and_selected test_candidate_creation_window test_second_replacement_after_completion}; do
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
