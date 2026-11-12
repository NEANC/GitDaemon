#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
MAPPING_PROFILE=fixture-profile

wrong_proxy_ca_uses_product_8443_and_recovers() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
    MAPPING_CLIENT_PROXY_CA=/ca/proxy-ca.crt MAPPING_CLIENT_UPSTREAM_CA=/ca/upstream-ca.crt
    MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
    MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_PRODUCT=product-1
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_scenario_upstream_count() { printf '0\n'; }
    mapping_proxy_count_read_remote() {
        [[ $1 == 8443 ]] || return 1
        if [[ -f $dir/recovered ]]; then printf '2\n'; elif [[ -f $dir/calls ]]; then printf '1\n'; else printf '0\n'; fi
    }
    mapping_scenario_connect_evidence() {
        [[ $1 == fallback && $2 == mapping-fallback-wrong-proxy-ca ]] || return 1
        if [[ -f $dir/calls ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        if [[ -f $dir/recovered ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        return 0
    }
    mapping_negative_wrong_ca() { [[ $1 == proxy-ca.crt ]] && : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { rm "$dir/injected"; : > "$dir/recovered"; }
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$dir/calls"
        if [[ -f $dir/injected ]]; then
            printf '传输失败：配置的 HTTPS 代理\nfatal: unable to access: SSL certificate problem: unable to get local issuer certificate\n'
            return 128
        fi
        printf '同步传输路径：配置的 HTTPS 代理\n'
    }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 0 ]] || return 1
    [[ $(cat "$dir/baseline.exit") == 0 && $(cat "$dir/request.exit") == 128 ]] || return 1
    [[ $(cat "$dir/baseline.before") == 0 && $(cat "$dir/baseline.after") == 1 ]] || return 1
    grep -Eqi 'certificate|issuer|SSL' "$dir/request.failed.log" || return 1
    grep -Fq '传输失败：配置的 HTTPS 代理' "$dir/request.failed.log" || return 1
    [[ $(cat "$dir/recovery.exit") == 0 ]] || return 1
    [[ $(cat "$dir/proxy.before") == 1 && $(cat "$dir/proxy.after") == 1 ]] || return 1
    [[ $(cat "$dir/proxy.recovered") == 2 ]] || return 1
    [[ $(cat "$dir/connect.before") == "$(cat "$dir/connect.log")" ]] || return 1
    [[ $(wc -l < "$dir/connect.baseline") == 1 ]] || return 1
    [[ $(wc -l < "$dir/connect.before") == 1 ]] || return 1
    [[ $(wc -l < "$dir/connect.recovered") == 2 ]] || return 1
    [[ $(wc -l < "$dir/calls") == 3 ]] || return 1
    ! grep -Eq '8444|--insecure|--proxy-insecure' "$dir/calls" || return 1
    [[ $(mapping_scenario_gitconfig_content) == *'proxySSLCAInfo = /ca/proxy-ca.crt'* ]] || return 1
    grep -Fq 'git-mirror-sync.sh' "$dir/calls" || return 1
    grep -Fq 'PROXY_URL=https://gm-proxy:8443' "$dir/calls"
}

wrong_proxy_ca_rejects_unrelated_failure() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_ASSERT_PRODUCT=product-1
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { printf '1\n'; }
    mapping_scenario_connect_evidence() { printf 'existing\n'; }
    mapping_negative_wrong_ca() { return 0; }
    mapping_negative_proxy_ca_restore() { return 0; }
    mapping_fixture_docker() { printf 'connection refused\n'; return 7; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
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
    mapping_tls_negative_run() { printf '%s %s %s %s\n' "$1" "$MAPPING_ASSERT_PRODUCT" "${3:-missing}" "${4:-missing}" > "$2/dispatched"; }
    mapping_scenario_sync_exec() { return 90; }
    mapping_scenario_evidence fallback mapping-fallback-wrong-proxy-ca g1 "$dir" || rc=$?
    [[ $rc == 0 ]] && [[ $(cat "$dir/dispatched") == 'wrong_proxy_ca product-1 fallback mapping-fallback-wrong-proxy-ca' ]]
}

# 本轮 CONNECT 记录必须包含目标 U，旧记录与伪造的增长不能充抵。
wrong_proxy_ca_rejects_unrelated_connect() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_ACCEPT_PORT=8443
    MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
    MAPPING_ASSERT_PRODUCT=product-1
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() {
        if [[ -f $dir/recovered ]]; then printf '2\n'; elif [[ -f $dir/calls ]]; then printf '1\n'; else printf '0\n'; fi
    }
    mapping_scenario_connect_evidence() {
        [[ $1 == fallback && $2 == mapping-fallback-wrong-proxy-ca ]] || return 1
        if [[ -f $dir/calls ]]; then printf 'authority=other.test:443\tmode=accept\tdial_target=140.82.112.9:443\n'; fi
        if [[ -f $dir/recovered ]]; then printf 'authority=other.test:443\tmode=accept\tdial_target=140.82.112.9:443\n'; fi
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/recovered"; }
    mapping_fixture_docker() {
        : > "$dir/calls"
        if [[ -f $dir/injected && ! -f $dir/recovered ]]; then printf 'SSL certificate problem\n'; return 128; fi
        printf '同步传输路径：配置的 HTTPS 代理\n'
    }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 ]]
}

