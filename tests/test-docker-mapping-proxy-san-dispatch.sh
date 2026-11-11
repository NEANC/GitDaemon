#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"

[[ $(type -t mapping_proxy_san_case) == function ]]
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 将取证前置边界固定为成功，保留真实场景分派。
mapping_scenario_fixture_prepare() { return 0; }
mapping_scenario_calibrate() { return 0; }
mapping_scenario_product_up() { printf 'product\n'; }
mapping_scenario_upstream_count() { printf '1\n'; }
mapping_scenario_upstream_commit() { return 0; }
mapping_scenario_identity_write() { return 0; }
mapping_scenario_upstream_refs() { printf 'refs\n'; }
mapping_scenario_upstream_head() { printf 'head\n'; }

# 记录独立入口调用及参数，并返回本轮期望的故障码。
mapping_proxy_san_case() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WORK/dispatch"
    return "$SAN_RC"
}

# 通用注入若先执行即留下记录，以便测试拒绝错误分派。
mapping_scenario_apply_negative() {
    printf 'generic\n' >> "$WORK/dispatch"
    return 80
}

for SAN_RC in 1 80; do
    for kind in fallback direct; do
        scenario=$(mapping_assert_scenario "$kind")
        dir=$WORK/$kind-$SAN_RC
        mkdir -p "$dir"
        : > "$WORK/dispatch"
        MAPPING_ASSERT_CASE=wrong_proxy_san
        rc=0
        mapping_scenario_evidence "$kind" "$scenario" generation "$dir" || rc=$?
        [[ $rc == "$SAN_RC" ]] || { printf 'wrong_proxy_san exit: %s != %s\n' "$rc" "$SAN_RC" >&2; exit 1; }
        [[ $(cat "$WORK/dispatch") == "$(printf '%s\t%s\t%s' "$dir" "$kind" "$scenario")" ]] || {
            printf 'wrong_proxy_san did not exclusively dispatch before generic injection\n' >&2
            exit 1
        }
    done
done
printf 'proxy SAN standalone dispatch PASS\n'
