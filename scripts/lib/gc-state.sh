#!/usr/bin/env bash

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/gc-schedule.sh" || return 1

gm_gc_state_validate() {
    local -n record=$1
    local key
    case ${record[schema]-} in
        1) [[ ${#record[@]} == 17 ]] || return 1 ;;
        2)
            [[ ${#record[@]} == 19 ]] || return 1
            if [[ ${record[failed_identity]-} == none ]]; then
                [[ ${record[failed_generation]-} == none ]] || return 1
            else
                [[ ${record[failed_identity]-} =~ ^[0-9]+-[0-9]+$ && ${record[failed_generation]-} =~ ^[0-9]+$ ]] || return 1
            fi ;;
        *) return 1 ;;
    esac
    for key in schema repo anchor_date schedule_timezone next_due_date not_before last_attempt_at last_success_at last_result operation_id status generation identity reason write_blocked resumed_boot log; do
        [[ ${record[$key]+present} ]] || return 1
    done
    [[ ${record[generation]} =~ ^[0-9]+$ && ${record[identity]} =~ ^[0-9]+-[0-9]+$ ]] || return 1
    gm_validate_repo_name "${record[repo]}" || return 1
    gm_gc_at_two "${record[anchor_date]}" "${record[schedule_timezone]}" >/dev/null || return 1
    gm_gc_at_two "${record[next_due_date]}" "${record[schedule_timezone]}" >/dev/null || return 1
    for key in not_before last_attempt_at last_success_at; do gm_gc_valid_epoch "${record[$key]}" || return 1; done
    [[ ${record[operation_id]} == none || ${record[operation_id]} =~ ^[a-f0-9-]{36}$ ]] || return 1
    [[ ${record[resumed_boot]} == none || ${record[resumed_boot]} =~ ^[a-f0-9-]{36}$ ]] || return 1
    [[ ${record[write_blocked]} == yes || ${record[write_blocked]} == no ]] || return 1
    case ${record[status]} in scheduled|pending|running|retry_wait|blocked) ;; *) return 1 ;; esac
    case ${record[last_result]} in NONE|SUCCESS|NOT_DUE|BUSY|RECOVERY_REQUIRED|BLOCKED|INTERRUPTED|STOPPED|UNSAFE|UNKNOWN) ;; *) return 1 ;; esac
    case ${record[reason]} in none|running|manual_intervention|environment|unknown|rebuild_pending|check_failed|state_failed|interrupted) ;; *) return 1 ;; esac
    [[ ${record[log]} == none || ${record[log]} =~ ^gc\.[A-Za-z0-9]+$ ]]
}

gm_gc_state_read() {
    local repo=$1 output=$2 file=$RUN_ROOT/state/gc/$1.state line key
    local -n loaded=$output
    loaded=()
    gm_validate_repo_name "$repo" || return 1
    gm_validate_file "$file" read || return 1
    [[ -f $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || return 1
        key=${line%%=*}
        case $key in schema|repo|anchor_date|schedule_timezone|next_due_date|not_before|last_attempt_at|last_success_at|last_result|operation_id|status|generation|identity|reason|write_blocked|resumed_boot|log|failed_identity|failed_generation) ;; *) return 1 ;; esac
        [[ ! ${loaded[$key]+present} ]] || return 1
        loaded[$key]=${line#*=}
    done < "$file"
    gm_gc_state_validate "$output" || return 1
    if [[ ${loaded[schema]} == 1 ]]; then
        loaded[schema]=2 loaded[failed_identity]=none loaded[failed_generation]=none
    fi
    [[ ${loaded[repo]} == "$repo" ]]
}

gm_gc_state_commit_locked() {
    local repo=$1 input=$2 file=$RUN_ROOT/state/gc/$1.state temporary key status=0
    local -n saved=$input
    GM_STATE_COMMIT_RESULT=failed
    gm_gc_state_validate "$input" || return 1
    if [[ ${saved[schema]} == 1 ]]; then
        saved[schema]=2 saved[failed_identity]=none saved[failed_generation]=none
    fi
    [[ ${saved[repo]} == "$repo" ]] || return 1
    gm_state_directory_prepare "${file%/*}" && gm_validate_file "$file" || return 1
    temporary=$(mktemp "${file%/*}/.gc.XXXXXXXX") || return 1
    for key in schema repo anchor_date schedule_timezone next_due_date not_before last_attempt_at last_success_at last_result operation_id status generation identity reason write_blocked resumed_boot log failed_identity failed_generation; do
        printf '%s=%s\n' "$key" "${saved[$key]}" >> "$temporary" || status=1
    done
    if (( status == 0 )) && gm_state_flush "$temporary" && mv -f -- "$temporary" "$file"; then
        if ! gm_state_flush "${file%/*}"; then
            GM_STATE_COMMIT_RESULT=indeterminate
            return 2
        fi
        GM_STATE_COMMIT_RESULT=committed
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

gm_gc_publication_locked() {
    local repo=$1 generation=$2 identity=$3 file=$RUN_ROOT/state/gc/$1.state day
    local -A publication_gc=()
    if [[ -e $file || -L $file ]]; then
        gm_gc_state_read "$repo" publication_gc || return 1
        if [[ ${publication_gc[generation]} != "$generation" || ${publication_gc[identity]} != "$identity" ]]; then
            publication_gc[generation]=$generation publication_gc[identity]=$identity
            gm_gc_state_commit_locked "$repo" publication_gc || return 1
        fi
        return 0
    fi
    day=$(TZ="${TZ:-UTC}" date +%F) || return 1
    gm_gc_init "$day" "${TZ:-UTC}" publication_gc || return 1
    publication_gc[schema]=2 publication_gc[repo]=$repo publication_gc[generation]=$generation
    publication_gc[failed_identity]=none publication_gc[failed_generation]=none
    publication_gc[identity]=$identity publication_gc[operation_id]=none publication_gc[reason]=none
    publication_gc[write_blocked]=no publication_gc[resumed_boot]=${GM_BOOT_GENERATION:?} publication_gc[log]=none
    gm_gc_state_commit_locked "$repo" publication_gc
}

gm_gc_startup_resume_locked() {
    local repo=$1 now=$2
    local -A resume_gc=()
    [[ -e $RUN_ROOT/state/gc/$repo.state || -L $RUN_ROOT/state/gc/$repo.state ]] || return 0
    gm_gc_state_read "$repo" resume_gc || return 1
    [[ ${resume_gc[resumed_boot]} != "$GM_BOOT_GENERATION" ]] || return 0
    resume_gc[schedule_timezone]=${TZ:-UTC}
    gm_gc_resume resume_gc "$now" || return 1
    if [[ ${resume_gc[status]} == running || ${resume_gc[last_result]} == UNKNOWN || ${resume_gc[last_result]} == INTERRUPTED ]]; then
        resume_gc[write_blocked]=yes resume_gc[status]=blocked
        if [[ ${resume_gc[reason]} == none || ${resume_gc[reason]} == running ]]; then resume_gc[reason]=unknown; fi
    fi
    resume_gc[resumed_boot]=$GM_BOOT_GENERATION
    gm_gc_state_commit_locked "$repo" resume_gc
}

gm_gc_write_allowed() {
    local repo=$1
    local -A write_gc=()
    [[ -e $RUN_ROOT/state/gc/$repo.state || -L $RUN_ROOT/state/gc/$repo.state ]] || return 0
    gm_gc_state_read "$repo" write_gc || return 1
    [[ ${write_gc[write_blocked]} == no && ${write_gc[status]} != running ]]
}
