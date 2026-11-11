#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
MAPPING_PROFILE=fixture-profile

upstream_ca_git_8443_restores_refs() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
    MAPPING_CLIENT_UPSTREAM_CA=/ca/upstream-ca.crt MAPPING_CLIENT_PROXY_CA=/ca/proxy-ca.crt
    MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
    MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_PRODUCT=product-1
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { [[ $1 == 8443 ]] && printf '%s\n' "$(cat "$dir/proxy-count")"; }
    mapping_scenario_upstream_count() { printf '%s\n' "$(cat "$dir/dial-count")"; }
    mapping_scenario_connect_evidence() {
        [[ $1 == fallback && $2 == mapping-fallback-wrong-upstream-ca ]] || return 9
        local n
        for ((n=0; n<$(cat "$dir/proxy-count"); n++)); do
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        done
    }
    mapping_negative_wrong_ca() { [[ $1 == upstream-ca.crt ]] && : > "$dir/injected"; }
    mapping_negative_upstream_ca_restore() { : > "$dir/restored"; }
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$dir/calls"
        local n
        n=$(cat "$dir/proxy-count"); printf '%s\n' "$((n+1))" > "$dir/proxy-count"
        n=$(cat "$dir/dial-count"); printf '%s\n' "$((n+1))" > "$dir/dial-count"
        if [[ -f $dir/injected && ! -f $dir/restored ]]; then
            printf 'fatal: unable to access https://github.com/acme/demo.git/: SSL certificate problem: unable to get local issuer certificate\n'
            return 128
        fi
        printf '同步传输路径：配置的 HTTPS 代理\n'
    }
    mapping_scenario_local_refs() { printf 'abc\trefs/heads/main\n'; }
    printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"
    printf '0\n' > "$dir/proxy-count" "$dir/dial-count"
    mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
    [[ $rc == 0 && $(cat "$dir/baseline.exit") == 0 && $(cat "$dir/request.exit") == 128 && $(cat "$dir/recovery.exit") == 0 ]] || return 1
    [[ $(cat "$dir/proxy.before") == 1 && $(cat "$dir/proxy.after") == 2 && $(cat "$dir/proxy.recovered") == 3 ]] || return 1
    [[ $(cat "$dir/upstream.before") == 1 && $(cat "$dir/upstream.after") == 2 ]] || return 1
    [[ $(cat "$dir/tls-layer.tsv") == *$'layer\tinner-failure'* ]] || return 1
    cmp -s "$dir/refs.expected" "$dir/refs.actual" || return 1
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || return 1
    [[ $MAPPING_ASSERT_REJECT_LAYER == tls-upstream ]] || return 1
    [[ $(wc -l < "$dir/calls") == 3 ]] || return 1
    grep -Fq 'PROXY_URL=https://gm-proxy:8443' "$dir/calls" || return 1
    ! grep -Eq '8444|--insecure|--proxy-insecure' "$dir/calls"
}

upstream_ca_wrong_layer_is_assertion_not_fixture() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'wrong_upstream_ca\n' > "$dir/case.tsv"
    for name in baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after connect.baseline.new connect.failed.new connect.recovered.new request.failed.log refs.expected refs.actual; do
        printf '0\n' > "$dir/$name"
    done
    printf 'case\twrong_upstream_ca\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t128\n' > "$dir/tls-layer.tsv"
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    rm "$dir/tls-layer.tsv"
    rc=0
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'case\twrong_upstream_ca\nlayer\tinner-failure\nconnect_delta\t1\nrequest_exit\t128\n' > "$dir/tls-layer.tsv"
    rc=0
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 1 ]]
}

