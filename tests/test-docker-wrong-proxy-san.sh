#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/docker-wrong-proxy-san.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

volume_pair_roundtrip() {
    local root=$WORK/volume d=$WORK/volume/proxy/tls script
    mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '//CN=fixture-ca' \
        -keyout "$d/ca.key" -out "$d/ca.crt" >/dev/null 2>&1 || return 1
    openssl req -newkey rsa:2048 -nodes -subj '//CN=gm-proxy' \
        -keyout "$d/srv.key" -out "$WORK/original.csr" >/dev/null 2>&1 || return 1
    printf 'subjectAltName=DNS:gm-proxy\n' > "$WORK/original.ext"
    openssl x509 -req -in "$WORK/original.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" \
        -CAcreateserial -days 2 -extfile "$WORK/original.ext" -out "$d/srv.crt" >/dev/null 2>&1 || return 1
    cp "$d/srv.crt" "$WORK/original.crt" || return 1
    cp "$d/srv.key" "$WORK/original.key" || return 1
    script=$(mapping_proxy_san_volume_script) || return 1
    if [[ $OSTYPE == cygwin || $OSTYPE == msys* ]]; then script=$(printf '%s' "$script" | awk '{gsub("/CN=other-host.invalid", "//CN=other-host.invalid"); print}'); fi
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=replace sh -c "$script" || return 1
    ! cmp -s "$d/srv.crt" "$WORK/original.crt" || return 1
    openssl verify -CAfile "$d/ca.crt" "$d/srv.crt" >/dev/null || return 1
    local hostname_rc=0
    openssl x509 -in "$d/srv.crt" -noout -checkhost gm-proxy > "$WORK/hostname.txt" || hostname_rc=$?
    [[ $hostname_rc != 0 ]] && grep -q 'does NOT match' "$WORK/hostname.txt" || return 1
    [[ "$(openssl x509 -in "$d/srv.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)" == \
        "$(openssl pkey -in "$d/srv.key" -pubout -outform DER | openssl dgst -sha256)" ]] || return 1
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=restore sh -c "$script" || return 1
    cmp -s "$d/srv.crt" "$WORK/original.crt" || return 1
    cmp -s "$d/srv.key" "$WORK/original.key" || return 1
    cmp -s "$d/srv.original.key" "$WORK/original.key" && cmp -s "$d/srv.original.crt" "$WORK/original.crt"
}

volume_sign_failure_restores_pair() {
    local root=$WORK/sign-failure d=$WORK/sign-failure/proxy/tls script real_openssl
    mkdir -p "$d" "$WORK/sign-bin" || return 1
    cp "$WORK/original.crt" "$d/srv.crt" || return 1
    cp "$WORK/original.key" "$d/srv.key" || return 1
    cp "$WORK/volume/proxy/tls/ca.crt" "$WORK/volume/proxy/tls/ca.key" "$d/" || return 1
    real_openssl=$(command -v openssl) || return 1
    cat > "$WORK/sign-bin/openssl" <<'SH'
#!/bin/sh
if [ "$1" = x509 ] && [ "$2" = -req ]; then
    printf 'sign-entered\n' > "$SIGN_ENTERED"
    exit 9
fi
exec "$REAL_OPENSSL" "$@"
SH
    chmod +x "$WORK/sign-bin/openssl" || return 1
    script=$(mapping_proxy_san_volume_script) || return 1
    if [[ $OSTYPE == cygwin || $OSTYPE == msys* ]]; then script=$(printf '%s' "$script" | awk '{gsub("/CN=other-host.invalid", "//CN=other-host.invalid"); print}'); fi
    if PATH="$WORK/sign-bin:$PATH" REAL_OPENSSL="$real_openssl" SIGN_ENTERED="$root/sign-entered" \
        MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=replace sh -c "$script"; then return 1; fi
    [[ -f $root/sign-entered ]] || return 1
    cmp -s "$d/srv.crt" "$WORK/original.crt" || return 1
    cmp -s "$d/srv.key" "$WORK/original.key" || return 1
    MAPPING_ASSET_ROOT="$root" MAPPING_SAN_ACTION=restore sh -c "$script" || return 1
    cmp -s "$d/srv.crt" "$WORK/original.crt" && cmp -s "$d/srv.key" "$WORK/original.key"
}

leaf_original_reads_live_pair() (
    local dir=$WORK/leaf-live rc=0
    mkdir -p "$dir"
    MAPPING_ASSERT_PRODUCT=product
    mapping_proxy_container() { printf 'proxy\n'; }
    mapping_fixture_docker() {
        if [[ $1 == exec && $2 == proxy && $3 == cmp ]]; then return 1; fi
        if [[ $1 == exec && $2 == proxy && $3 == openssl ]]; then
            openssl x509 -in "$WORK/original.crt" -noout -fingerprint -sha256
        elif [[ $1 == exec && $2 == product ]]; then
            cat "$WORK/original.crt"
        else
            return 1
        fi
    }
    mapping_proxy_san_leaf "$dir" original || rc=$?
    [[ $rc == 0 && -s $dir/leaf.original ]] || return 1
    rc=0
    mapping_proxy_san_leaf "$dir" restored || rc=$?
    [[ $rc == 80 ]]
)

hostname_probe_status() {
    local mode=$1 expected=$2 rc=0 dir=$WORK/probe-$1
    mkdir -p "$dir"
    (
        MAPPING_ASSERT_PRODUCT=product
        MAPPING_PROXY_HOST=gm-proxy MAPPING_PROXY_ACCEPT_PORT=8443
        MAPPING_CLIENT_PROXY_CA=/proxy-ca.crt MAPPING_CLIENT_UPSTREAM_CA=/upstream-ca.crt
        mapping_fixture_docker() {
            case "$mode" in
                hostname) printf 'SSL: no alternative certificate subject name matches target host name\n'; return 60 ;;
                other-certificate) printf 'SSL certificate problem: unable to get local issuer certificate\n'; return 60 ;;
                timeout) printf 'Operation timed out\n'; return 28 ;;
                exec-timeout) printf 'context deadline exceeded\n'; return 124 ;;
                exec-error) printf 'Error response from daemon: exec failed\n'; return 1 ;;
                curl-error) printf 'curl: option --proxy: is unknown\n'; return 1 ;;
                completed-error) printf 'Could not resolve proxy\n'; return 5 ;;
            esac
        }
        mapping_proxy_san_hostname_probe "$dir"
    ) || rc=$?
    [[ $rc == "$expected" ]] || { printf 'probe %s: expected %s, got %s\n' "$mode" "$expected" "$rc"; return 1; }
}

