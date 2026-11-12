#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

full_request_routes_target_without_moving_nonce() (
    local actual rc=0
    guard_mapping_request_handle() { printf '%s\n' "$*"; }
    actual=$(guard_full_mapping_request 'mapping-snapshot g1 net-one hash host-input nonce-snapshot') || rc=$?
    [[ $rc == 0 && $actual == 'mapping-snapshot g1 net-one hash nonce-snapshot host-input' ]] || return 1
    actual=$(guard_full_mapping_request 'mapping-ready g1 net-one hash nonce-ready') || rc=$?
    [[ $rc == 0 && $actual == 'mapping-ready g1 net-one hash nonce-ready' ]] || return 1
    actual=$(guard_full_mapping_request 'mapping-release g1 net-one hash nonce-release') || rc=$?
    [[ $rc == 0 && $actual == 'mapping-release g1 net-one hash nonce-release' ]]
)

full_request_rejects_snapshot_without_target() (
    local rc=0
    seq=7 last_nonce='' MP_PROFILE_SHA256=$(printf profile | sha256sum | cut -d' ' -f1)
    GUARD_MAPPING_STATE=ACTIVE GUARD_MAPPING_GENERATION=g1 GUARD_MAPPING_NETWORK_ID=net-one
    guard_mapping_ack_publish() { return 0; }
    guard_full_mapping_request "mapping-snapshot g1 net-one $MP_PROFILE_SHA256 nonce-only" || rc=$?
    [[ $rc == 65 ]]
)

receiver_snapshot_uses_explicit_target() (
    source "$HERE/docker-mapping-fixture.sh"
    IT_CONTROL_DIR=$WORK/receiver/control MAPPING_ASSERT_GENERATION=g1 MP_NETWORK_ID=net-one
    MP_PROFILE_SHA256=$(printf profile | sha256sum | cut -d' ' -f1)
    MAPPING_ASSERT_TARGET=host-input
    mkdir -p "$IT_CONTROL_DIR"
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $5 == dns-udp ]] || return 65
        CONTROL_SEQ=1
        printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' > "$WORK/receiver/mapping-snapshot-1.witness"
    }
    [[ $(mapping_receiver_witness_counts dns-udp) == $'0\n0\n0\n0' ]] || return 1
    ! mapping_receiver_witness_counts unknown
)

calibration_routes_each_key_to_both_snapshots() (
    local profile=$WORK/profile.tsv key
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$profile"
    source "$HERE/docker-mapping-fixture.sh"
    mapping_receiver_witness_counts() { printf '%s\n' "$1" >> "$WORK/targets"; printf '0\n0\n0\n0\n'; }
    mapping_receiver_probe() { return 0; }
    mapping_witness_growth() { return 0; }
    mapping_calibrate_witness "$profile" >/dev/null || return 1
    for key in $MAPPING_WITNESS_KEYS; do
        [[ $(awk -v key="$key" '$0 == key {n++} END {print n+0}' "$WORK/targets") == 2 ]] || return 1
    done
    [[ $(wc -l < "$WORK/targets") == 10 ]]
)

full_request_routes_target_without_moving_nonce
full_request_rejects_snapshot_without_target
receiver_snapshot_uses_explicit_target
calibration_routes_each_key_to_both_snapshots
