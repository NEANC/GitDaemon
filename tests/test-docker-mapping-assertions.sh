#!/usr/bin/env bash
# Mapping 双断言与反假绿判定的替身契约测试。
# 只替换 Docker/Git/同步入口/TLS 注入等外部边界；编排顺序、证据落盘与判定器走真实实现。
# 判定器不设替身，因此 DNS 假绿、缺计数、system 成功等样本必须被真实判定逻辑拒绝。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-resource-ledger.sh"
source "$HERE/docker-network-fixture.sh"
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
MAPPING_MANIFEST=$WORK/manifest.tsv
MAPPING_PRODUCT_IMAGE=product
MAPPING_TOOLS_IMAGE=tools
MAPPING_ASSET_ROOT=$WORK/assets
printf 'manifest\n' > "$MAPPING_MANIFEST"
export MAPPING_PROFILE MAPPING_MANIFEST MAPPING_PRODUCT_IMAGE MAPPING_TOOLS_IMAGE MAPPING_ASSET_ROOT LOG_FILE
mkdir -p "$WORK/run/control"
sha256sum "$MAPPING_MANIFEST" > "$WORK/run/inputs.sha256"
sha256sum "$WORK/run/inputs.sha256" | cut -d' ' -f1 > "$WORK/run/inputs.sha256.digest"
IT_CONTROL_DIR=$WORK/run/control
IT_EVIDENCE_DIR=$WORK/run
mapping_scenario_input_facts() { printf '0 644\n'; }

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
    EV_DNS=$'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n'
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
# 传 1 时保留真实 mapping_scenario_release（供「同进程重跑」用例验证释放完整性）。
sa_doubles() {
    local keep_release=${1:-0}
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
        local dir=${3:-} content
        [[ ${D_PRODUCT_FAIL:-0} == 0 ]] || return 80
        [[ -n $dir && -d $dir ]] || return 80
        # 行为级取证：真实消费按用例选定的快照模式，把本轮实际写入的快照内容落盘，
        # 使「missing-map 未置 none / invalid-map 未置 reserved」这类回归可被断言检出。
        content=$(mapping_scenario_snapshot_content "$1") || return 80
        printf '%s' "$content" > "$dir/control/snapshot.content" || return 80
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
    mapping_network_id_load() { printf '%s\n' "${D_NETWORK_ID:-netid-double}"; }
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
    # 受控 DNS 状态替身：按假绿开关推导，模拟「开关生效 → github.com 指向可信 U；开关复位 → NXDOMAIN」，
    # 使假绿负例自包含，并让「恢复 NXDOMAIN」可被真实断言。
    mapping_scenario_dns_state() {
        local fake='NXDOMAIN' proxy
        mapping_profile_load "$MAPPING_PROFILE" || return 80
        if [[ ${MAPPING_DNS_FAKE_HOST:-} == "$MAPPING_UPSTREAM_HOST" && -n ${MAPPING_DNS_FAKE_IP:-} ]]; then
            fake=$MAPPING_DNS_FAKE_IP
        fi
        proxy=${D_PROXY_X:-$MP_X}
        printf '%s\tA\t%s\n' "$MAPPING_UPSTREAM_HOST" "$fake"
        printf '%s\tAAAA\tNXDOMAIN\n' "$MAPPING_UPSTREAM_HOST"
        printf '%s\tA\t%s\n' "$MAPPING_PROXY_HOST" "$proxy"
    }
    mapping_dns_set() { return 0; }
    if [[ $keep_release != 1 ]]; then
        mapping_scenario_release() { return 0; }
    fi
    # 证书替换与额外网络附件是唯一被替换的负例注入边界，负例缺陷选择逻辑保持真实。
    mapping_negative_wrong_ca() { return 0; }
    mapping_negative_wrong_san() { return 0; }
    mapping_negative_extra_network() { return 0; }
    mapping_isolation_check() { return 0; }
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

# 负例证据的被拒层次断言（行为级）：底层同步失败记为 sync，映射判定拒绝记为 mapping，
# 配置审计拒绝记为 policy；层次必须被记录且与用例语义一致，供后续区分拒绝来源。
sa_negative_layer() {
    local case_name=$1 dir=$2 layer expect
    case "$case_name" in
        missing-map|invalid-map|wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san) expect=sync ;;
        dns-false-green|unreachable-map-system) expect=mapping ;;
        isolation) expect=policy ;;
        *) printf 'unknown negative case %s\n' "$case_name"; return 1 ;;
    esac
    layer=$(sed -n '1p' "$dir/reject.layer" 2>/dev/null) || layer=''
    [[ -n $layer ]] || { printf 'case %s recorded no reject layer\n' "$case_name"; return 1; }
    [[ $layer == "$expect" ]] || {
        printf 'case %s rejected at layer %s != %s\n' "$case_name" "$layer" "$expect"
        return 1
    }
    printf 'REJECT_LAYER %s=%s\n' "$case_name" "$layer"
    return 0
}

