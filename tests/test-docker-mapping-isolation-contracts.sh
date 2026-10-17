#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"

isolation_never_attaches_second_network() {
    local dir calls rc=0
    dir=$(mktemp -d); calls=$dir/calls
    MAPPING_ASSERT_CASE=isolation MAPPING_PROFILE=profile
    mapping_fixture_docker() { printf '%s\n' "$*" >> "$calls"; }
    mapping_isolation_check() { return 0; }
    mapping_negative_apply fallback scenario "$dir" product || rc=$?
    if [[ -f $calls ]] && grep -q 'network connect' "$calls"; then rc=1; fi
    grep -Fqx $'isolation\tPASS' "$dir/isolation.tsv" || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

witness_counts_use_guard_nsenter() {
    grep -q 'nsenter -t.*-n iptables.*mapping-snapshot' "$HERE/docker-network-guard.sh"
}

tcp_dns_uses_registered_shared_netns() {
    grep -q 'dns-tcp).*docker exec.*nslookup -tcp' "$HERE/docker-mapping-fixture.sh"
}

paused_listener_fails_calibration() {
    MP_WITNESS_CALIBRATED=0
    mapping_receiver_witness_counts() { printf '0\n0\n0\n'; }
    mapping_receiver_probe() { return 0; }
    mapping_calibrate_witness profile >/dev/null 2>&1 && return 1
    [[ $MP_WITNESS_CALIBRATED == 0 ]]
}

missing_drop_key_fails() {
    local file profile
    file=$(mktemp); profile=$(mktemp)
    : > "$file"; printf 'schema_version\t1\n' > "$profile"
    ! mapping_count "$file" "$profile" dns-tcp >/dev/null 2>&1
    rm -f "$file" "$profile"
}

wrong_protocol_or_bridge_fails() {
    grep -q 'iface != br.*pr != proto' "$HERE/docker-mapping-fixture.sh"
}

receiver_growth_fails_isolation() {
    ! mapping_witness_growth $'0\n0\n0' $'1\n1\n0'
}

failed=0
for name in isolation_never_attaches_second_network witness_counts_use_guard_nsenter tcp_dns_uses_registered_shared_netns paused_listener_fails_calibration missing_drop_key_fails wrong_protocol_or_bridge_fails receiver_growth_fails_isolation; do
    rc=0; ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
