#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

snapshot_receipt_is_bound_to_root_capture() (
    E=$WORK/run RUN=mtest
    mkdir -p "$E"
    guard_mapping_witness_identity() { printf '123\n'; }
    iptables-save() { printf 'original-rules\n'; }
    nsenter() { printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n'; }
    guard_mapping_snapshot 7 g1 net-one "$(printf profile | sha256sum | cut -d' ' -f1)" host-input
    [[ $(awk -F '\t' '$1 == "target" {print $2}' "$E/mapping-snapshot-7.receipt") == host-input ]]
    [[ $(awk -F '\t' '$1 == "seq" {print $2}' "$E/mapping-snapshot-7.receipt") == 7 ]]
    [[ $(awk -F '\t' '$1 == "generation" {print $2}' "$E/mapping-snapshot-7.receipt") == g1 ]]
    [[ $(awk -F '\t' '$1 == "network_id" {print $2}' "$E/mapping-snapshot-7.receipt") == net-one ]]
    [[ $(awk -F '\t' '$1 == "rules_sha256" {print $2}' "$E/mapping-snapshot-7.receipt") == "$(sha256sum "$E/mapping-snapshot-7.rules" | cut -d' ' -f1)" ]]
    [[ $(awk -F '\t' '$1 == "witness_sha256" {print $2}' "$E/mapping-snapshot-7.receipt") == "$(sha256sum "$E/mapping-snapshot-7.witness" | cut -d' ' -f1)" ]]
)

snapshot_request_requires_exact_target() (
    local target=$1 expected=$2 rc=0 sent=''
    MP_PROFILE_SHA256=$(printf profile | sha256sum | cut -d' ' -f1)
    network_control() { sent=$1; MAPPING_ACK_GENERATION=g1; }
    mapping_control_request mapping-snapshot g1 net-one "$MP_PROFILE_SHA256" "$target" || rc=$?
    [[ $rc == "$expected" ]]
    if [[ $expected == 0 ]]; then
        [[ $sent == "mapping-snapshot g1 net-one $MP_PROFILE_SHA256 $target" ]]
    else
        [[ -z $sent ]]
    fi
)

guard_request_rejects_target_mismatch_without_ack() (
    local target=$1 expected=$2 rc=0 snapshots=0 acks=0
    seq=7 last_nonce='' rules_start=0 E=$WORK/guard-request RUN=mtest
    MP_PROFILE_SHA256=$(printf profile | sha256sum | cut -d' ' -f1)
    GUARD_MAPPING_STATE=ACTIVE GUARD_MAPPING_GENERATION=g1 GUARD_MAPPING_NETWORK_ID=net-one
    GUARD_MAPPING_CONTROL_IDENTITY=identity
    guard_mapping_snapshot() { snapshots=$((snapshots + 1)); [[ $5 == host-input ]] || return 80; }
    guard_mapping_ack_publish() { acks=$((acks + 1)); }
    guard_mapping_request_handle mapping-snapshot g1 net-one "$MP_PROFILE_SHA256" nonce "$target" || rc=$?
    [[ $rc == "$expected" ]]
    if [[ $expected == 0 ]]; then
        [[ $snapshots == 1 && $acks == 1 ]]
    else
        [[ $snapshots == 0 && $acks == 0 ]]
    fi
)

snapshot_rejects_invalid_target_and_hash_failures() (
    local mode=$1 rc=0 profile acks=0
    E=$WORK/$mode RUN=mtest
    mkdir -p "$E"
    profile=$(printf profile | sha256sum | cut -d' ' -f1)
    seq=7 last_nonce='' GUARD_MAPPING_CONTROL_IDENTITY=identity
    GUARD_MAPPING_STATE=ACTIVE GUARD_MAPPING_GENERATION=g1 GUARD_MAPPING_NETWORK_ID=net-one
    MP_PROFILE_SHA256=$profile
    guard_mapping_ack_publish() { acks=$((acks + 1)); }
    guard_mapping_witness_identity() { printf '123\n'; }
    iptables-save() { printf 'original-rules\n'; }
    nsenter() { printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n'; }
    case $mode in
        invalid) guard_mapping_request_handle mapping-snapshot g1 net-one "$profile" nonce unknown || rc=$? ;;
        rules-failed|rules-short|witness-failed|witness-short)
            sha256sum() {
                if [[ ( $mode == rules-* && $1 == *.rules ) || ( $mode == witness-* && $1 == *.witness ) ]]; then
                    [[ $mode != *-failed ]] || return 1
                    printf 'bad  %s\n' "$1"
                else
                    command sha256sum "$@"
                fi
            }
            guard_mapping_request_handle mapping-snapshot g1 net-one "$profile" nonce host-input || rc=$?
            ;;
    esac
    if [[ $mode == invalid ]]; then
        [[ $rc == 65 && $acks == 0 && ! -e $E/mapping-snapshot-7.receipt ]]
    else
        [[ $rc == 80 && $acks == 0 && ! -e $E/mapping-snapshot-7.receipt ]]
    fi
)

snapshot_receipt_is_bound_to_root_capture
snapshot_request_requires_exact_target host-input 0
snapshot_request_requires_exact_target unknown 65
snapshot_request_requires_exact_target '' 65
guard_request_rejects_target_mismatch_without_ack host-input 0
guard_request_rejects_target_mismatch_without_ack unknown 65
guard_request_rejects_target_mismatch_without_ack '' 65
for mode in invalid rules-failed rules-short witness-failed witness-short; do
    snapshot_rejects_invalid_target_and_hash_failures "$mode"
done
