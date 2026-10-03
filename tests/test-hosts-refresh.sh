#!/usr/bin/env bash
# 地址快照刷新行为测试：以桩下载与本地临时目录构造确定性场景，不访问公网。
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-hosts-refresh.XXXXXXXX") || exit 1
CHECKS=0
FAILURES=0

# 仅清理本测试通过 mktemp 创建的目录。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

if [[ -f $ROOT/scripts/update-github-hosts.sh ]]; then
    source "$ROOT/scripts/update-github-hosts.sh"
fi

# 每个用例在独立子 Shell 中运行，避免全局状态互相污染。
check() {
    local label=$1
    shift
    if [[ -n ${TEST_FILTER-} && $label != *"$TEST_FILTER"* ]]; then return 0; fi
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 缺少约定接口时返回明确断言失败，而不是调用不存在的命令。
require_function() {
    if ! declare -F "$1" >/dev/null; then
        printf '缺少共享接口：%s\n' "$1"
        return 1
    fi
}

# 合法公网 IPv4 记录必须被接受并规范化为 "IP 域名"。
filter_accepts_public_ipv4() {
    require_function gm_hosts_filter_records || return 1
    local out
    out=$(printf '140.82.121.3 github.com\n' | gm_hosts_filter_records) || return 1
    [[ $out == '140.82.121.3 github.com' ]]
}

# 多地址与重复记录必须去重排序，同一域名保留多个已校验地址。
filter_multi_address_dedupes() {
    require_function gm_hosts_filter_records || return 1
    local out expected
    out=$(printf '%s\n' '140.82.121.4 github.com' '140.82.121.3 github.com' '140.82.121.3 github.com' | gm_hosts_filter_records) || return 1
    expected=$(printf '%s\n' '140.82.121.3 github.com' '140.82.121.4 github.com')
    [[ $out == "$expected" ]]
}

# 行首空白、制表符与行内注释必须被容忍。
filter_tolerates_whitespace() {
    require_function gm_hosts_filter_records || return 1
    local out
    out=$(printf '   140.82.121.3\tgithub.com   # 注释\n' | gm_hosts_filter_records) || return 1
    [[ $out == '140.82.121.3 github.com' ]]
}

# 环回、私网、链路本地、元数据、保留与组播地址必须被拒绝。
filter_rejects_reserved_ipv4() {
    require_function gm_hosts_filter_records || return 1
    local ip
    for ip in 0.0.0.0 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 169.254.169.254 \
        172.16.0.1 172.31.255.1 192.0.0.1 192.168.1.1 198.18.0.1 198.51.100.1 \
        203.0.113.1 224.0.0.1 255.255.255.255; do
        if printf '%s github.com\n' "$ip" | gm_hosts_filter_records >/dev/null 2>&1; then
            printf '保留地址未被拒绝：%s\n' "$ip"
            return 1
        fi
    done
    return 0
}

# 环回、未指定、唯一本地、链路本地、组播与 IPv4 映射/兼容保留地址的压缩与展开写法都必须被拒绝，
# 合法公网 IPv6（含 2001:db8 格式示例）的压缩与展开写法都必须被接受且不被改写。
filter_ipv6_public_and_reserved() {
    require_function gm_hosts_filter_records || return 1
    local ip out
    for ip in :: ::1 fc00::1 fd12:3456::1 fe80::1 feb0::1 ff02::1 \
        0:0:0:0:0:0:0:0 0:0:0:0:0:0:0:1 0000:0000:0000:0000:0000:0000:0000:0001 \
        fc00:0000:0000:0000:0000:0000:0000:0001 fd00:ec2::254 \
        fe80:0000:0000:0000:0000:0000:0000:0001 ff02:0000:0000:0000:0000:0000:0000:0001 \
        ::ffff:7f00:1 0:0:0:0:0:ffff:7f00:0001 ::ffff:c0a8:101 ::7f00:1; do
        if printf '%s github.com\n' "$ip" | gm_hosts_filter_records >/dev/null 2>&1; then
            printf '保留 IPv6 未被拒绝：%s\n' "$ip"
            return 1
        fi
    done
    for ip in 2606:50c0:8000::153 2001:db8::1 2606:50c0:8000:0000:0000:0000:0000:0153; do
        out=$(printf '%s github.com\n' "$ip" | gm_hosts_filter_records) || { printf '公网 IPv6 被拒绝：%s\n' "$ip"; return 1; }
        [[ $out == "$ip github.com" ]] || { printf '公网 IPv6 被改写：%s\n' "$ip"; return 1; }
    done
    return 0
}

# 通配符、非白名单域名与格式错误记录必须被拒绝或过滤。
filter_rejects_wildcard_and_foreign_domain() {
    require_function gm_hosts_filter_records || return 1
    if printf '%s\n' '* github.com' '140.82.121.3 *.github.com' '140.82.121.3 example.com' '140.82.121.3 api.github.com' | gm_hosts_filter_records >/dev/null 2>&1; then
        printf '非法域名或通配符未被拒绝\n'
        return 1
    fi
    return 0
}

# 空响应、缺少必需域名与格式错误行都不能产生有效记录。
filter_rejects_empty_and_missing_required() {
    require_function gm_hosts_filter_records || return 1
    if printf '' | gm_hosts_filter_records >/dev/null 2>&1; then return 1; fi
    if printf '%s\n' '140.82.121.3 example.com' | gm_hosts_filter_records >/dev/null 2>&1; then return 1; fi
    if printf '%s\n' 'not-an-ip github.com' 'github.com' '140.82.121.3' | gm_hosts_filter_records >/dev/null 2>&1; then return 1; fi
    return 0
}

# 渲染快照必须写入来源、获取时间、记录数与摘要头，摘要覆盖纯数据字节。
render_writes_metadata_and_digest() {
    require_function gm_hosts_render_snapshot || return 1
    local out expected_digest
    out=$(gm_hosts_render_snapshot 'https://src.invalid/hosts' '2026-01-02T03:04:05+0800' <<< '1.2.3.4 github.com') || return 1
    expected_digest=$(printf '1.2.3.4 github.com\n' | sha256sum)
    expected_digest=${expected_digest%% *}
    [[ $out == *'# FORMAT=1'* ]] || { printf '缺少格式头\n'; return 1; }
    [[ $out == *'# SOURCE=https://src.invalid/hosts'* ]] || { printf '缺少来源\n'; return 1; }
    [[ $out == *'# FETCHED=2026-01-02T03:04:05+0800'* ]] || { printf '缺少获取时间\n'; return 1; }
    [[ $out == *"# DIGEST=sha256:$expected_digest"* ]] || { printf '摘要不一致\n'; return 1; }
    [[ $out == *'# COUNT=1'* ]] || { printf '缺少记录数\n'; return 1; }
    [[ $(printf '%s\n' "$out" | grep -vc '^#') == 1 ]] || { printf '数据行数不正确\n'; return 1; }
    [[ $out == *'1.2.3.4 github.com' ]]
}

# 下载期间已发布快照保持旧内容，校验通过后原子替换且临时文件被消费。
apply_source_publishes_atomically() {
    require_function hosts_apply_source || return 1
    local snapshot=$TEST_ROOT/apply.snapshot tmp=$TEST_ROOT/apply.tmp before
    printf '# FORMAT=1\n# SOURCE=old\n# FETCHED=old\n# DIGEST=sha256:00\n# COUNT=1\n9.9.9.9 github.com\n' > "$snapshot"
    before=$(<"$snapshot")
    gm_hosts_download() {
        # 模拟下载阶段：已发布快照必须仍为旧内容，读者不会看到半写入数据。
        [[ $(<"$snapshot") == "$before" ]] || return 1
        printf '140.82.121.3 github.com\n' > "$2"
        return 0
    }
    hosts_apply_source 'https://src.invalid/hosts' '2026-01-02T03:04:05+0800' "$snapshot" "$tmp" || return 1
    [[ ! -e $tmp ]] || { printf '临时文件未清理\n'; return 1; }
    grep -q '^# SOURCE=https://src.invalid/hosts$' "$snapshot" || { printf '快照来源未更新\n'; return 1; }
    grep -qx '140.82.121.3 github.com' "$snapshot"
}

# 非法数据必须拒绝发布并保留最近一次有效快照。
apply_source_rejects_invalid_keeps_old() {
    require_function hosts_apply_source || return 1
    local snapshot=$TEST_ROOT/apply-invalid.snapshot tmp=$TEST_ROOT/apply-invalid.tmp keep
    printf '# FORMAT=1\n# SOURCE=old\n# FETCHED=old\n# DIGEST=sha256:00\n# COUNT=1\n140.82.121.3 github.com\n' > "$snapshot"
    keep=$(<"$snapshot")
    gm_hosts_download() { printf '10.0.0.1 github.com\n127.0.0.1 github.com\n' > "$2"; return 0; }
    if hosts_apply_source 'https://src.invalid/hosts' '2026-01-02T03:04:05+0800' "$snapshot" "$tmp"; then
        printf '非法数据被发布\n'
        return 1
    fi
    [[ $(<"$snapshot") == "$keep" ]] || { printf '旧快照被覆盖\n'; return 1; }
    [[ ! -e $tmp ]]
}

# 主源失败时使用备用源发布快照并清除陈旧标记。
refresh_uses_fallback_source() {
    require_function hosts_refresh_sources || return 1
    local snapshot=$TEST_ROOT/fallback.snapshot tmp=$TEST_ROOT/fallback.tmp stale=$TEST_ROOT/fallback.stale
    rm -f -- "$snapshot" "$tmp" "$stale"
    HOSTS_LOG_FILE=$TEST_ROOT/fallback.log
    : > "$HOSTS_LOG_FILE"
    gm_hosts_download() {
        case "$1" in
            https://primary.invalid/hosts) return 1 ;;
            https://fallback.invalid/hosts) printf '140.82.121.3 github.com\n' > "$2"; return 0 ;;
            *) return 1 ;;
        esac
    }
    hosts_refresh_sources 'https://primary.invalid/hosts' 'https://fallback.invalid/hosts' \
        "$snapshot" "$tmp" "$stale" '2026-01-02T03:04:05+0800' || return 1
    grep -q '^# SOURCE=https://fallback.invalid/hosts$' "$snapshot" || { printf '备用源未生效\n'; return 1; }
    [[ ! -e $stale ]] || { printf '陈旧标记未清除\n'; return 1; }
    grep -q '数据源失败：https://primary.invalid/hosts' "$HOSTS_LOG_FILE"
}

