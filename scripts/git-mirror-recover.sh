#!/usr/bin/env bash

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-mirror-sync.sh" || return 1
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/repository-recovery.sh" || return 1

gm_startup_gate_validate() {
    local boot pid start namespace extra current status=0
    local -A owner=()
    gm_validate_file "$RUN_ROOT/runtime/publication-gate" read || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    read -r boot pid start namespace extra < "$RUN_ROOT/runtime/publication-gate" || return 1
    [[ -z $extra && $boot =~ ^[a-f0-9-]{36}$ && $start =~ ^[0-9]+$ ]] || return 1
    IFS= read -r current < "$RUN_ROOT/runtime/generation" || return 1
    [[ $current == "$boot" ]] || return 1
    gm_process_identity "$pid" owner || return 1
    [[ ${owner[start]} == "$start" && ${owner[state]} != Z ]] || return 1
    [[ $(readlink "/proc/$pid/ns/pid") == "$namespace" && $(readlink /proc/self/ns/pid) == "$namespace" ]] || return 1
    (gm_lock_release container; gm_container_lease_acquire) >/dev/null 2>&1 || status=$?
    [[ $status == 75 ]] || return 1
    GM_BOOT_GENERATION=$boot
    export GM_BOOT_GENERATION
}

# 启动扫描仅凭当前配置、管理记录与替换副本证据接受悬空别名。
gm_startup_validate_link() {
    local path=$1 index
    if [[ -e $path ]]; then gm_validate_managed_link "$RUN_ROOT" "$path"; return $?; fi
    for index in "${!GM_LINK_TARGETS[@]}"; do
        if [[ $path == "$RUN_ROOT/repos/${GM_LINK_NAMES[$index]}.git" ]]; then
            gm_repo_validate_aliases_locked "${GM_LINK_TARGETS[$index]}"
            return $?
        fi
    done
    return 1
}

gm_startup_prepare() {
    [[ -z ${GM_STOP_SCOPE-} && ${GM_LOCAL_FROZEN-} != yes ]] || return 1
    [[ ${GM_CONTAINER_OWNER-} == "$BASHPID" && -n ${GM_LOCK_FDS[container]-} && -z ${GM_BOOT_GENERATION-} ]] || return 1
    local path listing repo status=0
    local -A owner=() replay_outcome=()
    gm_lock_acquire instance exclusive || return $?
    gm_lock_acquire sync exclusive || { gm_lock_release instance; return 1; }
    if [[ -e $RUN_ROOT/runtime/task ]]; then
        local previous_boot previous_pid previous_start previous_namespace extra
        gm_validate_file "$RUN_ROOT/runtime/publication-gate" read || return 1
        read -r previous_boot previous_pid previous_start previous_namespace extra < "$RUN_ROOT/runtime/publication-gate" || return 1
        [[ -z $extra && $previous_namespace == pid:\[*\] && $previous_namespace != "$(readlink /proc/self/ns/pid)" ]] || return 1
        gm_validate_file "$RUN_ROOT/runtime/task" && rm -- "$RUN_ROOT/runtime/task" && gm_state_flush "$RUN_ROOT/runtime" || return 1
    fi
    for path in publication-gate checks-complete; do
        gm_validate_file "$RUN_ROOT/runtime/$path" && rm -f -- "$RUN_ROOT/runtime/$path" || return 1
    done
    listing=$(mktemp "$RUN_ROOT/runtime/.exports.XXXXXXXX") || return 1
    if ! busybox find "$RUN_ROOT/repos" \( -name git-daemon-export-ok -o -type l \) -print0 > "$listing"; then rm -f "$listing"; return 1; fi
    while IFS= read -r -d '' path; do
        if [[ -L $path ]]; then
            gm_startup_validate_link "$path" || { status=1; break; }
        else
            gm_validate_file "$path" && rm -f -- "$path" && gm_state_flush "${path%/*}" || { status=1; break; }
        fi
    done < "$listing"
    rm -f -- "$listing" || return 1
    (( status == 0 )) || return 1
    gm_container_begin || return 1
    for repo in "${GM_REPOS[@]}"; do
        [[ -z ${GM_STOP_SCOPE-} && ${GM_LOCAL_FROZEN-} != yes ]] || return 1
        if [[ -e $RUN_ROOT/state/replacements/$repo.state || -L $RUN_ROOT/state/replacements/$repo.state ]]; then
            gm_repo_replay_locked "$repo" replay_outcome || return 1
        fi
    done
    gm_process_identity "$BASHPID" owner || return 1
    [[ -z ${GM_STOP_SCOPE-} && ${GM_LOCAL_FROZEN-} != yes ]] || return 1
    gm_lifecycle_record "$RUN_ROOT/runtime/publication-gate" "$GM_BOOT_GENERATION $BASHPID ${owner[start]} $(readlink /proc/self/ns/pid)" || return 1
    if [[ -n ${GM_STOP_SCOPE-} || ${GM_LOCAL_FROZEN-} == yes ]]; then
        rm -f -- "$RUN_ROOT/runtime/publication-gate" || return 1
        gm_task_freeze || return 1
        return 1
    fi
    gm_lock_release sync && gm_lock_release instance
}

