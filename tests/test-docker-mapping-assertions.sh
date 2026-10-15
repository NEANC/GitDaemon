#!/usr/bin/env bash
# Mapping 双断言与反假绿判定的替身契约测试。
# 只替换 Docker/Git/同步入口/TLS 注入等外部边界；编排顺序、证据落盘与判定器走真实实现。
# 判定器不设替身，因此 DNS 假绿、缺计数、system 成功等样本必须被真实判定逻辑拒绝。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
source "$HERE/../scripts/git-mirror-sync.sh"

WORK=$(mktemp -d)
LOG_FILE=$WORK/product.log
trap 'rm -rf "$WORK"' EXIT

# 冻结档案样本：地址仅作替身输入，经未修改的产品校验器判定后才被接受。
profile_write() {
    local file=$1
    printf 'schema_version\t1\n' > "$file"
    printf 'run_id\tmtest\n' >> "$file"
    printf 'cidr\t140.82.112.0/24\n' >> "$file"
    printf 'gateway\t140.82.112.1\n' >> "$file"
    printf 'P\t140.82.112.10\n' >> "$file"
    printf 'U\t140.82.112.11\n' >> "$file"
    printf 'X\t140.82.112.12\n' >> "$file"
    printf 'D\t140.82.112.13\n' >> "$file"
    printf 'N\t140.82.112.14\n' >> "$file"
    printf 'network_name\tgm-mtest-m-net\n' >> "$file"
    printf 'bridge\tmmtest\n' >> "$file"
}

mkdir -p "$WORK"
profile_write "$WORK/profile.tsv"
MAPPING_PROFILE=$WORK/profile.tsv
MAPPING_PRODUCT_IMAGE=product
MAPPING_TOOLS_IMAGE=tools
MAPPING_ASSET_ROOT=$WORK/assets
export MAPPING_PROFILE MAPPING_PRODUCT_IMAGE MAPPING_TOOLS_IMAGE MAPPING_ASSET_ROOT LOG_FILE

# 证据文件 samples 使用的可变字段。
EV_UNIQUE=''
EV_REFS_EXPECTED='' EV_REFS_ACTUAL='' EV_HEAD_EXPECTED='' EV_HEAD_ACTUAL=''
EV_UP_BEFORE='' EV_UP_AFTER='' EV_SYNC_EXIT='' EV_FSCK_EXIT=''
EV_LOG='' EV_CONNECT='' EV_DNS='' EV_ACCEPT_BEFORE='' EV_REJECT_BEFORE='' EV_ACCEPT_AFTER='' EV_REJECT_AFTER=''

# 生命周期替身使用的可变字段。
D_FIXTURE_FAIL=0 D_PRODUCT_FAIL=0 D_EXTRA_NETWORK=0
D_NETWORK_ID='' D_PRODUCT_ID='' D_UNIQUE=''
D_REFS_EXPECTED='' D_REFS_ACTUAL='' D_HEAD_EXPECTED='' D_HEAD_ACTUAL=''
D_UP_BEFORE='' D_UP_AFTER='' D_SYNC_EXIT='' D_FSCK=''
D_ACCEPT_BEFORE='' D_REJECT_BEFORE='' D_ACCEPT_AFTER='' D_REJECT_AFTER=''
D_LOG='' D_CONNECT='' D_DNS=''

# 代理基线文件写入（accept/reject/total 三键，与夹具同格式）。
sa_baseline_write() {
    local file=$1 accept=$2 reject=$3
    printf 'accept\t%s\nreject\t%s\ntotal\t%s\n' "$accept" "$reject" "$((accept + reject))" > "$file"
}

