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
    mapping_tls_client_upstream_ca_hash() {
        if [[ -f $dir/injected && ! -f $dir/restored ]]; then printf 'wrong-ca' | sha256sum | awk '{print $1}'; else printf 'original-ca' | sha256sum | awk '{print $1}'; fi
    }
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
    mapping_scenario_local_head() { printf 'abc\n'; }
    mapping_scenario_local_fsck() { printf '0\n'; }
    printf '0\n' > "$dir/proxy-count"
    printf '0\n' > "$dir/dial-count"
    printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"
    printf 'abc\n' > "$dir/head.expected"
    mkdir -p "$dir/control"
    printf 'abc\n' > "$dir/control/unique-commit"
    printf 'run_id\tr1\nscenario\tmapping-fallback\ngeneration\tg1\nnetwork_id\tn1\nimage_id\ti1\nprofile_sha256\tp1\ninput_sha256\ta1\nmanifest_sha256\tm1\nunique_commit\tabc\n' > "$dir/identity.tsv"
    mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
    [[ $rc == 0 && $(cat "$dir/baseline.exit") == 0 && $(cat "$dir/request.exit") == 128 && $(cat "$dir/recovery.exit") == 0 ]] || return 1
    [[ $(cat "$dir/proxy.before") == 1 && $(cat "$dir/proxy.after") == 2 && $(cat "$dir/proxy.recovered") == 3 ]] || return 1
    [[ $(cat "$dir/upstream.before") == 1 && $(cat "$dir/upstream.after") == 2 && $(cat "$dir/upstream.recovered") == 3 ]] || return 1
    [[ $(cat "$dir/ca.before.sha256") == "$(printf 'original-ca' | sha256sum | awk '{print $1}')" && $(cat "$dir/ca.after.sha256") == "$(printf 'wrong-ca' | sha256sum | awk '{print $1}')" && $(cat "$dir/ca.recovered.sha256") == "$(cat "$dir/ca.before.sha256")" ]] || return 1
    [[ $(cat "$dir/tls-layer.tsv") == *$'layer\tinner-failure'* ]] || return 1
    cmp -s "$dir/refs.expected" "$dir/refs.actual" || return 1
    cmp -s "$dir/head.expected" "$dir/head.actual" || return 1
    [[ $(cat "$dir/fsck.exit") == 0 ]] || return 1
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || return 1
    [[ $MAPPING_ASSERT_REJECT_LAYER == tls-upstream ]] || return 1
    printf 'fatal: unable to access https://elsewhere.invalid/: SSL certificate problem: unable to get local issuer certificate\n' > "$dir/request.failed.log"
    rc=0; mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'fatal: unable to access https://github.com/acme/demo.git/: SSL certificate problem: unable to get local issuer certificate\n' > "$dir/request.failed.log"
    mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || return 1
    local matrix="${dir}-matrix.tsv"
    printf 'wrong_upstream_ca\tr1\tmapping-fallback\tg1\tm1\ta1\t%s\t0\tPASS\n' "$dir" > "$matrix"
    for n in $MAPPING_NEGATIVE_CASES; do
        [[ $n == wrong_upstream_ca ]] && continue
        mkdir -p "$dir/raw-${n//\//-}"
        printf '%s\tr1\tmapping-fallback\tg1\tm1\ta1\t%s\t0\tPASS\n' "$n" "$dir/raw-${n//\//-}" >> "$matrix"
    done
    rc=0; mapping_negative_matrix_accept "$matrix" r1 m1 a1 || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'other\n' > "$dir/head.actual"
    rc=0; mapping_negative_matrix_accept "$matrix" r1 m1 a1 || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'abc\n' > "$dir/head.actual"
    rm -f "$matrix"
    for n in baseline.before baseline.after upstream.baseline.before upstream.baseline upstream.recovered ca.before.sha256 ca.after.sha256 ca.recovered.sha256 request.baseline.log request.recovery.log connect.failed.new; do
        mv "$dir/$n" "$dir/$n.saved"
        rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
        [[ $rc == 80 ]] || return 1
        mv "$dir/$n.saved" "$dir/$n"
    done
    for n in upstream.recovered ca.before.sha256 ca.after.sha256 ca.recovered.sha256; do
        cp "$dir/$n" "$dir/$n.saved"
        case $n in
            upstream.recovered) printf '2\n' > "$dir/$n" ;;
            ca.before.sha256) cp "$dir/ca.after.sha256" "$dir/$n" ;;
            ca.after.sha256) cp "$dir/ca.before.sha256" "$dir/$n" ;;
            ca.recovered.sha256) cp "$dir/ca.after.sha256" "$dir/$n" ;;
        esac
        rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
        [[ $rc == 1 ]] || return 1
        mv "$dir/$n.saved" "$dir/$n"
    done
    printf 'fatal: unrelated error\n' > "$dir/request.failed.log"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'fatal: unable to access https://github.com/acme/demo.git/: SSL certificate problem: unable to get local issuer certificate\n' > "$dir/request.failed.log"
    printf 'old\trefs/heads/main\n' > "$dir/refs.actual"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'abc\trefs/heads/main\n' > "$dir/refs.actual"
    printf 'other\n' > "$dir/head.actual"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'abc\n' > "$dir/head.actual"
    mv "$dir/fsck.exit" "$dir/fsck.saved"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback g1 m1 a1 "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    mv "$dir/fsck.saved" "$dir/fsck.exit"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_ca r1 mapping-fallback other m1 a1 "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    [[ $(wc -l < "$dir/calls") == 3 ]] || return 1
    grep -Fq 'PROXY_URL=https://gm-proxy:8443' "$dir/calls" || return 1
    ! grep -Eq '8444|--insecure|--proxy-insecure' "$dir/calls"
}

