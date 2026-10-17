#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"

dns_timeout_is_fixture_failure() {
    local file rc=0
    file=$(mktemp)
    printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; SERVER: 1.1.1.1#53\n' > "$file"
    mapping_dns_query client resolver github.com A "$file" 9 || rc=$?
    rm -f "$file"
    [[ $rc == 80 ]]
}

dns_nodata_is_not_nxdomain() {
    local file rc=0
    file=$(mktemp)
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; flags: qr; QUERY: 1, ANSWER: 0\n;; SERVER: 1.1.1.1#53\n' > "$file"
    mapping_dns_query client resolver github.com A "$file" 0 || rc=$?
    rm -f "$file"
    [[ $rc == 80 ]]
}

dns_restore_recreates_service_and_client() {
    local dir calls rc=0
    dir=$(mktemp -d); calls=$dir/calls
    mapping_dns_set() { printf '%s\n' "$*" >> "$calls"; }
    mapping_scenario_dns_state() { printf 'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n'; }
    mapping_assert_dns_file() { return 0; }
    mapping_scenario_dns_restore fallback mapping-fallback "$dir" || rc=$?
    grep -Fq 'nxdomain mapping-fallback ' "$calls" || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

missing_evidence_is_not_expected_rejection() {
    local dir rc=0
    dir=$(mktemp -d)
    mapping_assert_require_files() { return 0; }
    mapping_assert_result() { MAPPING_ASSERT_REJECT_LAYER=sync; return 1; }
    mapping_negative_rejected wrong_proxy_ca fallback "$dir" || rc=$?
    rm -rf "$dir"
    [[ $rc == 80 ]]
}

identity_missing_hash_is_fatal() {
    local dir rc=0
    dir=$(mktemp -d); mkdir -p "$dir/control"
    printf 'unique\n' > "$dir/control/unique-commit"
    MAPPING_PROFILE=$dir/profile MAPPING_PRODUCT_IMAGE=image MP_RUN_ID=run MP_PROFILE_SHA256=hash
    mapping_profile_load() { MP_RUN_ID=run; MP_PROFILE_SHA256=hash; }
    mapping_network_id_load() { printf 'network\n'; }
    mapping_scenario_identity_write fallback mapping-fallback generation-1 "$dir" || rc=$?
    rm -rf "$dir"
    [[ $rc == 80 ]]
}

tls_injection_follows_healthy_baseline() {
    local dir order rc=0
    dir=$(mktemp -d); order=$dir/order
    MAPPING_ASSERT_CASE=wrong_proxy_ca
    MAPPING_PROFILE=profile MAPPING_PRODUCT_IMAGE=product MAPPING_TOOLS_IMAGE=tools
    mapping_prepare() { printf 'prepare\n' >> "$order"; }
    mapping_proxy_evidence_reset() { return 0; }
    mapping_proxy_calibrate() { printf 'calibrate\n' >> "$order"; }
    mapping_negative_wrong_ca() { printf 'inject\n' >> "$order"; }
    mapping_scenario_fixture_prepare fallback scenario "$dir" || rc=$?
    mapping_scenario_calibrate fallback scenario "$dir" || rc=$?
    mapping_scenario_apply_negative fallback scenario "$dir" product || rc=$?
    [[ $(tr '\n' ' ' < "$order") == 'prepare calibrate inject ' ]] || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

proxy_tls_failure_has_no_connect() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'accept\t4\nreject\t0\ntotal\t4\n' > "$dir/proxy.before"
    printf 'accept\t4\nreject\t0\ntotal\t4\n' > "$dir/proxy.after"
    printf '60\n' > "$dir/sync.exit"
    mapping_tls_layer_write wrong_proxy_ca "$dir" || rc=$?
    grep -Fqx $'layer\touter-failure' "$dir/tls-layer.tsv" || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

upstream_tls_failure_has_connect() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'accept\t4\nreject\t0\ntotal\t4\n' > "$dir/proxy.before"
    printf 'accept\t5\nreject\t0\ntotal\t5\n' > "$dir/proxy.after"
    printf '60\n' > "$dir/sync.exit"
    mapping_tls_layer_write wrong_upstream_ca "$dir" || rc=$?
    grep -Fqx $'layer\tinner-failure' "$dir/tls-layer.tsv" || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

dns_false_green_requires_system_success() {
    local dir rc=0
    dir=$(mktemp -d)
    printf '1\n' > "$dir/sync.exit"
    mapping_assert_require_files() { return 0; }
    mapping_assert_result() { MAPPING_ASSERT_REJECT_LAYER=mapping; return 1; }
    mapping_negative_rejected dns-false-green fallback "$dir" || rc=$?
    rm -rf "$dir"
    [[ $rc == 80 ]]
}

failed=0
for name in dns_timeout_is_fixture_failure dns_nodata_is_not_nxdomain dns_restore_recreates_service_and_client tls_injection_follows_healthy_baseline proxy_tls_failure_has_no_connect upstream_tls_failure_has_connect missing_evidence_is_not_expected_rejection dns_false_green_requires_system_success identity_missing_hash_is_fatal; do
    rc=0; ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
