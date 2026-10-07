#!/usr/bin/env bash
# 网络编排行为契约与受控宿主探针入口。
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 契约通过替身记录外部边界，断言实际函数行为而不是搜索源码。
contracts() {
    local failed=0 name rc
    for name in guard_missing_blocks_start subnet_conflict_preserves_existing secondary_network_rejected cleanup_preserves_primary_status interrupt_removes_owned_rules; do
        rc=0
        ( contract_case "$name" ) || rc=$?
        printf '%s EXIT=%s\n' "$name" "$rc"
        if (( rc != 0 )); then failed=1; fi
    done
    return "$failed"
}
# 每个隔离子 shell 装载真实实现并替换不可在本机执行的 Docker/规则边界。
contract_case() {
    local name=$1 calls=0 result=0 removed='' IT_NETWORK=n IT_WITNESS_NETWORK=w
    [[ -f $HERE/docker-network-guard.sh && -f $HERE/docker-network-fixture.sh ]] || { printf 'FAIL: network implementation absent\n'; return 1; }
    source "$HERE/docker-network-guard.sh"
    source "$HERE/docker-network-fixture.sh"
    case "$name" in
        guard_missing_blocks_start)
            unset IT_NETWORK_GUARD_READY
            docker() { calls=$((calls + 1)); }
            network_fixture_start || result=$?
            [[ $result != 0 && $calls == 0 ]]
            ;;
        subnet_conflict_preserves_existing)
            guard_subnets_clear '172.30.240.0/20' && return 1
            guard_subnets_clear '172.30.243.1/32' && return 1
            guard_subnets_clear '172.30.245.0/24' || return 1
            [[ $calls == 0 ]]
            ;;
        secondary_network_rejected)
            policy_networks "$IT_NETWORK" || return 1
            policy_networks "$IT_NETWORK other" && return 1
            return 0
            ;;
        cleanup_preserves_primary_status)
            [[ $(guard_result 7 2) == 7 ]] || return 1
            [[ $(guard_result 0 2) == 2 ]]
            ;;
        interrupt_removes_owned_rules)
            OWN_RULES=('raw|-A PREROUTING -i gr-test -j R2-test')
            OWN_CHAINS=('raw|R2-test')
            iptables() { removed+="$*;"; }
            guard_remove_rules || return 1
            [[ $removed == *'-D PREROUTING -i gr-test -j R2-test'* && $removed == *'-X R2-test'* && $removed != *'-F'* ]]
            ;;
    esac
}
case "${1:-}" in
    --contracts) contracts ;;
    --live)
        trap 'exit 143' TERM
        trap 'exit 130' INT
        printf '%s\n' "$$" > "$IT_EVIDENCE_DIR/control/runner.pid"
        source "$HERE/docker-network-fixture.sh"
        network_probe
        ;;
    *) printf 'usage: %s --contracts|--live\n' "$0" >&2; exit 2 ;;
esac
