#!/usr/bin/env bash
# 网络编排行为契约与受控宿主探针入口。
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 运行真实 guard 入口；仅替换授权宿主、Docker、su 与规则等外部边界。
contract_guard_driver() {
    source "$HERE/docker-network-guard.sh"
    id() { if [[ $# == 1 ]]; then printf '0\n'; else printf '10001\n'; fi; }
    ip() { [[ $* != '-4 addr show' ]] || printf 'inet 192.168.10.9/24\n'; return 0; }
    chown() { return 0; }
    docker() {
        case "$*" in
            'network create '*) printf 'business\n' >> "$SCRATCH/business"; return 7 ;;
            'network ls -q') [[ $WINDOW != conflict ]] || printf 'existing\n'; return 0 ;;
            'network inspect '*) [[ $WINDOW != conflict ]] || printf '172.30.240.0/20\n'; return 0 ;;
            'ps -aq '*) [[ $WINDOW != cleanup7 ]] || printf 'owned\n'; return 0 ;;
            'rm -f '*) [[ $WINDOW != cleanup7 ]] || return 9 ;;
            'ps -a '*|'network ls --format '*|'volume ls --format '*|'network ls -q '*|'volume ls -q '*) return 0 ;;
            'image inspect '*) printf '{}\n' ;;
            *) return 0 ;;
        esac
    }
    iptables-save() { return 0; }
    iptables() { printf '%s\n' "$*" >> "$SCRATCH/rules"; }
    su() { sleep 0.1; bash -c "${@: -1}"; }
    setsid() { "$@"; }
    export -f docker su
    local driver_pid=$BASHPID injected=0
    set -T
    # DEBUG 在实际命令执行前同步送 TERM，精确命中调用成功后及后台 PID 登记前。
    trap 'if [[ $BASHPID == "${driver_pid:-}" && ${injected:-1} == 0 ]]; then case "$WINDOW:$BASH_COMMAND" in rule:OWN_RULES+=*|chain:OWN_CHAINS+=*|spawn:CHILD=*) injected=1; kill -TERM "$BASHPID" ;; esac; fi' DEBUG
    guard_main --run-id timing --evidence-dir "$SCRATCH/evidence" --source-dir "$(cd "$HERE/.." && pwd)" --runner-user gmtest --mode probe --product-image product --tools-image tools
}
# 契约通过替身记录外部边界，断言实际函数行为而不是搜索源码。
contracts() {
    local failed=0 name rc
    for name in guard_missing_blocks_start subnet_conflict_preserves_existing secondary_network_rejected cleanup_preserves_primary_status interrupt_removes_owned_rules cleanup_failure_keeps_isolation preflight_query_failure_blocks_start conditional_library_failure_stops counter_evidence_rejects_invalid reusable_generation_dns_contract independent_status_capture; do
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
            local WINDOW=conflict SCRATCH actual=0
            SCRATCH=$(mktemp -d)
            export HERE WINDOW SCRATCH
            export -f contract_guard_driver
            bash -c contract_guard_driver > "$SCRATCH/output" 2>&1 || actual=$?
            [[ $actual == 70 && ! -e $SCRATCH/business && ! -e $SCRATCH/rules && ! -e $SCRATCH/evidence ]] || return 1
            rm -rf "$SCRATCH"
            ;;
        secondary_network_rejected)
            docker() { printf 'n other '; }
            assert_container_network_policy product && return 1
            return 0
            ;;
        cleanup_preserves_primary_status)
            local WINDOW=cleanup7 SCRATCH actual=0
            SCRATCH=$(mktemp -d)
            export HERE WINDOW SCRATCH
            export -f contract_guard_driver
            bash -c contract_guard_driver > "$SCRATCH/output" 2>&1 || actual=$?
            [[ $actual == 7 ]] || return 1
            grep -qx 'RUNNER_EXIT=7' "$SCRATCH/evidence/control/runner-status.txt" || return 1
            grep -qx 'PRIMARY_EXIT=7' "$SCRATCH/evidence/exit-status.txt" || return 1
            grep -qx 'CLEANUP_EXIT=2' "$SCRATCH/evidence/exit-status.txt" || return 1
            grep -q -- '-D\|-X' "$SCRATCH/rules" && return 1
            [[ -s $SCRATCH/evidence/recover.sh ]] || return 1
            rm -rf "$SCRATCH"
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
        independent_status_capture)
            local WINDOW=exit7 SCRATCH actual
            SCRATCH=$(mktemp -d)
            export HERE WINDOW SCRATCH
            export -f contract_guard_driver
            actual=0; bash -c contract_guard_driver > "$SCRATCH/output" 2>&1 || actual=$?
            [[ $actual == 7 ]] || { printf 'runner fixture exit=%s evidence=%s\n' "$actual" "$SCRATCH"; return 1; }
            grep -qx 'RUNNER_EXIT=7' "$SCRATCH/evidence/control/runner-status.txt" || return 1
            grep -qx 'BUSINESS_SU_EXIT=7' "$SCRATCH/evidence/business-su-status.txt" || return 1
            grep -qx 'SETSID_WAIT_EXIT=7' "$SCRATCH/evidence/exit-status.txt" || return 1
            grep -qx 'PRIMARY_EXIT=7' "$SCRATCH/evidence/exit-status.txt" || return 1
            grep -qx 'CLEANUP_EXIT=0' "$SCRATCH/evidence/exit-status.txt" || return 1
            local IT_EVIDENCE_DIR=$SCRATCH/evidence pipe_rc=0
            timeout() { printf 'r2-published\n'; return 7; }
            network_published_check || pipe_rc=$?
            [[ $pipe_rc == 7 ]] || return 1
            grep -qx 'PUBLISHED_PIPESTATUS=0 7' "$IT_EVIDENCE_DIR/control/pipeline-status.txt" || return 1
            rm -rf "$SCRATCH"
            ;;
        reusable_generation_dns_contract)
            local IT_RUN_ID=reuse IT_TOOLS_IMAGE=tools actual product_address=172.30.243.5 DNS_CALIBRATED=1 DNS_BASELINE=$'0\n0\n0' DNS_GENERATION='' negative_calls='' generation
            assert_container_network_policy() { return 0; }
            docker() {
                case "$*" in
                    *'.IPAddress'*) printf '%s' "$product_address" ;;
                    *'.HostConfig.NetworkMode'*) printf 'container:product 10001:10001' ;;
                    *'.Id'*) printf 'tool' ;;
                    *'id -ru'*) printf '10001 10001' ;;
                esac
                return 0
            }
            network_negative() { negative_calls+="$1 "; }
            network_run() { return 0; }
            network_control() { CONTROL_SEQ=$((CONTROL_SEQ + 1)); }
            network_witness() { printf '0\n0\n0\n'; }
            actual=0; assert_product_egress product wrong || actual=$?
            [[ $actual != 0 && -z $negative_calls ]] || { printf 'wrong product address accepted\n'; return 1; }
            product_address=172.30.243.4
            for generation in one two; do
                negative_calls=''
                assert_product_egress product "$generation" || return 1
                [[ $negative_calls == 'cross-network host-published host-input dns-udp dns-tcp ' ]] || return 1
                assert_dns_witness "$generation" || return 1
            done
            actual=0; assert_dns_witness stale || actual=$?
            [[ $actual != 0 ]] || return 1
            ;;
        counter_evidence_rejects_invalid)
            local IT_EVIDENCE_DIR IT_RUN_ID=counttest fault file actual spec label dest proto port count
            IT_EVIDENCE_DIR=$(mktemp -d)
            for fault in missing empty duplicate protocol integer negative; do
                file=$IT_EVIDENCE_DIR/snapshot-1.witness
                rm -f "$file"
                if [[ $fault != missing ]]; then
                    : > "$file"
                    if [[ $fault != empty ]]; then
                        for spec in 'tcp 19419' 'udp 53' 'tcp 53'; do
                            read -r proto port <<< "$spec"; count=0
                            [[ $fault != protocol ]] || proto=icmp
                            [[ $fault != integer ]] || count=1.5
                            [[ $fault != negative ]] || count=-1
                            printf '%s 0 RETURN %s -- * * 0.0.0.0/0 0.0.0.0/0 %s dpt:%s\n' "$count" "$proto" "$proto" "$port" >> "$file"
                        done
                        [[ $fault != duplicate ]] || printf '0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n' >> "$file"
                    fi
                fi
                actual=0; network_witness 1 >/dev/null 2>&1 || actual=$?
                [[ $actual != 0 ]] || { printf 'witness accepted %s\n' "$fault"; return 1; }
            done
            for fault in missing empty duplicate protocol integer negative; do
                file=$IT_EVIDENCE_DIR/snapshot-1.rules
                rm -f "$file"
                if [[ $fault != missing ]]; then
                    : > "$file"
                    if [[ $fault != empty ]]; then
                        for spec in 'cross-network 172.30.244.53 tcp 19419' 'host-published 172.30.243.1 tcp 49382' 'host-input 172.30.243.1 tcp 49383' 'dns-udp 172.30.244.53 udp 53' 'dns-tcp 172.30.244.53 tcp 53'; do
                            read -r label dest proto port <<< "$spec"; count=0
                            [[ $fault != protocol ]] || proto=icmp
                            [[ $fault != integer ]] || count=1.5
                            [[ $fault != negative ]] || count=-1
                            printf '[%s:0] -A Ecounttest -s 172.30.243.4/32 -d %s/32 -p %s -m %s --dport %s -m comment --comment counttest-%s -j DROP\n' "$count" "$dest" "$proto" "$proto" "$port" "$label" >> "$file"
                        done
                        [[ $fault != duplicate ]] || printf '[0:0] -A Ecounttest -s 172.30.243.4/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 19419 -m comment --comment counttest-cross-network -j DROP\n' >> "$file"
                    fi
                fi
                actual=0; network_count 1 cross-network >/dev/null 2>&1 || actual=$?
                [[ $actual != 0 ]] || { printf 'drop accepted %s\n' "$fault"; return 1; }
            done
            network_witness_delta $'0\n0\n0' $'0\n1\n0' udp || return 1
            network_witness_delta $'0\n0\n0' $'0\n0\n1' tcp || return 1
            network_witness_delta $'0\n0\n0' $'0\n0\n1' udp && return 1
            network_witness_delta $'0\n0\n0' $'0\n1\n1' udp && return 1
            rm -rf "$IT_EVIDENCE_DIR"
            ;;
        conditional_library_failure_stops)
            local fault actual scratch IT_RUN_ID=conditional IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE=tools IT_NETWORK_GUARD_READY=1
            scratch=$(mktemp -d)
            for fault in 1 2 3 4 5 6 7 8 9; do
                (
                    # 文件记录跨命令替换调用；每一个前置步骤失败后不得继续。
                    docker() {
                        local n=0
                        [[ ! -f $scratch/count ]] || read -r n < "$scratch/count"
                        n=$((n + 1)); printf '%s\n' "$n" > "$scratch/count"
                        [[ $n != "$fault" ]] || return 9
                        printf 'status: NXDOMAIN\n'
                    }
                    id() { printf '10001\n'; }
                    network_control() { docker control; }
                    actual=0; network_fixture_start || actual=$?
                    read -r calls < "$scratch/count"
                    [[ $actual == 9 && $calls == "$fault" ]]
                ) || { printf 'conditional start fault=%s FAILED\n' "$fault"; return 1; }
                rm "$scratch/count"
            done
            (
                assert_container_network_policy() { return 9; }
                network_negative() { calls=$((calls + 1)); }
                actual=0; assert_product_egress product generation || actual=$?
                [[ $actual == 9 && $calls == 0 ]]
            ) || return 1
            (
                network_control() { return 9; }
                actual=0; network_negative dns-udp false || actual=$?
                [[ $actual == 9 ]]
            ) || return 1
            (
                # 执行真实容器内 shell 片段，仅替换内核文件读取。
                docker() {
                    case "$*" in
                        *'.NetworkSettings.Networks'*) printf 'n ' ;;
                        *'.HostConfig.Dns'*) printf '[172.30.243.53]' ;;
                        *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]' ;;
                        *'.EnableIPv6'*) printf 'false' ;;
                        *'.HostConfig.Sysctls'*) printf '1' ;;
                        *'.HostConfig.ExtraHosts'*) printf '[] []' ;;
                        *'.Destination'*) printf 'gm-conditional-ca false' ;;
                        *'.Mounts'*) return 0 ;;
                        *'id -ru'*) printf '10001 10001' ;;
                        exec*) bash -c "${@: -1}" ;;
                        *) return 99 ;;
                    esac
                }
                cat() { if [[ $1 == /proc/* ]]; then printf '0'; else printf 'nameserver 127.0.0.11\n'; fi; }
                export -f cat
                actual=0; assert_container_network_policy product || actual=$?
                [[ $actual != 0 ]]
            ) || { printf 'IPv6 runtime rejection FAILED\n'; return 1; }
            rm -rf "$scratch"
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
            local WINDOW SCRATCH actual installed deleted
            export HERE WINDOW SCRATCH
            export -f contract_guard_driver
            for WINDOW in chain rule spawn; do
                SCRATCH=$(mktemp -d); actual=0
                bash -c contract_guard_driver > "$SCRATCH/output" 2>&1 || actual=$?
                installed=$(awk '$3=="-A" || $3=="-I" || $3=="-N" {n++} END {print n+0}' "$SCRATCH/rules")
                deleted=$(awk '$3=="-D" || $3=="-X" {n++} END {print n+0}' "$SCRATCH/rules")
                [[ $actual == 143 && $installed == "$deleted" && ! -e $SCRATCH/business ]] || { printf 'window=%s exit=%s installed=%s deleted=%s evidence=%s FAIL\n' "$WINDOW" "$actual" "$installed" "$deleted" "$SCRATCH"; return 1; }
                printf 'window=%s owned=%s exit=143 PASS\n' "$WINDOW" "$installed"
                rm -rf "$SCRATCH"
            done
            ;;
    esac
}
case "${1:-}" in
    --contracts) contracts ;;
    --live)
        trap 'runner_rc=$?; printf "RUNNER_EXIT=%s\n" "$runner_rc" > "$IT_EVIDENCE_DIR/control/runner-status.txt"' EXIT
        trap 'exit 143' TERM
        trap 'exit 130' INT
        printf '%s\n' "$$" > "$IT_EVIDENCE_DIR/control/runner.pid"
        while [[ ! -f $IT_EVIDENCE_DIR/control/start ]]; do
            [[ ! -f $IT_EVIDENCE_DIR/control/stop ]] || exit 143
            sleep 0.1
        done
        [[ ! -f $IT_EVIDENCE_DIR/control/stop ]] || exit 143
        source "$HERE/docker-network-fixture.sh"
        network_probe
        ;;
    *) printf 'usage: %s --contracts|--live\n' "$0" >&2; exit 2 ;;
esac
