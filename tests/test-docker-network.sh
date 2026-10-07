#!/usr/bin/env bash
# 网络编排行为契约与受控宿主探针入口。
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 契约通过替身记录外部边界，断言实际函数行为而不是搜索源码。
contracts() {
    local failed=0 name rc
    for name in guard_missing_blocks_start subnet_conflict_preserves_existing secondary_network_rejected cleanup_preserves_primary_status interrupt_removes_owned_rules cleanup_failure_keeps_isolation preflight_query_failure_blocks_start; do
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
        cleanup_failure_keeps_isolation)
            local E RUN=contract RUNNER=gmtest primary actual fault fault_kind phase expected
            for fault_kind in container network volume; do
                for phase in enumerate delete residual-query residual; do
                    fault=$fault_kind-$phase
                    for primary in 0 7; do
                        E=$(mktemp -d)
                        actual=0
                        (
                            OWN_RULES=('raw|-I PREROUTING -i gcontract -j Econtract')
                            OWN_CHAINS=('raw|Econtract')
                            # 文件计数跨命令替换保留，区分初次枚举与最终核验。
                            docker() {
                                local target=$1 n=0
                                [[ $target != ps ]] || target=container
                                if [[ $1 == ps || ${2:-} == ls ]]; then
                                    [[ ! -f $E/$target.count ]] || read -r n < "$E/$target.count"
                                    n=$((n + 1)); printf '%s\n' "$n" > "$E/$target.count"
                                    if [[ $target == "$fault_kind" ]]; then
                                        [[ $phase != enumerate || $n != 1 ]] || return 9
                                        [[ $phase != residual-query || $n != 2 ]] || return 9
                                        if [[ $phase == delete && $n == 1 || $phase == residual && $n == 2 ]]; then printf '%s-owned\n' "$target"; fi
                                    fi
                                fi
                                return 0
                            }
                            # 删除负例即便后续枚举为空，也必须保持本次隔离。
                            guard_gm() { return 9; }
                            iptables-save() { return 0; }
                            # 若误撤规则则留下标记，同时保留真正的恢复函数正文。
                            iptables() { printf 'removed\n' > "$E/removed"; }
                            trap guard_cleanup EXIT
                            exit "$primary"
                        ) || actual=$?
                        expected=$(guard_result "$primary" 2)
                        [[ ! -e $E/removed && $actual == "$expected" ]] || return 1
                        grep -qx "PRIMARY_EXIT=$primary" "$E/exit-status.txt" || return 1
                        grep -qx 'CLEANUP_EXIT=2' "$E/exit-status.txt" || return 1
                        [[ -s $E/recover.sh ]] || { printf 'missing precise recovery: %s primary=%s\n' "$fault" "$primary"; return 1; }
                        bash -n "$E/recover.sh" || return 1
                        grep -Fq 'gcontract' "$E/recover.sh" || return 1
                        grep -Fq 'Econtract' "$E/recover.sh" || return 1
                        # 人工恢复未确认 runner 停止时不得操作；查询失败不得撤规则。
                        actual=0
                        bash "$E/recover.sh" >/dev/null 2>&1 || actual=$?
                        [[ $actual == 64 ]] || return 1
                        (
                            # 恢复脚本的外部边界保证失败在资源查询，而非权限检查。
                            id() { printf '0\n'; }
                            docker() { return 9; }
                            iptables() { printf 'removed\n' > "$E/removed"; }
                            export E
                            export -f id docker iptables
                            actual=0
                            bash "$E/recover.sh" --runner-stopped || actual=$?
                            [[ $actual == 9 && ! -e $E/removed ]]
                        ) || return 1
                        printf 'cleanup fault=%s primary=%s cleanup=2 exit=%s PASS\n' "$fault" "$primary" "$expected"
                        rm -rf "$E"
                    done
                done
            done
            ;;
        preflight_query_failure_blocks_start)
            local fault actual scratch
            scratch=$(mktemp -d)
            for fault in network-list inspect route containers networks volumes links rules; do
                actual=0
                (
                    # 模拟已授权宿主，查询故障必须在任何资源操作之前返回。
                    id() { if [[ $# == 1 ]]; then printf '0\n'; else printf '10001\n'; fi; }
                    ip() {
                        case "$*" in
                            '-4 addr show') printf 'inet 192.168.10.9/24\n' ;;
                            '-4 route show') [[ $fault != route ]] || return 9 ;;
                            'link show') [[ $fault != links ]] || return 9 ;;
                            *) return 1 ;;
                        esac
                    }
                    docker() {
                        case "$*" in
                            'network ls -q') [[ $fault != network-list ]] || return 9; printf 'existing\n' ;;
                            'network inspect '*) [[ $fault != inspect ]] || return 9 ;;
                            'ps -a '*) [[ $fault != containers ]] || return 9 ;;
                            'network ls --format '*) [[ $fault != networks ]] || return 9 ;;
                            'volume ls --format '*) [[ $fault != volumes ]] || return 9 ;;
                            *) printf 'business\n' >> "$scratch/business" ;;
                        esac
                        return 0
                    }
                    iptables-save() { [[ $fault != rules ]] || return 9; }
                    # 到达资源准备也算错误；防止红灯测试真实写宿主目录。
                    mkdir() { printf 'business\n' >> "$scratch/business"; exit 91; }
                    guard_main --run-id querytest --evidence-dir /nonexistent-r2-query-contract --source-dir /source --runner-user gmtest --mode probe --product-image product --tools-image tools
                ) || actual=$?
                [[ $actual == 9 && ! -e $scratch/business ]] || { printf 'preflight fault=%s exit=%s FAILED\n' "$fault" "$actual"; return 1; }
                printf 'preflight fault=%s business=0 exit=9 PASS\n' "$fault"
            done
            rm -rf "$scratch"
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