# 证据样本默认值：fallback 代理增量 3→4 且映射成功；direct 代理 4→4。
sa_evidence_defaults() {
    local kind=$1 unique='7a1b2c3d4e5f60718293a4b5c6d7e8f900112233'
    EV_UNIQUE=$unique
    EV_REFS_EXPECTED=$(printf '%s\trefs/heads/main\n' "$unique")
    EV_REFS_ACTUAL=$EV_REFS_EXPECTED
    EV_HEAD_EXPECTED=$unique
    EV_HEAD_ACTUAL=$unique
    EV_UP_BEFORE=5 EV_UP_AFTER=6
    EV_SYNC_EXIT=0 EV_FSCK_EXIT=0
    EV_DNS=$'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\n'
    EV_ACCEPT_BEFORE=0 EV_REJECT_BEFORE=0 EV_ACCEPT_AFTER=0 EV_REJECT_AFTER=0
    EV_CONNECT=''
    case "$kind" in
        fallback)
            EV_ACCEPT_BEFORE=3 EV_REJECT_BEFORE=0
            EV_ACCEPT_AFTER=3 EV_REJECT_AFTER=1
            EV_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n同步传输路径：直连加动态地址映射\n'
            EV_CONNECT=$'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
            ;;
        direct)
            EV_ACCEPT_BEFORE=4 EV_REJECT_BEFORE=0
            EV_ACCEPT_AFTER=4 EV_REJECT_AFTER=0
            EV_LOG=$'同步传输路径：直连加动态地址映射\n'
            ;;
        *) return 1 ;;
    esac
    return 0
}

# 写出全部 14 个必需证据文件。
sa_evidence_write() {
    local kind=$1 dir=$2
    mkdir -p "$dir"
    {
        printf 'run_id\tr1\n'
        printf 'scenario\t%s\n' "$(mapping_assert_scenario "$kind")"
        printf 'generation\tg1\n'
        printf 'network_id\tnetid1\n'
        printf 'image_id\tproduct\n'
        printf 'profile_sha256\tp1\n'
        printf 'input_sha256\ti1\n'
        printf 'manifest_sha256\tm1\n'
        printf 'unique_commit\t%s\n' "$EV_UNIQUE"
    } > "$dir/identity.tsv"
    printf '%s\n' "$EV_UP_BEFORE" > "$dir/upstream.before"
    printf '%s\n' "$EV_UP_AFTER" > "$dir/upstream.after"
    printf '%s\n' "$EV_SYNC_EXIT" > "$dir/sync.exit"
    printf '%s\n' "$EV_FSCK_EXIT" > "$dir/fsck.exit"
    printf '%s' "$EV_LOG" > "$dir/sync.log"
    printf '%s' "$EV_CONNECT" > "$dir/connect.log"
    printf '%s' "$EV_REFS_EXPECTED" > "$dir/refs.expected"
    printf '%s' "$EV_REFS_ACTUAL" > "$dir/refs.actual"
    printf '%s' "$EV_HEAD_EXPECTED" > "$dir/head.expected"
    printf '%s' "$EV_HEAD_ACTUAL" > "$dir/head.actual"
    printf '%s' "$EV_DNS" > "$dir/dns.txt"
    sa_baseline_write "$dir/proxy.before" "$EV_ACCEPT_BEFORE" "$EV_REJECT_BEFORE"
    sa_baseline_write "$dir/proxy.after" "$EV_ACCEPT_AFTER" "$EV_REJECT_AFTER"
}

