#!/usr/bin/env bash

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lifecycle.sh" || return 1

# 将受管仓库及当前分支配置绑定为不含凭据的身份摘要。
gm_repo_config_identity() {
    local repo=$1 index digest
    for index in "${!GM_REPOS[@]}"; do
        [[ ${GM_REPOS[$index]} == "$repo" ]] || continue
        digest=$(printf '%s\n%s\n' "$repo" "${GM_BRANCHES[$index]}" | sha256sum) || return 1
        printf '%s\n' "${digest%% *}"
        return 0
    done
    return 1
}

# 撤销失败升级为实例故障，保留冻结而非继续发布。
gm_repo_export_remove_locked() {
    local repo=$1 dir=$RUN_ROOT/repos/$1.git marker
    marker=$dir/git-daemon-export-ok
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    if gm_validate_file "$marker" && rm -f -- "$marker" && gm_state_flush "$dir"; then return 0; fi
    GM_REPO_RESULT=UNSAFE
    gm_request_stop instance unpublish_failed
    gm_task_freeze || true
    return 2
}

# 关闭新下载后持久化未发布状态，不移动或删除仓库。
gm_repo_unpublish_locked() {
    local repo=$1
    local -A unpublish_state=()
    gm_repo_export_remove_locked "$repo" || return $?
    gm_repo_state_read "$repo" unpublish_state || return 1
    unpublish_state[published]=no
    gm_repo_state_commit_locked "$repo" unpublish_state
}

# 保存固定语言原始诊断，已知损坏与环境故障分别分类。
gm_repo_check_locked() {
    local repo=$1 dir=$2 output=$3 diagnostic status=0 line unknown=no damage=no environment=no bare config identity boot
    local -n check_result=$output
    local -A check_state=()
    check_result=([health]=recovery_required [reason]=check_failed [raw_status]=128)
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    [[ $dir == "$RUN_ROOT/repos/$repo.git" ]] || return 1
    gm_validate_path "$dir" read || return 1
    gm_repo_state_read "$repo" check_state || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    [[ $boot == "${GM_BOOT_GENERATION-}" && $boot =~ ^[a-f0-9-]{36}$ ]] || return 1
    config=$(gm_repo_config_identity "$repo") || return 1
    identity=$(stat -c '%d-%i' -- "$dir") || return 1
    gm_repo_export_remove_locked "$repo" || return $?
    check_state[published]=no
    check_state[message]=recovery_required
    if [[ ${check_state[schema]} == 2 ]]; then check_state[health]=recovery_required; fi
    gm_repo_state_commit_locked "$repo" check_state || return 1
    gm_state_directory_prepare "$RUN_ROOT/logs" || return 1
    diagnostic=$(mktemp "$RUN_ROOT/logs/fsck.XXXXXXXX") || return 1
    bare=$(LC_ALL=C git --git-dir="$dir" rev-parse --is-bare-repository 2>"$diagnostic") || status=$?
    if [[ $bare == true && $status == 0 ]]; then
        LC_ALL=C git --git-dir="$dir" fsck --full >>"$diagnostic" 2>&1 || status=$?
        while IFS= read -r line || [[ -n $line ]]; do
            case "$line" in
                *'Permission denied'*|*'Input/output error'*|*'No space left on device'*) environment=yes ;;
                'missing blob '*|'missing tree '*|'missing commit '*|'missing tag '*|*'hash mismatch'*|*'object corrupt or missing'*|*'invalid sha1 pointer'*|'fatal: loose object '*' is corrupt') damage=yes ;;
                'error: inflate: data stream error '*|'error: unable to unpack '*' header'|'broken link from '*|'              to '*) ;;
                ''|'dangling blob '*|'dangling tree '*|'dangling commit '*|'dangling tag '*|'unreachable '*|'notice: HEAD points to an unborn branch '*|'notice: No default references') ;;
                *) unknown=yes ;;
            esac
        done < "$diagnostic"
        if [[ $environment == yes ]]; then
            check_result[reason]=environment
        elif (( status > 0 && status <= 128 )) && [[ $damage == yes && $unknown == no ]]; then
            check_result[health]=corrupt
            check_result[reason]=object_damage
        elif (( status == 0 )) && [[ $unknown == no && $damage == no ]]; then
            check_result[health]=healthy
            check_result[reason]=verified
        fi
    fi
    check_result[raw_status]=$status
    check_result[log]=$diagnostic
    gm_state_flush "$diagnostic" || return 1
    check_state[schema]=2
    check_state[published]=no
    check_state[health]=${check_result[health]}
    check_state[reason]=${check_result[reason]}
    check_state[raw_status]=$status
    check_state[checked_boot]=$boot
    check_state[checked_generation]=${check_state[generation]}
    check_state[checked_config]=$config
    check_state[checked_identity]=$identity
    check_state[message]=${check_result[health]}
    gm_repo_state_commit_locked "$repo" check_state
}

# 核对本轮检查身份后开放入口，发布记录失败即撤销入口。
gm_repo_publish_locked() {
    local repo=$1 generation=$2 dir=$RUN_ROOT/repos/$1.git boot config identity marker
    local -A publish_state=()
    GM_REPO_RESULT=BLOCKED
    [[ ${GM_LOCAL_FROZEN-} != yes && ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    gm_repo_state_read "$repo" publish_state || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    config=$(gm_repo_config_identity "$repo") || return 1
    gm_validate_path "$dir" read || return 1
    identity=$(stat -c '%d-%i' -- "$dir") || return 1
    [[ ${publish_state[health]-} == healthy && ${publish_state[desired]} == present && ${publish_state[message]} != recovery_required ]] || return 1
    [[ ${publish_state[generation]} == "$generation" && ${publish_state[checked_generation]-} == "$generation" ]] || return 1
    [[ ${publish_state[checked_boot]-} == "$boot" && $boot == "${GM_BOOT_GENERATION-}" ]] || return 1
    [[ ${publish_state[checked_config]-} == "$config" && ${publish_state[checked_identity]-} == "$identity" ]] || return 1
    marker=$dir/git-daemon-export-ok
    gm_validate_file "$marker" || return 1
    if ! (umask 077; : > "$marker") || ! gm_state_flush "$marker" || ! gm_state_flush "$dir"; then
        gm_repo_export_remove_locked "$repo" || return $?
        return 1
    fi
    publish_state[published]=yes
    if ! gm_repo_state_commit_locked "$repo" publish_state; then
        gm_repo_export_remove_locked "$repo" || return $?
        return 1
    fi
    GM_REPO_RESULT=SUCCESS
    return 0
}
