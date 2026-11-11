#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/../scripts/git-mirror-sync.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LOG_FILE=$WORK/product.log
MAPPING_PROFILE=$WORK/profile
MAPPING_TOOLS_IMAGE=tools
MP_RUN_ID=run
MP_NETWORK_NAME=network
MP_D=140.82.112.13
MP_X=140.82.112.12
MP_U=140.82.112.11
MAPPING_ASSERT_PRODUCT=product
MAPPING_ASSERT_GENERATION=g1
MAPPING_ACK_GENERATION=g1
MAPPING_PROXY_HOST=gm-proxy
MAPPING_UPSTREAM_HOST=github.com
MAPPING_ASSERT_RESERVED_ADDR=198.18.0.1
printf 'profile\n' > "$MAPPING_PROFILE"
mapping_profile_load() { return 0; }
mapping_scenario_valid() { return 0; }
mapping_dns_container() { printf 'gm-run-dns\n'; }
mapping_fixture_wait() { return 0; }
mapping_fixture_docker() {
    printf '%s\n' "$*" >> "$WORK/docker.calls"
    case "$*" in
        *'logs product') printf '%s\n' "$MAPPING_PRODUCT_READY_MARK" ;;
        *'dig '* )
            case "$*" in
                *'gm-proxy A') printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; flags: qr aa; QUERY: 1, ANSWER: 1\ngm-proxy. 0 IN A 140.82.112.12\n;; SERVER: 140.82.112.13#53\n' ;;
                *'github.com A')
                    if [[ -n ${MAPPING_DNS_FAKE_HOST:-} ]]; then
                        printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; flags: qr aa; QUERY: 1, ANSWER: 1\ngithub.com. 0 IN A 140.82.112.11\n;; SERVER: 140.82.112.13#53\n'
                    else
                        printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; flags: qr aa; QUERY: 1, ANSWER: 0\n;; SERVER: 140.82.112.13#53\n'
                    fi
                    ;;
                *) printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; flags: qr aa; QUERY: 1, ANSWER: 0\n;; SERVER: 140.82.112.13#53\n' ;;
            esac
            ;;
        *'curl '*'http://github.com/') printf 'curl: (6) Could not resolve host: github.com\n' >&2; return 6 ;;
        *'curl '*'http://gm-proxy/') printf '* Trying %s:80...\ncurl: (28) Connection timed out\n' "$MP_X" >&2; return 28 ;;
        *'inspect -f'* ) printf 'id-dns\n' ;;
    esac
}
mapping_fixture_run() { printf '%s\n' "$*" >> "$WORK/created.calls"; printf 'new-dns\n'; }
resource_remove() { printf '%s\n' "$*" >> "$WORK/removed.calls"; }

dns_rebuild_and_restore() {
    local dir=$WORK/rebuild rc=0
    mkdir -p "$dir"
    MAPPING_DNS_FAKE_HOST=github.com MAPPING_DNS_FAKE_IP=$MP_U
    mapping_dns_set upstream mapping-fallback "$dir" || rc=$?
    [[ $rc == 0 ]] || return 1
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    mapping_scenario_dns_restore fallback mapping-fallback "$dir" || rc=$?
    [[ $rc == 0 ]] || return 1
    [[ $(wc -l < "$WORK/removed.calls") == 2 && $(wc -l < "$WORK/created.calls") == 2 ]] || return 1
    [[ $(wc -l < "$WORK/docker.calls") -ge 8 ]] || return 1
    [[ -f $dir/dns.restore && -f $dir/dns-rebuild-upstream.tsv && -f $dir/dns-rebuild-nxdomain.tsv ]]
}

dns_query_rejects_wrong_resolver() {
    local raw=$WORK/wrong-dig rc=0
    printf ';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1\n;; flags: qr aa; QUERY: 1, ANSWER: 0\n;; SERVER: 1.1.1.1#53\n' > "$raw"
    mapping_dns_query product "$MP_D" github.com A "$raw" 0 >/dev/null || rc=$?
    [[ $rc == 80 ]]
}

dns_restart_failure_is_fixture_80() {
    local dir=$WORK/restart-failure rc=0
    mkdir -p "$dir"
    mapping_fixture_docker() {
        case "$1" in
            inspect) printf 'id-dns\n' ;;
            restart) return 9 ;;
        esac
    }
    mapping_dns_set upstream mapping-fallback "$dir" || rc=$?
    [[ $rc == 80 ]]
}