# 改写 identity.tsv 的 scenario 字段（用于跨场景证据样本）。
sa_identity_scenario() {
    local dir=$1 scenario=$2 file=$1/identity.tsv
    awk -v s="$scenario" 'BEGIN{FS=OFS="\t"} $1=="scenario"{$2=s} {print}' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# 生命周期替身默认参数：与证据样本一致，另含独有提交与网络身份。
sa_lifecycle_defaults() {
    local kind=$1
    sa_evidence_defaults "$kind"
    D_FIXTURE_FAIL=0 D_PRODUCT_FAIL=0 D_EXTRA_NETWORK=0
    D_NETWORK_ID='netid-double' D_PRODUCT_ID="gm-double-$kind-product"
    D_UNIQUE=$EV_UNIQUE
    D_REFS_EXPECTED=$EV_REFS_EXPECTED D_REFS_ACTUAL=$EV_REFS_ACTUAL
    D_HEAD_EXPECTED=$EV_HEAD_EXPECTED D_HEAD_ACTUAL=$EV_HEAD_ACTUAL
    D_UP_BEFORE=$EV_UP_BEFORE D_UP_AFTER=$EV_UP_AFTER
    D_SYNC_EXIT=$EV_SYNC_EXIT D_FSCK=$EV_FSCK_EXIT
    D_ACCEPT_BEFORE=$EV_ACCEPT_BEFORE D_REJECT_BEFORE=$EV_REJECT_BEFORE
    D_ACCEPT_AFTER=$EV_ACCEPT_AFTER D_REJECT_AFTER=$EV_REJECT_AFTER
    D_LOG=$EV_LOG D_CONNECT=$EV_CONNECT D_DNS=$EV_DNS
}

# 替换全部外部边界：Docker/Git/同步入口/校准探针/隔离审计。
sa_doubles() {
    mapping_scenario_fixture_prepare() {
        local dir=$3
        [[ ${D_FIXTURE_FAIL:-0} == 0 ]] || return 80
        mkdir -p "$dir/control" || return 80
        printf 'network_id\t%s\n' "${D_NETWORK_ID:-netid-double}" > "$dir/control/mapping-network.tsv"
        # 负例缺陷选择走真实逻辑，只有证书替换/额外网络边界被替换。
        mapping_negative_prepare "$1" "$2" "$dir" || return 80
        return 0
    }
    mapping_scenario_calibrate() {
        sa_baseline_write "$3/proxy.before" "${D_ACCEPT_BEFORE:-0}" "${D_REJECT_BEFORE:-0}" || return 80
    }
    mapping_scenario_product_up() {
        [[ ${D_PRODUCT_FAIL:-0} == 0 ]] || return 80
        printf '%s\n' "${D_PRODUCT_ID:-gm-double-product}"
    }
    mapping_scenario_upstream_count() {
        local marker=$3/control/up-count
        if [[ -e $marker ]]; then
            printf '%s\n' "${D_UP_AFTER:-0}"
        else
            : > "$marker"
            printf '%s\n' "${D_UP_BEFORE:-0}"
        fi
    }
    mapping_scenario_upstream_commit() {
        mkdir -p "$3/control"
        printf '%s\n' "${D_UNIQUE:-}" > "$3/control/unique-commit"
        printf '%s\n' "${D_UNIQUE:-}"
    }
    mapping_scenario_upstream_refs() { printf '%s\n' "${D_REFS_EXPECTED:-}"; }
    mapping_scenario_upstream_head() { printf '%s\n' "${D_HEAD_EXPECTED:-}"; }
    mapping_scenario_sync_exec() {
        printf '%s' "${D_LOG:-}" > "$3/sync.log"
        printf '%s\n' "${D_SYNC_EXIT:-0}" > "$3/sync.exit"
        return 0
    }
    mapping_scenario_proxy_after() {
        local accept=${D_ACCEPT_AFTER:-0} reject=${D_REJECT_AFTER:-0}
        printf 'accept\t%s\nreject\t%s\ntotal\t%s\n' "$accept" "$reject" "$((accept + reject))"
    }
    mapping_scenario_connect_evidence() { printf '%s' "${D_CONNECT:-}"; }
    mapping_scenario_local_refs() { printf '%s\n' "${D_REFS_ACTUAL:-}"; }
    mapping_scenario_local_head() { printf '%s\n' "${D_HEAD_ACTUAL:-}"; }
    mapping_scenario_local_fsck() { printf '%s\n' "${D_FSCK:-0}"; }
    mapping_scenario_dns_state() { printf '%s' "${D_DNS:-}"; }
    mapping_scenario_release() { return 0; }
    # 证书替换与额外网络附件是唯一被替换的负例注入边界，负例缺陷选择逻辑保持真实。
    mapping_negative_wrong_ca() { return 0; }
    mapping_negative_wrong_san() { return 0; }
    mapping_negative_extra_network() { return 0; }
    mapping_policy_check() {
        if [[ ${D_EXTRA_NETWORK:-0} == 1 ]]; then return 1; fi
        return 0
    }
    return 0
}

# 安装替身并载入某场景参数。
sa_lifecycle_case() {
    sa_doubles
    sa_lifecycle_defaults "$1"
}

# 正例控制：同一替身下正例必须通过。
sa_positive_control() {
    local kind=$1 dir rc=0
    dir=$(mktemp -d)
    sa_lifecycle_case "$kind"
    mapping_scenario_run "$kind" "$dir" || rc=$?
    rm -rf "$dir"
    if [[ $rc != 0 ]]; then printf 'positive control %s rc=%s\n' "$kind" "$rc"; return 1; fi
    return 0
}

# 证据样本断言：fallback 需代理失败先于映射成功且代理增量与 U 计数为正。
fallback_requires_order_and_connect_growth() {
    local dir failed=0
    dir=$(mktemp -d)
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    if ! mapping_assert_result fallback "$dir"; then printf 'valid fallback sample rejected\n'; failed=1; fi
    sa_baseline_write "$dir/proxy.after" 3 0
    if mapping_assert_result fallback "$dir"; then printf 'zero proxy growth accepted\n'; failed=1; fi
    sa_evidence_defaults fallback
    EV_LOG=$'同步传输路径：直连加动态地址映射\n'
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'missing proxy precedence accepted\n'; failed=1; fi
    sa_evidence_defaults fallback
    EV_CONNECT=''
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'missing legal connect accepted\n'; failed=1; fi
    sa_evidence_defaults fallback
    EV_CONNECT=$'authority=github.com:443\tmode=accept\tdial_target=10.9.9.9:443\n'
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'foreign dial target accepted\n'; failed=1; fi
    sa_evidence_defaults fallback
    EV_UP_AFTER=5
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'zero upstream growth accepted\n'; failed=1; fi
    rm -rf "$dir"
    return "$failed"
}

# 证据样本断言：direct 以自身基线判定，代理增量严格为 0。
direct_requires_own_baseline() {
    local dir other failed=0
    dir=$(mktemp -d)
    other=$(mktemp -d)
    sa_evidence_defaults direct
    sa_evidence_write direct "$dir"
    if ! mapping_assert_result direct "$dir"; then printf 'valid direct sample rejected\n'; failed=1; fi
    sa_baseline_write "$dir/proxy.after" 5 0
    if mapping_assert_result direct "$dir"; then printf 'direct proxy growth accepted\n'; failed=1; fi
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$other"
    if mapping_assert_result direct "$other"; then printf 'fallback sample accepted as direct\n'; failed=1; fi
    if ! sa_positive_control direct; then printf 'direct lifecycle control failed\n'; failed=1; fi
    rm -rf "$dir" "$other"
    return "$failed"
}

# 顺序无关：两场景各自独立目录与 generation，互换执行顺序结果不变，且不触碰对方证据目录。
scenario_order_independent() {
    local a b c d failed=0 name file
    a=$(mktemp -d)
    b=$(mktemp -d)
    c=$(mktemp -d)
    d=$(mktemp -d)
    sa_lifecycle_case fallback
    mapping_scenario_run fallback "$a" || { printf 'fallback-first fallback failed rc=%s\n' "$?"; failed=1; }
    if [[ -n $(ls -A "$b" 2>/dev/null) ]]; then printf 'fallback wrote into direct evidence dir\n'; failed=1; fi
    sa_lifecycle_case direct
    mapping_scenario_run direct "$b" || { printf 'fallback-first direct failed rc=%s\n' "$?"; failed=1; }
    if [[ -n $(ls -A "$c" 2>/dev/null) ]]; then printf 'direct wrote into unused evidence dir\n'; failed=1; fi
    sa_lifecycle_case direct
    mapping_scenario_run direct "$c" || { printf 'direct-first direct failed rc=%s\n' "$?"; failed=1; }
    if [[ -n $(ls -A "$d" 2>/dev/null) ]]; then printf 'direct wrote into fallback evidence dir\n'; failed=1; fi
    sa_lifecycle_case fallback
    mapping_scenario_run fallback "$d" || { printf 'direct-first fallback failed rc=%s\n' "$?"; failed=1; }
    grep -qx $'scenario\tmapping-fallback' "$a/identity.tsv" || { printf 'fallback identity not bound\n'; failed=1; }
    grep -qx $'scenario\tmapping-direct' "$b/identity.tsv" || { printf 'direct identity not bound\n'; failed=1; }
    grep -qx $'scenario\tmapping-direct' "$c/identity.tsv" || { printf 'direct identity not bound (reverse)\n'; failed=1; }
    grep -qx $'scenario\tmapping-fallback' "$d/identity.tsv" || { printf 'fallback identity not bound (reverse)\n'; failed=1; }
    for name in $MAPPING_ASSERT_FILES; do
        file=$a/$name
        [[ -f $file ]] || { printf 'fallback evidence missing %s\n' "$name"; failed=1; }
        file=$b/$name
        [[ -f $file ]] || { printf 'direct evidence missing %s\n' "$name"; failed=1; }
    done
    rm -rf "$a" "$b" "$c" "$d"
    return "$failed"
}

# 跨场景 identity：另一场景的证据不得被判为本场景通过。
reject_cross_scenario_evidence() {
    local dir failed=0
    dir=$(mktemp -d)
    sa_evidence_defaults direct
    sa_evidence_write direct "$dir"
    sa_identity_scenario "$dir" mapping-fallback
    if mapping_assert_result direct "$dir"; then printf 'cross-scenario identity accepted by direct\n'; failed=1; fi
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    sa_identity_scenario "$dir" mapping-direct
    if mapping_assert_result fallback "$dir"; then printf 'cross-scenario identity accepted by fallback\n'; failed=1; fi
    if mapping_assert_result bogus "$dir" 2>/dev/null; then printf 'unknown kind accepted\n'; failed=1; fi
    rm -rf "$dir"
    return "$failed"
}

# 缺计数与坏读数：缺文件、负计数、非整数、零增量一律拒绝。
reject_missing_counter() {
    local dir failed=0
    dir=$(mktemp -d)
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    if ! mapping_assert_result fallback "$dir"; then printf 'valid sample rejected\n'; return 1; fi
    rm -f "$dir/proxy.after"
    if mapping_assert_result fallback "$dir"; then printf 'missing proxy counter accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    printf 'accept\t3\nreject\t1\n' > "$dir/proxy.after"
    if mapping_assert_result fallback "$dir"; then printf 'truncated counter accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    printf -- '-1\n' > "$dir/upstream.after"
    if mapping_assert_result fallback "$dir"; then printf 'negative upstream counter accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    rm -f "$dir/sync.exit"
    if mapping_assert_result fallback "$dir"; then printf 'missing sync.exit accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    rm -f "$dir/identity.tsv"
    if mapping_assert_result fallback "$dir"; then printf 'missing identity accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    rm -f "$dir/dns.txt"
    if mapping_assert_result fallback "$dir"; then printf 'missing dns evidence accepted\n'; failed=1; fi
    rm -rf "$dir"
    return "$failed"
}

# system/proxy 成功文案：即使同步退出 0 也必须否定 mapping 成功。
reject_system_success() {
    local dir failed=0
    dir=$(mktemp -d)
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    if ! mapping_assert_result fallback "$dir"; then printf 'clean mapping log rejected\n'; return 1; fi
    EV_LOG=$'同步传输路径：直连加动态地址映射\n同步传输路径：直连系统 DNS\n'
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'system success with mapping accepted\n'; failed=1; fi
    EV_LOG=$'同步传输路径：配置的 HTTPS 代理\n'
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'proxy success accepted\n'; failed=1; fi
    EV_LOG=$'同步传输路径：直连系统 DNS\n'
    EV_UP_AFTER=6
    sa_evidence_write fallback "$dir"
    if mapping_assert_result fallback "$dir"; then printf 'system-only success accepted\n'; failed=1; fi
    rm -rf "$dir"
    return "$failed"
}

# refs/HEAD：期望与实际必须精确一致，且含本轮独有提交。
reject_stale_refs() {
    local dir failed=0 other='0011223344556677889900aabbccddeeff001122'
    dir=$(mktemp -d)
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    if ! mapping_assert_result fallback "$dir"; then printf 'valid sample rejected\n'; return 1; fi
    printf 'main\t%s\n' "$other" > "$dir/refs.actual"
    if mapping_assert_result fallback "$dir"; then printf 'stale refs accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    printf '%s\n' "$other" > "$dir/head.actual"
    if mapping_assert_result fallback "$dir"; then printf 'head drift accepted\n'; failed=1; fi
    sa_evidence_write fallback "$dir"
    printf 'main\t%s\n' "$other" > "$dir/refs.expected"
    printf 'main\t%s\n' "$other" > "$dir/refs.actual"
    if mapping_assert_result fallback "$dir"; then printf 'refs without unique commit accepted\n'; failed=1; fi
    rm -rf "$dir"
    return "$failed"
}

# invalid-map 必须由未修改的产品校验器拒绝，且不生成 resolve 参数。
invalid_map_original_validator_rejects() {
    local failed=0 dir snap addr
    dir=$(mktemp -d)
    for addr in 10.0.0.9 172.16.0.9 192.168.0.9 192.0.2.9 198.51.100.9 203.0.113.9 198.18.0.9 198.19.0.9; do
        snap=$dir/snapshot
        printf '%s github.com\n' "$addr" > "$snap"
        if gm_hosts_read_snapshot "$snap" >/dev/null 2>&1; then printf 'reserved snapshot accepted: %s\n' "$addr"; failed=1; fi
        if mapping_public_address "$addr"; then printf 'mapping validator accepted reserved: %s\n' "$addr"; failed=1; fi
        GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
        GITHUB_HOST=github.com
        GM_RESOLVE_ARGS=()
        load_resolve_args "$snap" >/dev/null 2>&1 || true
        if (( ${#GM_RESOLVE_ARGS[@]} != 0 )); then printf 'resolve generated for reserved: %s\n' "$addr"; failed=1; fi
    done
    snap=$dir/legal
    printf '140.82.112.11 github.com\n' > "$snap"
    gm_hosts_read_snapshot "$snap" >/dev/null || { printf 'legal snapshot rejected\n'; failed=1; }
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GITHUB_HOST=github.com
    GM_RESOLVE_ARGS=()
    load_resolve_args "$snap" >/dev/null 2>&1 || true
    # 每个映射记录产生 -c 与解析值两个参数；保留地址必须一个都不产生。
    if (( ${#GM_RESOLVE_ARGS[@]} != 2 )); then printf 'legal snapshot did not produce resolve\n'; failed=1; fi
    if [[ ${GM_RESOLVE_ARGS[*]} != *http.curloptResolve=github.com:443:140.82.112.11* ]]; then
        printf 'legal resolve value wrong: %s\n' "${GM_RESOLVE_ARGS[*]}"
        failed=1
    fi
    rm -rf "$dir"
    return "$failed"
}

# 负例缺陷选择的行为断言：快照/DNS 模式与用例语义一致，且假绿例只指向可信 U。
sa_negative_expect_modes() {
    local case_name=$1 expect_snapshot='' expect_dns='none'
    case "$case_name" in
        missing-map) expect_snapshot=none ;;
        invalid-map) expect_snapshot=reserved ;;
        dns-false-green) expect_snapshot=none expect_dns=upstream ;;
        unreachable-map-system) expect_snapshot=unallocated expect_dns=upstream ;;
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san|isolation) expect_snapshot=valid ;;
        *) printf 'unknown negative case %s\n' "$case_name"; return 1 ;;
    esac
    [[ $MAPPING_ASSERT_SNAPSHOT_MODE == "$expect_snapshot" ]] || {
        printf 'case %s snapshot mode %s != %s\n' "$case_name" "$MAPPING_ASSERT_SNAPSHOT_MODE" "$expect_snapshot"
        return 1
    }
    [[ $MAPPING_ASSERT_DNS_MODE == "$expect_dns" ]] || {
        printf 'case %s dns mode %s != %s\n' "$case_name" "$MAPPING_ASSERT_DNS_MODE" "$expect_dns"
        return 1
    }
    if [[ $expect_dns == upstream ]]; then
        [[ $MAPPING_DNS_FAKE_HOST == github.com && -n $MAPPING_DNS_FAKE_IP ]] || {
            printf 'case %s did not point system DNS at trusted U\n' "$case_name"
            return 1
        }
    elif [[ -n $MAPPING_DNS_FAKE_HOST || -n $MAPPING_DNS_FAKE_IP ]]; then
        printf 'case %s leaked a fake DNS override\n' "$case_name"
        return 1
    fi
    return 0
}

# 负例通用驱动：编排走真实实现，缺陷由替身参数注入。
sa_negative_case() {
    local case_name=$1 kind=$2 mode=$3 dir rc=0 failed=0
    dir=$(mktemp -d)
    sa_lifecycle_case "$kind"
    sa_negative_overrides "$case_name"
    mapping_negative_run "$case_name" "$kind" "$dir" || rc=$?
    printf 'NEGATIVE %s/%s rc=%s\n' "$case_name" "$kind" "$rc"
    if [[ $rc != 0 ]]; then printf 'negative %s/%s not rejected rc=%s\n' "$case_name" "$kind" "$rc"; failed=1; fi
    sa_negative_expect_modes "$case_name" || failed=1
    if [[ $mode == judge ]]; then
        if mapping_assert_result "$kind" "$dir"; then printf 'negative %s/%s passed the judge\n' "$case_name" "$kind"; failed=1; fi
    fi
    rm -rf "$dir"
    return "$failed"
}

# 各负例的替身缺陷参数。
sa_negative_overrides() {
    case "$1" in
        missing-map|invalid-map)
            D_SYNC_EXIT=1
            D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n传输失败：直连加动态地址映射；尝试下一路径\n同步失败：全部传输路径均不可用：gitdaemon/fixture\n'
            ;;
        dns-false-green|unreachable-map-system)
            D_SYNC_EXIT=0
            D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n传输失败：直连加动态地址映射；尝试下一路径\n同步传输路径：直连系统 DNS\n'
            ;;
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san)
            D_SYNC_EXIT=1
            D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n传输失败：直连加动态地址映射；尝试下一路径\n同步失败：全部传输路径均不可用：gitdaemon/fixture\n'
            ;;
        isolation)
            D_EXTRA_NETWORK=1
            ;;
    esac
    return 0
}

