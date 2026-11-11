#!/usr/bin/env bash
# 映射注册与选择契约（原「延期选择」契约已随独立映射场景废弃）：
# 私网组不再注册旧两项 mapping；新独立 mapping 组 fallback/direct 各注册一次并保留 system 两项；
# full 汇总判定器拒绝缺项/重复项/非零字段；单项 mode 只选对应场景，不能作为 full 结论。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=defer IT_NETWORK=gm-defer-net
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
failed=0

# 生成完整 full 汇总样本：默认全部字段取通过值；可用 set/drop 改动单个键。
full_summary_write() {
    local file=$1 op=${2:-} key=${3:-} value=${4:-} k
    local -a zero_fields=(failures fixture_failures deferred primary_exit cleanup_exit residual_count)
    local -a pass_fields=(mapping_fallback mapping_direct system_fallback system_direct
        dns_negatives tls_negatives isolation_negatives)
    : > "$file"
    for k in "${zero_fields[@]}"; do
        [[ $op == drop && $k == "$key" ]] && continue
        if [[ $op == set && $k == "$key" ]]; then
            printf '%s\t%s\n' "$k" "$value" >> "$file"
        else
            printf '%s\t0\n' "$k" >> "$file"
        fi
    done
    for k in "${pass_fields[@]}"; do
        [[ $op == drop && $k == "$key" ]] && continue
        printf '%s\tPASS\n' "$k" >> "$file"
    done
}

# 唯一注册点：私网组不注册旧两项 mapping、保留代理成功/CONNECT 与 system 两项；
# 新组正例 fallback/direct 各一次并注册三组负例。
registration_moves_only_two_mapping_checks() {
    local calls=$TEST_ROOT/reg-calls rc=0
    : > "$calls"
    fixture_proxy_failure_falls_back_to_mapping() { printf 'old\t%s\n' "$*" >> "$calls"; }
    fixture_direct_attempts_leave_proxy_untouched() { printf 'old\t%s\n' "$*" >> "$calls"; }
    check_proxy_sync() { printf 'proxy\t%s\n' "${2:-}" >> "$calls"; }
    check_mapping_sync() { printf 'mapping\t%s\n' "${2:-}" >> "$calls"; }
    check_mapping_negative() { printf 'negative\t%s\t%s\n' "${2:-}" "${3:-}" >> "$calls"; }
    IT_MAPPING_SCENARIO=''
    integration_register_proxy_group
    integration_register_mapping_group
    grep -q 'fixture_proxy_failure_falls_back_to_mapping' "$calls" \
        && { printf 'FAIL 私网组仍注册旧 mapping 回退断言\n'; rc=1; }
    grep -q 'fixture_direct_attempts_leave_proxy_untouched' "$calls" \
        && { printf 'FAIL 私网组仍注册旧纯映射直连断言\n'; rc=1; }
    grep -qx $'proxy\tfixture_proxy_path_succeeds' "$calls" \
        || { printf 'FAIL 私网组丢失代理成功断言\n'; rc=1; }
    grep -qx $'proxy\tfixture_proxy_connect_evidence' "$calls" \
        || { printf 'FAIL 私网组丢失代理 CONNECT 证据断言\n'; rc=1; }
    grep -qx $'proxy\tfixture_proxy_failure_falls_back_to_system' "$calls" \
        || { printf 'FAIL 私网组丢失 system 回退断言\n'; rc=1; }
    grep -qx $'proxy\tfixture_system_direct_leaves_proxy_untouched' "$calls" \
        || { printf 'FAIL 私网组丢失 system 直连断言\n'; rc=1; }
    [[ $(grep -c $'^mapping\t' "$calls") == 2 ]] || { printf 'FAIL 新组正例注册次数不为 2\n'; rc=1; }
    grep -qx $'mapping\tfallback' "$calls" || { printf 'FAIL 新组未注册 fallback 场景\n'; rc=1; }
    grep -qx $'mapping\tdirect' "$calls" || { printf 'FAIL 新组未注册 direct 场景\n'; rc=1; }
    [[ $(grep -c $'^negative\t' "$calls") == 21 ]] || { printf 'FAIL 新组负例注册次数不为 21\n'; rc=1; }
    return "$rc"
}

