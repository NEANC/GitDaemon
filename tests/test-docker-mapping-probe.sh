#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-probe.sh"

probe_runs_all_required_checks() {
    local dir key
    dir=$(mktemp -d)
    for key in $MAPPING_PROBE_KEYS; do eval "mapping_probe_check_$key() { printf '%s\\n' '$key' >> '$dir/order'; }"; done
    mapping_probe_run profile product tools "$dir" || return 1
    diff -u <(printf '%s\n' $MAPPING_PROBE_KEYS) "$dir/order" || return 1
    mapping_probe_accept "$dir/probe-summary.tsv" || return 1
    [[ ! -e $dir/mapping-full-summary.tsv ]]
}

probe_failure_stops_next_check() {
    local dir count=0 key rc=0
    dir=$(mktemp -d)
    for key in $MAPPING_PROBE_KEYS; do eval "mapping_probe_check_$key() { count=\$((count + 1)); [[ '$key' != volume_owner ]]; }"; done
    mapping_probe_run profile product tools "$dir" || rc=$?
    [[ $rc == 1 && $count == 4 ]]
}

probe_missing_tool_returns_80() {
    local dir rc=0 key
    dir=$(mktemp -d)
    for key in $MAPPING_PROBE_KEYS; do eval "mapping_probe_check_$key() { return 0; }"; done
    mapping_probe_check_ipam() { return 80; }
    mapping_probe_run profile product tools "$dir" || rc=$?
    [[ $rc == 80 ]]
}

probe_never_writes_full_summary() {
    local dir key
    dir=$(mktemp -d)
    for key in $MAPPING_PROBE_KEYS; do eval "mapping_probe_check_$key() { return 0; }"; done
    mapping_probe_run profile product tools "$dir" || return 1
    [[ -f $dir/probe-summary.tsv && ! -e $dir/mapping-full-summary.tsv ]]
}

probe_requires_guard_handshake() {
    local dir rc=0
    dir=$(mktemp -d)
    unset IT_NETWORK_GUARD_READY MAPPING_ACK_GENERATION
    mapping_probe_run profile product tools "$dir" || rc=$?
    [[ $rc == 77 && ! -e $dir/probe-summary.tsv ]]
}

failed=0
for name in probe_runs_all_required_checks probe_failure_stops_next_check probe_missing_tool_returns_80 probe_never_writes_full_summary probe_requires_guard_handshake; do
    rc=0
    ( IT_NETWORK_GUARD_READY=1 MAPPING_ACK_GENERATION=generation-1 "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
