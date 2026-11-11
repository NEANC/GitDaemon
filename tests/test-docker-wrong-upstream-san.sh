#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

upstream_evidence_survives_restart() {
    local script
    script=$(mapping_upstream_serve_script)
    [[ $script == *'if test ! -f "$E/requests.log"; then : > "$E/requests.log" || exit 1; fi'* ]]
}

upstream_san_blocks_fallback() {
    MAPPING_ASSERT_CASE=wrong_upstream_san MAPPING_ASSERT_SNAPSHOT_MODE=valid MAPPING_ASSERT_DNS_MODE=none
    mapping_negative_prepare fallback mapping-fallback-wrong-upstream-san "$WORK"
    [[ $MAPPING_ASSERT_SNAPSHOT_MODE == none ]]
}

upstream_leaf_uses_frozen_address() {
    local dir=$WORK/leaf-check rc=0
    mkdir -p "$dir"
    (
        MAPPING_ASSERT_PRODUCT=product MP_U=140.82.112.11 MAPPING_ASSET_ROOT=/assets
        mapping_upstream_container() { printf 'upstream\n'; }
        mapping_fixture_docker() {
            if [[ $1 == exec && $2 == upstream ]]; then printf 'sha256 Fingerprint=AA\n'; return 0; fi
            [[ $* == *'140.82.112.11'* && $* == *'-servername github.com'* ]] || return 1
            printf '%s\n' '-----BEGIN CERTIFICATE-----' 'invalid' '-----END CERTIFICATE-----'
        }
        mapping_upstream_san_leaf "$dir" original 2>/dev/null
    ) || rc=$?
    [[ $rc == 80 ]]
}

