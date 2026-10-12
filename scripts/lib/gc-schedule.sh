#!/usr/bin/env bash

gm_gc_add_days() {
    LC_ALL=C TZ=UTC date -d "$1 00:00:00 $2 days" +%F
}

gm_gc_offset() {
    local offset sign hours minutes seconds
    offset=$(LC_ALL=C TZ="$1" date -d "@$2" +%::z) || return 1
    sign=${offset:0:1}
    IFS=: read -r hours minutes seconds <<< "${offset:1}"
    printf '%s\n' "$(( ${sign}1 * (10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds) ))"
}

gm_gc_at_two() {
    local day=$1 zone=$2 wall normalized probe offset previous_offset=
    local candidate rendered best= previous_probe low high middle middle_offset
    [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ $zone == UTC || $zone == GMT || ( $zone != /* && $zone != *..* && -f /usr/share/zoneinfo/$zone ) ]] || return 1
    normalized=$(LC_ALL=C TZ=UTC date -d "$day 00:00:00" +%F) || return 1
    [[ $normalized == "$day" ]] || return 1
    wall=$(LC_ALL=C TZ=UTC date -d "$day 02:00:00" +%s) || return 1
    for ((probe = wall - 129600; probe <= wall + 129600; probe += 21600)); do
        offset=$(gm_gc_offset "$zone" "$probe") || return 1
        if [[ $offset != "$previous_offset" ]]; then
            candidate=$((wall - offset))
            rendered=$(LC_ALL=C TZ="$zone" date -d "@$candidate" '+%F %T') || return 1
            if [[ $rendered == "$day 02:00:00" ]] && [[ -z $best || $candidate -lt $best ]]; then
                best=$candidate
            fi
            if [[ -n $previous_offset ]] && (( offset > previous_offset )); then
                low=$previous_probe high=$probe
                while (( high - low > 1 )); do
                    middle=$(((low + high) / 2))
                    middle_offset=$(gm_gc_offset "$zone" "$middle") || return 1
                    if (( middle_offset == previous_offset )); then
                        low=$middle
                    else
                        high=$middle
                    fi
                done
                if (( wall >= high + previous_offset && wall < high + offset )); then
                    if [[ -z $best || $high -lt $best ]]; then
                        best=$high
                    fi
                fi
            fi
        fi
        previous_offset=$offset previous_probe=$probe
    done
    [[ -n $best ]] || return 1
    printf '%s\n' "$best"
}

gm_gc_valid_epoch() {
    [[ $1 =~ ^(0|[1-9][0-9]{0,11})$ ]]
}

gm_gc_init() {
    local anchor=$1 zone=$2 next
    local -n gc_output=$3
    gm_gc_at_two "$anchor" "$zone" >/dev/null || return 1
    next=$(gm_gc_add_days "$anchor" 14) || return 1
    gc_output=([anchor_date]=$anchor [schedule_timezone]=$zone [next_due_date]=$next
        [not_before]=0 [last_attempt_at]=0 [last_success_at]=0 [last_result]=NONE
        [operation_id]='' [status]=scheduled)
    return 0
}

gm_gc_due() {
    local -n gc_state=$1
    local now=$2 due
    gm_gc_valid_epoch "$now" || return 1
    gm_gc_valid_epoch "${gc_state[not_before]}" || return 1
    due=$(gm_gc_at_two "${gc_state[next_due_date]}" "${gc_state[schedule_timezone]}") || return 1
    (( now >= due && now >= gc_state[not_before] ))
}

gm_gc_advance() {
    local -n gc_state=$1
    local completed=$2 next due
    gm_gc_valid_epoch "$completed" || return 1
    next=$(gm_gc_add_days "${gc_state[next_due_date]}" 14) || return 1
    due=$(gm_gc_at_two "$next" "${gc_state[schedule_timezone]}") || return 1
    while (( due <= completed )); do
        next=$(gm_gc_add_days "$next" 14) || return 1
        due=$(gm_gc_at_two "$next" "${gc_state[schedule_timezone]}") || return 1
    done
    gc_state[next_due_date]=$next
    gc_state[not_before]=0
    gc_state[last_success_at]=$completed
    gc_state[last_result]=SUCCESS
    gc_state[status]=scheduled
    return 0
}

gm_gc_retry() {
    local -n gc_state=$1
    local failure=$2 day floor
    gm_gc_valid_epoch "$failure" || return 1
    gm_gc_valid_epoch "${gc_state[not_before]}" || return 1
    day=$(LC_ALL=C TZ="${gc_state[schedule_timezone]}" date -d "@$failure" +%F) || return 1
    day=$(gm_gc_add_days "$day" 1) || return 1
    floor=$(gm_gc_at_two "$day" "${gc_state[schedule_timezone]}") || return 1
    if (( floor > gc_state[not_before] )); then
        gc_state[not_before]=$floor
    fi
    gc_state[status]=retry_wait
    return 0
}

gm_gc_resume() {
    local -n gc_state=$1
    local now=$2 due day floor saved_status
    gm_gc_valid_epoch "$now" || return 1
    gm_gc_valid_epoch "${gc_state[not_before]}" || return 1
    case "${gc_state[status]}:${gc_state[last_result]}" in
        running:*|retry_wait:*|*:UNKNOWN|*:INTERRUPTED)
            if [[ ${gc_state[not_before]} == 0 ]]; then
                saved_status=${gc_state[status]}
                gm_gc_retry "$1" "$now" || return 1
                if [[ $saved_status == blocked ]]; then
                    gc_state[status]=blocked
                fi
            fi
            return 0
            ;;
    esac
    if (( gc_state[not_before] >= now )); then
        return 0
    fi
    due=$(gm_gc_at_two "${gc_state[next_due_date]}" "${gc_state[schedule_timezone]}") || return 1
    if (( due >= now )); then
        return 0
    fi
    day=$(LC_ALL=C TZ="${gc_state[schedule_timezone]}" date -d "@$now" +%F) || return 1
    floor=$(gm_gc_at_two "$day" "${gc_state[schedule_timezone]}") || return 1
    if (( floor < now )); then
        day=$(gm_gc_add_days "$day" 1) || return 1
        floor=$(gm_gc_at_two "$day" "${gc_state[schedule_timezone]}") || return 1
    fi
    gc_state[not_before]=$floor
    return 0
}
