#!/usr/bin/env bash

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-mirror-recover.sh" || return 1
GM_GC_SOURCE=${BASH_SOURCE[0]}

gm_gc_stopped() {
    [[ -n ${GM_STOP_SCOPE-} || ${GM_LOCAL_FROZEN-} == yes || -e $RUN_ROOT/runtime/frozen || -L $RUN_ROOT/runtime/frozen || -e $RUN_ROOT/runtime/stopped ]]
}

gm_gc_unsafe_locked() {
    local repo=$1
    gm_repo_export_remove_locked "$repo" || true
    gm_request_stop instance gc_state_failed
    gm_task_freeze || true
    return 1
}

gm_gc_precheck() {
    local dir=$1 output=$2 listing node
    local -n precheck=$output
    precheck=([reason]=none)
    gm_validate_path "$dir" || { precheck[reason]=environment; return 1; }
    listing=$(busybox find "$dir" \( -name '*.lock' -o -name gc.pid -o -name gc.log \) -print) || { precheck[reason]=environment; return 1; }
    if [[ -n $listing ]]; then precheck[reason]=manual_intervention; return 1; fi
    for node in "$dir" "$dir/objects" "$dir/objects/pack"; do
        [[ -d $node && -w $node ]] || { precheck[reason]=environment; return 1; }
    done
    return 0
}

gm_gc_mark_recovery_locked() {
    local repo=$1
    local -A failed_repo=()
    gm_repo_export_remove_locked "$repo" || return 1
    gm_repo_state_read "$repo" failed_repo || return 1
    failed_repo[health]=recovery_required failed_repo[message]=recovery_required failed_repo[published]=no
    failed_repo[observed]=error
    gm_repo_state_commit_locked "$repo" failed_repo
}

gm_gc_environment_probe() {
    local dir=$1 node probe status
    for node in "$dir" "$dir/objects" "$dir/objects/pack" "$dir/refs"; do
        gm_validate_path "$node" || return 1
        probe=$(mktemp "$node/.gc-probe.XXXXXXXX") || return 1
        status=0
        printf 'git-mirror write probe\n' > "$probe" && gm_state_flush "$probe" && gm_state_flush "$node" || status=1
        rm -f -- "$probe" || return 1
        gm_state_flush "$node" || return 1
        (( status == 0 )) || return 1
    done
    return 0
}

