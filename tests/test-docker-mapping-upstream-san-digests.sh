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
    if [[ $2 == wrong ]]; then printf 'wrong\n' > "$WORK/leaf.$2"; else printf 'original\n' > "$WORK/leaf.$2"; fi
}
mapping_upstream_san_pair() {
    local name phase=$2
    [[ $phase == restored ]] && phase=original
    for name in cert key; do
        printf '%s-%s' "$name" "$phase" | sha256sum | awk '{print $1}' > "$WORK/$name.$2"
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
mapping_upstream_san_case "$WORK" fallback mapping-fallback-wrong-upstream-san
check() {
    local expected=$1 actual=0
    mapping_negative_case_evidence_accept wrong_upstream_san run mapping-fallback g1 manifest input "$WORK" || actual=$?
    [[ $actual == "$expected" ]] || { printf '%s: expected %s, got %s\n' "$name" "$expected" "$actual" >&2; exit 1; }
}
name=valid
check 0
for name in cert key; do
    for phase in original wrong restored; do
        file=$WORK/$name.$phase
        mv "$file" "$file.saved"
        check 80
        cp "$file.saved" "$file"
        if [[ $EUID != 0 ]]; then
            chmod 000 "$file"
            check 80
            chmod 600 "$file"
        fi
        printf 'invalid\n' > "$file"
        check 1
        cp "$file.saved" "$file"
        check 0
        mv "$file.saved" "$file"
    done
done
printf 'upstream SAN digest evidence PASS\n'