volume_pair_roundtrip() {
    local root=$WORK/volume d=$WORK/volume/upstream/tls script rc=0
    mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '//CN=fixture-ca' \
        -keyout "$d/ca.key" -out "$d/ca.crt" >/dev/null 2>&1 || return 1
    openssl req -newkey rsa:2048 -nodes -subj '//CN=github.com' \
        -keyout "$d/srv.key" -out "$WORK/original.csr" >/dev/null 2>&1 || return 1
    printf 'subjectAltName=DNS:github.com\n' > "$WORK/original.ext"
    openssl x509 -req -in "$WORK/original.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" \
        -CAcreateserial -days 2 -extfile "$WORK/original.ext" -out "$d/srv.crt" >/dev/null 2>&1 || return 1
    cp "$d/srv.crt" "$WORK/original.crt"
    cp "$d/srv.key" "$WORK/original.key"
    script=$(mapping_upstream_san_volume_script) || return 1
    if [[ $OSTYPE == cygwin || $OSTYPE == msys* ]]; then script=$(printf '%s' "$script" | awk '{gsub("/CN=other-host.invalid", "//CN=other-host.invalid"); print}'); fi
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=replace sh -c "$script" || return 1
    ! cmp -s "$d/srv.crt" "$WORK/original.crt" || return 1
    openssl verify -CAfile "$d/ca.crt" "$d/srv.crt" >/dev/null || return 1
    openssl x509 -in "$d/srv.crt" -noout -checkhost github.com > "$WORK/hostname" || rc=$?
    [[ $rc != 0 ]] && grep -q 'does NOT match' "$WORK/hostname" || return 1
    [[ "$(openssl x509 -in "$d/srv.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)" == \
        "$(openssl pkey -in "$d/srv.key" -pubout -outform DER | openssl dgst -sha256)" ]] || return 1
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=restore sh -c "$script" || return 1
    cmp -s "$d/srv.crt" "$WORK/original.crt" && cmp -s "$d/srv.key" "$WORK/original.key"
}

volume_sign_failure_restores_pair() {
    local root=$WORK/sign-failure d=$WORK/sign-failure/upstream/tls script real_openssl
    mkdir -p "$d" "$WORK/sign-bin"
    cp "$WORK/original.crt" "$d/srv.crt"
    cp "$WORK/original.key" "$d/srv.key"
    cp "$WORK/volume/upstream/tls/ca.crt" "$WORK/volume/upstream/tls/ca.key" "$d/"
    real_openssl=$(command -v openssl) || return 1
    cat > "$WORK/sign-bin/openssl" <<'SH'
#!/bin/sh
if [ "$1" = x509 ] && [ "$2" = -req ]; then
    printf 'sign-entered\n' > "$SIGN_ENTERED"
    exit 9
fi
exec "$REAL_OPENSSL" "$@"
SH
    chmod +x "$WORK/sign-bin/openssl"
    script=$(mapping_upstream_san_volume_script) || return 1
    if [[ $OSTYPE == cygwin || $OSTYPE == msys* ]]; then script=$(printf '%s' "$script" | awk '{gsub("/CN=other-host.invalid", "//CN=other-host.invalid"); print}'); fi
    if PATH="$WORK/sign-bin:$PATH" REAL_OPENSSL="$real_openssl" SIGN_ENTERED="$root/sign-entered" \
        MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=replace sh -c "$script"; then return 1; fi
    [[ -f $root/sign-entered ]] || return 1
    cmp -s "$d/srv.crt" "$WORK/original.crt" || return 1
    cmp -s "$d/srv.key" "$WORK/original.key" || return 1
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=restore sh -c "$script"
}

run_case() {
    local mode=$1 expected=$2 rc=0 dir=$WORK/$1
    mkdir -p "$dir/control"
    (
        MODE=$mode EVENTS=$dir/events MAPPING_ASSERT_PRODUCT=product MP_U=140.82.112.11 MAPPING_PROFILE=profile
        MAPPING_PROXY_ACCEPT_PORT=8443 MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443
        printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"
        printf 'abc\n' > "$dir/head.expected"
        printf 'abc\n' > "$dir/control/unique-commit"
        mapping_profile_load() { return 0; }
        mapping_scenario_valid() { return 0; }
        mapping_assert_identity_load() { MPA_UNIQUE_COMMIT=abc; [[ $MODE != identity-invalid ]]; }
        printf '2\n' > "$dir/proxy.count"
        printf '2\n' > "$dir/upstream.count"
        : > "$dir/connect.source"
        mapping_proxy_count_read_remote() { cat "$dir/proxy.count"; }
        mapping_scenario_upstream_count() {
            if [[ $MODE == delayed-count || $MODE == stuck-count ]]; then
                if [[ -f $dir/replaced && -f $dir/request.failed.log ]]; then
                    local reads=0
                    [[ ! -f $dir/count.reads ]] || reads=$(cat "$dir/count.reads")
                    printf '%s\n' "$((reads + 1))" > "$dir/count.reads"
                    if [[ $MODE == stuck-count || $reads == 0 ]]; then printf '3\n'; return; fi
                fi
            fi
            cat "$dir/upstream.count"
        }
        mapping_scenario_connect_evidence() { cat "$dir/connect.source"; }
        mapping_scenario_local_refs() { if [[ $MODE == absent-unique ]]; then printf 'old\trefs/heads/main\n'; else printf 'abc\trefs/heads/main\n'; fi; }
        mapping_scenario_local_head() { printf 'abc\n'; }
        mapping_scenario_local_fsck() { printf '0\n'; }
        mapping_upstream_san_leaf() {
            printf 'leaf:%s\n' "$2" >> "$EVENTS"
            [[ $MODE != leaf-fail || $2 != wrong ]] || return 80
            if [[ $2 == wrong ]]; then printf 'wrong\n' > "$dir/leaf.wrong"; else printf 'original\n' > "$dir/leaf.$2"; fi
        }
        mapping_upstream_san_replace() { printf 'replace\n' >> "$EVENTS"; [[ $MODE != replace-fail ]] || return 80; : > "$dir/replaced"; }
        mapping_upstream_san_restore() { printf 'restore\n' >> "$EVENTS"; [[ $MODE != restore-fail ]] || return 80; : > "$dir/restored"; }
        mapping_upstream_san_restart() { printf 'restart\n' >> "$EVENTS"; [[ $MODE != restart-fail ]]; }
        mapping_tls_product_request() {
            printf 'request\n' >> "$EVENTS"
            if [[ -f $dir/restored ]]; then
                printf '同步传输路径：配置的 HTTPS 代理\n' > "$dir/request.log"
                printf '5\n' > "$dir/proxy.count"
                printf '5\n' > "$dir/upstream.count"
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' >> "$dir/connect.source"
                printf '0\n'
            elif [[ -f $dir/replaced ]]; then
                printf '传输失败：配置的 HTTPS 代理；fatal: SSL: no alternative certificate subject name matches target host name\n' > "$dir/request.log"
                [[ $MODE == git-other-error ]] && printf 'fatal: Could not resolve host\n' > "$dir/request.log"
                if [[ $MODE == stale-hostname ]]; then
                    printf 'fatal: SSL: no alternative certificate subject name matches target host name\nfatal: Could not resolve host\n' > "$dir/request.log"
                fi
                printf '4\n' > "$dir/proxy.count"
                printf '4\n' > "$dir/upstream.count"
                if [[ $MODE != no-connect ]]; then
                    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' >> "$dir/connect.source"
                fi
                if [[ $MODE == unexpected-success ]]; then printf '0\n'; else printf '60\n'; fi
            else
                printf '同步传输路径：配置的 HTTPS 代理\n' > "$dir/request.log"
                [[ $MODE == baseline-fail ]] && printf '60\n' || printf '0\n'
                printf '3\n' > "$dir/proxy.count"
                printf '3\n' > "$dir/upstream.count"
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' >> "$dir/connect.source"
            fi
        }
        mapping_upstream_san_case "$dir" fallback mapping-fallback-wrong-upstream-san
    ) || rc=$?
    [[ $rc == "$expected" ]] || { printf '%s: expected %s, got %s\n' "$mode" "$expected" "$rc" >&2; return 1; }
    if [[ $mode != baseline-fail ]]; then
        [[ $(cat "$dir/events") == *restore* ]] || return 1
    fi
    if [[ $mode == ok || $mode == delayed-count ]]; then
        [[ $(cat "$dir/events") == *'replace'*'restart'*'leaf:wrong'*'request'*'restore'*'restart'*'leaf:restored'* ]] || return 1
        [[ $(cat "$dir/request.exit") == 60 && $(cat "$dir/refs.actual") == "$(cat "$dir/refs.expected")" ]] || return 1
        [[ $(cat "$dir/fsck.exit") == 0 ]] || return 1
    fi
    return 0
}

volume_pair_roundtrip
volume_sign_failure_restores_pair
upstream_evidence_survives_restart
upstream_san_blocks_fallback
upstream_leaf_uses_frozen_address
for spec in ok:0 baseline-fail:80 replace-fail:80 restart-fail:80 leaf-fail:80 no-connect:1 unexpected-success:1 git-other-error:1 stale-hostname:1 absent-unique:80 identity-invalid:80 delayed-count:0 stuck-count:80 restore-fail:80; do
    run_case "${spec%:*}" "${spec#*:}"
done
printf 'upstream SAN standalone PASS\n'