upstream_ca_recovery_requires_complete_positive_evidence() {
    local mode dir rc n
    for mode in stale-ref equal-stale-refs bad-head missing-object missing-refs missing-head missing-fsck invalid-fsck failed-head absent-unique absent-identity mismatched-identity ca-unchanged ca-not-restored unrelated-ssl recovery-flat-dial; do
        dir=$(mktemp -d)
        printf '0\n' > "$dir/proxy-count"
        printf '0\n' > "$dir/dial-count"
        MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
        MAPPING_CLIENT_UPSTREAM_CA=/ca/upstream-ca.crt MAPPING_CLIENT_PROXY_CA=/ca/proxy-ca.crt
        MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
        MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
        mkdir -p "$dir/control"
        if [[ $mode != absent-unique ]]; then printf 'abc\n' > "$dir/control/unique-commit"; fi
        if [[ $mode != absent-identity ]]; then
            printf 'run_id\tr1\nscenario\tmapping-fallback\ngeneration\tg1\nnetwork_id\tn1\nimage_id\ti1\nprofile_sha256\tp1\ninput_sha256\ta1\nmanifest_sha256\tm1\nunique_commit\tabc\n' > "$dir/identity.tsv"
        fi
        if [[ $mode == mismatched-identity ]]; then printf 'different\n' > "$dir/control/unique-commit"; fi
        mapping_profile_load() { MP_U=140.82.112.9; }
        mapping_proxy_count_read_remote() { cat "$dir/proxy-count"; }
        mapping_scenario_upstream_count() { cat "$dir/dial-count"; }
        mapping_scenario_connect_evidence() {
            for ((n=0; n<$(cat "$dir/proxy-count"); n++)); do
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
            done
        }
        mapping_negative_wrong_ca() { : > "$dir/injected"; }
        mapping_negative_upstream_ca_restore() { : > "$dir/restored"; }
        mapping_tls_client_upstream_ca_hash() {
            if [[ $mode == ca-unchanged ]]; then printf 'original-ca'; elif [[ $mode == ca-not-restored && -f $dir/injected ]]; then printf 'wrong-ca'; elif [[ -f $dir/injected && ! -f $dir/restored ]]; then printf 'wrong-ca'; else printf 'original-ca'; fi | sha256sum | awk '{print $1}'
        }
        mapping_fixture_docker() {
            n=$(cat "$dir/proxy-count"); printf '%s\n' "$((n+1))" > "$dir/proxy-count"
            if [[ $mode != recovery-flat-dial || ! -f $dir/restored ]]; then
                n=$(cat "$dir/dial-count"); printf '%s\n' "$((n+1))" > "$dir/dial-count"
            fi
            if [[ -f $dir/injected && ! -f $dir/restored ]]; then
                if [[ $mode == unrelated-ssl ]]; then printf 'fatal: unable to access https://elsewhere.invalid/: SSL certificate problem\n'; else printf 'fatal: unable to access https://github.com/acme/demo.git/: SSL certificate problem: unable to get local issuer certificate\n'; fi
                return 128
            fi
            printf '同步传输路径：配置的 HTTPS 代理\n'
        }
        mapping_scenario_local_refs() {
            [[ $mode != missing-refs ]] || return 9
            if [[ $mode == equal-stale-refs ]]; then printf 'old\trefs/heads/main\n'; else printf 'abc\trefs/heads/main\n'; fi
        }
        mapping_scenario_local_head() {
            [[ $mode != missing-head && $mode != failed-head ]] || return 9
            if [[ $mode == bad-head ]]; then printf 'other\n'; else printf 'abc\n'; fi
        }
        mapping_scenario_local_fsck() {
            [[ $mode != missing-fsck ]] || return 9
            if [[ $mode == missing-object ]]; then printf '1\n'; elif [[ $mode == invalid-fsck ]]; then printf 'invalid\n'; else printf '0\n'; fi
        }
        printf 'abc\n' > "$dir/head.expected"
        if [[ $mode == stale-ref ]]; then printf 'other\trefs/heads/main\n' > "$dir/refs.expected"; elif [[ $mode == equal-stale-refs ]]; then printf 'old\trefs/heads/main\n' > "$dir/refs.expected"; else printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"; fi
        rc=0
        mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
        if [[ $mode == equal-stale-refs ]]; then
            cmp -s "$dir/refs.expected" "$dir/refs.actual" || return 1
            ! mapping_assert_refs_contain "$dir/refs.expected" abc || return 1
            ! mapping_assert_refs_contain "$dir/refs.actual" abc || return 1
        fi
        if [[ $mode == missing-refs || $mode == missing-head || $mode == missing-fsck || $mode == invalid-fsck || $mode == failed-head || $mode == absent-unique || $mode == absent-identity ]]; then
            [[ $rc == 80 ]] || { printf '%s: expected 80, got %s\n' "$mode" "$rc" >&2; return 1; }
        else
            [[ $rc == 1 ]] || { printf '%s: expected 1, got %s\n' "$mode" "$rc" >&2; return 1; }
        fi
        [[ -f $dir/restored && $(cat "$dir/baseline.exit") == 0 ]] || { printf '%s: missing failure evidence\n' "$mode" >&2; return 1; }
        if [[ $mode != ca-unchanged ]]; then [[ $(cat "$dir/request.exit") == 128 ]] || return 1; fi
        if [[ $mode != ca-unchanged && $mode != ca-not-restored && $mode != unrelated-ssl ]]; then
            [[ $(cat "$dir/recovery.exit") == 0 ]] || return 1
        fi
        if [[ $mode != ca-unchanged ]]; then grep -Fq 'SSL certificate problem' "$dir/request.failed.log" || { printf '%s: missing failure log\n' "$mode" >&2; return 1; }; fi
    done
}

