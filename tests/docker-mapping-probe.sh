#!/usr/bin/env bash

MAPPING_PROBE_KEYS='ipam internal_peer uid_ports volume_owner dns proxy_tls upstream_tls connect_dial git_resolve bridge_drop input_drop witness_negative offline'
MAPPING_PROBE_FAILURE=80
MAPPING_PROBE_REJECT=1

mapping_probe_key_valid() {
    case " $MAPPING_PROBE_KEYS " in
        *" ${1:-} "*) return 0 ;;
        *) return 1 ;;
    esac
}

mapping_probe_accept() {
    local file=${1:-} key value seen='' count=0
    [[ -f $file && ! -L $file && -r $file ]] || return "$MAPPING_PROBE_REJECT"
    while IFS=$'\t' read -r key value extra; do
        [[ -n $key && $value == PASS && -z $extra ]] || return "$MAPPING_PROBE_REJECT"
        mapping_probe_key_valid "$key" || return "$MAPPING_PROBE_REJECT"
        case " $seen " in *" $key "*) return "$MAPPING_PROBE_REJECT" ;; esac
        seen+=" $key"
        count=$((count + 1))
    done < "$file"
    [[ $count == 13 ]] || return "$MAPPING_PROBE_REJECT"
    for key in $MAPPING_PROBE_KEYS; do case " $seen " in *" $key "*) ;; *) return "$MAPPING_PROBE_REJECT" ;; esac; done
    return 0
}

mapping_probe_run() {
    local profile=${1:-} product_image=${2:-} tools_image=${3:-} evidence=${4:-}
    local key rc=0 summary
    [[ $# == 4 && -n $profile && -n $product_image && -n $tools_image && -n $evidence ]] || return 2
    [[ ${IT_NETWORK_GUARD_READY:-} == 1 && -n ${MAPPING_ACK_GENERATION:-} ]] || return 77
    [[ ! -e $evidence || ( -d $evidence && ! -L $evidence ) ]] || return "$MAPPING_PROBE_FAILURE"
    mkdir -p "$evidence" || return "$MAPPING_PROBE_FAILURE"
    summary=$evidence/probe-summary.tsv
    [[ ! -e $summary ]] || return "$MAPPING_PROBE_FAILURE"
    : > "$summary.tmp" || return "$MAPPING_PROBE_FAILURE"
    for key in $MAPPING_PROBE_KEYS; do
        "mapping_probe_check_$key" "$profile" "$product_image" "$tools_image" "$evidence" || rc=$?
        if (( rc != 0 )); then
            rm -f "$summary.tmp"
            (( rc == MAPPING_PROBE_FAILURE )) && return "$MAPPING_PROBE_FAILURE"
            return "$MAPPING_PROBE_REJECT"
        fi
        printf '%s\tPASS\n' "$key" >> "$summary.tmp" || { rm -f "$summary.tmp"; return "$MAPPING_PROBE_FAILURE"; }
    done
    mv "$summary.tmp" "$summary" || return "$MAPPING_PROBE_FAILURE"
    mapping_probe_accept "$summary"
}

mapping_probe_check_ipam() { mapping_network_id_load >/dev/null; }
mapping_probe_check_internal_peer() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_uid_ports() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_volume_owner() { mapping_evidence_volume_verify "$3"; }
mapping_probe_check_dns() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_proxy_tls() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_upstream_tls() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_connect_dial() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_git_resolve() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_bridge_drop() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_input_drop() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_witness_negative() { return "$MAPPING_PROBE_FAILURE"; }
mapping_probe_check_offline() { return "$MAPPING_PROBE_FAILURE"; }
