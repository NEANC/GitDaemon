#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_probe_result() (
    local probe_result=$1 expected=$2 actual=0 requests=0 probes=0 expected_product_id
    expected_product_id=$(printf '%064d' 3)
    MP_WITNESS_CALIBRATED=1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1 MAPPING_ASSERT_GENERATION=gen1
    MP_NETWORK_ID=netid-abc MP_RUN_ID=return MPF_SCENARIO=mapping-fallback-isolation
    IT_CONTROL_DIR=$WORK/control IT_EVIDENCE_DIR=$WORK/$probe_result
    mkdir -p "$IT_CONTROL_DIR" "$IT_EVIDENCE_DIR"
    mapping_profile_load() { MP_PROFILE_SHA256=profile-sha; }
    mapping_fixture_docker() { [[ $1 == inspect && $4 == product ]] || return 80; printf '%s\n' "$expected_product_id"; }
    resource_ledger_dir() { printf '%s\n' "$WORK/resources"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { [[ $1 == container && $2 == "$expected_product_id" && $3 == mapping-fallback-isolation && $4 == product ]]; }
    mapping_receiver_probe() { return 0; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_witness() { cat "$1"; }
    mapping_receiver_listener_control() { [[ $2 != CONT || $3 == 123 ]] || return 80; printf '123\n'; }
    mapping_receiver_listener_observed_state() { if [[ -s $IT_EVIDENCE_DIR/isolation/cross-network/listener.restored.pid ]]; then printf 'R\n'; else printf 'T\n'; fi; }
    mapping_receiver_listener_running() { return 0; }
    mapping_receiver_negative_probe() { return 0; }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == gen1 && $3 == netid-abc && $4 == profile-sha && $5 == cross-network ]] || return 80
        requests=$((requests + 1))
        CONTROL_SEQ=$requests
        printf '%s\n0\n0\n0\n' "$((requests == 2))" > "$WORK/mapping-snapshot-$requests.witness"
        printf 'rules\n' > "$WORK/mapping-snapshot-$requests.rules"
        printf 'target\tcross-network\nseq\t%s\n' "$requests" > "$WORK/mapping-snapshot-$requests.receipt"
    }
    MAPPING_ASSERT_TARGET=cross-network
    mapping_probe_egress() { [[ $1 == "$expected_product_id" && $2 == gen1 && $3 == cross-network ]] || return 80; probes=$((probes + 1)); return "$probe_result"; }
    mapping_isolation_check product gen1 profile || actual=$?
    [[ $actual == "$expected" && $requests == 4 && $probes == 1 ]]
)

check_probe_result 1 1
check_probe_result 80 80