gm_startup_check_one() {
    local repo=$1 dir=$RUN_ROOT/repos/$1.git
    local -A state=() checked=()
    [[ -d $dir ]] || return 0
    if [[ ! -e $RUN_ROOT/state/repos/$repo.state ]]; then
        state=([schema]=1 [repo]="$repo" [generation]=1 [desired]=present [observed]=ready [published]=no [message]=unchecked)
        gm_repo_state_commit_locked "$repo" state || return 1
    fi
    gm_repo_check_locked "$repo" "$dir" checked || return $?
    [[ ${checked[health]} == healthy ]] || return 0
    gm_repo_state_read "$repo" state || return 1
    gm_repo_publish_locked "$repo" "${state[generation]}" || return $?
    if ! gm_publish_short_links "$RUN_ROOT" "$repo"; then
        gm_repo_unpublish_locked "$repo" || return 2
        return 1
    fi
    return 0
}

gm_startup_run_repo() {
    local repo=$1 operation=${2-check} status=0
    local -A startup_task=()
    gm_begin_operation sync || return $?
    gm_task_run_locked "$repo" "$operation" startup_task bash "$INSTALL_ROOT/git-mirror-recover.sh" --worker "$repo" "$operation" "${GM_LOCK_FDS[instance]}" "${GM_LOCK_FDS[sync]}" || status=$?
    gm_task_finish_locked startup_task retain || return 2
    [[ ${startup_task[result]} != UNSAFE ]] || return 2
    if [[ ${startup_task[result]} == RECOVERY_REQUIRED || ${startup_task[result]} == INTERRUPTED ]]; then
        if [[ -d $RUN_ROOT/repos/$repo.git ]]; then
            gm_repo_export_remove_locked "$repo" || { gm_task_freeze; return 2; }
        fi
        if [[ ${startup_task[raw_status]-} == 2 ]]; then gm_task_freeze; return 2; fi
    fi
    gm_lock_release sync && gm_lock_release instance || return 2
    [[ ! -e $RUN_ROOT/runtime/frozen ]] || return 2
    [[ -z ${GM_STOP_SCOPE-} ]] || return 1
    if (( status != 0 )); then return "$status"; fi
    [[ ${startup_task[result]} == SUCCESS ]]
}

gm_startup_checks() {
    local repo status
    gm_startup_gate_validate || return 1
    for repo in "${GM_REPOS[@]}"; do
        [[ -z ${GM_STOP_SCOPE-} ]] || return 1
        status=0
        gm_startup_run_repo "$repo" check || status=$?
        if (( status != 0 && status != 1 )); then return "$status"; fi
        [[ -z ${GM_STOP_SCOPE-} && ! -e $RUN_ROOT/runtime/frozen ]] || return 1
    done
    gm_lifecycle_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION"
}

