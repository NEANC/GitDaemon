#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=upstream-san-registration IT_NETWORK=gm-upstream-san-registration-net
source "$HERE/test-docker-integration.sh"
source "$HERE/docker-mapping-assertions.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
IT_EVIDENCE_DIR=$TEST_ROOT/evidence
mkdir -p "$IT_EVIDENCE_DIR/control"
check_mapping_sync() { return 0; }
mapping_negative_run() { printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/cases"; }
integration_register_mapping_group
[[ $(wc -l < "$TEST_ROOT/cases") == 4 ]]
grep -Fxq 'wrong_upstream_san fallback' "$TEST_ROOT/cases"
[[ ${IT_SLOT_DONE[tls_negatives]:-0} == 4 ]]
[[ ${IT_SLOT_FAIL[tls_negatives]:-0} == 0 ]]
printf 'upstream SAN full registration PASS\n'