dns_restore_requires_system_resolution_and_product_readiness() {
    local dir=$WORK/system-restore rc=0
    mkdir -p "$dir"
    mapping_dns_set() { return 0; }
    mapping_scenario_dns_state() { printf 'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t%s\n' "$MP_X"; }
    mapping_scenario_product_ready() { return 1; }
    mapping_fixture_docker() {
        case "$*" in
            *'curl '*'http://github.com/') printf '* Trying %s:80...\n' "$MP_U" >&2; return 28 ;;
            *'curl '*'http://gm-proxy/') printf '* Trying %s:80...\n' "$MP_X" >&2; return 28 ;;
        esac
    }
    MAPPING_ASSERT_PRODUCT=product
    mapping_scenario_dns_restore fallback mapping-fallback "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    mapping_scenario_product_ready() { return 0; }
    rc=0
    mapping_scenario_dns_restore fallback mapping-fallback "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    mapping_fixture_docker() {
        case "$*" in
            *'curl '*'http://github.com/') printf 'curl: (6) Could not resolve host: github.com\n' >&2; return 6 ;;
            *'curl '*'http://gm-proxy/') printf '* Trying %s:80...\n' "$MP_X" >&2; return 28 ;;
        esac
    }
    rc=0
    mapping_scenario_dns_restore fallback mapping-fallback "$dir" || rc=$?
    [[ $rc == 0 ]]
}

dns_false_green_requires_refs_head_before_dns() {
    local dir=$WORK/false-green rc=0
    mkdir -p "$dir"
    printf '0\n' > "$dir/sync.exit"
    printf '0\n' > "$dir/fsck.exit"
    printf '传输失败：直连加动态地址映射\n%s\n' "$MAPPING_ASSERT_MARK_SYSTEM" > "$dir/sync.log"
    mkdir -p "$dir/control"
    : > "$dir/control/snapshot.content"
    printf 'run_id\trun\nscenario\tmapping-fallback\ngeneration\tg1\nnetwork_id\tid\nimage_id\timage\nprofile_sha256\thash\ninput_sha256\thash\nmanifest_sha256\thash\nunique_commit\tabc\n' > "$dir/identity.tsv"
    printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"
    printf 'wrong\trefs/heads/main\n' > "$dir/refs.actual"
    printf 'abc\n' > "$dir/head.expected"
    printf 'wrong\n' > "$dir/head.actual"
    printf 'accept\t0\nreject\t0\ntotal\t0\n' > "$dir/proxy.before"
    printf 'accept\t0\nreject\t1\ntotal\t1\n' > "$dir/proxy.after"
    printf '0\n' > "$dir/upstream.before"
    printf '1\n' > "$dir/upstream.after"
    : > "$dir/connect.log"
    printf 'github.com\tA\t%s\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t%s\n' "$MP_U" "$MP_X" > "$dir/dns.txt"
    mapping_negative_rejected dns-false-green fallback "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'abc\trefs/heads/main\n' > "$dir/refs.actual"
    printf 'abc\n' > "$dir/head.actual"
    rc=0
    mapping_negative_rejected dns-false-green fallback "$dir" || rc=$?
    [[ $rc == 0 && $MAPPING_ASSERT_REJECT_LAYER == dns && $MAPPING_ASSERT_JUDGE == 1 ]]
}

missing_invalid_and_unreachable_keep_distinct_causes() {
    local dir=$WORK/causes case_name rc
    mkdir -p "$dir"
    mapping_assert_require_files() { return 0; }
    mapping_assert_identity_load() { MPA_UNIQUE_COMMIT=abc; MPA_SCENARIO=mapping-direct; return 0; }
    printf 'abc\trefs/heads/main\n' > "$dir/refs.expected"
    cp "$dir/refs.expected" "$dir/refs.actual"
    printf 'abc\n' > "$dir/head.expected"
    cp "$dir/head.expected" "$dir/head.actual"
    printf '0\n' > "$dir/sync.exit"
    printf '0\n' > "$dir/fsck.exit"
    printf '传输失败：直连加动态地址映射\n%s\n' "$MAPPING_ASSERT_MARK_SYSTEM" > "$dir/sync.log"
    printf 'github.com\tA\t%s\n' "$MP_U" > "$dir/dns.txt"
    MAPPING_ASSERT_SNAPSHOT_MODE=unallocated MP_N=140.82.112.14
    mkdir -p "$dir/control"
    printf '%s github.com\n' "$MP_N" > "$dir/control/snapshot.content"
    rc=0
    mapping_negative_rejected unreachable-map-system direct "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf '%s\n' "$MP_N" > "$dir/unreachable.txt"
    printf 'connection timed out\n' > "$dir/unreachable.log"
    rc=0
    mapping_negative_rejected unreachable-map-system direct "$dir" || rc=$?
    [[ $rc == 0 && $MAPPING_ASSERT_REJECT_LAYER == dns ]] || return 1
    printf '1\n' > "$dir/sync.exit"
    printf 'run_id\trun\nscenario\tmapping-direct\ngeneration\tg1\nnetwork_id\tid\nimage_id\timage\nprofile_sha256\thash\ninput_sha256\thash\nmanifest_sha256\thash\nunique_commit\tabc\n' > "$dir/identity.tsv"
    for case_name in missing-map invalid-map; do
        if [[ $case_name == missing-map ]]; then MAPPING_ASSERT_SNAPSHOT_MODE=none; else MAPPING_ASSERT_SNAPSHOT_MODE=reserved; fi
        if [[ $case_name == missing-map ]]; then
            printf '无地址快照，使用系统 DNS\n' > "$dir/sync.log"
            : > "$dir/control/snapshot.content"
        else
            printf '地址快照无效，忽略动态映射\n' > "$dir/sync.log"
            printf '%s github.com\n' "$MAPPING_ASSERT_RESERVED_ADDR" > "$dir/control/snapshot.content"
        fi
        rc=0
        mapping_negative_rejected "$case_name" direct "$dir" || rc=$?
        [[ $rc == 0 && $MAPPING_ASSERT_REJECT_LAYER == sync ]] || return 1
        printf '%s\n' "$MAPPING_ASSERT_MARK_MAPPING" >> "$dir/sync.log"
        rc=0
        mapping_negative_rejected "$case_name" direct "$dir" || rc=$?
        [[ $rc == 1 ]] || return 1
    done
}

