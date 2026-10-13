#!/usr/bin/env bash

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/repository-state.sh" || return 1
GM_LIFECYCLE_SOURCE=${BASH_SOURCE[0]}

gm_monotonic_ms() {
    local uptime idle
    read -r uptime idle < /proc/uptime || return 1
    printf -v "$1" '%s' "$(( ${uptime%.*} * 1000 + 10#${uptime#*.} * 10 ))"
}

gm_process_identity() {
    local pid=$1 target=$2 line
    local -a fields=()
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r line 2>/dev/null < "/proc/$pid/stat" || return 1
    read -r -a fields <<< "${line##*) }"
    local -n process_record=$target
    process_record=([pid]="$pid" [state]="${fields[0]}" [ppid]="${fields[1]}" [pgid]="${fields[2]}" [session]="${fields[3]}" [start]="${fields[19]}")
}

gm_lifecycle_record() {
    local path=$1 content=$2 temporary
    gm_validate_file "$path" || return 1
    temporary=$(mktemp "$RUN_ROOT/runtime/.lifecycle.XXXXXXXX") || return 1
    if ! { printf '%s\n' "$content" > "$temporary" && gm_state_flush "$temporary" && mv -f -- "$temporary" "$path"; }; then
        rm -f -- "$temporary"
        return 1
    fi
    gm_state_flush "$RUN_ROOT/runtime"
}

gm_container_lease_acquire() {
    gm_lock_acquire container exclusive || return $?
    GM_CONTAINER_OWNER=$BASHPID
}

# 校验活跃容器租约与发布门，将独立入口绑定到当前启动代次。
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

gm_without_container_lease() (
    gm_lock_release container || return 1
    "$@"
)

gm_container_begin() {
    [[ -z ${GM_STOP_SCOPE-} && ${GM_LOCAL_FROZEN-} != yes ]] || return 1
    [[ ${GM_CONTAINER_OWNER-} == "$BASHPID" && -n ${GM_LOCK_FDS[container]-} && -z ${GM_BOOT_GENERATION-} ]] || return 1
    local -A owner=()
    gm_process_identity "$BASHPID" owner || return 1
    GM_BOOT_GENERATION=$(cat /proc/sys/kernel/random/uuid) || return 1
    gm_lock_acquire dispatch exclusive || return $?
    local status=0
    gm_lifecycle_record "$RUN_ROOT/runtime/generation" "$GM_BOOT_GENERATION" || status=1
    [[ -z ${GM_STOP_SCOPE-} && ${GM_LOCAL_FROZEN-} != yes ]] || status=1
    if (( status == 0 )); then
        gm_validate_file "$RUN_ROOT/runtime/frozen" && gm_validate_file "$RUN_ROOT/runtime/stopped" &&
            rm -f -- "$RUN_ROOT/runtime/frozen" "$RUN_ROOT/runtime/stopped" && gm_state_flush "$RUN_ROOT/runtime" || status=1
    fi
    gm_lock_release dispatch || return 1
    if [[ -n ${GM_STOP_SCOPE-} || ${GM_LOCAL_FROZEN-} == yes ]]; then gm_task_freeze || return 1; return 1; fi
    export GM_BOOT_GENERATION
    return "$status"
}

gm_request_stop() {
    case "$1" in instance|task) ;; *) return 1 ;; esac
    if [[ ${GM_STOP_SCOPE-} != instance ]]; then GM_STOP_SCOPE=$1; fi
    if [[ $GM_STOP_SCOPE == instance ]]; then GM_LOCAL_FROZEN=yes; fi
    GM_STOP_REASON=$2
    return 0
}