# 所有来源失败时保留旧快照并写入陈旧标记。
refresh_all_fail_marks_stale() {
    require_function hosts_refresh_sources || return 1
    local snapshot=$TEST_ROOT/stale.snapshot tmp=$TEST_ROOT/stale.tmp stale=$TEST_ROOT/stale.marker keep
    printf '# FORMAT=1\n# SOURCE=old\n# FETCHED=old\n# DIGEST=sha256:00\n# COUNT=1\n140.82.121.3 github.com\n' > "$snapshot"
    keep=$(<"$snapshot")
    rm -f -- "$tmp" "$stale"
    HOSTS_LOG_FILE=$TEST_ROOT/stale.log
    : > "$HOSTS_LOG_FILE"
    gm_hosts_download() { return 1; }
    if hosts_refresh_sources 'https://primary.invalid/hosts' 'https://fallback.invalid/hosts' \
        "$snapshot" "$tmp" "$stale" '2026-01-02T03:04:05+0800'; then
        printf '全部来源失败却报告成功\n'
        return 1
    fi
    [[ $(<"$snapshot") == "$keep" ]] || { printf '旧快照被改写\n'; return 1; }
    [[ -e $stale ]] || { printf '缺少陈旧标记\n'; return 1; }
    grep -q '标记陈旧' "$HOSTS_LOG_FILE"
}

