#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/docker-mapping-fixture.sh"
export IT_SOURCE_ONLY=1 IT_RUN_ID=run IT_NETWORK=gm-run-net
source "$HERE/test-docker-integration.sh"
source "$HERE/../scripts/git-mirror-sync.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
MAPPING_PROFILE=$WORK/profile.tsv
printf 'schema_version\t1\nrun_id\trun\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-run-m-net\nbridge\tmrun\n' > "$MAPPING_PROFILE"

write_evidence() {
    local kind=$1 dir=$WORK/$1
    mkdir -p "$dir/control"
    printf 'run_id\trun\nscenario\tmapping-%s-missing-map\ngeneration\tgen-%s\nnetwork_id\tnet-%s\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' "$kind" "$kind" "$kind" > "$dir/identity.tsv"
    : > "$dir/control/snapshot.content"
    printf 'snapshot\tabsent\nresolve_count\t0\n' > "$dir/validator.tsv"
    printf '无地址快照，使用系统 DNS\n' > "$dir/validator.log"
    if [[ $kind == fallback ]]; then
        printf '传输失败：配置的 HTTPS 代理\n' > "$dir/sync.log"
    else
        : > "$dir/sync.log"
    fi
    printf '无地址快照，使用系统 DNS\n传输失败：直连系统 DNS\nfatal: unable to access '\''https://github.com/acme/demo.git/'\'': Could not resolve host: github.com\n' >> "$dir/sync.log"
    printf '1\n' > "$dir/sync.exit"
    printf 'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n' > "$dir/dns.txt"
    printf 'accept\t0\nreject\t0\ntotal\t0\n' > "$dir/proxy.before"
    if [[ $kind == fallback ]]; then
        printf 'accept\t0\nreject\t1\ntotal\t1\n' > "$dir/proxy.after"
    else
        cp "$dir/proxy.before" "$dir/proxy.after"
    fi
    printf '0\n' > "$dir/upstream.before"
    printf '0\n' > "$dir/upstream.after"
    : > "$dir/connect.log"
    printf 'commit refs/heads/main\n' > "$dir/refs.expected"
    : > "$dir/refs.actual"
    printf 'commit\n' > "$dir/head.expected"
    printf 'HEAD\n' > "$dir/head.actual"
    printf '128\n' > "$dir/head.exit"
    printf '0\n' > "$dir/fsck.exit"
}