gm_task_group_alive() {
    local group=$1 session=$2 excluded=${3-} path pid
    local -A member=()
    for path in /proc/[0-9]*/stat; do
        pid=${path#/proc/}; pid=${pid%/stat}
        [[ $pid != "$excluded" ]] || continue
        if ! gm_process_identity "$pid" member; then
            [[ ! -e $path ]] && continue
            return 2
        fi
        if [[ ${member[pgid]} == "$group" && ${member[session]} == "$session" && ${member[state]} != Z && ${member[state]} != X ]]; then return 0; fi
    done
    return 1
}

# 跨读取超时保留放行令牌片段，完整校验后才启动受监督命令。
gm_task_worker() {
    local directory=$1 parent=$2 parent_start=$3 lease=$4 dispatch=$5
    shift 5
    if [[ -n $lease ]]; then exec {lease}<&-; fi
    exec {dispatch}<&-
    local self=$BASHPID token= partial= elapsed start now status child worker_cancel=no
    local -A me=() supervisor=()
    gm_process_identity "$self" me || return 1
    [[ ${me[pgid]} == "$self" && ${me[session]} == "$self" ]] || return 1
    trap 'worker_cancel=yes' TERM INT
    exec 8<> "$directory/gate" || return 1
    printf '%s %s %s %s\n' "$self" "${me[start]}" "${me[pgid]}" "${me[session]}" > "$directory/ready" || return 1
    gm_monotonic_ms start || return 1
    while ! IFS= read -r -t 0.05 token <&8; do
        partial+=$token
        if [[ $worker_cancel == yes ]]; then printf '143\n' > "$directory/status"; return 0; fi
        gm_process_identity "$parent" supervisor || return 1
        [[ ${supervisor[start]} == "$parent_start" && ${supervisor[state]} != Z ]] || return 1
        gm_monotonic_ms now || return 1
        (( now - start < 10000 )) || return 1
    done
    exec 8>&-
    [[ $partial$token == "$GM_BOOT_GENERATION" ]] || return 1
    if [[ $worker_cancel == yes ]]; then printf '143\n' > "$directory/status"; return 0; fi
    trap ':' TERM INT
    "$@" & child=$!
    while :; do
        wait "$child"; status=$?
        if gm_process_identity "$child" supervisor && [[ ${supervisor[state]} != Z ]]; then continue; fi
        break
    done
    printf '%s\n' "$status" > "$directory/status" || return 1
    while gm_task_group_alive "$self" "$self" "$self"; do sleep 0.05; done
    return 0
}

gm_task_journal() {
    local repo=$1 operation=$2 phase=$3
    local -A journal=([schema]=1 [repo]="$repo" [generation]=0 [desired]=present [observed]=syncing [published]=no [message]="$operation-$phase")
    gm_operation_commit_locked "$repo" journal
}

gm_task_run_locked() {
    local repo=$1 operation=$2 output=$3 supplied_operation_id
    shift 3
    local -n task=$output
    supplied_operation_id=${task[requested_operation_id]-}
    task=([repo]="$repo" [operation]="$operation" [result]=BLOCKED)
    [[ ${GM_LOCAL_FROZEN-} != yes ]] || return 1
    [[ -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} && $# -gt 0 ]] || return 1
    [[ $operation =~ ^[a-z][a-z_-]*$ ]] || return 1
    gm_state_repo_path "$RUN_ROOT" "$repo" repos >/dev/null || return 1
    gm_lock_acquire dispatch exclusive || return $?
    local status=0 directory pid start now gate
    local -A supervisor=() worker=() eligibility=()
    if [[ -e $RUN_ROOT/runtime/frozen || -e $RUN_ROOT/runtime/stopped || -n ${GM_STOP_SCOPE-} ]]; then
        task[result]=STOPPED
        if [[ ${GM_STOP_SCOPE-} == task ]]; then task[result]=INTERRUPTED; fi
        gm_lock_release dispatch
        return 1
    fi
    gm_validate_file "$RUN_ROOT/runtime/generation" read && [[ -f $RUN_ROOT/runtime/generation ]] || status=1
    if (( status == 0 )); then IFS= read -r GM_BOOT_GENERATION < "$RUN_ROOT/runtime/generation" || status=1; fi
    [[ ${GM_BOOT_GENERATION-} =~ ^[a-f0-9-]{36}$ ]] || status=1
    if [[ -e $RUN_ROOT/state/repos/$repo.state || -L $RUN_ROOT/state/repos/$repo.state ]]; then
        if ! gm_repo_state_read "$repo" eligibility; then
            gm_lock_release dispatch
            return 1
        fi
        if [[ ( ${eligibility[message]} == recovery_required || ${eligibility[health]-} == corrupt || ${eligibility[health]-} == recovery_required ) && $operation != recovery && $operation != check ]]; then
            task[result]=RECOVERY_REQUIRED
            gm_lock_release dispatch
            return 1
        fi
    fi
    if [[ -n $supplied_operation_id ]]; then
        [[ $supplied_operation_id =~ ^[a-f0-9-]{36}$ ]] || status=1
        task[operation_id]=$supplied_operation_id
    else
        IFS= read -r 'task[operation_id]' < /proc/sys/kernel/random/uuid || status=1
    fi
    gm_task_journal "$repo" "$operation" starting || status=1
    if (( status != 0 )); then gm_lock_release dispatch; return 1; fi
    directory=$(mktemp -d "$RUN_ROOT/runtime/task.XXXXXXXX") || { gm_lock_release dispatch; return 1; }
    task[directory]=$directory
    mkfifo -m 600 "$directory/gate" || { gm_lock_release dispatch; return 1; }
    gm_process_identity "$BASHPID" supervisor || { gm_lock_release dispatch; return 1; }
    export GM_BOOT_GENERATION
    setsid bash "$GM_LIFECYCLE_SOURCE" --worker "$directory" "${supervisor[pid]}" "${supervisor[start]}" "${GM_LOCK_FDS[container]-}" "${GM_LOCK_FDS[dispatch]}" "$@" &
    task[wait_pid]=$!
    if gm_process_identity "${task[wait_pid]}" worker && [[ ${worker[ppid]} == "$BASHPID" ]]; then
        task[wait_start]=${worker[start]}
    fi
    gm_monotonic_ms start
    while [[ ! -s $directory/ready ]]; do
        gm_monotonic_ms now
        if (( now-start >= 2000 )); then status=1; break; fi
        sleep 0.02
    done
    if (( status == 0 )); then
        read -r pid task[start] task[pgid] task[session] < "$directory/ready" || status=1
        task[pid]=$pid
        gm_process_identity "$pid" worker || status=1
        [[ ${worker[start]-} == "${task[start]}" && ${worker[pgid]-} == "${task[pgid]}" && ${worker[session]-} == "${task[session]}" && $pid == "${task[pgid]}" ]] || status=1
    fi
    if (( status == 0 )); then
        task[boot]=$GM_BOOT_GENERATION
        gm_lifecycle_record "$RUN_ROOT/runtime/task" "$repo $operation $GM_BOOT_GENERATION $pid ${task[start]} ${task[pgid]} ${task[session]} ${task[operation_id]}" || status=1
    fi
    if (( status == 0 )) && [[ -z ${GM_STOP_SCOPE-} ]]; then
        exec {gate}<> "$directory/gate" || status=1
        if (( status == 0 )); then printf '%s\n' "$GM_BOOT_GENERATION" >&"$gate" || status=1; exec {gate}>&-; fi
    else
        status=1
    fi
    gm_lock_release dispatch || status=1
    if (( status != 0 )); then
        gm_request_stop task registration_failed
        task[result]=INTERRUPTED
        return 1
    fi
    task[result]=RUNNING
    return 0
}

gm_task_freeze() {
    GM_LOCAL_FROZEN=yes
    gm_lock_acquire dispatch exclusive || return 1
    local status=0
    gm_lifecycle_record "$RUN_ROOT/runtime/frozen" 'FROZEN=1' || status=1
    gm_lock_release dispatch || return 1
    return "$status"
}

gm_task_finish_locked() {
    local -n finished=$1
    local now deadline= term_at= killed=no alive status raw= wait_status interrupted=no
    local -A identity=() state=()
    if [[ -n ${finished[wait_pid]-} && -z ${finished[pid]-} ]]; then
        gm_monotonic_ms now || return 1
        term_at=$((now+5000)); deadline=$((now+7000))
        local sent=no exited=no
        while :; do
            if gm_process_identity "${finished[wait_pid]}" identity; then
                [[ -n ${finished[wait_start]-} && ${identity[start]} == "${finished[wait_start]}" && ${identity[ppid]} == "$BASHPID" ]] || break
                if [[ ${identity[state]} == Z || ${identity[state]} == X ]]; then exited=yes; break; fi
            elif [[ ! -e /proc/${finished[wait_pid]} ]]; then
                exited=yes; break
            else break
            fi
            gm_monotonic_ms now || break
            (( now < deadline )) || break
            if [[ $sent == no ]]; then
                kill -TERM "${finished[wait_pid]}" 2>/dev/null || break
                sent=yes
            elif (( now >= term_at )) && [[ $killed == no ]]; then
                kill -KILL "${finished[wait_pid]}" 2>/dev/null || break
                killed=yes
            fi
            sleep 0.05
        done
        if [[ $exited == yes ]]; then
            wait_status=0
            wait "${finished[wait_pid]}" || wait_status=$?
            if (( wait_status != 127 )); then
                raw=$wait_status
                finished[raw_status]=$raw
                finished[result]=INTERRUPTED
            fi
        fi
    fi
    while [[ -n ${finished[pid]-} ]]; do
        if [[ -n ${GM_STOP_SCOPE-} && -z $deadline ]]; then
            gm_monotonic_ms now || break
            term_at=$((now+5000)); deadline=$((now+7000)); interrupted=yes
            if [[ $GM_STOP_SCOPE == instance ]]; then gm_task_freeze || break; fi
            gm_process_identity "${finished[pid]}" identity || break
            [[ ${identity[start]} == "${finished[start]}" && ${identity[pgid]} == "${finished[pgid]}" && ${identity[session]} == "${finished[session]}" ]] || break
            if ! kill -TERM -- "-${finished[pgid]}" 2>/dev/null; then
                if gm_task_group_alive "${finished[pgid]}" "${finished[session]}"; then break; else status=$?; fi
                (( status == 1 )) || break
            fi
        fi
        if gm_task_group_alive "${finished[pgid]}" "${finished[session]}"; then alive=0; else alive=$?; fi
        if (( alive == 1 )); then
            wait_status=0
            wait "${finished[wait_pid]}" || wait_status=$?
            if [[ -n $deadline && $killed == yes && $wait_status == 137 ]]; then raw=137
            elif [[ $wait_status == 0 && -f ${finished[directory]}/status ]]; then
                IFS= read -r raw < "${finished[directory]}/status" || break
                [[ $raw =~ ^[0-9]+$ && $raw -le 255 ]] || break
            else break
            fi
            finished[raw_status]=$raw
            finished[result]=SUCCESS
            if [[ $interrupted == yes ]]; then finished[result]=INTERRUPTED
            elif (( raw != 0 )); then finished[result]=RECOVERY_REQUIRED; fi
            break
        fi
        (( alive == 0 )) || break
        if [[ -n $deadline ]]; then
            gm_monotonic_ms now || break
            (( now < deadline )) || break
            if (( now >= term_at )) && [[ $killed == no ]]; then
                gm_process_identity "${finished[pid]}" identity || break
                [[ ${identity[start]} == "${finished[start]}" ]] || break
                kill -KILL -- "-${finished[pgid]}" || break
                killed=yes
            fi
        fi
        sleep 0.05
    done
    if [[ -n ${finished[wait_pid]-} && -z $raw ]]; then
        finished[result]=UNSAFE
        gm_task_freeze || true
        return 1
    fi
    if [[ ${GM_STOP_SCOPE-} == instance ]]; then gm_task_freeze || { finished[result]=UNSAFE; return 1; }; fi
    if [[ ${finished[result]} == INTERRUPTED || ${finished[result]} == RECOVERY_REQUIRED ]]; then
        if [[ -f $RUN_ROOT/state/repos/${finished[repo]}.state ]]; then
            gm_repo_state_read "${finished[repo]}" state || { finished[result]=UNSAFE; gm_task_freeze; return 1; }
        else
            state=([schema]=1 [repo]="${finished[repo]}" [generation]=0 [desired]=present [observed]=error [published]=no [message]=recovery_required)
        fi
        state[observed]=error state[message]=recovery_required
        gm_repo_state_commit_locked "${finished[repo]}" state || { finished[result]=UNSAFE; gm_task_freeze; return 1; }
    fi
    gm_task_journal "${finished[repo]}" "${finished[operation]}" "${finished[result]}" || { finished[result]=UNSAFE; gm_task_freeze; return 1; }
    if [[ -n ${finished[directory]-} ]]; then
        gm_lock_acquire dispatch exclusive || { finished[result]=UNSAFE; gm_task_freeze; return 1; }
        status=0
        rm -f -- "$RUN_ROOT/runtime/task" "${finished[directory]}/gate" "${finished[directory]}/ready" "${finished[directory]}/status" &&
            rmdir -- "${finished[directory]}" && gm_state_flush "$RUN_ROOT/runtime" || status=1
        gm_lock_release dispatch || status=1
        if (( status != 0 )); then finished[result]=UNSAFE; gm_task_freeze; return 1; fi
    fi
    if [[ ${GM_STOP_SCOPE-} == instance ]]; then gm_task_freeze || { finished[result]=UNSAFE; return 1; }; fi
    if [[ ${2-release} != retain ]]; then
        gm_lock_release sync && gm_lock_release instance || return 1
    fi
    if [[ ${GM_STOP_SCOPE-} == task && ${GM_RETAIN_TASK_STOP-no} != yes ]]; then unset GM_STOP_SCOPE GM_STOP_REASON; fi
    return 0
}

if [[ ${1-} == --worker && ${BASH_SOURCE[0]} == "$0" ]]; then
    shift
    gm_task_worker "$@"
    exit $?
fi