# 无旧快照且全部来源失败时不写陈旧标记，交由系统 DNS 兜底。
refresh_no_snapshot_uses_dns() {
    require_function hosts_refresh_sources || return 1
    local snapshot=$TEST_ROOT/dns.snapshot tmp=$TEST_ROOT/dns.tmp stale=$TEST_ROOT/dns.stale
    rm -f -- "$snapshot" "$tmp" "$stale"
    HOSTS_LOG_FILE=$TEST_ROOT/dns.log
    : > "$HOSTS_LOG_FILE"
    gm_hosts_download() { return 1; }
    if hosts_refresh_sources 'https://primary.invalid/hosts' '' \
        "$snapshot" "$tmp" "$stale" '2026-01-02T03:04:05+0800'; then
        printf '无快照且失败却报告成功\n'
        return 1
    fi
    [[ ! -e $snapshot && ! -e $stale ]] || return 1
    grep -q '系统 DNS' "$HOSTS_LOG_FILE"
}

# 下载必须限制协议、体积、超时与重定向，且不得关闭 TLS 校验。
download_records_security_limits() {
    require_function gm_hosts_download || return 1
    local rec=$TEST_ROOT/curl-argv out=$TEST_ROOT/dl.out
    : > "$rec"
    curl() {
        printf '%s\n' "$@" > "$rec"
        local path= prev=
        for a in "$@"; do
            if [ "$prev" = --output ]; then path=$a; fi
            prev=$a
        done
        printf '140.82.121.3 github.com\n' > "$path"
        return 0
    }
    gm_hosts_download 'https://src.invalid/hosts' "$out" || return 1
    grep -qx -- '--proto' "$rec" || { printf '缺少协议限制\n'; return 1; }
    grep -qx -- '=https' "$rec" || { printf '协议白名单不正确\n'; return 1; }
    grep -qx -- '--proto-redir' "$rec" || return 1
    grep -qx -- '--max-filesize' "$rec" || { printf '缺少体积限制\n'; return 1; }
    grep -qx -- '--max-redirs' "$rec" || { printf '缺少重定向限制\n'; return 1; }
    grep -qx -- '--connect-timeout' "$rec" || return 1
    grep -qx -- '--max-time' "$rec" || return 1
    if grep -qx -- '--insecure' "$rec" || grep -qx -- '-k' "$rec"; then
        printf '出现关闭 TLS 校验的参数\n'
        return 1
    fi
    [[ $(<"$out") == '140.82.121.3 github.com' ]]
}

