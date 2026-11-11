#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"

matrix_write() {
    local file=$1 drop=${2:-} case_id dir
    : > "$file"
    for case_id in $MAPPING_NEGATIVE_CASES; do
        [[ $case_id == "$drop" ]] && continue
        dir=${file%/*}/raw-${case_id//\//-}; mkdir -p "$dir"; printf 'raw\n' > "$dir/evidence.txt"
        printf '%s\trun\tscenario\tgeneration\tmanifest\tinput\t%s\t0\tPASS\n' "$case_id" "$dir" >> "$file"
    done
}

full_requires_all_21_negative_cases() {
    local dir file
    dir=$(mktemp -d); file=$dir/matrix.tsv; matrix_write "$file"
    mapping_negative_matrix_accept "$file" run manifest input
    rm -rf "$dir"
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
    mapping_negative_matrix_accept "$file" run manifest input || return 1
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
    mapping_finalize "$dir" "$guard" "$carrier" || return 1
    mapping_full_accept "$dir/mapping-full-summary.tsv" || return 1
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
for name in full_requires_all_21_negative_cases any_one_negative_cannot_pass_group negative_matrix_rejects_duplicate_unknown_or_foreign_case negative_matrix_requires_raw_evidence negative_matrix_requires_exact_bound_rows missing_summary_slot_rejected single_mode_cannot_finalize_full full_waits_for_guard_and_carrier_cleanup finalize_removes_stale_pass finalize_requires_raw_status_and_business primary_error_wins_over_cleanup; do
    rc=0; ( "$name" ) || rc=$?; printf '%s EXIT=%s\n' "$name" "$rc"; [[ $rc == 0 ]] || failed=1
done
exit "$failed"