gm_startup_network_one() {
    local repo=$1 index branches= dir=$RUN_ROOT/repos/$1.git status=0
    local -A current=() outcome=()
    gm_match_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION" || return 1
    for index in "${!GM_REPOS[@]}"; do
        if [[ ${GM_REPOS[$index]} == "$repo" ]]; then branches=${GM_BRANCHES[$index]}; break; fi
    done
    LOG_FILE=$RUN_ROOT/logs/sync.log
    gm_load_sync_credentials "$RUN_ROOT" || return 1
    clear_proxy_environment && prepare_credentials && load_resolve_args "$RUN_ROOT/hosts/github-hosts.snapshot" && build_transport_sequence || return 1
    if [[ ! -e $dir && ! -e $RUN_ROOT/state/replacements/$repo.state ]]; then
        gm_validate_path "$dir" || return 1
        (umask 077; mkdir -p "${dir%/*}") || return 1
        git init -q --bare "$dir" || return 1
        git --git-dir="$dir" remote add origin "https://github.com/$repo.git" || return 1
        gm_startup_check_one "$repo" || return $?
    fi
    gm_repo_state_read "$repo" current || return 1
    if [[ ${current[health]-} == corrupt || -e $RUN_ROOT/state/replacements/$repo.state ]]; then
        gm_repo_rebuild_locked "$repo" "$branches" outcome || status=$?
    elif [[ ${current[health]-} == healthy ]]; then
        gm_sync_one_locked "$repo" "$branches" outcome || status=$?
        if (( status == 1 )) && [[ ${outcome[transport_only]-} != yes ]]; then
            gm_startup_check_one "$repo" || status=$?
        fi
    fi
    if (( status == 2 )) || [[ -e $RUN_ROOT/runtime/frozen ]]; then return 2; fi
    return 0
}

gm_startup_network() {
    local repo status
    gm_startup_gate_validate || return 1
    gm_match_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION" || return 1
    for repo in "${GM_REPOS[@]}"; do
        [[ -z ${GM_STOP_SCOPE-} ]] || return 1
        status=0
        gm_startup_run_repo "$repo" recovery || status=$?
        if (( status == 2 )) || [[ -n ${GM_STOP_SCOPE-} ]]; then return 1; fi
    done
    return 0
}

gm_recover_main() {
    case "$#:${1-}" in
        1:--startup)
            [[ ${GM_CONTAINER_OWNER-} == "$BASHPID" && -n ${GM_LOCK_FDS[container]-} ]] || { gm_error '恢复仅允许有效容器启动上下文调用'; return 1; }
            gm_startup_checks ;;
        5:--worker)
            local repo=$2 operation=$3 instance=$4 sync=$5 boot registered_repo registered_operation pid start pgid session operation_id
            local -A identity=()
            gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
            gm_startup_gate_validate || return 1
            gm_validate_repo_name "$repo" || return 1
            [[ $instance =~ ^[0-9]+$ && $sync =~ ^[0-9]+$ ]] || return 1
            [[ $(readlink "/proc/$BASHPID/fd/$instance") == "$RUN_ROOT/runtime/instance.lock" && $(readlink "/proc/$BASHPID/fd/$sync") == "$RUN_ROOT/runtime/sync.lock" ]] || return 1
            read -r registered_repo registered_operation boot pid start pgid session operation_id < "$RUN_ROOT/runtime/task" || return 1
            gm_process_identity "$BASHPID" identity || return 1
            [[ $repo == "$registered_repo" && $operation == "$registered_operation" && $boot == "$GM_BOOT_GENERATION" && ${identity[pgid]} == "$pgid" && ${identity[session]} == "$session" ]] || return 1
            GM_LOCK_FDS[instance]=$instance GM_LOCK_FDS[sync]=$sync
            case "$operation" in
                check) gm_startup_check_one "$repo" ;;
                recovery) gm_startup_network_one "$repo" ;;
                *) return 2 ;;
            esac ;;
        *) gm_error '用法：git-mirror-recover.sh --startup'; return 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    gm_recover_main "$@"
fi