wrong_proxy_ca_accepts_dedicated_evidence() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443 MP_U=140.82.112.9
    mapping_profile_load() { MP_U=140.82.112.9; }
    printf 'wrong_proxy_ca\n' > "$dir/case.tsv"
    printf '0\n' > "$dir/baseline.exit"
    printf '0\n' > "$dir/baseline.before"
    printf '1\n' > "$dir/baseline.after"
    printf '128\n' > "$dir/request.exit"
    printf '0\n' > "$dir/recovery.exit"
    printf '1\n' > "$dir/proxy.before"
    printf '1\n' > "$dir/proxy.after"
    printf '2\n' > "$dir/proxy.recovered"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n' > "$dir/connect.before"
    cp "$dir/connect.before" "$dir/connect.baseline"
    cp "$dir/connect.before" "$dir/connect.baseline.new"
    cp "$dir/connect.before" "$dir/connect.log"
    cat "$dir/connect.log" "$dir/connect.log" > "$dir/connect.recovered"
    cp "$dir/connect.before" "$dir/connect.recovered.new"
    printf '传输失败：配置的 HTTPS 代理\nfatal: SSL certificate problem\n' > "$dir/request.log"
    cp "$dir/request.log" "$dir/request.failed.log"
    printf 'case\twrong_proxy_ca\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t128\n' > "$dir/tls-layer.tsv"
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

wrong_proxy_ca_restore_uses_both_real_mounts_and_exact_bytes() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MP_RUN_ID=contract
    printf '%s\n' '-----BEGIN CERTIFICATE-----' first second '-----END CERTIFICATE-----' > "$dir/source"
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$dir/argv"
        [[ $* == *"-v $(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT:ro"* && $* == *"-v $(mapping_ca_volume):$MAPPING_CA_MOUNT"* ]] || return 9
        [[ $* == *"$MAPPING_ASSET_ROOT/proxy/tls/ca.crt"* && $* == *"$MAPPING_CLIENT_PROXY_CA"* && $* == *'cmp -s'* ]] || return 9
        cp "$dir/source" "$dir/target"
    }
    mapping_negative_proxy_ca_restore || rc=$?
    [[ $rc == 0 ]] && cmp -s "$dir/source" "$dir/target"
}

wrong_proxy_ca_restores_after_injected_evidence_failure() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/injected ]]; then return 9; fi
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() {
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
        printf '0\n'
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/restored"; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 && -f $dir/restored && -f $dir/baseline.exit && -f $dir/case.tsv ]]
}

wrong_proxy_ca_restore_failure_keeps_original_failure() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/injected ]]; then return 9; fi
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() {
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
        printf '0\n'
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/restored"; return 9; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 && -f $dir/restored && -f $dir/baseline.exit && -f $dir/case.tsv ]]
}