# 负例快照行为断言（行为级）：读取本轮实际写入的快照内容，核验「按用例选择快照模式」未回归。
# 空内容=未写快照；invalid-map 写的地址必须仍被未修改的产品校验器拒绝；
# unreachable-map-system 必须写冻结未分配地址 N；TLS/isolation 必须写可信 U。
sa_negative_snapshot() {
    local case_name=$1 dir=$2 file=$2/control/snapshot.content content addr expect
    case "$case_name" in
        missing-map|dns-false-green) expect=none ;;
        invalid-map) expect=reserved ;;
        unreachable-map-system) expect=unallocated ;;
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san|isolation) expect=valid ;;
        *) printf 'unknown negative case %s\n' "$case_name"; return 1 ;;
    esac
    [[ -f $file ]] || { printf 'case %s recorded no snapshot decision\n' "$case_name"; return 1; }
    content=$(cat -- "$file" 2>/dev/null) || content=''
    mapping_profile_load "$MAPPING_PROFILE" || return 1
    if [[ $expect == none ]]; then
        [[ -z $content ]] || { printf 'case %s wrote snapshot %s\n' "$case_name" "$content"; return 1; }
        printf 'NEG_SNAPSHOT %s=%s\n' "$case_name" "$expect"
        return 0
    fi
    [[ -n $content && $content == *" $MAPPING_UPSTREAM_HOST" ]] || {
        printf 'case %s wrote malformed snapshot: %s\n' "$case_name" "$content"
        return 1
    }
    addr=${content%% *}
    case "$expect" in
        reserved)
            if mapping_public_address "$addr" >/dev/null 2>&1; then
                printf 'case %s wrote a public address %s\n' "$case_name" "$addr"
                return 1
            fi
            ;;
        unallocated|valid)
            if ! mapping_public_address "$addr"; then
                printf 'case %s wrote non-public address %s\n' "$case_name" "$addr"
                return 1
            fi
            if [[ $expect == unallocated ]]; then
                [[ $addr == "$MP_N" ]] || { printf 'case %s wrote %s != N\n' "$case_name" "$addr"; return 1; }
            else
                [[ $addr == "$MP_U" ]] || { printf 'case %s wrote %s != U\n' "$case_name" "$addr"; return 1; }
            fi
            ;;
    esac
    printf 'NEG_SNAPSHOT %s=%s\n' "$case_name" "$expect"
    return 0
}

