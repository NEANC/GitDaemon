#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/../scripts/git-mirror-sync.sh"
source "$HERE/docker-mapping-fixture.sh"

matrix_write() {
    local file=$1 drop=${2:-} case_id dir
    : > "$file"
    for case_id in $MAPPING_NEGATIVE_CASES; do
        [[ $case_id == "$drop" ]] && continue
        dir=${file%/*}/raw-${case_id//\//-}; mkdir -p "$dir"; printf 'raw\n' > "$dir/evidence.txt"
        printf '%s\trun\tscenario\tgeneration\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$dir" >> "$file"
    done
}

placeholder_matrix_cannot_finalize() {
    local dir guard carrier rc=0 status=0
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    mapping_negative_matrix_accept "$dir/mapping-negative-matrix.tsv" run manifest input || status=$?
    [[ $status == 80 ]] || rc=1
    mapping_finalize "$dir" "$guard" "$carrier" && rc=1
    [[ ! -e $dir/mapping-full-summary.tsv && ! -e $dir/mapping-full-finalized.tsv ]] || rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

single_raw_case_is_independently_verified() {
    local dir evidence rc=0
    dir=$(mktemp -d); evidence=$dir/raw-wrong_proxy_ca
    mkdir -p "$evidence"
    printf 'wrong_proxy_ca\n' > "$evidence/case.tsv"
    printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' > "$evidence/identity.tsv"
    printf 'case\twrong_proxy_ca\nlayer\touter-failure\nconnect_delta\t0\nrequest_exit\t1\n' > "$evidence/tls-layer.tsv"
    printf '0\n' > "$evidence/baseline.exit"
    printf '1\n' > "$evidence/request.exit"
    printf '0\n' > "$evidence/recovery.exit"
    printf '3\n' > "$evidence/proxy.before"
    printf '3\n' > "$evidence/proxy.after"
    printf '4\n' > "$evidence/proxy.recovered"
    : > "$evidence/connect.before"
    cp "$evidence/connect.before" "$evidence/connect.log"
    printf '传输失败：配置的 HTTPS 代理 SSL certificate problem\n' > "$evidence/request.failed.log"
    printf '同步传输路径：配置的 HTTPS 代理\n' > "$evidence/request.baseline.log"
    cp "$evidence/request.baseline.log" "$evidence/request.recovery.log"
    printf '2\n' > "$evidence/baseline.before"
    printf '3\n' > "$evidence/baseline.after"
    printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$evidence/connect.baseline.new"
    cp "$evidence/connect.baseline.new" "$evidence/connect.recovered.new"
    cp "$evidence/connect.baseline.new" "$evidence/connect.baseline"
    cp "$evidence/connect.recovered.new" "$evidence/connect.recovered"
    printf '0\n' > "$evidence/upstream.before"
    printf '0\n' > "$evidence/upstream.after"
    MAPPING_PROFILE=$dir/profile.tsv
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    mapping_negative_case_evidence_accept wrong_proxy_ca run scenario generation manifest input "$evidence" || rc=1
    printf '2\n' > "$evidence/request.exit"
    mapping_negative_case_evidence_accept wrong_proxy_ca run scenario generation manifest input "$evidence" && rc=1
    printf '1\n' > "$evidence/request.exit"
    mapping_negative_case_evidence_accept wrong_proxy_ca run other generation manifest input "$evidence" && rc=1
    rm -rf "$dir"
    [[ $rc == 0 ]]
}

remaining_cases_are_unimplemented() {
    local dir evidence case_id rc=0 count=0 status
    dir=$(mktemp -d)
    for case_id in $MAPPING_NEGATIVE_CASES; do
        [[ $case_id == wrong_proxy_ca ]] && continue
        count=$((count + 1))
        evidence=$dir/raw-${case_id//\//-}
        mkdir -p "$evidence"
        printf 'run_id\trun\nscenario\tscenario\ngeneration\tgeneration\nnetwork_id\tnet\nimage_id\timage\nprofile_sha256\tprofile\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' > "$evidence/identity.tsv"
        status=0
        mapping_negative_case_evidence_accept "$case_id" run scenario generation manifest input "$evidence" || status=$?
        [[ $status == 80 ]] || rc=1
    done
    rm -rf "$dir"
    [[ $count == 20 && $rc == 0 ]]
}

full_requires_all_21_negative_cases() {
    local dir file status=0
    dir=$(mktemp -d); file=$dir/matrix.tsv; matrix_write "$file"
    mapping_negative_matrix_accept "$file" run manifest input || status=$?
    rm -rf "$dir"
    [[ $status == 80 ]]
}

any_one_negative_cannot_pass_group() {
    local dir file case_id rc=0
    dir=$(mktemp -d); file=$dir/matrix.tsv
    for case_id in $MAPPING_NEGATIVE_CASES; do
        matrix_write "$file" "$case_id"
        mapping_negative_matrix_accept "$file" run manifest input && rc=1
    done
    rm -rf "$dir"; [[ $rc == 0 ]]
}

negative_matrix_rejects_duplicate_unknown_or_foreign_case() {
    local dir file
    dir=$(mktemp -d); file=$dir/matrix.tsv; matrix_write "$file"
    head -n 1 "$file" >> "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input
    rm -rf "$dir"
}

negative_matrix_requires_raw_evidence() {
    local dir file raw
    dir=$(mktemp -d); file=$dir/matrix.tsv; matrix_write "$file"
    raw=$(awk -F '\t' 'NR==1 {print $7}' "$file"); rm -f "$raw/evidence.txt"
    ! mapping_negative_matrix_accept "$file" run manifest input
    rm -rf "$dir"
}

# 矩阵不得接受额外列、空列、外轮输入或伪造的证据目录。
negative_matrix_requires_exact_bound_rows() {
    local dir file raw
    dir=$(mktemp -d); file=$dir/matrix.tsv; matrix_write "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    printf '\textra' >> "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    matrix_write "$file"
    ! mapping_negative_matrix_accept "$file" other manifest input || return 1
    ! mapping_negative_matrix_accept "$file" run other input || return 1
    ! mapping_negative_matrix_accept "$file" run manifest other || return 1
    awk -F '\t' 'BEGIN {OFS="\t"} NR==1 {$8=2} {print}' "$file" > "$file.next"; mv "$file.next" "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    matrix_write "$file"
    awk -F '\t' 'BEGIN {OFS="\t"} NR==1 {$9="DEFER"} {print}' "$file" > "$file.next"; mv "$file.next" "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    matrix_write "$file"
    awk -F '\t' 'BEGIN {OFS="\t"} NR==1 {$2="other"} {print}' "$file" > "$file.next"; mv "$file.next" "$file"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    matrix_write "$file"
    raw=$(awk -F '\t' 'NR==1 {print $7}' "$file")
    rm -f "$raw/evidence.txt"
    ! mapping_negative_matrix_accept "$file" run manifest input || return 1
    rm -rf "$dir"
}

# 已存在的旧 PASS 也不能在缺失或失败时留在最终路径。
finalize_removes_stale_pass() {
    local dir guard carrier
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    printf 'old\tPASS\n' > "$dir/mapping-full-summary.tsv"
    rm -f "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    [[ ! -e $dir/mapping-full-summary.tsv ]] || return 1
    rm -rf "$dir"
}

# business 严格 13 键，guard 与 carrier 必须各自提供完整原始状态。
finalize_requires_raw_status_and_business() {
    local dir guard carrier key
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    [[ ! -e $dir/mapping-full-summary.tsv && ! -e $dir/mapping-full-finalized.tsv ]] || return 1
    for key in primary_exit cleanup_exit residual_count; do
        printf 'old\tPASS\n' > "$dir/mapping-full-summary.tsv"
        awk -F '\t' -v k="$key" '$1 != k' "$guard" > "$guard.next"; mv "$guard.next" "$guard"
        ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
        [[ ! -e $dir/mapping-full-summary.tsv ]] || return 1
        printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    done
    printf 'host_unchanged\tFAIL\ncarrier_cleanup_exit\t0\ncarrier_residual_count\t0\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t1\nhost_unchanged\tPASS\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    for key in failures fixture_failures deferred primary_exit cleanup_exit residual_count mapping_fallback mapping_direct system_fallback system_direct dns_negatives tls_negatives isolation_negatives; do
        awk -F '\t' -v k="$key" '$1 != k' "$dir/mapping-business-summary.tsv" > "$dir/business.next"
        mv "$dir/business.next" "$dir/mapping-business-summary.tsv"
        ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
        business_write "$dir"
    done
    printf 'unknown\tPASS\n' >> "$dir/mapping-business-summary.tsv"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    business_write "$dir"
    rm -f "$dir/mapping-run-input.tsv"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    rm -rf "$dir"
}

summary_write() {
    local file=$1 drop=${2:-} key
    for key in failures fixture_failures deferred primary_exit cleanup_exit residual_count; do
        [[ $key == "$drop" ]] || printf '%s\t0\n' "$key"
    done > "$file"
    for key in mapping_fallback mapping_direct system_fallback system_direct dns_negatives tls_negatives isolation_negatives host_unchanged; do
        [[ $key == "$drop" ]] || printf '%s\tPASS\n' "$key" >> "$file"
    done
    for key in carrier_cleanup_exit carrier_residual_count; do
        [[ $key == "$drop" ]] || printf '%s\t0\n' "$key" >> "$file"
    done
}

# 为纯文件判定提供本轮冻结输入，不替代未来载体生产者。
run_input_write() {
    printf 'run_id\trun\nmanifest_sha256\tmanifest\ninput_sha256\tinput\n' > "$1/mapping-run-input.tsv"
}

# 业务只保留六零值及七个分组槽位。
business_write() {
    summary_write "$1/mapping-business-summary.tsv" carrier_cleanup_exit
    awk -F '\t' '$1 != "carrier_residual_count" && $1 != "host_unchanged"' \
        "$1/mapping-business-summary.tsv" > "$1/business.next"
    mv "$1/business.next" "$1/mapping-business-summary.tsv"
    run_input_write "$1"
}

missing_summary_slot_rejected() {
    local dir file
    dir=$(mktemp -d); file=$dir/summary.tsv; summary_write "$file" host_unchanged
    ! mapping_full_accept "$file"
    rm -rf "$dir"
}

single_mode_cannot_finalize_full() {
    local dir file
    dir=$(mktemp -d); file=$dir/summary.tsv; summary_write "$file" mapping_direct
    ! mapping_full_accept "$file"
    rm -rf "$dir"
}

# 手写完整字段但缺少同轮矩阵、输入和 finalized 来源必须拒绝。
handwritten_full_without_matrix_is_rejected() {
    local dir file
    dir=$(mktemp -d); file=$dir/mapping-full-summary.tsv
    summary_write "$file"
    ! mapping_full_accept "$file" || return 1
    ! integration_business_accept "$file" >/dev/null 2>&1 || return 1
    rm -rf "$dir"
}

finalized_full_requires_bound_sources() {
    local dir guard carrier file
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    file=$dir/mapping-full-summary.tsv
    summary_write "$file"
    finalized_receipt_write "$dir"
    ! mapping_full_accept "$file" || return 1
    mv "$dir/mapping-negative-matrix.tsv" "$dir/matrix.saved"
    ! mapping_full_accept "$file" || return 1
    mv "$dir/matrix.saved" "$dir/mapping-negative-matrix.tsv"
    printf 'tampered\n' >> "$dir/mapping-negative-matrix.tsv"
    ! mapping_full_accept "$file" || return 1
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'run_id\tother\nmanifest_sha256\tmanifest\ninput_sha256\tinput\n' > "$dir/mapping-run-input.tsv"
    ! mapping_full_accept "$file" || return 1
    run_input_write "$dir"
    printf 'unknown\tPASS\n' >> "$file"
    ! mapping_full_accept "$file" || return 1
    sed -i '$d' "$file"
    printf 'old\n' > "$dir/mapping-full-finalized.tsv"
    ! mapping_full_accept "$file" || return 1
    rm -rf "$dir"
}

finalized_full_rejects_duplicate_and_failed_slot() {
    local dir guard carrier file
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    file=$dir/mapping-full-summary.tsv
    summary_write "$file"
    finalized_receipt_write "$dir"
    ! mapping_full_accept "$file" || return 1
    ! integration_business_accept "$file" > "$dir/runner.out" 2>&1 || return 1
    ! grep -q 'MAPPING_FULL_ACCEPT=0' "$dir/runner.out" || return 1
    cp "$file" "$dir/valid-summary.tsv"
    printf 'mapping_direct\tPASS\n' >> "$file"
    ! mapping_full_accept "$file" || return 1
    cp "$dir/valid-summary.tsv" "$file"
    ! mapping_full_accept "$file" || return 1
    awk -F '\t' 'BEGIN {OFS="\t"} $1 == "tls_negatives" {$2="FAIL"} {print}' "$file" > "$dir/failed-summary.tsv"
    cp "$dir/failed-summary.tsv" "$file"
    ! mapping_full_accept "$file" || return 1
    cp "$dir/valid-summary.tsv" "$file"
    ! mapping_full_accept "$file" || return 1
    rm -rf "$dir"
}

finalized_summary_digest_refresh() {
    local dir=$1 digest
    digest=$(sha256sum "$dir/mapping-full-summary.tsv") || return 1
    awk -F '\t' -v hash="${digest%% *}" 'BEGIN {OFS="\t"} $1 == "summary" {$2=hash} {print}' \
        "$dir/mapping-full-finalized.tsv" > "$dir/receipt.next" || return 1
    mv "$dir/receipt.next" "$dir/mapping-full-finalized.tsv"
}

finalized_receipt_write() {
    local dir=$1 name file digest
    : > "$dir/mapping-full-finalized.tsv"
    for name in summary matrix input; do
        case $name in
            summary) file=$dir/mapping-full-summary.tsv ;;
            matrix) file=$dir/mapping-negative-matrix.tsv ;;
            input) file=$dir/mapping-run-input.tsv ;;
        esac
        digest=$(sha256sum "$file") || return 1
        printf '%s\t%s\n' "$name" "${digest%% *}" >> "$dir/mapping-full-finalized.tsv"
    done
}

finalized_full_rejects_forbidden_field_after_digest_refresh() {
    local dir guard carrier file
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    printf 'carrier_cleanup_exit\t0\ncarrier_residual_count\t0\nhost_unchanged\tPASS\n' > "$carrier"
    ! mapping_finalize "$dir" "$guard" "$carrier" || return 1
    file=$dir/mapping-full-summary.tsv
    summary_write "$file"
    finalized_receipt_write "$dir"
    ! mapping_full_accept "$file" || return 1
    printf 'forbidden\tPASS\n' >> "$file"
    finalized_summary_digest_refresh "$dir" || return 1
    ! mapping_full_accept "$file" || return 1
    sed -i '$d' "$file"
    finalized_summary_digest_refresh "$dir" || return 1
    ! mapping_full_accept "$file" || return 1
    rm -rf "$dir"
}

full_waits_for_guard_and_carrier_cleanup() {
    local dir guard carrier rc=0
    dir=$(mktemp -d); guard=$dir/guard.tsv; carrier=$dir/carrier.tsv
    business_write "$dir"
    matrix_write "$dir/mapping-negative-matrix.tsv"
    printf 'primary_exit\t0\ncleanup_exit\t0\nresidual_count\t0\n' > "$guard"
    mapping_finalize "$dir" "$guard" "$carrier" >/dev/null 2>&1 || rc=$?
    [[ $rc == 1 && ! -e $dir/mapping-full-summary.tsv ]]
    rm -rf "$dir"
}

primary_error_wins_over_cleanup() {
    mapping_final_exit 7 2 2 | grep -qx 7 && mapping_final_exit 0 2 2 | grep -qx 2
}

failed=0
for name in single_raw_case_is_independently_verified remaining_cases_are_unimplemented placeholder_matrix_cannot_finalize full_requires_all_21_negative_cases any_one_negative_cannot_pass_group negative_matrix_rejects_duplicate_unknown_or_foreign_case negative_matrix_requires_raw_evidence negative_matrix_requires_exact_bound_rows missing_summary_slot_rejected single_mode_cannot_finalize_full handwritten_full_without_matrix_is_rejected finalized_full_requires_bound_sources finalized_full_rejects_duplicate_and_failed_slot finalized_full_rejects_forbidden_field_after_digest_refresh full_waits_for_guard_and_carrier_cleanup finalize_removes_stale_pass finalize_requires_raw_status_and_business primary_error_wins_over_cleanup; do
    rc=0; ( "$name" ) || rc=$?; printf '%s EXIT=%s\n' "$name" "$rc"; [[ $rc == 0 ]] || failed=1
done
exit "$failed"