negative_missing_map() {
    sa_negative_case missing-map fallback judge || return 1
    sa_negative_case missing-map direct judge
}

negative_invalid_map() {
    invalid_map_original_validator_rejects || return 1
    sa_negative_case invalid-map fallback judge || return 1
    sa_negative_case invalid-map direct judge
}

# 两个 DNS 假绿例：DNS 指向可信 U 时底层 system 可成功，判定器必须非零。
negative_dns_false_green() {
    sa_negative_case dns-false-green fallback judge || return 1
    sa_negative_case dns-false-green direct judge || return 1
    if ! sa_positive_control fallback; then printf 'post-negative positive control failed\n'; return 1; fi
    if ! sa_positive_control direct; then printf 'post-negative positive control failed\n'; return 1; fi
    return 0
}

negative_unreachable_map_system() {
    sa_negative_case unreachable-map-system fallback judge || return 1
    sa_negative_case unreachable-map-system direct judge
}

negative_tls_names() {
    local name failed=0
    for name in wrong_proxy_ca wrong_proxy_san wrong_upstream_ca wrong_upstream_san; do
        sa_negative_case "$name" fallback judge || failed=1
        sa_negative_case "$name" direct judge || failed=1
    done
    return "$failed"
}

negative_isolation() {
    sa_negative_case isolation fallback policy || return 1
    sa_negative_case isolation direct policy
}

