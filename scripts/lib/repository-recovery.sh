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
    local repo=$1 generation=$2 dir=$RUN_ROOT/repos/$1.git boot config identity marker status=0
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
    gm_repo_note_publication_locked "$repo" "$boot" || return 1
    if ! (umask 077; : > "$marker") || ! gm_state_flush "$marker" || ! gm_state_flush "$dir"; then
        gm_repo_export_remove_locked "$repo" || return $?
        return 1
    fi
    publish_state[published]=yes
    gm_repo_state_commit_locked "$repo" publish_state || status=$?
    if (( status != 0 )); then
        gm_repo_export_remove_locked "$repo" || return $?
        if (( status == 2 )); then
            GM_REPO_RESULT=UNSAFE
            gm_request_stop instance publish_indeterminate
            gm_task_freeze || true
        fi
        return "$status"
    fi
    GM_REPO_RESULT=SUCCESS
    return 0
}

gm_repo_note_publication_locked() {
    local repo=$1 boot=$2 file=$RUN_ROOT/runtime/published/$2/$1
    gm_state_directory_prepare "${file%/*}" || return 1
    gm_validate_file "$file" || return 1
    (umask 077; printf '%s\n' "$boot" > "$file") || return 1
    gm_state_flush "$file" && gm_state_flush "${file%/*}"
}

gm_repo_readers_drained() {
    local repo=$1 boot
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    [[ $boot == "${GM_BOOT_GENERATION-}" && $boot =~ ^[a-f0-9-]{36}$ ]] || return 1
    gm_validate_path "$RUN_ROOT/runtime/published/$boot/${repo%/*}" || return 1
    [[ ! -e $RUN_ROOT/runtime/published/$boot/$repo && ! -L $RUN_ROOT/runtime/published/$boot/$repo ]]
}

gm_repo_replacement_validate() {
    local -n entry=$1
    local key
    [[ ${#entry[@]} == 11 ]] || return 1
    for key in schema repo operation phase old_identity new_identity generation config boot published_boot reason; do
        gm_state_validate_value "${entry[$key]-}" || return 1
    done
    [[ ${entry[schema]} == 1 && ${entry[operation]} =~ ^[a-f0-9-]{36}$ ]] || return 1
    gm_state_repo_path "$RUN_ROOT" "${entry[repo]}" repos >/dev/null || return 1
    case ${entry[phase]} in detected|unpublished|old_isolated|candidate_building|candidate_verified|installed|published|cleanup_complete) ;; *) return 1 ;; esac
    [[ ${entry[old_identity]} =~ ^[0-9]+-[0-9]+$ && ${entry[new_identity]} =~ ^([0-9]+-[0-9]+|none)$ ]] || return 1
    [[ ${entry[generation]} =~ ^[0-9]+$ && ${entry[config]} =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ ${entry[boot]} =~ ^[a-f0-9-]{36}$ && ${entry[published_boot]} =~ ^([a-f0-9-]{36}|none)$ ]]
}

gm_repo_replacement_read() {
    local repo=$1 output=$2 file=$RUN_ROOT/state/replacements/$1.state line key
    local -n record=$output
    record=()
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    gm_validate_file "$file" read || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}
        case $key in schema|repo|operation|phase|old_identity|new_identity|generation|config|boot|published_boot|reason) ;; *) return 1 ;; esac
        [[ ! ${record[$key]+present} ]] || return 1
        record[$key]=${line#*=}
    done < "$file"
    gm_repo_replacement_validate "$output" || return 1
    [[ ${record[repo]} == "$repo" ]]
}