gm_gc_recover_locked() {
    local repo=$1 output=$2 verify_reason=${3:-yes} acknowledged=${4-} now status=0 index config= eligible=no
    local -n recovered=$output
    local -A recovery_gc=() recovery_task=() recovered_repo=() conditions=() replacement=()
    recovered=([result]=BLOCKED [reason]=check_failed)
    [[ -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} ]] || return 1
    gm_repo_config_identity "$repo" >/dev/null || return 1
    gm_gc_state_read "$repo" recovery_gc || return 1
    if gm_gc_stopped; then recovered[result]=STOPPED; return 1; fi
    [[ ! -e $RUN_ROOT/runtime/task && ! -L $RUN_ROOT/runtime/task ]] || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    if [[ -n $acknowledged ]]; then
        [[ $acknowledged =~ ^[a-f0-9-]{36}$ && $acknowledged == "${recovery_gc[operation_id]}" && ${recovery_gc[write_blocked]} == yes ]] || return 1
    fi
    if [[ ${recovery_gc[last_result]} == BLOCKED && ${recovery_gc[reason]} == manual_intervention ]]; then
        if ! gm_gc_precheck "$RUN_ROOT/repos/$repo.git" conditions; then
            recovered[reason]=${recovery_gc[reason]}
            return 0
        fi
    fi
    now=$(date +%s) || return 1
    if [[ ${recovery_gc[not_before]} == 0 && ( ${recovery_gc[status]} == running || ${recovery_gc[last_result]} == UNKNOWN || ${recovery_gc[last_result]} == INTERRUPTED ) ]]; then
        gm_gc_retry recovery_gc "$now" || return 1
    fi
    recovery_gc[write_blocked]=yes recovery_gc[status]=blocked
    if [[ ${recovery_gc[reason]} == running || ${recovery_gc[reason]} == none ]]; then recovery_gc[reason]=unknown; fi
    gm_gc_mark_recovery_locked "$repo" && gm_gc_state_commit_locked "$repo" recovery_gc || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    for index in "${!GM_REPOS[@]}"; do
        if [[ ${GM_REPOS[$index]} == "$repo" ]]; then
            config=$repo
            if [[ -n ${GM_BRANCHES[$index]} ]]; then config+=" ${GM_BRANCHES[$index]}"; fi
            break
        fi
    done
    gm_task_run_locked "$repo" check recovery_task bash -c '
        source "$1/lib/repository-recovery.sh" || exit 1
        gm_parse_repos "$3" "" || exit 1
        declare -A checked=()
        gm_repo_check_locked "$2" "$RUN_ROOT/repos/$2.git" checked
    ' _ "$INSTALL_ROOT" "$repo" "$config" || status=$?
    gm_task_finish_locked recovery_task retain || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    if (( status != 0 )) || [[ ${recovery_task[result]} != SUCCESS ]] || gm_gc_stopped; then
        gm_gc_mark_recovery_locked "$repo" || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
        recovered[result]=RECOVERY_REQUIRED
        return 1
    fi
    gm_repo_state_read "$repo" recovered_repo || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    if [[ ${recovered_repo[health]} == corrupt ]]; then
        recovery_gc[reason]=rebuild_pending
        recovered[result]=RECOVERY_REQUIRED recovered[reason]=rebuild_pending
    elif [[ ${recovered_repo[health]} == healthy ]]; then
        case ${recovery_gc[reason]} in
            environment|manual_intervention) eligible=yes ;;
            interrupted|unknown|state_failed|check_failed)
                if [[ -n $acknowledged ]]; then eligible=yes; fi ;;
            rebuild_pending)
                if gm_repo_replacement_read "$repo" replacement &&
                    [[ ${replacement[phase]} == published || ${replacement[phase]} == cleanup_complete ]] &&
                    [[ ${replacement[new_identity]} != "${replacement[old_identity]}" && ${replacement[new_identity]} == "${recovered_repo[checked_identity]}" && ${replacement[generation]} == "${recovered_repo[generation]}" && ${replacement[config]} == "${recovered_repo[checked_config]}" ]]; then
                    eligible=yes
                fi ;;
        esac
        if [[ $verify_reason == yes && $eligible == yes ]]; then
            if gm_gc_precheck "$RUN_ROOT/repos/$repo.git" conditions && gm_gc_environment_probe "$RUN_ROOT/repos/$repo.git" && ! gm_gc_stopped; then
                recovery_gc[write_blocked]=no recovery_gc[reason]=none recovery_gc[status]=retry_wait
            fi
        fi
        gm_repo_publish_locked "$repo" "${recovered_repo[generation]}" && gm_publish_short_links "$RUN_ROOT" "$repo" || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
        recovery_gc[generation]=${recovered_repo[generation]} recovery_gc[identity]=${recovered_repo[checked_identity]}
        recovered[result]=BLOCKED recovered[reason]=${recovery_gc[reason]}
        if [[ ${recovery_gc[write_blocked]} == no ]]; then recovered[result]=NOT_DUE; fi
    else
        recovery_gc[reason]=check_failed
        recovered[result]=RECOVERY_REQUIRED recovered[reason]=check_failed
    fi
    gm_gc_state_commit_locked "$repo" recovery_gc || { recovered[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    return 0
}

gm_gc_one_locked() {
    local repo=$1 now=$2 output=$3 dir=$RUN_ROOT/repos/$1.git boot identity config completed status=0 interrupted=0 diagnostic
    local -n gc_out=$output
    local -A execution=() repo_state=() gc_task=() conditions=() previous=()
    gc_out=([result]=BLOCKED [reason]=check_failed)
    [[ -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} ]] || return 1
    gm_validate_repo_name "$repo" && gm_gc_valid_epoch "$now" || return 1
    config=$(gm_repo_config_identity "$repo") || return 1
    if gm_gc_stopped; then gc_out[result]=STOPPED; return 1; fi
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    [[ $boot == "${GM_BOOT_GENERATION-}" ]] && gm_match_record "$RUN_ROOT/runtime/checks-complete" "$boot" || return 1
    [[ ! -e $RUN_ROOT/runtime/task && ! -L $RUN_ROOT/runtime/task ]] || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    gm_repo_state_read "$repo" repo_state && gm_gc_state_read "$repo" execution || return 1
    execution[schedule_timezone]=${TZ:-UTC}
    if [[ -n ${4-} ]]; then
        gm_gc_recover_locked "$repo" "$output" yes "$4" || return 1
        [[ ${gc_out[result]} == NOT_DUE ]]
        return $?
    fi
    if [[ ${execution[status]} == running || ${repo_state[health]-} == recovery_required || ${repo_state[message]} == recovery_required ]]; then
        gm_gc_recover_locked "$repo" "$output" || return 1
        return 1
    fi
    gm_validate_path "$dir" || return 1
    identity=$(stat -c '%d-%i' -- "$dir") || return 1
    [[ ${repo_state[health]-} == healthy && ${repo_state[desired]} == present && ${repo_state[checked_boot]-} == "$boot" && ${repo_state[checked_generation]-} == "${repo_state[generation]}" && ${repo_state[checked_config]-} == "$config" && ${repo_state[checked_identity]-} == "$identity" ]] || return 1
    [[ ${execution[generation]} == "${repo_state[generation]}" && ${execution[identity]} == "$identity" ]] || return 1
    if [[ ${execution[write_blocked]} == yes ]]; then
        gm_gc_recover_locked "$repo" "$output" || return 1
        [[ ${gc_out[result]} == NOT_DUE ]]
        return $?
    fi
    if ! gm_gc_due execution "$now"; then gc_out[result]=NOT_DUE gc_out[reason]=none; return 0; fi
    if ! gm_gc_precheck "$dir" conditions; then
        execution[status]=blocked execution[write_blocked]=yes execution[last_result]=BLOCKED execution[reason]=${conditions[reason]}
        gc_out[reason]=${conditions[reason]}
        gm_gc_state_commit_locked "$repo" execution || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; }
        return 1
    fi
    for config in "${!execution[@]}"; do previous[$config]=${execution[$config]}; done
    diagnostic=$(mktemp "$RUN_ROOT/logs/gc.XXXXXXXX") || return 1
    execution[log]=${diagnostic##*/}
    execution[status]=running execution[last_result]=UNKNOWN execution[reason]=running
    execution[last_attempt_at]=$now execution[generation]=${repo_state[generation]} execution[identity]=$identity
    execution[operation_id]=$(cat /proc/sys/kernel/random/uuid) || return 1
    gm_gc_state_commit_locked "$repo" execution || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    gc_task[requested_operation_id]=${execution[operation_id]}
    gm_task_run_locked "$repo" gc gc_task env LC_ALL=C git -c gc.autoDetach=false --git-dir="$dir" gc --auto >"$diagnostic" 2>&1 || status=$?
    if [[ -z ${gc_task[wait_pid]-} ]]; then
        if [[ $status == 75 ]]; then gc_out[result]=BUSY; else gc_out[result]=${gc_task[result]}; fi
        gm_gc_state_commit_locked "$repo" previous || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
        if [[ $status == 75 ]]; then return 75; fi
        return 1
    fi
    gm_task_finish_locked gc_task retain || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    completed=$(date +%s) || { gm_gc_unsafe_locked "$repo"; return 1; }
    if [[ ${gc_task[result]} == SUCCESS ]] && (( status == 0 )); then
        if gm_state_flush "$diagnostic" && gm_gc_advance execution "$completed"; then
            execution[reason]=none
            if gm_gc_state_commit_locked "$repo" execution; then
                gc_out[result]=SUCCESS gc_out[reason]=none gc_out[operation_id]=${execution[operation_id]}
                return 0
            fi
        fi
        execution[last_success_at]=${previous[last_success_at]} execution[next_due_date]=${previous[next_due_date]}
        execution[last_result]=UNKNOWN execution[reason]=state_failed execution[write_blocked]=yes
        gm_gc_retry execution "$completed" || true
        gm_gc_mark_recovery_locked "$repo" || true
        gm_gc_state_commit_locked "$repo" execution || true
        gc_out[result]=UNSAFE gc_out[reason]=state_failed
        gm_gc_unsafe_locked "$repo"
        return 1
    fi
    execution[last_result]=RECOVERY_REQUIRED execution[reason]=unknown execution[write_blocked]=yes
    if [[ ${gc_task[result]} == INTERRUPTED || ${gc_task[raw_status]-} == 130 || ${gc_task[raw_status]-} == 143 ]]; then
        execution[last_result]=INTERRUPTED execution[reason]=interrupted interrupted=143
        if [[ ${GM_GC_SIGNAL-} == INT || ${gc_task[raw_status]-} == 130 ]]; then interrupted=130; fi
    elif grep -Eq 'No space left on device|Permission denied|Input/output error' "$diagnostic"; then
        execution[reason]=environment
    fi
    gm_gc_retry execution "$completed" && gm_gc_mark_recovery_locked "$repo" && gm_gc_state_commit_locked "$repo" execution && gm_state_flush "$diagnostic" || { gc_out[result]=UNSAFE; gm_gc_unsafe_locked "$repo"; return 1; }
    gc_out[result]=${execution[last_result]} gc_out[reason]=${execution[reason]}
    if ! gm_gc_stopped; then
        gm_gc_recover_locked "$repo" "$output" no || return 1
    fi
    if (( interrupted != 0 )); then return "$interrupted"; fi
    return 1
}