# 负例通用驱动：编排走真实实现，缺陷由替身参数注入。
# 行为级断言：未注入缺陷时同一替身下正例通过（证明缺陷真的改变了结果），注入后负例被拒，
# 证据记录了与用例语义一致的被拒层次，且本轮实际写入的快照内容与用例语义一致。
sa_negative_case() {
    local case_name=$1 kind=$2 mode=$3 dir rc=0 failed=0
    sa_positive_control "$kind" || { printf 'baseline control failed %s/%s\n' "$case_name" "$kind"; failed=1; }
    dir=$(mktemp -d)
    sa_lifecycle_case "$kind"
    sa_negative_overrides "$case_name"
    mapping_negative_run "$case_name" "$kind" "$dir" || rc=$?
    printf 'NEGATIVE %s/%s rc=%s\n' "$case_name" "$kind" "$rc"
    if [[ $rc != 0 ]]; then printf 'negative %s/%s not rejected rc=%s\n' "$case_name" "$kind" "$rc"; failed=1; fi
    sa_negative_layer "$case_name" "$dir" || failed=1
    sa_negative_snapshot "$case_name" "$dir" || failed=1
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
        dns-false-green)
            D_SYNC_EXIT=0
            D_LOG=$'传输失败：直连加动态地址映射；尝试下一路径\n同步传输路径：直连系统 DNS\n'
            ;;
        unreachable-map-system)
            D_SYNC_EXIT=0
            D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n传输失败：直连加动态地址映射；尝试下一路径\n同步传输路径：直连系统 DNS\n'
            ;;
        wrong_proxy_ca|wrong_proxy_san)
            D_SYNC_EXIT=1
            D_ACCEPT_AFTER=$D_ACCEPT_BEFORE D_REJECT_AFTER=$D_REJECT_BEFORE
            D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n传输失败：直连加动态地址映射；尝试下一路径\n同步失败：全部传输路径均不可用：gitdaemon/fixture\n'
            ;;
        wrong_upstream_ca|wrong_upstream_san)
            D_SYNC_EXIT=1
            D_ACCEPT_AFTER=$((D_ACCEPT_BEFORE + 1)) D_REJECT_AFTER=$D_REJECT_BEFORE
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

# 两个 DNS 假绿例：系统 DNS 指向可信 U 时底层 system 可成功，判定器必须因 DNS 证据非零。
# 负例自包含（拒绝来自 dns.txt 本身，不依赖正例重跑），结束后断言受控 DNS 恢复 NXDOMAIN。
negative_dns_false_green() {
    local dir failed=0
    sa_negative_case dns-false-green fallback judge || return 1
    sa_negative_case dns-false-green direct judge || return 1
    [[ -z ${MAPPING_DNS_FAKE_HOST:-} && -z ${MAPPING_DNS_FAKE_IP:-} ]] || { printf 'fake dns override leaked\n'; return 1; }
    dir=$(mktemp -d)
    mapping_scenario_dns_restore fallback mapping-fallback-fake "$dir" \
        || { printf 'dns not restored to NXDOMAIN\n'; failed=1; }
    rm -rf "$dir"
    return "$failed"
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

# 场景运行必须局部化证据目录：返回后外层 IT_EVIDENCE_DIR 不得被改写，
# 否则映射组之后的其它分组会把证据写进映射场景的嵌套目录。
scenario_evidence_dir_local() {
    local dir_a dir_b failed=0 rc=0
    dir_a=$(mktemp -d)
    dir_b=$(mktemp -d)
    sa_lifecycle_case fallback
    IT_EVIDENCE_DIR=/outer/evidence
    mapping_scenario_run fallback "$dir_a" || { printf 'scenario run failed\n'; failed=1; }
    [[ $IT_EVIDENCE_DIR == /outer/evidence ]] \
        || { printf 'scenario run changed IT_EVIDENCE_DIR: %s\n' "$IT_EVIDENCE_DIR"; failed=1; }
    sa_lifecycle_case fallback
    D_SYNC_EXIT=1
    D_LOG=$'传输失败：配置的 HTTPS 代理；尝试下一路径\n'
    IT_EVIDENCE_DIR=/outer/evidence
    rc=0
    mapping_negative_run missing-map fallback "$dir_b" || rc=$?
    [[ $rc == 0 ]] || { printf 'negative run rc=%s\n' "$rc"; failed=1; }
    [[ $IT_EVIDENCE_DIR == /outer/evidence ]] \
        || { printf 'negative run changed IT_EVIDENCE_DIR: %s\n' "$IT_EVIDENCE_DIR"; failed=1; }
    MAPPING_ASSERT_CASE=''
    rm -rf "$dir_a" "$dir_b"
    return "$failed"
}

# 隔离负例的真实注入代码必须执行：创建并登记第二个网络，再把产品接入该网络；
# 只替换 Docker 边界，注入逻辑本身走真实实现（不能整体替换为 return 0）。
negative_extra_network_real_injection() {
    local failed=0 ledger calls id
    RS_STORE=$(mktemp)
    : > "$RS_STORE"
    ledger=$(mktemp -d)
    calls=$(mktemp)
    rs_install
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$calls"
        rs_docker "$@"
    }
    mapping_profile_load "$MAPPING_PROFILE" || { printf 'profile load failed\n'; failed=1; }
    MAPPING_ASSERT_CASE=isolation
    mapping_negative_extra_network "$ledger" product-id || { printf 'extra network injection failed\n'; failed=1; }
    id=$(rs_lookup network gm-mtest-neg-net)
    [[ -n $id ]] || { printf 'extra network was not created and registered\n'; failed=1; }
    grep -q 'network connect gm-mtest-neg-net product-id' "$calls" \
        || { printf 'product was not attached to the extra network\n'; failed=1; }
    printf 'EXTRA_NETWORK id=%s\n' "$id"
    MAPPING_ASSERT_CASE=''
    rm -rf "$ledger"
    rm -f "$RS_STORE" "$calls"
    return "$failed"
}

