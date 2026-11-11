#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"

check_probe_result() (
    local probe_result=$1 expected=$2 actual=0 requests=0
    MP_WITNESS_CALIBRATED=1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1 MAPPING_ASSERT_GENERATION=gen1
    MP_NETWORK_ID=netid-abc IT_CONTROL_DIR=/tmp/mapping-isolation-test/control IT_EVIDENCE_DIR=/tmp
    mapping_profile_load() { MP_PROFILE_SHA256=profile-sha; }
    network_control() {
        [[ $1 == mapping-snapshot ]] || return 80
        requests=$((requests + 1))
        CONTROL_SEQ=$requests
    }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == gen1 && $3 == netid-abc && $4 == profile-sha ]] || return 80
        requests=$((requests + 1))
        CONTROL_SEQ=$requests
    }
    mapping_probe_egress() { return "$probe_result"; }
    mapping_isolation_check product gen1 profile || actual=$?
    [[ $actual == "$expected" && $requests == 1 ]]
)

check_probe_result 1 1
check_probe_result 80 80