gm_gc_run_one() {
    local repo=$1 status=0 now
    local -A result=()
    trap 'GM_GC_SIGNAL=TERM; gm_request_stop task TERM' TERM
    trap 'GM_GC_SIGNAL=INT; gm_request_stop task INT' INT
    gm_begin_operation sync || return $?
    now=$(date +%s) || return 1
    gm_gc_one_locked "$repo" "$now" result "${2-}" || status=$?
    printf 'repo=%s result=%s reason=%s\n' "$repo" "${result[result]}" "${result[reason]}"
    [[ ${result[result]} != UNSAFE ]] || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    return "$status"
}

gm_gc_main() {
    local selected= repo result=0 status install acknowledged=
    case $# in
        0) ;;
        2) [[ $1 == --repo ]] || return 1; selected=$2; gm_validate_repo_name "$selected" || return 1 ;;
        4)
            [[ $1 == --repo && $3 == --recover && $4 =~ ^[a-f0-9-]{36}$ ]] || return 1
            selected=$2 acknowledged=$4
            gm_validate_repo_name "$selected" || return 1 ;;
        *) return 1 ;;
    esac
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" && gm_startup_gate_validate || return 1
    if [[ -n $selected ]]; then gm_repo_config_identity "$selected" >/dev/null || return 1; fi
    for repo in "${GM_REPOS[@]}"; do
        [[ -z $selected || $selected == "$repo" ]] || continue
        status=0
        gm_gc_run_one "$repo" "$acknowledged" || status=$?
        case $status in 0) ;; 75|130|143) return "$status" ;; *) result=1 ;; esac
        if gm_gc_stopped; then return 1; fi
    done
    return "$result"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -uo pipefail
    gm_gc_main "$@"
fi