# dns.txt 是活证据：github.com 指向可信 U（假绿）或 gm-proxy 未指向 X 时必须拒绝，
# 且拒绝层次为映射判定层。
dns_evidence_required() {
    local dir failed=0 layer
    dir=$(mktemp -d)
    sa_evidence_defaults fallback
    sa_evidence_write fallback "$dir"
    mapping_assert_result fallback "$dir" || { printf 'valid dns evidence rejected\n'; failed=1; }
    # 假绿：系统 DNS 把 github.com 指向可信 U，其余证据完好 —— 必须拒绝且层次为 mapping。
    EV_DNS=$'github.com\tA\t140.82.112.11\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t140.82.112.12\n'
    sa_evidence_write fallback "$dir"
    mapping_assert_result fallback "$dir" && { printf 'dns false green accepted\n'; failed=1; }
    layer=$MAPPING_ASSERT_REJECT_LAYER
    [[ $layer == mapping ]] || { printf 'dns false green rejected at layer %s\n' "${layer:-none}"; failed=1; }
    # AAAA 未 NXDOMAIN。
    EV_DNS=$'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\t140.82.112.11\ngm-proxy\tA\t140.82.112.12\n'
    sa_evidence_write fallback "$dir"
    mapping_assert_result fallback "$dir" && { printf 'aaaa not nxdomain accepted\n'; failed=1; }
    # gm-proxy 未指向 X。
    EV_DNS=$'github.com\tA\tNXDOMAIN\ngithub.com\tAAAA\tNXDOMAIN\ngm-proxy\tA\t10.0.0.1\n'
    sa_evidence_write fallback "$dir"
    mapping_assert_result fallback "$dir" && { printf 'wrong proxy resolution accepted\n'; failed=1; }
    rm -rf "$dir"
    return "$failed"
}

# 代理计数与 CONNECT 日志按 run 独立：上一轮残留合法行不得让本轮仅凭残留通过校验。
residual_connect_not_reused() {
    local failed=0 root saved base log1 log2 c1 residual
    root=$(mktemp -d)
    saved=${MAPPING_ASSET_ROOT:-}
    MAPPING_ASSET_ROOT=$root
    unset MAPPING_PROXY_RUN_ID
    base=$root/proxy/scenarios/mapping-fallback
    mkdir -p "$base"
    residual=$'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n'
    printf '%s' "$residual" > "$base/connect.log"
    printf '9\n' > "$base/accept.count"
    # 残留行本身是合法样本：证明它能通过判据（否则「不复用」无意义）。
    mapping_assert_connect_legal "$base/connect.log" 140.82.112.11 || { printf 'residual line is not legal\n'; failed=1; }
    MAPPING_PROXY_RUN_ID=run-A
    log1=$(mapping_proxy_log_path mapping-fallback) || failed=1
    c1=$(mapping_proxy_count_path mapping-fallback "$MAPPING_PROXY_ACCEPT_PORT") || failed=1
    MAPPING_PROXY_RUN_ID=run-B
    log2=$(mapping_proxy_log_path mapping-fallback) || failed=1
    MAPPING_PROXY_RUN_ID=run-A
    [[ $log1 != "$base/connect.log" && $log2 != "$log1" ]] || { printf 'run logs share the residual path\n'; failed=1; }
    [[ $c1 != "$base/accept.count" ]] || { printf 'run counters share the residual path\n'; failed=1; }
    # 场景开始时重建本轮日志：替身把写入落到替身目录。
    mapping_fixture_asset_write() {
        local rel=$1 content=$2
        mkdir -p "$root/$(dirname -- "$rel")" || return 1
        printf '%s' "$content" > "$root/$rel"
    }
    mapping_proxy_evidence_reset mapping-fallback product || { printf 'evidence reset failed\n'; failed=1; }
    [[ -f $log1 && ! -s $log1 ]] || { printf 'run log was not rebuilt empty\n'; failed=1; }
    if mapping_assert_connect_legal "$log1" 140.82.112.11; then printf 'residual alone satisfied the check\n'; failed=1; fi
    MAPPING_ASSET_ROOT=$saved
    unset MAPPING_PROXY_RUN_ID
    rm -rf "$root"
    return "$failed"
}