# 夹具失败一律 80；正例与负例都不得把它吞成 0 或 1。
fixture_failure_is_80() {
    local dir failed=0 rc=0
    dir=$(mktemp -d)
    sa_lifecycle_case fallback
    D_FIXTURE_FAIL=1
    mapping_scenario_run fallback "$dir" || rc=$?
    printf 'RUN_FIXTURE_FAIL rc=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'run did not surface fixture failure\n'; failed=1; }
    rm -rf "$dir"
    dir=$(mktemp -d)
    sa_lifecycle_case fallback
    D_FIXTURE_FAIL=1
    rc=0
    mapping_negative_run missing-map fallback "$dir" || rc=$?
    printf 'NEG_FIXTURE_FAIL rc=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'negative did not surface fixture failure\n'; failed=1; }
    rm -rf "$dir"
    return "$failed"
}

MAPPING_ASSERTION_TESTS='fallback_requires_order_and_connect_growth
direct_requires_own_baseline
scenario_order_independent
reject_cross_scenario_evidence
reject_missing_counter
reject_system_success
reject_stale_refs
invalid_map_original_validator_rejects
negative_missing_map
negative_invalid_map
negative_dns_false_green
negative_unreachable_map_system
negative_tls_names
negative_isolation
fixture_failure_is_80'

case "${1:-all}" in
    all) TESTS=$MAPPING_ASSERTION_TESTS ;;
    *) TESTS=$1 ;;
esac

failed=0
for name in $TESTS; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