upstream_ca_wrong_layer_is_assertion_not_fixture() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'wrong_upstream_ca\n' > "$dir/case.tsv"
    for name in baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after upstream.recovered connect.baseline.new connect.failed.new connect.recovered.new request.failed.log refs.expected refs.actual; do
        printf '0\n' > "$dir/$name"
    done
    for name in ca.before.sha256 ca.after.sha256 ca.recovered.sha256; do printf '%064d\n' 0 > "$dir/$name"; done
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
    mapping_scenario_upstream_count() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
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
    mapping_tls_client_upstream_ca_hash() {
        if [[ -f $dir/injected && ! -f $dir/restored ]]; then printf 'wrong-ca'; else printf 'original-ca'; fi | sha256sum | awk '{print $1}'
    }
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
        mapping_tls_client_upstream_ca_hash() {
            if [[ -f $dir/injected && ! -f $dir/restored ]]; then printf 'wrong-ca'; else printf 'original-ca'; fi | sha256sum | awk '{print $1}'
        }
        rc=0
        mapping_tls_negative_run wrong_upstream_ca "$dir" fallback mapping-fallback-wrong-upstream-ca || rc=$?
        [[ $rc == 80 && -f $dir/restored ]] || { printf '%s: expected fixture, got %s\n' "$missing" "$rc" >&2; return 1; }
    done
}

upstream_ca_missing_verdict_count_is_fixture() {
    local dir rc=0
    dir=$(mktemp -d)
    printf 'wrong_upstream_ca\n' > "$dir/case.tsv"
    for name in baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after upstream.recovered ca.before.sha256 ca.after.sha256 ca.recovered.sha256 connect.baseline.new connect.failed.new connect.recovered.new request.failed.log refs.expected refs.actual; do
        printf '1\n' > "$dir/$name"
    done
    printf '0\n' > "$dir/baseline.exit" "$dir/recovery.exit"
    printf 'case\twrong_upstream_ca\nlayer\tinner-failure\nconnect_delta\t1\nrequest_exit\t1\n' > "$dir/tls-layer.tsv"
    rm "$dir/upstream.after"
    mapping_negative_rejected wrong_upstream_ca fallback "$dir" || rc=$?
    [[ $rc == 80 ]]
}