original_validator_does_not_resolve() (
    local kind=$1 dir=$WORK/original-$1 rc=0
    mkdir -p "$dir"
    RUN_ROOT=$dir LOG_FILE=$dir/log GITHUB_HOST=github.com
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GM_CONFIG[PROXY_URL]=''
    load_resolve_args "$dir/hosts/github-hosts.snapshot" || rc=$?
    build_transport_sequence || rc=$?
    [[ $rc == 0 && ${#GM_RESOLVE_ARGS[@]} == 0 && ${GM_TRANSPORT_SEQUENCE[*]} == system ]] || return 1
    [[ $(cat "$dir/log") == *'无地址快照，使用系统 DNS'* && ! -e $dir/hosts/github-hosts.snapshot ]]
)

validator_exec_uses_original_code() (
    local kind=$1 dir=$WORK/validator-$1 script rc=0
    mkdir -p "$dir"
    mapping_fixture_docker() {
        [[ $1 == exec && $2 == -e && $3 == "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" && $4 == product && $5 == /bin/bash && $6 == -c ]] || return 1
        script=${7//\/usr\/local\/lib\/git-mirror\/git-mirror-sync.sh/$HERE\/..\/scripts\/git-mirror-sync.sh}
        RUN_ROOT=$dir /bin/bash -c "$script"
    }
    mapping_scenario_missing_map_validator product "$dir" || rc=$?
    [[ $rc == 0 && $(cat "$dir/validator.tsv") == $'snapshot\tabsent\nresolve_count\t0' ]] || return 1
    grep -Fq '无地址快照，使用系统 DNS' "$dir/validator.log" || return 1
    mkdir -p "$dir/hosts"
    printf '140.82.112.11 github.com\n' > "$dir/hosts/github-hosts.snapshot"
    mapping_scenario_missing_map_validator product "$dir" || return 1
    [[ $(cat "$dir/validator.tsv") == $'snapshot\tpresent\nresolve_count\t0' ]]
)

check() {
    local kind=$1 expected=$2 rc=0
    mapping_negative_case_evidence_accept "missing-map/$kind" run "mapping-$kind-missing-map" "gen-$kind" manifest input "$WORK/$kind" || rc=$?
    [[ $rc == "$expected" ]] || { printf '%s expected=%s actual=%s\n' "$kind" "$expected" "$rc" >&2; return 1; }
}

missing_map_evidence() {
    local kind=$1 dir=$WORK/$1 name rc=0
    write_evidence "$kind"
    check "$kind" 0 || return 1
    printf 'wrong\n' > "$dir/identity.tsv"
    check "$kind" 80 || return 1
    write_evidence "$kind"
    printf 'run_id\tother\n' >> "$dir/identity.tsv"
    check "$kind" 80 || return 1
    write_evidence "$kind"
    for name in validator.tsv validator.log sync.log sync.exit dns.txt proxy.before proxy.after upstream.before upstream.after connect.log control/snapshot.content refs.actual head.actual head.exit fsck.exit; do
        mv "$dir/$name" "$dir/$name.saved"
        check "$kind" 80 || return 1
        mv "$dir/$name.saved" "$dir/$name"
    done
    printf '0\n' > "$dir/sync.exit"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'bad\n' > "$dir/sync.exit"
    check "$kind" 80 || return 1
    write_evidence "$kind"
    printf '1\n' > "$dir/fsck.exit"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf '0\n' > "$dir/head.exit"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf '1\n' > "$dir/sync.exit"
    printf '传输失败：直连系统 DNS\nConnection refused\n' > "$dir/sync.log"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'Could not resolve host: github.com\n' > "$dir/sync.log"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'github.com\tA\t140.82.112.11\n' > "$dir/dns.txt"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'snapshot\tabsent\nresolve_count\t1\n' > "$dir/validator.tsv"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'bad\n' > "$dir/validator.tsv"
    check "$kind" 80 || return 1
    write_evidence "$kind"
    printf 'not-empty\n' > "$dir/control/snapshot.content"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf '传输失败：直连系统 DNS\nfatal: unable to access '\''https://github.com/acme/demo.git/'\'': Connection refused\n' > "$dir/sync.log"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'fatal: unable to access '\''https://elsewhere.invalid/'\'': Could not resolve host: github.com\n' >> "$dir/sync.log"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf '1\n' > "$dir/upstream.after"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'accept\t0\nreject\t1\ntotal\t1\n' > "$dir/proxy.after"
    if [[ $kind == direct ]]; then check "$kind" 1 || return 1; fi
    write_evidence "$kind"
    if [[ $kind == fallback ]]; then
        cp "$dir/proxy.before" "$dir/proxy.after"
        check "$kind" 1 || return 1
    fi
    write_evidence "$kind"
    printf 'wrong\n' > "$dir/identity.tsv"
    check "$kind" 80 || return 1
    write_evidence "$kind"
    printf '同步传输路径：直连系统 DNS\n' >> "$dir/sync.log"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'commit refs/heads/main\n' > "$dir/refs.actual"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'commit\n' > "$dir/head.actual"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    mv "$dir/refs.expected" "$dir/refs.expected.saved"
    check "$kind" 80 || return 1
    mv "$dir/refs.expected.saved" "$dir/refs.expected"
    mv "$dir/head.expected" "$dir/head.expected.saved"
    check "$kind" 80 || return 1
    mv "$dir/head.expected.saved" "$dir/head.expected"
    : > "$dir/refs.expected"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    : > "$dir/head.expected"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'old refs/heads/main\n' > "$dir/refs.expected"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'old\n' > "$dir/head.expected"
    check "$kind" 1 || return 1
    write_evidence "$kind"
    printf 'commit refs/heads/main\n' > "$dir/refs.expected"
    printf 'commit\n' > "$dir/head.expected"
    check "$kind" 0 || return 1
    write_evidence "$kind"
    rc=0
    mapping_negative_case_evidence_accept "missing-map/$kind" run "mapping-$kind-missing-map" "gen-other" manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    rc=0
    mapping_negative_case_evidence_accept "missing-map/$kind" run "mapping-$kind-missing-map" "gen-$kind" other input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'commit\n' > "$dir/control/unique-commit"
    MAPPING_ASSERT_REJECT_LAYER=''
    MAPPING_ASSERT_GENERATION="gen-$kind" MP_RUN_ID=run
    mapping_negative_rejected missing-map "$kind" "$dir" || return 1
    [[ $MAPPING_ASSERT_JUDGE == 1 && $MAPPING_ASSERT_REJECT_LAYER == sync ]] || return 1
    return 0
}

missing_map_matrix() {
    local kind=$1 dir=$WORK/$1 rc=0
    write_evidence "$kind"
    printf 'missing-map/%s\trun\tmapping-%s-missing-map\tgen-%s\tmanifest\tinput\t%s\t0\tPASS\n' "$kind" "$kind" "$kind" "$dir" > "$WORK/matrix.tsv"
    mapping_negative_matrix_accept "$WORK/matrix.tsv" run manifest input || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'wrong\n' > "$dir/identity.tsv"
    rc=0
    mapping_negative_matrix_accept "$WORK/matrix.tsv" run manifest input || rc=$?
    [[ $rc == 80 ]]
}

scenario_runs_sync() (
    local kind=$1 dir=$WORK/scenario-$1 script rc=0
    mkdir -p "$dir/control"
    MAPPING_ASSERT_CASE=missing-map MAPPING_ASSERT_DNS_MODE=none
    MAPPING_ASSERT_GENERATION="gen-$kind" MP_RUN_ID=run
    MAPPING_UPSTREAM_OWNER=acme MAPPING_UPSTREAM_REPO=demo
    mapping_scenario_fixture_prepare() { mapping_negative_prepare "$@"; }
    mapping_scenario_calibrate() { return 0; }
    mapping_scenario_product_up() { printf 'product\n'; }
    mapping_scenario_upstream_count() { printf '0\n'; }
    mapping_scenario_upstream_commit() { printf 'commit\n' > "$dir/control/unique-commit"; }
    mapping_scenario_identity_write() {
        [[ $2 == "mapping-$kind-missing-map" ]] || return 80
        return 0
    }
    mapping_scenario_upstream_refs() { printf 'commit refs/heads/main\n'; }
    mapping_scenario_upstream_head() { printf 'commit\n'; }
    mapping_scenario_apply_negative() { return 0; }
    mapping_fixture_docker() {
        [[ $1 == exec ]] || return 1
        if [[ $2 == -e && $3 == "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" && $5 == /bin/bash ]]; then
            script=${7//\/usr\/local\/lib\/git-mirror\/git-mirror-sync.sh/$HERE\/..\/scripts\/git-mirror-sync.sh}
            RUN_ROOT=$dir /bin/bash -c "$script"
            return $?
        fi
        printf '无地址快照，使用系统 DNS\n传输失败：直连系统 DNS\nfatal: unable to access '\''https://github.com/acme/demo.git/'\'': Could not resolve host: github.com\n'
        return 1
    }
    mapping_scenario_proxy_after() { printf 'accept\t0\nreject\t0\ntotal\t0\n'; }
    mapping_scenario_connect_evidence() { return 0; }
    mapping_scenario_local_refs() { return 0; }
    mapping_scenario_local_head() { printf 'HEAD\n'; return 128; }
    mapping_scenario_local_fsck() { printf '0\n'; }
    mapping_scenario_dns_state() { printf 'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n'; }
    mapping_scenario_evidence "$kind" "mapping-$kind-missing-map" "gen-$kind" "$dir" || rc=$?
    [[ $rc == 0 && $(cat "$dir/sync.exit") == 1 && $(cat "$dir/head.exit") == 128 && $(cat "$dir/head.actual") == HEAD && $(cat "$dir/fsck.exit") == 0 && -s $dir/validator.tsv && -s $dir/validator.log ]] || return 1
    grep -Fq 'Could not resolve host: github.com' "$dir/sync.log"
)

integration_dispatches_missing_map() (
    local kind=$1 rc=0
    IT_EVIDENCE_DIR=$WORK/integration-$kind
    mkdir -p "$IT_EVIDENCE_DIR/control"
    IT_NEGATIVE_SEEN=()
    integration_slot_record() { return 0; }
    mapping_negative_run() {
        [[ $1 == missing-map && $2 == "$kind" ]] || return 80
        printf '%s\n' "$*" > "$IT_EVIDENCE_DIR/called"
        return 0
    }
    check_mapping_negative "missing map $kind" "missing-map/$kind" "$kind" || rc=$?
    [[ $rc == 0 && -f $IT_EVIDENCE_DIR/called && $(cat "$IT_EVIDENCE_DIR/called") == "missing-map $kind $IT_EVIDENCE_DIR/control/mapping-neg-missing-map-$kind" ]]
)

failed=0
for kind in fallback direct; do
    original_validator_does_not_resolve "$kind" || failed=1
    validator_exec_uses_original_code "$kind" || failed=1
    scenario_runs_sync "$kind" || failed=1
    integration_dispatches_missing_map "$kind" || failed=1
    missing_map_evidence "$kind" || failed=1
    missing_map_matrix "$kind" || failed=1
done
exit "$failed"