wrong_proxy_ca_assertion_failure_still_restores() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_scenario_upstream_count() { printf '0\n'; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() {
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
        printf '0\n'
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/restored"; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 1 && -f $dir/restored && $(cat "$dir/request.exit") == 0 ]]
}

wrong_proxy_ca_assertion_and_restore_failure_returns_80() {
    local dir rc=0
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_scenario_upstream_count() { printf '0\n'; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() {
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
        printf '0\n'
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/restored"; return 9; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 && -f $dir/restored && $(cat "$dir/request.exit") == 0 ]]
}

# 注入已写坏 CA 后返回失败，必须恢复并保留三份原始证据。
wrong_proxy_ca_partial_injection_failure_restores_and_preserves_evidence() {
    local dir rc=0 name restore_rc
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/baseline.exit ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
        fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() {
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"
        printf '0\n'
    }
    mapping_negative_wrong_ca() { printf 'inject\n' >> "$dir/calls"; printf 'partial CA\n' > "$dir/ca"; return 9; }
    mapping_negative_proxy_ca_restore() { printf 'restore\n' >> "$dir/calls"; printf 'original CA\n' > "$dir/ca"; return "$restore_rc"; }
    for restore_rc in 0 9; do
        dir=$(mktemp -d)
        for name in request.exit request.failed.log tls-layer.tsv; do
            printf '旧证据:%s\n\n' "$name" > "$dir/$name"
            cp "$dir/$name" "$dir/$name.before"
        done
        rc=0
        mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
        [[ $rc == 80 && $(cat "$dir/ca") == 'original CA' ]] || return 1
        [[ $(cat "$dir/calls") == $'inject\nrestore' ]] || return 1
        for name in request.exit request.failed.log tls-layer.tsv; do
            cmp -s "$dir/$name.before" "$dir/$name" || return 1
        done
    done
}

# 原本缺失的注入阶段证据不能因失败路径出现。
wrong_proxy_ca_partial_injection_failure_keeps_missing_evidence() {
    local dir rc=0 name
    dir=$(mktemp -d)
    MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PRODUCT_IMAGE=product
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_proxy_count_read_remote() { if [[ -f $dir/baseline.exit ]]; then printf '1\n'; else printf '0\n'; fi; }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/baseline.exit ]]; then printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'; fi
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'
    }
    mapping_tls_product_request() { printf '同步传输路径：配置的 HTTPS 代理\n' > "$1/request.log"; printf '0\n'; }
    mapping_negative_wrong_ca() { printf 'inject\n' >> "$dir/calls"; printf 'partial CA\n' > "$dir/ca"; return 9; }
    mapping_negative_proxy_ca_restore() { printf 'restore\n' >> "$dir/calls"; printf 'original CA\n' > "$dir/ca"; }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 && $(cat "$dir/ca") == 'original CA' ]] || return 1
    [[ $(cat "$dir/calls") == $'inject\nrestore' ]] || return 1
    for name in request.exit request.failed.log tls-layer.tsv; do [[ ! -e $dir/$name ]] || return 1; done
}