run_case() {
    local mode=$1 expected=$2 rc=0
    local dir=$WORK/$mode
    mkdir -p "$dir/control"
    (
        EVENTS=$dir/events
        MODE=$mode
        MAPPING_ASSERT_PRODUCT=product
        MP_U=140.82.112.11
        mapping_proxy_count_read_remote() {
            if [[ -f $dir/recovered.marker ]]; then printf '4\n'; else printf '3\n'; fi
        }
        mapping_scenario_connect_evidence() {
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
            if [[ -f $dir/recovered.marker ]]; then
                printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
            fi
            if [[ -f $dir/health.new && $MODE != stale-connect ]]; then
                if [[ $MODE == foreign-connect ]]; then
                    printf 'authority=elsewhere.invalid:443\tmode=accept\tdial_target=140.82.112.11:443\n'
                else
                    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
                fi
            fi
        }
        mapping_scenario_upstream_count() { printf '2\n'; }
        mapping_scenario_upstream_refs() { printf 'abc\trefs/heads/main\n'; }
        mapping_scenario_upstream_head() { printf 'abc\n'; }
        mapping_scenario_local_refs() { printf 'abc\trefs/heads/main\n'; }
        mapping_scenario_local_head() { printf 'abc\n'; }
        mapping_scenario_local_fsck() { printf '0\n'; }
        mapping_proxy_san_health() {
            printf 'health:%s\n' "$2" >> "$EVENTS"
            if [[ $2 == recovered ]]; then : > "$dir/health.new"; fi
            [[ $MODE != health-fail ]]
        }
        mapping_proxy_san_replace() { printf 'replace\n' >> "$EVENTS"; [[ $MODE != replace-fail ]]; }
        mapping_proxy_san_restore() {
            printf 'restore\n' >> "$EVENTS"
            [[ $MODE != restore-fail ]] || return 80
            : > "$dir/recovered.marker"
        }
        mapping_proxy_san_restart() { printf 'restart\n' >> "$EVENTS"; [[ $MODE != restart-fail ]]; }
        mapping_proxy_san_leaf() {
            printf 'leaf:%s\n' "$2" >> "$EVENTS"
            [[ $MODE != leaf-fail || $2 != wrong ]] || return 80
            if [[ $2 == wrong ]]; then printf 'wrong\n' > "$dir/leaf.wrong"; else printf 'original\n' > "$dir/leaf.$2"; fi
        }
        mapping_proxy_san_pair() {
            printf 'pair:%s\n' "$2" >> "$EVENTS"
        }
        mapping_proxy_san_hostname_probe() {
            printf 'hostname\n' >> "$EVENTS"
            [[ $MODE != probe-infrastructure ]] || return 80
        }
        mapping_scenario_sync_exec() {
            printf 'request\n' >> "$EVENTS"
            if [[ -f $dir/recovered.marker ]]; then
                printf '同步传输路径：配置的 HTTPS 代理\n' > "$dir/sync.log"
                printf '0\n' > "$dir/sync.exit"
                return 0
            fi
            if [[ $MODE == git-infrastructure ]]; then return 80; fi
            if [[ $MODE == git-other-error ]]; then
                printf '传输失败：配置的 HTTPS 代理；fatal: Could not resolve proxy\n' > "$dir/sync.log"
            else
                printf '传输失败：配置的 HTTPS 代理；fatal: SSL: no alternative certificate subject name matches target host name\n' > "$dir/sync.log"
            fi
            if [[ $MODE == unexpected-success ]]; then printf '0\n' > "$dir/sync.exit"; else printf '60\n' > "$dir/sync.exit"; fi
        }
        mapping_proxy_san_recovery_git() {
            printf 'git\n' >> "$EVENTS"
            [[ $MODE != git-fail ]]
        }
        mapping_proxy_san_case "$dir" fallback mapping-fallback-wrong-proxy-san
    ) || rc=$?
    [[ $rc == "$expected" ]] || { printf '%s: expected %s, got %s\n' "$mode" "$expected" "$rc"; return 1; }
    if [[ $mode != health-fail ]]; then
        local events
        events=$(cat "$dir/events")
        [[ $events == *restore* ]] || return 1
        if [[ $mode != restore-fail && $mode != restart-fail ]]; then [[ $events == *git* ]] || return 1; fi
        [[ ${events%%replace*} == *health:baseline* ]] || return 1
        if [[ $mode == ok ]]; then
            [[ $events == *'replace'*'restart'*'leaf:wrong'*'request'*'restore'*'restart'*'leaf:restored'*'git'* ]] || return 1
        fi
    fi
}

failed=0
volume_pair_roundtrip || failed=1
printf 'volume_pair_roundtrip EXIT=%s\n' "$failed"
volume_sign_failure_restores_pair || failed=1
printf 'volume_sign_failure_restores_pair EXIT=%s\n' "$failed"
leaf_original_reads_live_pair || failed=1
printf 'leaf_original_reads_live_pair EXIT=%s\n' "$failed"
for spec in hostname:0 other-certificate:1 timeout:80 exec-timeout:80 exec-error:80 curl-error:1 completed-error:1; do
    mode=${spec%:*} expected=${spec#*:}
    hostname_probe_status "$mode" "$expected" || failed=1
    printf 'hostname_probe_%s EXIT=%s\n' "$mode" "$failed"
done
for spec in ok:0 stale-connect:1 foreign-connect:1 health-fail:80 replace-fail:80 restart-fail:80 leaf-fail:80 probe-infrastructure:80 git-infrastructure:80 unexpected-success:1 restore-fail:80 git-fail:80 git-other-error:1; do
    mode=${spec%:*} expected=${spec#*:}
    run_case "$mode" "$expected" || failed=1
    printf '%s EXIT=%s\n' "$mode" "$failed"
done
exit "$failed"