# 有状态资源替身：同名对象重复创建即失败（等同 docker 冲突），删除后消失。
# 身份与名称分离：容器/网络身份为与名称不同的 ID，卷身份为名称（与 docker create/volume create
# 的打印一致），从而真正守护「按登记身份而非名称删除」。
rs_new_id() { printf 'id-%s-%s\n' "$1" "$(printf '%s' "$2" | cksum | cut -d' ' -f1)"; }

# 按 kind 与名称查原始行；不存在时输出为空。
rs_row() {
    awk -v k="$1" -v n="$2" 'BEGIN{FS="\t"} $1==k && $2==n {print; exit}' "$RS_STORE"
}

# 按 kind 与（名称或身份）查询登记身份。
rs_lookup() {
    awk -v k="$1" -v key="$2" 'BEGIN{FS="\t"} $1==k && ($2==key || $3==key) {print $3; exit}' "$RS_STORE"
}

# 身份是否已登记（严格匹配身份列，名称不算）。
rs_has_id() {
    awk -v k="$1" -v id="$2" 'BEGIN{FS="\t"} $1==k && $3==id {found=1} END{exit found?0:1}' "$RS_STORE"
}

rs_add() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RS_STORE"; }

rs_delete() {
    awk -v k="$1" -v id="$2" 'BEGIN{FS="\t"} !($1==k && $3==id)' "$RS_STORE" > "$RS_STORE.tmp"
    mv -- "$RS_STORE.tmp" "$RS_STORE"
}

rs_count() { wc -l < "$RS_STORE" | tr -d ' '; }

rs_docker() {
    local -a a=("$@")
    local last=${a[${#a[@]}-1]} name='' kind id i
    case "${a[0]}" in
        network|volume)
            kind=${a[0]}
            case "${a[1]:-}" in
                create)
                    [[ -z $(rs_row "$kind" "$last") ]] || return 1
                    if [[ $kind == volume ]]; then id=$last; else id=$(rs_new_id "$kind" "$last"); fi
                    rs_add "$kind" "$last" "$id"
                    printf '%s\n' "$id"
                    ;;
                inspect) rs_lookup "$kind" "$last" ;;
                rm) rs_delete "$kind" "$last" ;;
                *) return 0 ;;
            esac
            ;;
        create)
            for ((i = 0; i < ${#a[@]}; i++)); do [[ ${a[i]} == --name ]] && name=${a[i + 1]}; done
            [[ -n $name ]] || name=$last
            [[ -z $(rs_row container "$name") ]] || return 1
            id=$(rs_new_id container "$name")
            rs_add container "$name" "$id"
            printf '%s\n' "$id"
            ;;
        rm) rs_delete container "$last" ;;
        inspect) rs_lookup container "$last" ;;
        *) return 0 ;;
    esac
}

