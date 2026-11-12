#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/../scripts/git-mirror-sync.sh"
source "$HERE/docker-mapping-fixture.sh"

proxy_san_matrix_proof() {
    local root dir name saved rc=0 failed=0 spec
    root=$(mktemp -d); dir=$root/raw
    mkdir -p "$dir/control"
    MAPPING_PROFILE=$root/profile.tsv
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tabc123\n' > "$dir/identity.tsv"
    printf 'abc123\n' > "$dir/control/unique-commit"
    printf 'wrong_proxy_san\n' > "$dir/case.tsv"
    printf 'case\twrong_proxy_san\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t1\n' > "$dir/tls-layer.tsv"
    printf '1\n' > "$dir/request.exit"
    printf '3\n' > "$dir/baseline.before"
    printf '4\n' > "$dir/proxy.before"
    printf '4\n' > "$dir/proxy.after"
    printf '5\n' > "$dir/proxy.recovered"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$dir/connect.baseline"
    cp "$dir/connect.baseline" "$dir/connect.before"
    cp "$dir/connect.before" "$dir/connect.log"
    cp "$dir/connect.baseline" "$dir/connect.recovered"
    cat "$dir/connect.baseline" >> "$dir/connect.recovered"
    cp "$dir/connect.baseline" "$dir/connect.recovered.new"
    cp "$dir/connect.recovered" "$dir/connect.health.before"
    cp "$dir/connect.health.before" "$dir/connect.health.after"
    cat "$dir/connect.baseline" >> "$dir/connect.health.after"
    cp "$dir/connect.baseline" "$dir/connect.health.new"
    printf 'aabbcc\n' > "$dir/leaf.original"
    printf 'ddeeff\n' > "$dir/leaf.wrong"
    cp "$dir/leaf.original" "$dir/leaf.restored"
    printf 'original-cert\n' > "$dir/cert.original"
    printf 'wrong-cert\n' > "$dir/cert.wrong"
    cp "$dir/cert.original" "$dir/cert.restored"
    printf 'original-key\n' > "$dir/key.original"
    printf 'wrong-key\n' > "$dir/key.wrong"
    cp "$dir/key.original" "$dir/key.restored"
    printf 'healthy\n' > "$dir/health.baseline"
    cp "$dir/health.baseline" "$dir/health.recovered"
    printf 'SSL: no alternative certificate subject name matches target host name\n' > "$dir/hostname.log"
    printf '传输失败：配置的 HTTPS 代理；fatal: unable to access '\''https://github.com/gitdaemon/fixture.git/'\'': SSL: no alternative certificate subject name matches target host name '\''gm-proxy'\''\n' > "$dir/request.failed.log"
    printf '同步传输路径：配置的 HTTPS 代理\n' > "$dir/request.log"
    printf 'abc123\trefs/heads/main\n' > "$dir/refs.expected"
    cp "$dir/refs.expected" "$dir/refs.actual"
    printf 'abc123\n' > "$dir/head.expected"
    cp "$dir/head.expected" "$dir/head.actual"
    printf '0\n' > "$dir/fsck.exit"
    mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || { printf 'valid case rejected\n'; return 1; }
    for name in control/unique-commit case.tsv tls-layer.tsv request.exit baseline.before proxy.before proxy.after proxy.recovered connect.baseline connect.before connect.log connect.recovered connect.recovered.new connect.health.before connect.health.after connect.health.new leaf.original leaf.wrong leaf.restored cert.original cert.wrong cert.restored key.original key.wrong key.restored health.baseline health.recovered hostname.log request.failed.log request.log refs.expected refs.actual head.expected head.actual fsck.exit; do
        mv "$dir/$name" "$dir/$name.saved"
        rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf 'missing %s: %s\n' "$name" "$rc"; failed=1; }
        mv "$dir/$name.saved" "$dir/$name"
    done
    for name in connect.health.before connect.health.after connect.health.new; do
        cp "$dir/$name" "$dir/$name.saved"
        printf 'authority=elsewhere.invalid:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$dir/$name"
        rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
        [[ $rc == 1 ]] || { printf 'bad health CONNECT %s: %s\n' "$name" "$rc"; failed=1; }
        mv "$dir/$name.saved" "$dir/$name"
    done
    cp "$dir/connect.health.after" "$dir/connect.health.after.saved"
    printf 'authority=elsewhere.invalid:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$dir/connect.health.after"
    cat "$dir/connect.health.before" >> "$dir/connect.health.after"
    cat "$dir/connect.health.new" >> "$dir/connect.health.after"
    rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || { printf 'changed health prefix: %s\n' "$rc"; failed=1; }
    mv "$dir/connect.health.after.saved" "$dir/connect.health.after"
    for spec in 'leaf.wrong:aabbcc' 'leaf.restored:ddeeff' 'cert.wrong:original-cert' 'cert.restored:wrong-cert' 'key.wrong:original-key' 'key.restored:wrong-key' 'proxy.after:5' 'proxy.recovered:4' 'connect.log:changed' 'connect.recovered:changed' 'connect.recovered.new:changed' 'request.failed.log:SSL certificate problem' 'request.exit:0' 'refs.actual:old' 'head.actual:old' 'fsck.exit:1' 'control/unique-commit:old'; do
        name=${spec%%:*}; saved=${spec#*:}
        cp "$dir/$name" "$dir/$name.saved"
        printf '%s\n' "$saved" > "$dir/$name"
        rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
        [[ $rc == 1 ]] || { printf 'bad %s: %s\n' "$name" "$rc"; failed=1; }
        mv "$dir/$name.saved" "$dir/$name"
    done
    cp "$dir/request.failed.log" "$dir/request.failed.log.saved"
    for saved in \
        "fatal: unable to access 'https://elsewhere.invalid/repo.git/': SSL: no alternative certificate subject name matches target host name 'gm-proxy'" \
        "fatal: unable to access 'https://github.com/': SSL: no alternative certificate subject name matches target host name 'gm-proxy'"; do
        printf '传输失败：配置的 HTTPS 代理；%s\n' "$saved" > "$dir/request.failed.log"
        rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
        [[ $rc == 1 ]] || { printf 'wrong fatal source: %s\n' "$rc"; failed=1; }
    done
    printf '传输失败：配置的 HTTPS 代理；%s\n%s\n' "fatal: unable to access 'https://github.com/gitdaemon/fixture.git/': SSL: no alternative certificate subject name matches target host name 'gm-proxy'" "fatal: unable to access 'https://elsewhere.invalid/': SSL: no alternative certificate subject name matches target host name 'gm-proxy'" > "$dir/request.failed.log"
    rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || { printf 'double fatal: %s\n' "$rc"; failed=1; }
    printf '传输失败：配置的 HTTPS 代理；fatal: unable to access '\''https://elsewhere.invalid/'\'': SSL: no alternative certificate subject name matches target host name '\''gm-proxy'\''; fatal: unable to access '\''https://github.com/gitdaemon/fixture.git/'\'': unrelated\n' > "$dir/request.failed.log"
    rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || { printf 'mixed fatal line: %s\n' "$rc"; failed=1; }
    printf '传输失败：配置的 HTTPS 代理；fatal: unable to access '\''https://github.com/gitdaemon/fixture.git/'\'': SSL: no alternative certificate subject name matches target host name '\''gm-proxy'\''; fatal: unable to access '\''https://elsewhere.invalid/'\'': unrelated\n' > "$dir/request.failed.log"
    rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || { printf 'second fatal on same line: %s\n' "$rc"; failed=1; }
    mv "$dir/request.failed.log.saved" "$dir/request.failed.log"
    cp "$dir/identity.tsv" "$dir/identity.tsv.original"
    printf 'input_sha256\tother\n' >> "$dir/identity.tsv"
    rc=0; mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || failed=1
    mv "$dir/identity.tsv.original" "$dir/identity.tsv"
    rc=0; mapping_negative_case_evidence_accept wrong_upstream_san run scenario generation manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || failed=1
    rm -rf "$root"
    return "$failed"
}