# 单项 mode 只选对应场景：只注册该正例、不注册其它正例与负例，且不选择旧业务组。
single_mapping_mode_is_independent() {
    local calls=$TEST_ROOT/single-calls rc=0
    : > "$calls"
    check_mapping_sync() { printf 'mapping\t%s\n' "${2:-}" >> "$calls"; }
    check_mapping_negative() { printf 'negative\t%s\t%s\n' "${2:-}" "${3:-}" >> "$calls"; }
    IT_MAPPING_SCENARIO=fallback
    integration_register_mapping_group || { printf 'FAIL 单项 mode 注册失败\n'; rc=1; }
    grep -qx $'mapping\tfallback' "$calls" || { printf 'FAIL 单项 mode 未注册对应场景\n'; rc=1; }
    grep -q $'mapping\tdirect' "$calls" && { printf 'FAIL 单项 mode 越权注册其它场景\n'; rc=1; }
    grep -q $'^negative\t' "$calls" && { printf 'FAIL 单项 mode 越权注册负例\n'; rc=1; }
    integration_group_selected mapping || { printf 'FAIL 单项 mode 未选择映射组\n'; rc=1; }
    integration_group_selected https && { printf 'FAIL 单项 mode 选择旧业务组\n'; rc=1; }
    IT_MAPPING_SCENARIO=''
    return "$rc"
}

# 旧业务汇总仅供业务层校验，不能充当 finalized 最终结论。
mapping_full_accept_contract() {
    local dir=$TEST_ROOT/full rc=0
    mkdir -p "$dir"
    full_summary_write "$dir/ok.tsv"
    if mapping_full_accept "$dir/ok.tsv"; then printf 'FAIL 旧业务汇总冒充最终通过\n'; rc=1; fi
    full_summary_write "$dir/no-system.tsv" drop system_fallback
    if mapping_full_accept "$dir/no-system.tsv"; then printf 'FAIL 缺 system 汇总被接受\n'; rc=1; fi
    full_summary_write "$dir/no-mapping.tsv" drop mapping_direct
    if mapping_full_accept "$dir/no-mapping.tsv"; then printf 'FAIL 缺 mapping 汇总被接受\n'; rc=1; fi
    full_summary_write "$dir/defer.tsv" set deferred 1
    if mapping_full_accept "$dir/defer.tsv"; then printf 'FAIL deferred=1 汇总被接受\n'; rc=1; fi
    full_summary_write "$dir/cleanup.tsv" set cleanup_exit 2
    if mapping_full_accept "$dir/cleanup.tsv"; then printf 'FAIL cleanup_exit=2 汇总被接受\n'; rc=1; fi
    full_summary_write "$dir/dup.tsv"
    printf 'mapping_direct\tPASS\n' >> "$dir/dup.tsv"
    if mapping_full_accept "$dir/dup.tsv"; then printf 'FAIL 重复键汇总被接受\n'; rc=1; fi
    return "$rc"
}

