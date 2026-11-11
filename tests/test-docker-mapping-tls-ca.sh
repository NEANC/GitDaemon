#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"

wrong_proxy_ca_uses_product_8443_and_recovers() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
    MAPPING_CLIENT_PROXY_CA=/ca/proxy-ca.crt MAPPING_CLIENT_UPSTREAM_CA=/ca/upstream-ca.crt
    MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_HEALTH=mapping-upstream-ok
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_PRODUCT=product-1
    mapping_proxy_count_read_remote() {
        [[ $1 == 8443 ]] || return 1
        if [[ -f $dir/recovered ]]; then printf '2\n'; elif [[ -f $dir/calls ]]; then printf '1\n'; else printf '0\n'; fi
    }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/calls ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=10.0.0.2:443\n'
        fi
        if [[ -f $dir/recovered ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=10.0.0.2:443\n'
        fi
        return 0
    }
    mapping_negative_wrong_ca() { [[ $1 == proxy-ca.crt ]] && : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { rm "$dir/injected"; : > "$dir/recovered"; }
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$dir/calls"
        if [[ -f $dir/injected ]]; then
            printf 'curl: (60) SSL certificate problem: unable to get local issuer certificate\n'
            return 60
        fi
        printf 'mapping-upstream-ok\n'
    }
    mapping_tls_negative_run wrong_proxy_ca "$dir" || rc=$?
    [[ $rc == 0 ]] || return 1
    [[ $(cat "$dir/baseline.exit") == 0 && $(cat "$dir/request.exit") == 60 ]] || return 1
    [[ $(cat "$dir/baseline.before") == 0 && $(cat "$dir/baseline.after") == 1 ]] || return 1
    grep -Eqi 'certificate|issuer|SSL' "$dir/request.failed.log" || return 1
    [[ $(cat "$dir/recovery.exit") == 0 ]] || return 1
    [[ $(cat "$dir/proxy.before") == 1 && $(cat "$dir/proxy.after") == 1 ]] || return 1
    [[ $(cat "$dir/proxy.recovered") == 2 ]] || return 1
    [[ $(cat "$dir/connect.before") == "$(cat "$dir/connect.log")" ]] || return 1
    [[ $(wc -l < "$dir/connect.before") == 1 ]] || return 1
    [[ $(wc -l < "$dir/connect.recovered") == 2 ]] || return 1
    [[ $(wc -l < "$dir/calls") == 3 ]] || return 1
    ! grep -Eq '8444|--insecure|--proxy-insecure' "$dir/calls" || return 1
    grep -Fq -- '--noproxy  --proxy https://gm-proxy:8443' "$dir/calls"
}

wrong_proxy_ca_rejects_unrelated_failure() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_ASSERT_PRODUCT=product-1
    mapping_proxy_count_read_remote() { printf '1\n'; }
    mapping_scenario_connect_evidence() { printf 'existing\n'; }
    mapping_negative_wrong_ca() { return 0; }
    mapping_negative_proxy_ca_restore() { return 0; }
    mapping_fixture_docker() { printf 'connection refused\n'; return 7; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" || rc=$?
    [[ $rc == 80 ]]
}

wrong_proxy_ca_dispatches_dedicated_path() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_ASSERT_CASE=wrong_proxy_ca
    mapping_assert_kind_valid() { [[ $1 == fallback ]]; }
    mapping_assert_scenario() { printf 'mapping-fallback\n'; }
    mapping_scenario_fixture_prepare() { return 0; }
    mapping_scenario_calibrate() { return 0; }
    mapping_scenario_product_up() { printf 'product-1\n'; }
    mapping_scenario_upstream_count() { printf '0\n'; }
    mapping_scenario_upstream_commit() { return 0; }
    mapping_scenario_identity_write() { return 0; }
    mapping_scenario_upstream_refs() { return 0; }
    mapping_scenario_upstream_head() { return 0; }
    mapping_tls_negative_run() { printf '%s %s\n' "$1" "$MAPPING_ASSERT_PRODUCT" > "$2/dispatched"; }
    mapping_scenario_sync_exec() { return 90; }
    mapping_scenario_evidence fallback mapping-fallback-wrong-proxy-ca g1 "$dir" || rc=$?
    [[ $rc == 0 ]] && [[ $(cat "$dir/dispatched") == 'wrong_proxy_ca product-1' ]]
}

wrong_proxy_ca_accepts_dedicated_evidence() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'wrong_proxy_ca\n' > "$dir/case.tsv"
    printf '0\n' > "$dir/baseline.exit"
    printf '0\n' > "$dir/baseline.before"
    printf '1\n' > "$dir/baseline.after"
    printf '60\n' > "$dir/request.exit"
    printf '0\n' > "$dir/recovery.exit"
    printf '1\n' > "$dir/proxy.before"
    printf '1\n' > "$dir/proxy.after"
    printf '2\n' > "$dir/proxy.recovered"
    printf 'authority=github.com:443\tmode=accept\tdial_target=10.0.0.2:443\n' > "$dir/connect.before"
    cp "$dir/connect.before" "$dir/connect.log"
    cat "$dir/connect.log" "$dir/connect.log" > "$dir/connect.recovered"
    printf 'curl: (60) SSL certificate problem\n' > "$dir/request.log"
    cp "$dir/request.log" "$dir/request.failed.log"
    printf 'case\twrong_proxy_ca\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t60\n' > "$dir/tls-layer.tsv"
    mapping_negative_rejected wrong_proxy_ca fallback "$dir" || rc=$?
    [[ $rc == 0 ]] || return 1
    printf '2\n' > "$dir/proxy.after"
    rc=0; mapping_negative_rejected wrong_proxy_ca fallback "$dir" || rc=$?
    [[ $rc != 0 ]] || return 1
    printf '1\n' > "$dir/proxy.after"
    printf 'unrelated failure\n' > "$dir/request.failed.log"
    rc=0; mapping_negative_rejected wrong_proxy_ca fallback "$dir" || rc=$?
    [[ $rc != 0 ]]
}

failed=0
for name in wrong_proxy_ca_uses_product_8443_and_recovers wrong_proxy_ca_rejects_unrelated_failure wrong_proxy_ca_dispatches_dedicated_path wrong_proxy_ca_accepts_dedicated_evidence; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