# 按真实绝对挂载路径执行恢复命令，并拒绝写入后字节不一致。
wrong_proxy_ca_restore_executes_mounted_paths_and_rejects_mismatch() {
    local dir rc=0 script source target mismatch=0
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MP_RUN_ID=contract
    MAPPING_FIXTURE_MOUNT="$dir/assets" MAPPING_ASSET_ROOT="$dir/assets"
    MAPPING_CA_MOUNT="$dir/ca" MAPPING_CLIENT_PROXY_CA="$dir/ca/proxy-ca.crt"
    mkdir -p "$dir/assets/proxy/tls" "$dir/ca"
    source="$MAPPING_ASSET_ROOT/proxy/tls/ca.crt" target=$MAPPING_CLIENT_PROXY_CA
    printf 'real CA\nsecond line\n' > "$source"
    printf 'partial CA\n' > "$target"
    mapping_fixture_docker() {
        [[ $* == *"-v $(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT:ro"* && $* == *"-v $(mapping_ca_volume):$MAPPING_CA_MOUNT"* ]] || return 9
        while [[ $# -gt 0 && $1 != -c ]]; do shift; done
        script=$2
        [[ $3 == sh && $4 == "$source" && $5 == "$target" ]] || return 9
        if (( mismatch )); then script=${script/cmp -s/printf corrupted >> \"\$2\"; cmp -s}; fi
        bash -c "$script" sh "$source" "$target"
    }
    mapping_negative_proxy_ca_restore || return 1
    cmp -s "$source" "$target" || return 1
    mismatch=1
    mapping_negative_proxy_ca_restore || rc=$?
    [[ $rc != 0 ]] && ! cmp -s "$source" "$target"
}

wrong_proxy_ca_samples_real_upstream_boundary() {
    local dir rc=0 dial=5 mode=stable
    dir=$(mktemp -d)
    MAPPING_PRODUCT_IMAGE=product MAPPING_PROXY_ACCEPT_PORT=8443
    MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443
    mapping_profile_load() { MP_U=140.82.112.9; }
    mapping_scenario_upstream_count() {
        printf '%s\n' "$*" >> "$dir/upstream.calls"
        [[ $mode != unavailable ]] || return 9
        if [[ $mode == growth && -f $dir/request.failed.log ]]; then printf '6\n'; else printf '%s\n' "$dial"; fi
    }
    mapping_proxy_count_read_remote() {
        if [[ -f $dir/recovered ]]; then printf '2\n'; elif [[ -f $dir/request.baseline.log ]]; then printf '1\n'; else printf '0\n'; fi
    }
    mapping_scenario_connect_evidence() {
        if [[ -f $dir/request.baseline.log ]]; then printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'; fi
        if [[ -f $dir/recovered ]]; then printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.9:443\n'; fi
    }
    mapping_negative_wrong_ca() { : > "$dir/injected"; }
    mapping_negative_proxy_ca_restore() { : > "$dir/recovered"; dial=9; }
    mapping_fixture_docker() {
        if [[ -f $dir/injected && ! -f $dir/recovered ]]; then printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n'; return 128; fi
        printf '同步传输路径：配置的 HTTPS 代理\n'
    }
    mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 0 && $(cat "$dir/upstream.before") == 5 && $(cat "$dir/upstream.after") == 5 ]] || return 1
    [[ $(wc -l < "$dir/upstream.calls") == 2 ]] || return 1
    [[ $(cat "$dir/upstream.calls") == $'fallback mapping-fallback-wrong-proxy-ca '"$dir"$'\nfallback mapping-fallback-wrong-proxy-ca '"$dir" ]] || return 1
    mode=growth; dial=5; rm -f "$dir/recovered"; rm -rf "$dir"; dir=$(mktemp -d)
    rc=0; mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 1 && -f $dir/recovered && $(cat "$dir/upstream.before") == 5 && $(cat "$dir/upstream.after") == 6 ]] || return 1
    mode=unavailable; rm -rf "$dir"; dir=$(mktemp -d)
    rc=0; mapping_tls_negative_run wrong_proxy_ca "$dir" fallback mapping-fallback-wrong-proxy-ca || rc=$?
    [[ $rc == 80 && -f $dir/recovered ]]
}

failed=0
for name in wrong_proxy_ca_uses_product_8443_and_recovers wrong_proxy_ca_rejects_unrelated_failure wrong_proxy_ca_dispatches_dedicated_path wrong_proxy_ca_rejects_unrelated_connect wrong_proxy_ca_accepts_dedicated_evidence wrong_proxy_ca_restore_uses_both_real_mounts_and_exact_bytes wrong_proxy_ca_restores_after_injected_evidence_failure wrong_proxy_ca_restore_failure_keeps_original_failure wrong_proxy_ca_assertion_failure_still_restores wrong_proxy_ca_assertion_and_restore_failure_returns_80 wrong_proxy_ca_partial_injection_failure_restores_and_preserves_evidence wrong_proxy_ca_partial_injection_failure_keeps_missing_evidence wrong_proxy_ca_restore_executes_mounted_paths_and_rejects_mismatch wrong_proxy_ca_samples_real_upstream_boundary; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
