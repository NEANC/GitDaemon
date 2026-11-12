#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/../scripts/git-mirror-sync.sh"
source "$HERE/docker-mapping-fixture.sh"

matrix_proof_rejects_claims() {
    local dir file case_id evidence rc=0
    dir=$(mktemp -d)
    file=$dir/mapping-negative-matrix.tsv
    for case_id in $MAPPING_NEGATIVE_CASES; do
        evidence=$dir/raw-${case_id//\//-}
        mkdir -p "$evidence"
        printf 'PASS\n' > "$evidence/evidence.txt"
        printf '%s\trun\tscenario\tgeneration\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$evidence" >> "$file"
    done
    mapping_negative_matrix_accept "$file" run manifest input && rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

matrix_tls_requires_bound_raw_layer() {
    local dir file evidence case_id rc=0 name result
    dir=$(mktemp -d)
    file=$dir/matrix.tsv
    case_id=wrong_proxy_ca
    evidence=$dir/raw
    mkdir -p "$evidence"
    printf 'raw\n' > "$evidence/evidence.txt"
    printf '%s\trun\tscenario\tgeneration\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$evidence" > "$file"
    printf 'case\t%s\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t1\n' "$case_id" > "$evidence/tls-layer.tsv"
    printf '1\n' > "$evidence/request.exit"
    printf '0\n' > "$evidence/baseline.exit"
    printf '0\n' > "$evidence/recovery.exit"
    printf '3\n' > "$evidence/proxy.before"
    printf '3\n' > "$evidence/proxy.after"
    printf '4\n' > "$evidence/proxy.recovered"
    : > "$evidence/connect.before"
    cp "$evidence/connect.before" "$evidence/connect.log"
    printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n' > "$evidence/request.failed.log"
    printf '同步传输路径：配置的 HTTPS 代理\n' > "$evidence/request.baseline.log"
    cp "$evidence/request.baseline.log" "$evidence/request.recovery.log"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$evidence/connect.baseline.new"
    cp "$evidence/connect.baseline.new" "$evidence/connect.recovered.new"
    printf '2\n' > "$evidence/baseline.before"
    printf '3\n' > "$evidence/baseline.after"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$evidence/connect.baseline"
    cp "$evidence/connect.baseline" "$evidence/connect.recovered"
    printf '0\n' > "$evidence/upstream.before"
    printf '0\n' > "$evidence/upstream.after"
    printf '%s\n' "$case_id" > "$evidence/case.tsv"
    printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' > "$evidence/identity.tsv"
    MAPPING_PROFILE=$dir/profile.tsv
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    for name in connect.baseline.new connect.recovered.new request.baseline.log request.recovery.log; do
        mv "$evidence/$name" "$evidence/$name.saved"
        result=0
        mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || result=$?
        [[ $result == 80 ]] || rc=1
        mv "$evidence/$name.saved" "$evidence/$name"
    done
    printf 'bogus\n' > "$evidence/connect.baseline.new"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    cp "$evidence/connect.recovered.new" "$evidence/connect.baseline.new"
    : > "$evidence/connect.recovered.new"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    cp "$evidence/connect.baseline.new" "$evidence/connect.recovered.new"
    printf '3\n' > "$evidence/baseline.before"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '2\n' > "$evidence/baseline.before"
    printf '4\n' > "$evidence/baseline.after"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '3\n' > "$evidence/baseline.after"
    printf '1\n' > "$evidence/upstream.after"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '0\n' > "$evidence/upstream.after"
    printf 'only a failed request\n' > "$evidence/request.baseline.log"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    cp "$evidence/request.recovery.log" "$evidence/request.baseline.log"
    printf 'only a failed request\n' > "$evidence/request.recovery.log"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    cp "$evidence/request.baseline.log" "$evidence/request.recovery.log"
    printf '同步传输路径：直连加动态地址映射\n' >> "$evidence/request.failed.log"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n' > "$evidence/request.failed.log"
    printf '同步传输路径：直连系统 DNS\n' >> "$evidence/request.failed.log"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n' > "$evidence/request.failed.log"
    printf 'SSL certificate problem\n' > "$evidence/request.failed.log"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n' > "$evidence/request.failed.log"
    printf '2\n' > "$evidence/request.exit"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '1\n' > "$evidence/request.exit"
    printf '4\n' > "$evidence/proxy.after"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    printf '3\n' > "$evidence/proxy.after"
    printf 'generation\tother\n' >> "$evidence/identity.tsv"
    ! mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

matrix_dns_unimplemented_is_fixture_failure() {
    local dir file evidence case_id rc=0
    dir=$(mktemp -d)
    file=$dir/matrix.tsv
    for case_id in $MAPPING_NEGATIVE_CASES; do
        evidence=$dir/raw-${case_id//\//-}
        mkdir -p "$evidence"
        printf 'PASS\n' > "$evidence/evidence.txt"
        printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' > "$evidence/identity.tsv"
        printf '%s\trun\tscenario\tgeneration\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$evidence" >> "$file"
    done
    mapping_negative_case_evidence_accept missing-map/fallback run scenario generation manifest input "$dir/raw-missing-map-fallback" || rc=$?
    [[ $rc == 80 ]] || return 1
    rc=0
    mapping_negative_matrix_accept "$file" run manifest input || rc=$?
    rm -rf "$dir"
    [[ $rc == 80 ]]
}

failed=0
for name in matrix_proof_rejects_claims matrix_tls_requires_bound_raw_layer matrix_dns_unimplemented_is_fixture_failure; do
    rc=0; ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