upstream_ca_restore_uses_upstream_asset_and_client_volume() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MP_RUN_ID=contract
    MAPPING_FIXTURE_MOUNT="$dir/assets" MAPPING_ASSET_ROOT="$dir/assets"
    MAPPING_CA_MOUNT="$dir/ca" MAPPING_CLIENT_UPSTREAM_CA="$dir/ca/upstream-ca.crt"
    mkdir -p "$dir/assets/upstream/tls" "$dir/ca"
    printf 'original upstream CA\n' > "$dir/assets/upstream/tls/ca.crt"
    printf 'incorrect CA\n' > "$dir/ca/upstream-ca.crt"
    mapping_fixture_docker() {
        [[ $* == *"-v $(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT:ro"* && $* == *"-v $(mapping_ca_volume):$MAPPING_CA_MOUNT"* ]] || return 9
        while [[ $# -gt 0 && $1 != -c ]]; do shift; done
        [[ $3 == sh && $4 == "$dir/assets/upstream/tls/ca.crt" && $5 == "$dir/ca/upstream-ca.crt" ]] || return 9
        bash -c "$2" sh "$4" "$5"
    }
    mapping_negative_upstream_ca_restore || rc=$?
    [[ $rc == 0 ]] && cmp -s "$dir/assets/upstream/tls/ca.crt" "$dir/ca/upstream-ca.crt"
}

upstream_ca_missing_dial_is_not_inner_failure() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() {
        if [[ -f $dir/injected ]]; then printf '2\n'; elif [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi
    }
    mapping_scenario_upstream_count() { printf '1\n'; }
    mapping_scenario_connect_evidence() {
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        if [[ -f $dir/injected ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
    }
    mapping_tls_product_request() {
        if [[ -f $dir/injected ]]; then
            printf 'fatal: SSL certificate problem\n' > "$1/request.log"
            printf '128\n'
        else
            printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
            printf '0\n'
        fi
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_upstream_ca_restore() { : > "$dir/restored"; }
    mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
    [[ $rc == 1 && -f $dir/restored ]]
}

upstream_ca_missing_count_restores_and_returns_fixture() {
    local dir missing rc=0
    for missing in proxy-before upstream-before proxy-after upstream-after empty-proxy-before empty-upstream-after; do
        dir=$(mktemp -d)
        printf '0\n' > "$dir/proxy-count"
        printf '0\n' > "$dir/dial-count"
        MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
        mapping_profile_load() { MP_U=140.82.112.9; }
        mapping_proxy_count_read_remote() {
            if [[ $missing == empty-proxy-before && -f $dir/injected && ! -f $dir/request.exit ]]; then return 0; fi
            if [[ $missing == proxy-before && -f $dir/injected && ! -f $dir/request.exit ||
                  $missing == proxy-after && -f $dir/request.exit && ! -f $dir/restored ]]; then return 9; fi
            cat "$dir/proxy-count"
        }
        mapping_scenario_upstream_count() {
            if [[ $missing == empty-upstream-after && -f $dir/request.exit && ! -f $dir/restored ]]; then return 0; fi
            if [[ $missing == upstream-before && -f $dir/injected && ! -f $dir/request.exit ||
                  $missing == upstream-after && -f $dir/request.exit && ! -f $dir/restored ]]; then return 9; fi
            cat "$dir/dial-count"
        }
        mapping_scenario_connect_evidence() {
            local n
            for ((n=0; n<$(cat "$dir/proxy-count"); n++)); do
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
            done
        }
        mapping_tls_product_request() {
            local n
            n=$(cat "$dir/proxy-count"); printf '%s\n' "$((n+1))" > "$dir/proxy-count"
            n=$(cat "$dir/dial-count"); printf '%s\n' "$((n+1))" > "$dir/dial-count"
            if [[ -f $dir/injected && ! -f $dir/restored ]]; then
                printf 'fatal: SSL certificate problem\n' > "$1/request.log"
                printf '128\n'
            else
                printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
                printf '0\n'
            fi
        }
        mapping_negative_wrong_ca() { : > "$dir/injected"; }
        mapping_negative_upstream_ca_restore() { : > "$dir/restored"; }
        rc=0
        mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
        [[ $rc == 80 && -f $dir/restored ]] || return 1
    done
}

upstream_ca_missing_verdict_count_is_fixture() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'wrong_upstream_ca\n' > "$dir/case.tsv"
    for name in baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after connect.baseline.new connect.failed.new connect.recovered.new request.failed.log refs.expected refs.actual; do
        printf '1\n' > "$dir/$name"
    done
    printf '0\n' > "$dir/baseline.exit" "$dir/recovery.exit"
    printf 'case\twrong_upstream_ca\nlayer\tinner-failure\nconnect_delta\t1\nrequest_exit\t1\n' > "$dir/tls-layer.tsv"
    rm "$dir/upstream.after"
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 80 ]]
}

failed=0
for name in upstream_ca_git_8443_restores_refs upstream_ca_wrong_layer_is_assertion_not_fixture upstream_ca_restore_uses_upstream_asset_and_client_volume upstream_ca_missing_dial_is_not_inner_failure upstream_ca_missing_count_restores_and_returns_fixture upstream_ca_missing_verdict_count_is_fixture; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