missing_invalid_require_real_judge() {
    local dir=$WORK/false-green case_name rc
    [[ -f $dir/identity.tsv ]] || return 1
    printf '1\n' > "$dir/sync.exit"
    : > "$dir/control/snapshot.content"
    printf '无地址快照，使用系统 DNS\n' > "$dir/sync.log"
    for case_name in missing-map invalid-map; do
        if [[ $case_name == invalid-map ]]; then
            printf '%s github.com\n' "$MAPPING_ASSERT_RESERVED_ADDR" > "$dir/control/snapshot.content"
            printf '地址快照无效，忽略动态映射\n' > "$dir/sync.log"
        fi
        MAPPING_ASSERT_JUDGE=0 rc=0
        mapping_negative_rejected "$case_name" fallback "$dir" || rc=$?
        [[ $rc == 0 && $MAPPING_ASSERT_JUDGE == 1 && $MAPPING_ASSERT_REJECT_LAYER == sync ]] || return 1
    done
}

reserved_snapshots_never_generate_resolve() {
    local addr snap=$WORK/reserved-snapshot
    for addr in 10.0.0.9 172.16.0.9 192.168.0.9 192.0.2.9 198.51.100.9 203.0.113.9 198.18.0.9 198.19.255.9; do
        printf '%s github.com\n' "$addr" > "$snap"
        GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes GITHUB_HOST=github.com GM_RESOLVE_ARGS=()
        load_resolve_args "$snap" >/dev/null || return 1
        (( ${#GM_RESOLVE_ARGS[@]} == 0 )) || return 1
    done
}

missing_snapshot_never_generates_resolve() {
    local snap=$WORK/absent-snapshot
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes GITHUB_HOST=github.com GM_RESOLVE_ARGS=()
    load_resolve_args "$snap" >/dev/null || return 1
    (( ${#GM_RESOLVE_ARGS[@]} == 0 ))
}

unreachable_probe_rejects_empty_and_unrelated_failure() {
    local dir=$WORK/probe rc=0
    mkdir -p "$dir"
    MP_N=140.82.112.14
    mapping_fixture_docker() { return 7; }
    mapping_scenario_unreachable_probe product "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    mapping_fixture_docker() { printf 'curl: (7) Failed to connect to unrelated.example:443\n'; return 7; }
    rc=0
    mapping_scenario_unreachable_probe product "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    mapping_fixture_docker() { printf 'curl: (7) Failed to connect to %s port 443: Connection refused\n' "$MP_N"; return 7; }
    rc=0
    mapping_scenario_unreachable_probe product "$dir" || rc=$?
    [[ $rc == 0 && -s $dir/unreachable.log ]]
}

product_dns_has_no_host_search_suffix() {
    local dir=$WORK/product-dns rc=0
    mkdir -p "$dir"
    MAPPING_PROFILE=$WORK/profile MAPPING_PRODUCT_IMAGE=product MP_P=140.82.112.10
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_CALIBRATED_GENERATION=g1 MAPPING_ACK_GENERATION=g1
    mapping_scenario_release_probe() { return 0; }
    resource_create_register() { return 0; }
    mapping_scenario_data_write() { return 0; }
    mapping_ca_volume() { printf 'ca\n'; }
    mapping_fixture_create() {
        printf '%s\n' "$*" > "$WORK/product.create"
        return 80
    }
    mapping_scenario_product_up direct mapping-direct "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    grep -Fq -- '--dns-search=.' "$WORK/product.create"
}

failed=0
for name in dns_rebuild_and_restore dns_query_rejects_wrong_resolver dns_restart_failure_is_fixture_80 dns_restore_requires_system_resolution_and_product_readiness dns_false_green_requires_refs_head_before_dns missing_invalid_and_unreachable_keep_distinct_causes missing_invalid_require_real_judge reserved_snapshots_never_generate_resolve missing_snapshot_never_generates_resolve unreachable_probe_rejects_empty_and_unrelated_failure product_dns_has_no_host_search_suffix; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