# 安装有状态资源替身：resource_docker 与容器边界同名冲突即失败；
# resource_remove 只接受登记身份（容器/网络为 ID，卷为名称），传名称一律返回 2。
rs_install() {
    mapping_fixture_docker() { rs_docker "$@"; }
    resource_docker() { rs_docker "$@"; }
    resource_create_register() {
        local kind=$1 scenario=$2 role=$3
        shift 3
        [[ ${1:-} != -- ]] || shift
        local id rc=0
        id=$("$@") || rc=$?
        (( rc == 0 )) || return "$rc"
        [[ -n $id ]] || return 2
        RESOURCE_CREATED_ID=$id
        return 0
    }
    resource_remove() {
        local kind=$1 identity=$2
        rs_has_id "$kind" "$identity" || return 2
        rs_delete "$kind" "$identity"
    }
    return 0
}

# 同一 scenario 在同一进程内连续运行两次均成功：释放必须清掉映射网络与固定名容器，
# 第二次才能重建同名资源；残留即视为释放不完整。
scenario_repeated_run_succeeds() {
    local failed=0 dir1 dir2 rc1=0 rc2=0
    dir1=$(mktemp -d)
    dir2=$(mktemp -d)
    RS_STORE=$(mktemp)
    : > "$RS_STORE"
    rs_install
    sa_doubles 1
    sa_lifecycle_defaults fallback
    resource_cleanup_scenario() { : > "$RS_STORE"; }
    mapping_control_request() { return 0; }
    mapping_scenario_fixture_prepare() {
        local kind=$1 scenario=$2 dir=$3 ledger=$dir/control/resources
        mkdir -p "$dir/control" || return 80
        mapping_network_create "$MAPPING_PROFILE" "$ledger" >/dev/null || return 80
        RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
        resource_create_register container "$kind" upstream -- \
            resource_docker create --label "gitdaemon.run=$MP_RUN_ID" \
            --name "$(mapping_upstream_container)" "$MAPPING_PRODUCT_IMAGE" >/dev/null || return 80
        mapping_negative_prepare "$kind" "$scenario" "$dir" || return 80
        return 0
    }
    mapping_scenario_run fallback "$dir1" || rc1=$?
    printf 'REPEAT run1 rc=%s leftover=%s\n' "$rc1" "$(rs_count)"
    [[ $rc1 == 0 ]] || failed=1
    [[ $(rs_count) == 0 ]] || { printf 'run1 left resources behind\n'; failed=1; }
    mapping_scenario_run fallback "$dir2" || rc2=$?
    printf 'REPEAT run2 rc=%s leftover=%s\n' "$rc2" "$(rs_count)"
    [[ $rc2 == 0 ]] || failed=1
    [[ $(rs_count) == 0 ]] || { printf 'run2 left resources behind\n'; failed=1; }
    rm -rf "$dir1" "$dir2"
    rm -f "$RS_STORE"
    return "$failed"
}

# 顺序占位释放必须按登记身份（容器 ID）而非容器名：替身的身份与名称不同，
# 按名称删除必须被拒（等价真实拓扑返回 2），按登记身份删除必须成功且无残留。
probe_release_uses_registered_id() {
    local failed=0 ledger name id rc=0
    RS_STORE=$(mktemp)
    : > "$RS_STORE"
    ledger=$(mktemp -d)
    rs_install
    mapping_profile_load "$MAPPING_PROFILE" || { rm -rf "$ledger" "$RS_STORE"; return 1; }
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    name=$(mapping_probe_container)
    resource_create_register container "$MAPPING_LEDGER_SCENARIO" probe -- \
        resource_docker create --label "gitdaemon.run=$MP_RUN_ID" \
        --name "$name" "$MAPPING_PRODUCT_IMAGE" || { printf 'probe registration failed\n'; failed=1; }
    id=${RESOURCE_CREATED_ID:-}
    [[ -n $id && $id != "$name" ]] || { printf 'double identity %s equals name %s\n' "${id:-none}" "$name"; failed=1; }
    [[ $(rs_count) == 1 ]] || { printf 'probe was not registered\n'; failed=1; }
    resource_remove container "$name" && rc=0 || rc=$?
    printf 'PROBE_REMOVE_BY_NAME rc=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'removal by container name was accepted\n'; failed=1; }
    mapping_scenario_release_probe || { printf 'probe release rejected the registered id\n'; failed=1; }
    [[ $(rs_count) == 0 ]] || { printf 'release left the probe behind\n'; failed=1; }
    rm -rf "$ledger"
    rm -f "$RS_STORE"
    return "$failed"
}