gm_repo_replacement_commit() {
    local repo=$1 input=$2 file=$RUN_ROOT/state/replacements/$1.state temporary key status=0
    local -n record=$input
    gm_repo_replacement_validate "$input" || return 1
    [[ ${record[repo]} == "$repo" ]] || return 1
    gm_state_directory_prepare "${file%/*}" || return 1
    gm_validate_file "$file" || return 1
    temporary=$(mktemp "${file%/*}/.replacement.XXXXXXXX") || return 1
    for key in schema repo operation phase old_identity new_identity generation config boot published_boot reason; do
        printf '%s=%s\n' "$key" "${record[$key]}" >> "$temporary" || status=1
    done
    if (( status == 0 )) && gm_state_flush "$temporary" && mv -f -- "$temporary" "$file"; then
        if ! gm_state_flush "${file%/*}"; then
            gm_request_stop instance replacement_indeterminate
            gm_task_freeze || true
            return 2
        fi
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

gm_repo_replace_phase() {
    local repo=$1 input=$2 phase=$3
    local -n phase_record=$input
    phase_record[phase]=$phase
    gm_repo_replacement_commit "$repo" "$input" || return $?
    [[ ${GM_REPLACE_TEST_STOP-} != "$phase" ]]
}

gm_repo_copy_validate() (
    local dir=$1 identity=$2 flush=${3-no} root_device node metadata listing
    gm_validate_path "$dir" read || return 1
    [[ $(stat -c '%d-%i' -- "$dir") == "$identity" ]] || return 1
    root_device=$(stat -c %d -- "$RUN_ROOT/repos") || return 1
    [[ $(stat -c %d -- "$dir") == "$root_device" ]] || return 1
    listing=$(mktemp "$RUN_ROOT/runtime/copy-scan.XXXXXXXX") || return 1
    trap 'rm -f -- "$listing"' EXIT
    find "$dir" -depth -print0 > "$listing" || return 1
    while IFS= read -r -d '' node; do
        [[ ! -L $node && -O $node ]] || return 1
        metadata=$(stat -c '%d %a %h' -- "$node") || return 1
        local device mode links
        read -r device mode links <<< "$metadata"
        [[ $device == "$root_device" ]] && (( (8#$mode & 0022) == 0 )) || return 1
        if [[ -f $node ]]; then [[ $links == 1 ]] || return 1
        elif [[ ! -d $node ]]; then return 1; fi
        if [[ $flush == yes ]]; then gm_state_flush "$node" || return 1; fi
    done < "$listing"
    [[ ! -e $dir/objects/info/alternates && ! -e $dir/objects/info/http-alternates ]]
)

gm_repo_validate_aliases_locked() {
    local repo=$1 index name link record actual target=$1.git
    local -A alias_journal=()
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    gm_validate_path "$RUN_ROOT/repos" read || return 1
    gm_validate_path "$RUN_ROOT/repos/${repo%/*}" read || return 1
    for index in "${!GM_LINK_TARGETS[@]}"; do
        [[ ${GM_LINK_TARGETS[$index]} == "$repo" ]] || continue
        name=${GM_LINK_NAMES[$index]}
        [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != *..* ]] || return 1
        link=$RUN_ROOT/repos/$name.git
        record=$RUN_ROOT/config/managed-links/$name.git
        if [[ ! -e $link && ! -L $link ]]; then
            [[ ! -e $record && ! -L $record ]] || return 1
            continue
        fi
        [[ -L $link && $(stat -c %u -- "$link") == "$EUID" ]] || return 1
        gm_validate_file "$record" read || return 1
        [[ $(<"$record") == "$(printf 'FORMAT=1\nTARGET=%s' "$target")" ]] || return 1
        actual=$(readlink -- "$link") || return 1
        [[ $actual == "$target" ]] || return 1
        if [[ -d $RUN_ROOT/repos/$target ]]; then
            gm_validate_managed_link "$RUN_ROOT" "$link" || return 1
        else
            gm_validate_path "$RUN_ROOT/repos/$target" || return 1
            gm_repo_replacement_read "$repo" alias_journal || return 1
            case ${alias_journal[phase]} in unpublished|old_isolated|candidate_building|candidate_verified) ;; *) return 1 ;; esac
            gm_repo_copy_validate "$RUN_ROOT/quarantine/${alias_journal[operation]}/repo.git" "${alias_journal[old_identity]}" || return 1
        fi
    done
    return 0
}

gm_repo_candidate_verify() {
    local repo=$1 dir=$2 branches=$3 identity=$4 refs head branch ref expected actual diagnostic
    local -a selected=()
    gm_repo_copy_validate "$dir" "$identity" || return 1
    [[ $(git --git-dir="$dir" rev-parse --is-bare-repository) == true ]] || return 1
    [[ ! -e $dir/git-daemon-export-ok ]] || return 1
    diagnostic=$(mktemp "$RUN_ROOT/logs/candidate-fsck.XXXXXXXX") || return 1
    LC_ALL=C git --git-dir="$dir" fsck --full > "$diagnostic" 2>&1 || return 1
    gm_state_flush "$diagnostic" || return 1
    refs=$(git --git-dir="$dir" for-each-ref --format='%(refname)') || return 1
    head=$(git --git-dir="$dir" symbolic-ref HEAD) || return 1
    [[ $head == refs/heads/* ]] || return 1
    if [[ -n $refs ]]; then git --git-dir="$dir" rev-parse --verify HEAD >/dev/null || return 1; fi
    actual=$(git --git-dir="$dir" config --get-all remote.origin.fetch) || return 1
    if [[ -z $branches ]]; then
        [[ $actual == '+refs/*:refs/*' && $(git --git-dir="$dir" config --get remote.origin.mirror) == true ]] || return 1
    else
        IFS=, read -r -a selected <<< "$branches"
        expected=
        for branch in "${selected[@]}"; do
            git --git-dir="$dir" show-ref --verify --quiet "refs/heads/$branch" || return 1
            expected+="+refs/heads/$branch:refs/heads/$branch"$'\n'
        done
        [[ $actual == "${expected%$'\n'}" && $head == "refs/heads/${selected[0]}" ]] || return 1
        [[ $(git --git-dir="$dir" config --get remote.origin.mirror) == false && $(git --git-dir="$dir" config --get remote.origin.tagOpt) == --no-tags ]] || return 1
        while IFS= read -r ref; do
            [[ ,$branches, == *,${ref#refs/heads/},* && $ref == refs/heads/* ]] || return 1
        done <<< "$refs"
    fi
    return 0
}

gm_repo_replay_locked() {
    local repo=$1 output=$2 dir=$RUN_ROOT/repos/$1.git old candidate identity
    local -n replay_result=$output
    local -A replay=()
    replay_result=([reason]=replay_blocked)
    [[ ${GM_LOCAL_FROZEN-} != yes && ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    gm_repo_replacement_read "$repo" replay || return 1
    [[ ${replay[config]} == "$(gm_repo_config_identity "$repo")" ]] || return 1
    old=$RUN_ROOT/quarantine/${replay[operation]}/repo.git
    candidate=$RUN_ROOT/staging/${replay[operation]}/repo.git
    for identity in "$dir" "$old" "$candidate"; do gm_validate_path "$identity" || return 1; done
    if [[ -d $old ]]; then gm_repo_copy_validate "$old" "${replay[old_identity]}" || return 1; fi
    if [[ -d $candidate ]]; then
        if [[ ${replay[phase]} == old_isolated && ${replay[new_identity]} == none ]]; then
            identity=$(stat -c '%d-%i' -- "$candidate") || return 1
            gm_repo_copy_validate "$candidate" "$identity" || return 1
            identity=$(find "$candidate" -mindepth 1 -print -quit) || return 1
            [[ -z $identity ]] || return 1
            replay[new_identity]=$(stat -c '%d-%i' -- "$candidate") || return 1
            gm_repo_replace_phase "$repo" replay candidate_building || return $?
        else
            gm_repo_copy_validate "$candidate" "${replay[new_identity]}" || return 1
        fi
    fi
    if [[ -d $dir ]]; then
        identity=$(stat -c '%d-%i' -- "$dir") || return 1
        if [[ $identity == "${replay[old_identity]}" ]]; then
            [[ ! -e $old && ( ${replay[phase]} == detected || ${replay[phase]} == unpublished ) ]] || return 1
        elif [[ $identity == "${replay[new_identity]}" ]]; then
            [[ ! -e $candidate ]] || return 1
            case ${replay[phase]} in candidate_verified|installed|published|cleanup_complete) ;; *) return 1 ;; esac
            gm_repo_copy_validate "$dir" "$identity" || return 1
            if [[ ${replay[phase]} == candidate_verified ]]; then
                gm_state_flush "${dir%/*}" && gm_state_flush "${candidate%/*}" || return 1
                gm_repo_replace_phase "$repo" replay installed || return $?
            fi
        else return 1; fi
    else
        [[ -d $old ]] || return 1
        case ${replay[phase]} in
            unpublished)
                gm_state_flush "${old%/*}" && gm_state_flush "${dir%/*}" || return 1
                gm_repo_replace_phase "$repo" replay old_isolated || return $? ;;
            old_isolated|candidate_building|candidate_verified) ;;
            *) return 1 ;;
        esac
    fi
    [[ -d $old || ${replay[phase]} == detected || ${replay[phase]} == unpublished || ${replay[phase]} == published || ${replay[phase]} == cleanup_complete ]] || return 1
    gm_repo_validate_aliases_locked "$repo" || return 1
    replay_result[reason]=replayed
    return 0
}

gm_repo_cleanup_old_locked() {
    local repo=$1 dir=$RUN_ROOT/repos/$1.git old boot
    local -A cleanup=() current=()
    [[ ${GM_LOCAL_FROZEN-} != yes && ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    gm_repo_replacement_read "$repo" cleanup || return 1
    [[ ${cleanup[phase]} == published || ${cleanup[phase]} == cleanup_complete ]] || return 1
    [[ ${cleanup[published_boot]} == "${GM_BOOT_GENERATION-}" ]] || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    [[ $boot == "${GM_BOOT_GENERATION-}" ]] || return 1
    gm_repo_state_read "$repo" current || return 1
    [[ ${current[health]-} == healthy && ${current[published]} == yes && ${current[generation]} == "${cleanup[generation]}" ]] || return 1
    [[ ${current[checked_boot]-} == "${GM_BOOT_GENERATION-}" && ${current[checked_identity]-} == "${cleanup[new_identity]}" && ${current[checked_config]-} == "$(gm_repo_config_identity "$repo")" ]] || return 1
    gm_repo_copy_validate "$dir" "${cleanup[new_identity]}" || return 1
    gm_validate_file "$dir/git-daemon-export-ok" read || return 1
    gm_repo_validate_aliases_locked "$repo" || return 1
    old=$RUN_ROOT/quarantine/${cleanup[operation]}/repo.git
    gm_validate_path "$old" || return 1
    if [[ -e $old ]]; then
        gm_repo_copy_validate "$old" "${cleanup[old_identity]}" || return 1
        [[ ${cleanup[old_identity]} != "${cleanup[new_identity]}" ]] || return 1
        if ! rm -rf -- "$old"; then
            cleanup[reason]=cleanup_pending
            gm_repo_replacement_commit "$repo" cleanup || return $?
            return 1
        fi
    fi
    gm_state_flush "${old%/*}" || return 1
    cleanup[reason]=complete
    gm_repo_replace_phase "$repo" cleanup cleanup_complete
}

gm_repo_rebuild_locked() {
    local repo=$1 branches=$2 output=$3 dir=$RUN_ROOT/repos/$1.git old candidate operation identity index found=no
    local -n rebuild_result=$output
    local -A replacement=() current=() checked=()
    rebuild_result=([reason]=replacement_blocked)
    [[ ${GM_LOCAL_FROZEN-} != yes && ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    for index in "${!GM_REPOS[@]}"; do
        if [[ ${GM_REPOS[$index]} == "$repo" && ${GM_BRANCHES[$index]} == "$branches" ]]; then found=yes; fi
    done
    [[ $found == yes ]] || return 1
    gm_repo_state_read "$repo" current || return 1
    if [[ -e $RUN_ROOT/state/replacements/$repo.state || -L $RUN_ROOT/state/replacements/$repo.state ]]; then
        gm_repo_replay_locked "$repo" "$output" || return $?
        gm_repo_replacement_read "$repo" replacement || return 1
    fi
    if [[ ${#replacement[@]} == 0 || ( ${replacement[phase]} == cleanup_complete && ${current[health]-} == corrupt ) ]]; then
        [[ ${current[health]-} == corrupt ]] || return 1
        gm_validate_path "$dir" read || return 1
        operation=$(cat /proc/sys/kernel/random/uuid) || return 1
        replacement=([schema]=1 [repo]="$repo" [operation]="$operation" [phase]=detected [old_identity]="$(stat -c '%d-%i' -- "$dir")" [new_identity]=none [generation]="$((10#${current[generation]}+1))" [config]="$(gm_repo_config_identity "$repo")" [boot]="${GM_BOOT_GENERATION-}" [published_boot]=none [reason]=recovering)
        gm_repo_replace_phase "$repo" replacement detected || return $?
    fi
    old=$RUN_ROOT/quarantine/${replacement[operation]}/repo.git
    candidate=$RUN_ROOT/staging/${replacement[operation]}/repo.git
    if [[ ${replacement[phase]} == detected ]]; then
        gm_repo_unpublish_locked "$repo" || return $?
        gm_repo_replace_phase "$repo" replacement unpublished || return $?
    fi
    if [[ ${replacement[phase]} == unpublished ]]; then
        if ! gm_repo_readers_drained "$repo"; then
            replacement[reason]=readers_unknown
            rebuild_result[reason]=readers_unknown
            gm_repo_replacement_commit "$repo" replacement || return $?
            return 1
        fi
        gm_repo_copy_validate "$dir" "${replacement[old_identity]}" || return 1
        gm_repo_validate_aliases_locked "$repo" || return 1
        gm_state_directory_prepare "${old%/*}" || return 1
        [[ ! -e $old && ! -L $old && $(stat -c %d -- "${old%/*}") == "$(stat -c %d -- "$dir")" ]] || return 1
        mv -- "$dir" "$old" || return 1
        gm_state_flush "${dir%/*}" && gm_state_flush "${old%/*}" || return 1
        gm_repo_replace_phase "$repo" replacement old_isolated || return $?
    fi
    if [[ ${replacement[phase]} == old_isolated ]]; then
        gm_state_directory_prepare "${candidate%/*}" || return 1
        [[ ! -e $candidate && ! -L $candidate ]] || return 1
        (umask 077; mkdir -- "$candidate") || return 1
        gm_state_flush "${candidate%/*}" || return 1
        replacement[new_identity]=$(stat -c '%d-%i' -- "$candidate") || return 1
        gm_repo_replace_phase "$repo" replacement candidate_building || return $?
    fi
    if [[ ${replacement[phase]} == candidate_building ]]; then
        gm_repo_copy_validate "$candidate" "${replacement[new_identity]}" || return 1
        gm_repo_build_candidate_locked "$repo" "$branches" "$candidate" || return 1
        gm_repo_candidate_verify "$repo" "$candidate" "$branches" "${replacement[new_identity]}" || return 1
        gm_repo_copy_validate "$candidate" "${replacement[new_identity]}" yes || return 1
        gm_repo_replace_phase "$repo" replacement candidate_verified || return $?
    fi
    if [[ ${replacement[phase]} == candidate_verified ]]; then
        gm_repo_candidate_verify "$repo" "$candidate" "$branches" "${replacement[new_identity]}" || return 1
        gm_validate_path "$dir" || return 1
        [[ ! -e $dir && ! -L $dir ]] || return 1
        mv -- "$candidate" "$dir" || return 1
        gm_state_flush "${candidate%/*}" && gm_state_flush "${dir%/*}" || return 1
        gm_repo_replace_phase "$repo" replacement installed || return $?
    fi
    case ${replacement[phase]} in
        installed|published|cleanup_complete)
            gm_repo_copy_validate "$dir" "${replacement[new_identity]}" || return 1
            current[generation]=${replacement[generation]}
            current[published]=no
            current[message]=recovery_required
            gm_repo_state_commit_locked "$repo" current || return 1
            gm_repo_check_locked "$repo" "$dir" checked || return $?
            [[ ${checked[health]} == healthy ]] || return 1
            gm_repo_candidate_verify "$repo" "$dir" "$branches" "${replacement[new_identity]}" || return 1
            gm_repo_validate_aliases_locked "$repo" || return 1
            gm_repo_publish_locked "$repo" "${replacement[generation]}" || return $?
            if ! gm_publish_short_links "$RUN_ROOT" "$repo"; then gm_repo_unpublish_locked "$repo"; return 1; fi
            replacement[published_boot]=$GM_BOOT_GENERATION
            gm_repo_replace_phase "$repo" replacement published || return $? ;;
        *) return 1 ;;
    esac
    gm_repo_cleanup_old_locked "$repo" || return $?
    rebuild_result[reason]=complete
    return 0
}