# 集成结束路径写出的 13 键业务汇总反映断言与槽位结果，但不得作为最终通过。
full_summary_producer_contract() {
    local file=$TEST_ROOT/producer/summary.tsv rc=0 k
    local -a slots=(mapping_fallback mapping_direct system_fallback system_direct
        dns_negatives tls_negatives isolation_negatives)
    mkdir -p "$TEST_ROOT/producer"
    FAILURES=0 FIXTURE_FAILURES=0
    IT_DEFERRED=0 IT_PRIMARY_EXIT=0 IT_CLEANUP_EXIT=0 IT_RESIDUAL_COUNT=0
    IT_SLOT_DONE=() IT_SLOT_FAIL=()
    for k in "${slots[@]}"; do integration_slot_pass "$k"; done
    integration_full_summary_write "$file" || { printf 'FAIL 汇总写出失败\n'; return 1; }
    [[ $(wc -l < "$file") == 13 ]] || { printf 'FAIL 汇总字段数 %s != 13\n' "$(wc -l < "$file")"; rc=1; }
    if mapping_full_accept "$file"; then printf 'FAIL 13 键业务汇总冒充最终通过\n'; rc=1; fi
    if integration_full_accept "$file" >/dev/null 2>&1; then printf 'FAIL runner 将业务汇总当最终通过\n'; rc=1; fi
    # 断言失败计数非零：判定器必须拒绝。
    FAILURES=1
    integration_full_summary_write "$file" || rc=1
    if mapping_full_accept "$file"; then printf 'FAIL 非零断言汇总被接受\n'; rc=1; fi
    FAILURES=0
    # 槽位缺席（单项 mode 或过滤运行）：判定器必须拒绝。
    IT_SLOT_DONE=() IT_SLOT_FAIL=()
    integration_full_summary_write "$file" || rc=1
    if integration_full_accept "$file" >/dev/null 2>&1; then printf 'FAIL 缺槽位汇总被接受\n'; rc=1; fi
    # 槽位失败：判定器必须拒绝。
    for k in "${slots[@]}"; do integration_slot_pass "$k"; done
    integration_slot_fail tls_negatives
    integration_full_summary_write "$file" || rc=1
    if mapping_full_accept "$file"; then printf 'FAIL 失败槽位汇总被接受\n'; rc=1; fi
    # 延期计数非零同样拒绝（该计数派生自必需映射分组是否真实执行）。
    IT_SLOT_DONE=() IT_SLOT_FAIL=()
    for k in "${slots[@]}"; do integration_slot_pass "$k"; done
    IT_DEFERRED=1
    integration_full_summary_write "$file" || rc=1
    if mapping_full_accept "$file"; then printf 'FAIL 延期汇总被接受\n'; rc=1; fi
    IT_DEFERRED=0
    return "$rc"
}

# runner 结束路径：未 finalized 的替身汇总不论槽位是否完整都必须拒绝。
integration_runner_judges_summary() {
    local scratch failed=0 rc=0
    scratch=$(mktemp -d)
    mkdir -p "$scratch/evidence/control"
    : > "$scratch/evidence/control/start"
    # 集成脚本替身：按 INTEGRATION_VERDICT 写出一份通过或缺失槽位的汇总后返回 0。
    bash() {
        case "$1" in
            *test-docker-integration.sh)
                if [[ ${INTEGRATION_VERDICT:-pass} == pass ]]; then
                    full_summary_write "$IT_EVIDENCE_DIR/control/mapping-full-summary.tsv"
                else
                    full_summary_write "$IT_EVIDENCE_DIR/control/mapping-full-summary.tsv" drop mapping_direct
                fi
                return 0
                ;;
            *) command bash "$@" ;;
        esac
    }
    id() { printf '10001\n'; }
    export -f bash full_summary_write id
    rc=0
    INTEGRATION_VERDICT=pass IT_EVIDENCE_DIR=$scratch/evidence IT_NETWORK_GUARD_READY=1 \
        command bash "$HERE/test-docker-network.sh" --integration > "$scratch/pass.out" 2>&1 || rc=$?
    printf 'RUNNER_FULL_PASS rc=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'FAIL runner accepted an unfinalized summary\n'; failed=1; }
    rc=0
    INTEGRATION_VERDICT=drop IT_EVIDENCE_DIR=$scratch/evidence IT_NETWORK_GUARD_READY=1 \
        command bash "$HERE/test-docker-network.sh" --integration > "$scratch/drop.out" 2>&1 || rc=$?
    printf 'RUNNER_FULL_REJECT rc=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'FAIL runner accepted an incomplete summary\n'; failed=1; }
    grep -q 'MAPPING_FULL_ACCEPT=REJECT' "$scratch/drop.out" \
        || { printf 'FAIL reject marker missing\n'; failed=1; }
    rm -rf "$scratch"
    return "$failed"
}

for name in registration_moves_only_two_mapping_checks single_mapping_mode_is_independent mapping_full_accept_contract \
    full_summary_producer_contract integration_runner_judges_summary; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