# 验证负例入口沿证据调用链保留判定与夹具退出码，并释放场景。
upstream_ca_entry_preserves_evidence_verdict() {
    local dir expected rc
    for expected in 1 80; do
        dir=$(mktemp -d)
        IT_CONTROL_DIR=$dir/control
        mkdir -p "$IT_CONTROL_DIR"
        mapping_assert_generation() { MAPPING_ASSERT_GENERATION=g1; }
        mapping_scenario_evidence() { return "$expected"; }
        mapping_scenario_release() { printf 'released\n' > "$4/released"; }
        rc=0
        mapping_negative_run wrong_upstream_ca fallback "$dir/evidence" || rc=$?
        [[ $rc == "$expected" && -f $dir/evidence/released && ${MAPPING_ASSERT_CASE:-} == '' ]] || return 1
    done
}

# 完整入口使用真实 TLS 取证与恢复，拒绝没有上游拨号增长或证书诊断的失败。
upstream_ca_entry_rejects_invalid_git_evidence() {
    local test_root mode rc n
    for mode in flat-dial bad-log; do
        test_root=$(mktemp -d)
        IT_CONTROL_DIR=$test_root/control
        mkdir -p "$IT_CONTROL_DIR"
        MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
        MAPPING_CLIENT_UPSTREAM_CA=/ca/upstream-ca.crt MAPPING_CLIENT_PROXY_CA=/ca/proxy-ca.crt
        MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
        MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
        printf '0\n' > "$test_root/proxy-count"
        printf '0\n' > "$test_root/dial-count"
        mapping_assert_generation() { MAPPING_ASSERT_GENERATION=g1; }
        mapping_profile_load() { MP_U=140.82.112.9; }
        mapping_scenario_fixture_prepare() { return 0; }
        mapping_scenario_calibrate() { return 0; }
        mapping_scenario_product_up() { printf 'product-1\n'; }
        mapping_scenario_upstream_count() { cat "$test_root/dial-count"; }
        mapping_scenario_upstream_commit() { return 0; }
        mapping_scenario_identity_write() { return 0; }
        mapping_scenario_upstream_refs() { printf 'abc\trefs/heads/main\n'; }
        mapping_scenario_upstream_head() { printf 'abc\n'; }
        mapping_proxy_count_read_remote() { cat "$test_root/proxy-count"; }
        mapping_scenario_connect_evidence() {
            for ((n=0; n<$(cat "$test_root/proxy-count"); n++)); do
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
            done
        }
        mapping_negative_wrong_ca() { : > "$test_root/injected"; }
        mapping_negative_upstream_ca_restore() { : > "$test_root/restored"; }
        mapping_tls_client_upstream_ca_hash() {
            if [[ -f $test_root/injected && ! -f $test_root/restored ]]; then printf 'wrong-ca'; else printf 'original-ca'; fi | sha256sum | awk '{print $1}'
        }
        mapping_fixture_docker() {
            n=$(cat "$test_root/proxy-count"); printf '%s\n' "$((n+1))" > "$test_root/proxy-count"
            if [[ $mode != flat-dial || ! -f $test_root/injected || -f $test_root/restored ]]; then
                n=$(cat "$test_root/dial-count"); printf '%s\n' "$((n+1))" > "$test_root/dial-count"
            fi
            if [[ -f $test_root/injected && ! -f $test_root/restored ]]; then
                if [[ $mode == bad-log ]]; then printf 'fatal: repository not found\n'; else printf 'fatal: SSL certificate problem\n'; fi
                return 128
            fi
            printf '同步传输路径：配置的 HTTPS 代理\n'
        }
        mapping_scenario_release() { printf 'released\n' > "$4/released"; }
        rc=0
        mapping_negative_run wrong_upstream_ca fallback "$test_root/evidence" || rc=$?
        [[ $rc == 1 && -f $test_root/restored && -f $test_root/evidence/released ]] || return 1
        [[ $(cat "$test_root/evidence/baseline.exit") == 0 && $(cat "$test_root/evidence/request.exit") == 128 ]] || return 1
        [[ ! -f $test_root/evidence/recovery.exit && ! -f $test_root/evidence/refs.actual ]] || return 1
    done
}

failed=0
for name in upstream_ca_git_8443_restores_refs upstream_ca_recovery_requires_complete_positive_evidence upstream_ca_wrong_layer_is_assertion_not_fixture upstream_ca_restore_uses_upstream_asset_and_client_volume upstream_ca_missing_dial_is_not_inner_failure upstream_ca_missing_count_restores_and_returns_fixture upstream_ca_missing_verdict_count_is_fixture upstream_ca_entry_preserves_evidence_verdict upstream_ca_entry_rejects_invalid_git_evidence; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