# 空响应与超大响应必须被拒绝。
download_rejects_empty_and_oversize() {
    require_function gm_hosts_download || return 1
    local out=$TEST_ROOT/limit.out
    curl() {
        local path= prev=
        for a in "$@"; do
            if [ "$prev" = --output ]; then path=$a; fi
            prev=$a
        done
        : > "$path"
        return 0
    }
    if gm_hosts_download 'https://src.invalid/hosts' "$out"; then
        printf '空响应未被拒绝\n'
        return 1
    fi
    curl() {
        local path= prev=
        for a in "$@"; do
            if [ "$prev" = --output ]; then path=$a; fi
            prev=$a
        done
        head -c 2000000 /dev/zero > "$path"
        return 0
    }
    if gm_hosts_download 'https://src.invalid/hosts' "$out"; then
        printf '超大响应未被拒绝\n'
        return 1
    fi
    return 0
}

# 传输失败（如 TLS 校验失败）必须使下载失败，不得静默回退。
download_propagates_transport_failure() {
    require_function gm_hosts_download || return 1
    curl() { return 60; }
    if gm_hosts_download 'https://src.invalid/hosts' "$TEST_ROOT/tls.out"; then
        printf 'TLS 校验失败未被拒绝\n'
        return 1
    fi
    return 0
}

# 禁用开关时刷新入口不触发任何下载。
main_disabled_skips_refresh() {
    require_function gm_hosts_main || return 1
    local RUN_ROOT=$TEST_ROOT/disabled-run marker=$TEST_ROOT/disabled-refresh-called
    mkdir -p "$RUN_ROOT/hosts" "$RUN_ROOT/logs" || return 1
    rm -f -- "$marker"
    declare -A GM_CONFIG=([ENABLE_HOSTS_UPDATE]=no)
    gm_prepare_runtime() { return 0; }
    gm_begin_operation() { return 0; }
    hosts_refresh_sources() { : > "$marker"; return 0; }
    gm_hosts_main >/dev/null 2>&1 || return 1
    [[ ! -e $marker ]]
}

# 启用开关时刷新入口按配置调用刷新流程。
main_enabled_runs_refresh() {
    require_function gm_hosts_main || return 1
    local RUN_ROOT=$TEST_ROOT/enabled-run marker=$TEST_ROOT/enabled-refresh-called
    mkdir -p "$RUN_ROOT/hosts" "$RUN_ROOT/logs" || return 1
    rm -f -- "$marker"
    declare -A GM_CONFIG=([ENABLE_HOSTS_UPDATE]=yes [HOSTS_URL]=https://a.invalid/h [HOSTS_URL_FALLBACK]=https://b.invalid/h)
    gm_prepare_runtime() { return 0; }
    gm_begin_operation() { return 0; }
    hosts_refresh_sources() { : > "$marker"; return 0; }
    gm_hosts_main >/dev/null 2>&1 || return 1
    [[ -e $marker ]]
}

check '合法公网 IPv4 记录被接受' filter_accepts_public_ipv4
check '多地址去重并按序输出' filter_multi_address_dedupes
check '容忍行首空白与行内注释' filter_tolerates_whitespace
check '拒绝环回私网链路本地元数据等 IPv4' filter_rejects_reserved_ipv4
check '拒绝保留 IPv6 并接受公网 IPv6' filter_ipv6_public_and_reserved
check '拒绝通配符与非白名单域名' filter_rejects_wildcard_and_foreign_domain
check '拒绝空响应缺域名与格式错误' filter_rejects_empty_and_missing_required
check '快照渲染含来源时间记录数与摘要' render_writes_metadata_and_digest
check '下载期间旧快照不变且原子替换' apply_source_publishes_atomically
check '非法数据拒绝发布会保留旧快照' apply_source_rejects_invalid_keeps_old
check '主源失败改用备用源并清陈旧标记' refresh_uses_fallback_source
check '全部来源失败保留旧快照并标记陈旧' refresh_all_fail_marks_stale
check '无旧快照失败时交由系统 DNS' refresh_no_snapshot_uses_dns
check '下载限制协议体积超时与重定向' download_records_security_limits
check '拒绝空响应与超大响应' download_rejects_empty_and_oversize
check '传输失败拒绝下载' download_propagates_transport_failure
check '禁用开关不触发刷新' main_disabled_skips_refresh
check '启用开关按配置触发刷新' main_enabled_runs_refresh

printf '地址快照刷新行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