# direct 传输必须显式清空 Git http.proxy（键存在且值为空），只单独指定代理 CA。
direct_clears_git_proxy() {
    local failed=0 cfg
    cfg=$(mapping_scenario_gitconfig_content) || { printf 'gitconfig content failed\n'; return 1; }
    printf '%s\n' "$cfg"
    grep -qE '^[[:space:]]*proxy[[:space:]]*=[[:space:]]*$' <<< "$cfg" || { printf 'gitconfig does not clear http.proxy\n'; failed=1; }
    grep -q 'proxySSLCAInfo = ' <<< "$cfg" || { printf 'gitconfig lost proxySSLCAInfo\n'; failed=1; }
    # http.proxy 必须在 [http] 段内，且不得被 proxySSLCAInfo 误匹配。
    awk 'BEGIN{s=0} /^\[http\]/{s=1;next} /^\[/{s=0} {if (s && $0 ~ /^[[:space:]]*proxy[[:space:]]*=/) found=1} END{exit found?0:1}' <<< "$cfg" \
        || { printf 'cleared http.proxy not inside [http]\n'; failed=1; }
    return "$failed"
}

# 产品就绪必须等可观测标记：仅 State.Running 不得判为就绪；容器退出即失败。
product_ready_requires_marker() {
    local failed=0
    MAPPING_PRODUCT_READY_TRIES=2
    mapping_fixture_docker() {
        case "$*" in
            logs*) printf '[git-daemon] 初始化命名卷内实例\n' ;;
            *"{{.State.Running}}"*) printf 'true\n' ;;
            *) return 0 ;;
        esac
    }
    if mapping_scenario_product_ready probe; then printf 'running-only container accepted as ready\n'; failed=1; fi
    mapping_fixture_docker() {
        case "$*" in
            logs*) printf '[git-daemon] 容器前台就绪\n' ;;
            *"{{.State.Running}}"*) printf 'true\n' ;;
            *) return 0 ;;
        esac
    }
    mapping_scenario_product_ready probe || { printf 'ready marker rejected\n'; failed=1; }
    mapping_fixture_docker() {
        case "$*" in
            logs*) printf '[git-daemon] 启动 git-daemon\n' ;;
            *"{{.State.Running}}"*) printf 'false\n' ;;
            *) return 0 ;;
        esac
    }
    if mapping_scenario_product_ready probe; then printf 'exited container accepted as ready\n'; failed=1; fi
    return "$failed"
}

# full 汇总槽位必须有真实断言支撑：两个正例 kind 与 DNS/TLS/隔离负例均被断言库接受，
# 未知 kind/负例名被拒绝，正例集合恰为两项（与 mapping_full_accept 的字段一一对应）。
full_summary_slots_supported() {
    local slot case_name failed=0
    for slot in mapping_fallback mapping_direct; do
        mapping_assert_kind_valid "${slot#mapping_}" || { printf 'missing positive kind %s\n' "$slot"; failed=1; }
    done
    for case_name in dns-false-green wrong_upstream_ca isolation; do
        mapping_assert_negative_valid "$case_name" || { printf 'missing negative case %s\n' "$case_name"; failed=1; }
    done
    mapping_assert_kind_valid probe && { printf 'probe wrongly accepted as positive kind\n'; failed=1; }
    mapping_assert_negative_valid bogus && { printf 'unknown negative accepted\n'; failed=1; }
    [[ $(printf '%s\n' $MAPPING_ASSERT_KINDS | wc -l) == 2 ]] || { printf 'positive kind set not exactly two\n'; failed=1; }
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
dns_evidence_required
residual_connect_not_reused
scenario_evidence_dir_local
negative_extra_network_real_injection
scenario_repeated_run_succeeds
probe_release_uses_registered_id
direct_clears_git_proxy
product_ready_requires_marker
negative_missing_map
negative_invalid_map
negative_dns_false_green
negative_unreachable_map_system
negative_tls_names
negative_isolation
fixture_failure_is_80
full_summary_slots_supported'

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
