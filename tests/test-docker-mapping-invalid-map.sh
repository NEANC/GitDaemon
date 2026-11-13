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
    local category=$1 kind=$2 address=$3 dir=$WORK/$1-$2
    mkdir -p "$dir/control"
    printf 'run_id\trun\nscenario\tmapping-%s-inv-%s\ngeneration\tgen-%s-%s\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' "$kind" "$category" "$category" "$kind" > "$dir/identity.tsv"
    printf '%s github.com\n' "$address" > "$dir/control/snapshot.content"
    printf 'snapshot\tpresent\nresolve_count\t0\n' > "$dir/validator.tsv"
    printf '地址快照无效，忽略动态映射\n' > "$dir/validator.log"
    printf '地址快照无效，忽略动态映射\n传输失败：直连系统 DNS\nfatal: unable to access '\''https://github.com/acme/demo.git/'\'': Could not resolve host: github.com\n' > "$dir/sync.log"
    if [[ $kind == fallback ]]; then printf '传输失败：配置的 HTTPS 代理\n' >> "$dir/sync.log"; fi
    printf '1\n' > "$dir/sync.exit"
    printf 'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n' > "$dir/dns.txt"
    printf 'accept\t0\nreject\t0\ntotal\t0\n' > "$dir/proxy.before"
    if [[ $kind == fallback ]]; then printf 'accept\t0\nreject\t1\ntotal\t1\n' > "$dir/proxy.after"; else cp "$dir/proxy.before" "$dir/proxy.after"; fi
    printf '0\n' > "$dir/upstream.before"
    printf '0\n' > "$dir/upstream.after"
    : > "$dir/connect.log"
    printf 'commit refs/heads/main\n' > "$dir/refs.expected"
    : > "$dir/refs.actual"
    printf 'commit\n' > "$dir/head.expected"
    printf 'HEAD\n' > "$dir/head.actual"
    printf '128\n' > "$dir/head.exit"
    printf '0\n' > "$dir/fsck.exit"
    printf 'commit\n' > "$dir/control/unique-commit"
}

check() {
    local category=$1 kind=$2 expected=$3 rc=0 dir=$WORK/$1-$2
    mapping_negative_case_evidence_accept "invalid-map/$category/$kind" run "mapping-$kind-inv-$category" "gen-$category-$kind" manifest input "$dir" || rc=$?
    [[ $rc == "$expected" ]] || { printf '%s/%s expected=%s actual=%s\n' "$category" "$kind" "$expected" "$rc" >&2; return 1; }
}

invalid_case() (
    local category=$1 kind=$2 address=$3 dir=$WORK/$1-$2 name rc=0
    write_evidence "$category" "$kind" "$address"
    check "$category" "$kind" 0 || return 1
    for name in validator.tsv validator.log sync.exit sync.log control/snapshot.content head.exit refs.actual; do
        mv "$dir/$name" "$dir/$name.saved"
        check "$category" "$kind" 80 || return 1
        mv "$dir/$name.saved" "$dir/$name"
    done
    printf 'snapshot\tpresent\nresolve_count\t1\n' > "$dir/validator.tsv"
    check "$category" "$kind" 1 || return 1
    write_evidence "$category" "$kind" "$address"
    printf 'bad\n' > "$dir/validator.tsv"
    check "$category" "$kind" 80 || return 1
    write_evidence "$category" "$kind" "$address"
    printf '198.19.0.1 github.com\n' > "$dir/control/snapshot.content"
    check "$category" "$kind" 1 || return 1
    write_evidence "$category" "$kind" "$address"
    printf 'Connection refused\n' > "$dir/sync.log"
    check "$category" "$kind" 1 || return 1
    write_evidence "$category" "$kind" "$address"
    printf 'commit refs/heads/main\n' > "$dir/refs.actual"
    check "$category" "$kind" 1 || return 1
    write_evidence "$category" "$kind" "$address"
    printf '同步传输路径：直连系统 DNS\n' >> "$dir/sync.log"
    check "$category" "$kind" 1 || return 1
    write_evidence "$category" "$kind" "$address"
    MAPPING_ASSERT_GENERATION="gen-$category-$kind" MP_RUN_ID=run MAPPING_ASSERT_CASE="invalid-map/$category"
    mapping_negative_rejected "$MAPPING_ASSERT_CASE" "$kind" "$dir" || rc=$?
    [[ $rc == 0 && $MAPPING_ASSERT_JUDGE == 1 && $MAPPING_ASSERT_REJECT_LAYER == sync ]]
)

producer_and_validator() (
    local category=$1 kind=$2 address=$3 dir=$WORK/producer-$1-$2 script rc=0
    mkdir -p "$dir"
    MAPPING_ASSERT_CASE="invalid-map/$category" MAPPING_ASSERT_DNS_MODE=none
    mapping_negative_prepare "$kind" "mapping-$kind-inv-$category" "$dir" || return 1
    [[ $(mapping_scenario_snapshot_content "$kind") == "$address github.com" ]] || return 1
    printf '%s github.com\n' "$address" > "$dir/hosts.snapshot"
    mapping_fixture_docker() {
        [[ $1 == exec && $2 == -e && $3 == "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" && $4 == -e && $5 == MAPPING_VALIDATE_INVALID=yes && $6 == product && $7 == /bin/bash && $8 == -c ]] || return 1
        script=${9//\/usr\/local\/lib\/git-mirror\/git-mirror-sync.sh/$HERE\/..\/scripts\/git-mirror-sync.sh}
        RUN_ROOT=$dir MAPPING_VALIDATE_INVALID=yes /bin/bash -c "$script"
    }
    mkdir -p "$dir/hosts"
    cp "$dir/hosts.snapshot" "$dir/hosts/github-hosts.snapshot"
    mapping_scenario_missing_map_validator product "$dir" || rc=$?
    [[ $rc == 0 && $(cat "$dir/validator.tsv") == $'snapshot\tpresent\nresolve_count\t0' ]] || return 1
    grep -Fq '地址快照无效，忽略动态映射' "$dir/validator.log"
)

dispatch() (
    local category=$1 kind=$2 rc=0
    IT_EVIDENCE_DIR=$WORK/dispatch-$1-$2
    mkdir -p "$IT_EVIDENCE_DIR/control"
    IT_NEGATIVE_SEEN=()
    integration_slot_record() { return 0; }
    mapping_negative_run() {
        [[ $1 == "invalid-map/$category" && $2 == "$kind" ]] || return 80
        printf '%s\n' "$*" > "$IT_EVIDENCE_DIR/called"
    }
    check_mapping_negative "invalid map" "invalid-map/$category/$kind" "$kind" || rc=$?
    [[ $rc == 0 && -s $IT_EVIDENCE_DIR/called ]]
)

failed=0
for category in rfc1918 test-net benchmark; do
    case $category in rfc1918) address=10.0.0.1 ;; test-net) address=192.0.2.1 ;; benchmark) address=198.18.0.1 ;; esac
    for kind in fallback direct; do
        invalid_case "$category" "$kind" "$address" || failed=1
        producer_and_validator "$category" "$kind" "$address" || failed=1
        dispatch "$category" "$kind" || failed=1
    done
done
exit "$failed"