proxy_san_dedicated_production() {
    local root dir rc=0
    root=$(mktemp -d); dir=$root/raw
    mkdir -p "$dir/control"
    MAPPING_PROFILE=$root/profile.tsv
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tabc123\n' > "$dir/identity.tsv"
    printf 'abc123\n' > "$dir/control/unique-commit"
    printf 'abc123\trefs/heads/main\n' > "$dir/refs.expected"
    printf 'abc123\n' > "$dir/head.expected"
    MAPPING_ASSERT_PRODUCT=product
    MAPPING_PROXY_ACCEPT_PORT=8443
    mapping_proxy_count_read_remote() { if [[ -f $dir/recovered.marker ]]; then printf '4\n'; else printf '3\n'; fi; }
    mapping_scenario_connect_evidence() {
        printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
        if [[ -f $dir/recovered.marker ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
        fi
        if [[ -f $dir/health.new ]]; then
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
        fi
    }
    mapping_proxy_san_health() {
        printf 'healthy\n' > "$1/health.$2"
        if [[ $2 == recovered ]]; then : > "$1/health.new"; fi
    }
    mapping_proxy_san_pair() {
        if [[ $2 == wrong ]]; then
            printf 'wrong-cert\n' > "$1/cert.wrong"; printf 'wrong-key\n' > "$1/key.wrong"
        else
            printf 'original-cert\n' > "$1/cert.$2"; printf 'original-key\n' > "$1/key.$2"
        fi
    }
    mapping_proxy_san_leaf() {
        if [[ $2 == wrong ]]; then printf 'ddeeff\n' > "$1/leaf.wrong"; else printf 'aabbcc\n' > "$1/leaf.$2"; fi
    }
    mapping_proxy_san_replace() { return 0; }
    mapping_proxy_san_restart() { return 0; }
    mapping_proxy_san_restore() { : > "$dir/recovered.marker"; }
    mapping_proxy_san_hostname_probe() { printf 'SSL: no alternative certificate subject name matches target host name\n' > "$1/hostname.log"; }
    mapping_scenario_sync_exec() {
        if [[ -f $dir/recovered.marker ]]; then
            printf '同步传输路径：配置的 HTTPS 代理\n' > "$3/sync.log"
            printf '0\n' > "$3/sync.exit"
        else
            printf '传输失败：配置的 HTTPS 代理；fatal: unable to access '\''https://github.com/gitdaemon/fixture.git/'\'': SSL: no alternative certificate subject name matches target host name '\''gm-proxy'\''\n' > "$3/sync.log"
            printf '1\n' > "$3/sync.exit"
        fi
    }
    mapping_scenario_local_refs() { cat "$dir/refs.expected"; }
    mapping_scenario_local_head() { cat "$dir/head.expected"; }
    mapping_scenario_local_fsck() { printf '0\n'; }
    mapping_proxy_san_case "$dir" fallback scenario || rc=$?
    [[ $rc == 0 ]] || { printf 'dedicated producer: %s\n' "$rc"; return 1; }
    mapping_negative_case_evidence_accept wrong_proxy_san run scenario generation manifest input "$dir" || { printf 'dedicated consumer rejected\n'; return 1; }
    rm -rf "$root"
}

proxy_san_matrix_proof
proxy_san_dedicated_production
