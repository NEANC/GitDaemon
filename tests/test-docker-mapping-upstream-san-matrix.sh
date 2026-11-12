#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MAPPING_PROFILE=$WORK/profile.tsv
MAPPING_ASSERT_PRODUCT=product MAPPING_PROXY_ACCEPT_PORT=8443
MAPPING_UPSTREAM_HOST=github.com MAPPING_UPSTREAM_OWNER=gitdaemon MAPPING_UPSTREAM_REPO=fixture
printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
mapping_profile_load "$MAPPING_PROFILE"
mkdir -p "$WORK/control"
printf 'abc\n' > "$WORK/control/unique-commit"
printf 'run_id\trun\nscenario\tmapping-fallback\ngeneration\tg1\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tabc\n' > "$WORK/identity.tsv"
printf 'abc\trefs/heads/main\n' > "$WORK/refs.expected"
printf 'abc\n' > "$WORK/head.expected"
printf '2\n' > "$WORK/proxy.count"
printf '2\n' > "$WORK/upstream.count"
: > "$WORK/connect.source"
mapping_scenario_valid() { return 0; }
mapping_proxy_count_read_remote() { cat "$WORK/proxy.count"; }
mapping_scenario_upstream_count() { cat "$WORK/upstream.count"; }
mapping_scenario_connect_evidence() { cat "$WORK/connect.source"; }
mapping_upstream_san_leaf() {
    local phase=$2
    if [[ $phase == wrong ]]; then printf 'wrong\n' > "$WORK/leaf.$phase"; else printf 'original\n' > "$WORK/leaf.$phase"; fi
}
mapping_upstream_san_pair() {
    local name
    for name in cert key; do
        if [[ $2 == wrong ]]; then printf 'changed-%s' "$name" | sha256sum | awk '{print $1}' > "$WORK/$name.$2"; else printf 'original-%s' "$name" | sha256sum | awk '{print $1}' > "$WORK/$name.$2"; fi
    done
}
mapping_upstream_san_replace() { : > "$WORK/replaced"; }
mapping_upstream_san_restore() { : > "$WORK/restored"; }
mapping_upstream_san_restart() { return 0; }
mapping_tls_product_request() {
    local count dial
    count=$(cat "$WORK/proxy.count"); dial=$(cat "$WORK/upstream.count")
    printf '%s\n' "$((count+1))" > "$WORK/proxy.count"
    printf '%s\n' "$((dial+1))" > "$WORK/upstream.count"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' >> "$WORK/connect.source"
    if [[ -f $WORK/replaced && ! -f $WORK/restored ]]; then
        printf "fatal: unable to access 'https://github.com/gitdaemon/fixture.git/': SSL: no alternative certificate subject name matches target host name 'github.com'\n" > "$WORK/request.log"
        printf '1\n'
    else
        printf '同步传输路径：配置的 HTTPS 代理\n' > "$WORK/request.log"
        printf '0\n'
    fi
}
mapping_scenario_local_refs() { cat "$WORK/refs.expected"; }
mapping_scenario_local_head() { cat "$WORK/head.expected"; }
mapping_scenario_local_fsck() { printf '0\n'; }
status=0
mapping_upstream_san_case "$WORK" fallback mapping-fallback-wrong-upstream-san || status=$?
[[ $status == 0 ]] || { printf '生产证据退出 %s\n' "$status" >&2; exit 1; }
check() {
    local expected=$1 result=0
    mapping_negative_case_evidence_accept wrong_upstream_san run mapping-fallback g1 manifest input "$WORK" || result=$?
    [[ $result == "$expected" ]] || { printf '证据期望 %s 实际 %s\n' "$expected" "$result" >&2; exit 1; }
}
check 0
for name in baseline.before baseline.after upstream.baseline.before upstream.baseline upstream.recovered request.baseline.log request.recovery.log connect.before connect.baseline connect.log connect.recovered cert.original key.restored; do
    mv "$WORK/$name" "$WORK/$name.saved"
    check 80
    mv "$WORK/$name.saved" "$WORK/$name"
done
for name in upstream.baseline upstream.recovered proxy.recovered cert.restored key.wrong; do
    cp "$WORK/$name" "$WORK/$name.saved"
    if [[ $name == cert.restored ]]; then cp "$WORK/cert.wrong" "$WORK/$name"; elif [[ $name == key.wrong ]]; then cp "$WORK/key.original" "$WORK/$name"; else printf '2\n' > "$WORK/$name"; fi
    check 1
    mv "$WORK/$name.saved" "$WORK/$name"
done
cp "$WORK/request.failed.log" "$WORK/request.failed.log.saved"
printf 'fatal: certificate verify failed\n' > "$WORK/request.failed.log"
check 1
mv "$WORK/request.failed.log.saved" "$WORK/request.failed.log"
check 0
cp "$WORK/refs.actual" "$WORK/refs.actual.saved"
printf 'old\trefs/heads/main\n' > "$WORK/refs.actual"
check 1
mv "$WORK/refs.actual.saved" "$WORK/refs.actual"
cp "$WORK/control/unique-commit" "$WORK/control/unique-commit.saved"
printf 'other\n' > "$WORK/control/unique-commit"
check 1
mv "$WORK/control/unique-commit.saved" "$WORK/control/unique-commit"
check 0
status=0
mapping_negative_case_evidence_accept wrong_upstream_san run mapping-fallback g2 manifest input "$WORK" || status=$?
[[ $status == 80 ]] || exit 1
for case_id in $MAPPING_NEGATIVE_CASES; do
    [[ $case_id == wrong_upstream_san || $case_id == wrong_proxy_ca || $case_id == wrong_proxy_san || $case_id == wrong_upstream_ca ]] && continue
    status=0
    mapping_negative_case_evidence_accept "$case_id" run mapping-fallback g1 manifest input "$WORK" || status=$?
    [[ $status == 80 ]] || exit 1
done
printf 'upstream SAN matrix evidence PASS\n'
