#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=negative-registration IT_NETWORK=gm-negative-registration-net
source "$HERE/test-docker-integration.sh"
source "$HERE/docker-mapping-assertions.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
IT_EVIDENCE_DIR=$TEST_ROOT/evidence
mkdir -p "$IT_EVIDENCE_DIR/control"
check_mapping_sync() { return 0; }
mapping_negative_run() { printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/cases"; }
integration_register_mapping_group
[[ $(wc -l < "$TEST_ROOT/cases") == 2 ]]
grep -Fxq 'wrong_proxy_ca fallback' "$TEST_ROOT/cases"
grep -Fxq 'wrong_upstream_ca fallback' "$TEST_ROOT/cases"
[[ ${IT_SLOT_DONE[dns_negatives]:-0} == 12 ]]
[[ ${IT_SLOT_DONE[tls_negatives]:-0} == 4 ]]
[[ ${IT_SLOT_DONE[isolation_negatives]:-0} == 5 ]]
[[ ${IT_SLOT_FAIL[dns_negatives]:-0} == 12 ]]
[[ ${IT_SLOT_FAIL[tls_negatives]:-0} == 2 ]]
[[ ${IT_SLOT_FAIL[isolation_negatives]:-0} == 5 ]]
FAILURES=0 FIXTURE_FAILURES=0 IT_DEFERRED=0 IT_PRIMARY_EXIT=0 IT_CLEANUP_EXIT=0 IT_RESIDUAL_COUNT=0
integration_full_summary_write "$TEST_ROOT/summary.tsv"
grep -Fxq $'dns_negatives\tFAIL' "$TEST_ROOT/summary.tsv"
grep -Fxq $'tls_negatives\tFAIL' "$TEST_ROOT/summary.tsv"
grep -Fxq $'isolation_negatives\tFAIL' "$TEST_ROOT/summary.tsv"
printf 'NEGATIVE_REGISTRATION=PASS\n'
