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
    guard_mapping_snapshot 7 g1 net-one "$(printf profile | sha256sum | cut -d' ' -f1)"
    [[ $(awk -F '\t' '$1 == "seq" {print $2}' "$E/mapping-snapshot-7.receipt") == 7 ]]
    [[ $(awk -F '\t' '$1 == "generation" {print $2}' "$E/mapping-snapshot-7.receipt") == g1 ]]
    [[ $(awk -F '\t' '$1 == "network_id" {print $2}' "$E/mapping-snapshot-7.receipt") == net-one ]]
    [[ $(awk -F '\t' '$1 == "rules_sha256" {print $2}' "$E/mapping-snapshot-7.receipt") == "$(sha256sum "$E/mapping-snapshot-7.rules" | cut -d' ' -f1)" ]]
    [[ $(awk -F '\t' '$1 == "witness_sha256" {print $2}' "$E/mapping-snapshot-7.receipt") == "$(sha256sum "$E/mapping-snapshot-7.witness" | cut -d' ' -f1)" ]]
)

snapshot_receipt_is_bound_to_root_capture
