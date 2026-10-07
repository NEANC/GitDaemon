#!/usr/bin/env bash
# 授权宿主专属规则外层；不接受任意业务命令。
set -Eeuo pipefail
OWN_RULES=() OWN_CHAINS=()
# 比较 CIDR 区间，创建资源前拒绝任何网段覆盖。
guard_subnets_clear() {
    awk 'function ip(s,a){split(s,a,".");return ((a[1]*256+a[2])*256+a[3])*256+a[4]} BEGIN{lo=ip("172.30.243.0");hi=ip("172.30.244.255")} /\./{split($1,c,"/");p=(c[2]==""?32:c[2]);z=2^(32-p);s=int(ip(c[1])/z)*z;if(s<=hi && s+z-1>=lo)exit 1}' <<< "$1"
}
# 主业务非零优先，清理失败单独保留。
guard_result() {
    if (( $1 != 0 )); then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}
# 只逆序删除本轮成功安装的规则与链，不触及既有规则。
guard_remove_rules() {
    local i table rule status=0
    local -a args
    for ((i=${#OWN_RULES[@]}-1;i>=0;i--)); do
        table=${OWN_RULES[i]%%|*}; rule=${OWN_RULES[i]#*|}
        read -ra args <<< "$rule"; args[0]=-D
        iptables -t "$table" "${args[@]}" || status=2
    done
    for ((i=${#OWN_CHAINS[@]}-1;i>=0;i--)); do
        table=${OWN_CHAINS[i]%%|*}; rule=${OWN_CHAINS[i]#*|}
        iptables -t "$table" -X "$rule" || status=2
    done
    return "$status"
}
# 逐条登记已成功安装的规则，部分安装失败也能精确回滚。
guard_rule() {
    local table=$1; shift
    iptables -t "$table" "$@"
    OWN_RULES+=("$table|$*")
    printf '%s|%s\n' "$table" "$*" >> "$E/rules.owned"
}
# 实际以普通宿主用户调用 Docker，记录 su 直接状态。
guard_gm() {
    local cmd rc=0
    printf -v cmd '%q ' "$@"
    su -s /bin/bash "$RUNNER" -c "$cmd" || rc=$?
    printf 'SU_EXIT=%s\n' "$rc" >> "$E/su-status.log"
    return "$rc"
}
# 为本次失败生成独立恢复脚本；先成功清空标签资源，再撤销当前精确规则。
guard_write_recovery() {
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'RUN=%q\nRUNNER=%q\n' "$RUN" "$RUNNER"
        declare -p OWN_RULES OWN_CHAINS
        declare -f guard_remove_rules
        cat <<'RECOVERY'
# 管理员须先确认本轮 runner 已停止，再显式授权恢复。
[[ ${1:-} == --runner-stopped ]] || exit 64
[[ $(id -u) == 0 ]] || exit 77
# 通过普通宿主用户删除每个重新枚举到的精确对象。
recover_remove() {
    local command
    printf -v command '%q ' docker "$@"
    su -s /bin/bash "$RUNNER" -c "$command"
}
ids=$(docker ps -aq --filter "label=gitdaemon.run=$RUN")
for item in $ids; do recover_remove rm -f "$item"; done
for kind in network volume; do
    ids=$(docker "$kind" ls -q --filter "label=gitdaemon.run=$RUN")
    for item in $ids; do recover_remove "$kind" rm "$item"; done
done
ids=$(docker ps -aq --filter "label=gitdaemon.run=$RUN")
[[ -z $ids ]]
for kind in network volume; do
    ids=$(docker "$kind" ls -q --filter "label=gitdaemon.run=$RUN")
    [[ -z $ids ]]
done
guard_remove_rules
RECOVERY
    } > "$E/recover.sh"
}
# 清理前先保存输入关联的容器状态、日志与规则计数。
guard_cleanup() {
    local primary=$? clean=0 item ids kind residual isolated=1
    trap - EXIT TERM INT
    set +e
    if [[ -n ${CHILD:-} ]]; then
        if [[ -f $E/control/runner.pid ]]; then
            guard_gm kill -TERM "$(cat "$E/control/runner.pid")" 2>/dev/null
        else
            kill -TERM -- "-$CHILD" 2>/dev/null
        fi
        wait "$CHILD"; printf 'CLEANUP_CHILD_WAIT_EXIT=%s\n' "$?" >> "$E/exit-status.txt"
    fi
    iptables-save -c > "$E/rules-before-cleanup.txt" || clean=2
    ids=$(docker ps -aq --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
    for item in $ids; do
        docker inspect "$item" > "$E/inspect-$item.json" || clean=2
        docker logs "$item" > "$E/container-$item.log" 2>&1 || clean=2
        guard_gm docker rm -f "$item" || { clean=2; isolated=0; }
    done
    for kind in network volume; do
        ids=$(docker "$kind" ls -q --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
        for item in $ids; do
            guard_gm docker "$kind" rm "$item" || { clean=2; isolated=0; }
        done
    done
    residual=$(docker ps -aq --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
    printf '%s\n' "$residual" > "$E/residual-containers.txt"
    [[ -z $residual ]] || { clean=2; isolated=0; }
    for kind in network volume; do
        residual=$(docker "$kind" ls -q --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
        printf '%s\n' "$residual" > "$E/residual-${kind}s.txt"
        [[ -z $residual ]] || { clean=2; isolated=0; }
    done
    if (( isolated )); then
        guard_remove_rules || clean=2
    else
        printf 'ISOLATION_RETAINED=1\nRUN=%s\nRecovery: confirm runner stopped, then run bash recover.sh --runner-stopped as the authorized host administrator. The script re-queries only label gitdaemon.run=%s and requires empty resources before reversing the embedded active rule/chain manifest. Never flush global tables.\n' "$RUN" "$RUN" >> "$E/recovery.txt"
        guard_write_recovery || clean=2
    fi
    iptables-save -c > "$E/rules-after-cleanup.txt" || clean=2
    printf 'PRIMARY_EXIT=%s\nCLEANUP_EXIT=%s\n' "$primary" "$clean" >> "$E/exit-status.txt"
    exit "$(guard_result "$primary" "$clean")"
}
# 仅为指定校准源开放见证 DNS，不允许其他端口和目的。
guard_calibration() {
    local proto
    for proto in udp tcp; do
        guard_rule raw -A "$EARLY" -s 172.30.243.3 -d 172.30.244.53 -p "$proto" --dport 53 -j ACCEPT
        guard_rule raw -A "$RETURN" -s 172.30.244.53 -d 172.30.243.3 -p "$proto" --sport 53 -j ACCEPT
        guard_rule filter -I FORWARD -i "$BR" -o "$WBR" -s 172.30.243.3 -d 172.30.244.53 -p "$proto" --dport 53 -j ACCEPT
        guard_rule filter -I FORWARD -i "$WBR" -o "$BR" -s 172.30.244.53 -d 172.30.243.3 -p "$proto" --sport 53 -m conntrack --ctstate ESTABLISHED -j ACCEPT
    done
}
# 根据固定请求保存计数；业务库永远不调用 iptables 或 nsenter。
guard_snapshot() {
    local seq=$1 pid
    iptables-save -c > "$E/snapshot-$seq.rules"
    pid=$(docker inspect -f '{{.State.Pid}}' "gm-$RUN-witness")
    nsenter -t "$pid" -n iptables -t raw -nvxL "$SEEN" > "$E/snapshot-$seq.witness"
    chmod a+r "$E/snapshot-$seq.rules" "$E/snapshot-$seq.witness"
}
# 校准结束后撤销临时放行，随后才允许创建产品。
guard_close_calibration() {
    local i table rule
    local -a args keep=()
    for ((i=${#OWN_RULES[@]}-1;i>=CAL_START;i--)); do
        table=${OWN_RULES[i]%%|*}; rule=${OWN_RULES[i]#*|}
        read -ra args <<< "$rule"; args[0]=-D
        iptables -t "$table" "${args[@]}"
    done
    for ((i=0;i<CAL_START;i++)); do keep+=("${OWN_RULES[i]}"); done
    OWN_RULES=("${keep[@]}")
}
# 固定入口解析、宿主预检、规则安装以及降权执行。
guard_main() {
    local mode='' source='' image='' tools='' existing table chain parent bridge seq request pid command rc=0
    RUN='' E='' RUNNER=''
    while (( $# )); do
        [[ $# -ge 2 ]] || return 2
        case "$1" in
            --run-id) RUN=$2 ;; --evidence-dir) E=$2 ;; --source-dir) source=$2 ;;
            --runner-user) RUNNER=$2 ;; --mode) mode=$2 ;; --product-image) image=$2 ;; --tools-image) tools=$2 ;;
            *) return 2 ;;
        esac
        shift 2
    done
    [[ $RUN =~ ^[a-zA-Z0-9-]{1,10}$ && $RUNNER == gmtest && $E == /* && $source == /* && -n $image && -n $tools ]] || return 2
    case "$mode" in probe) ;; o1|full) printf 'R3 integration not implemented\n' >&2; return 64 ;; *) return 2 ;; esac
    [[ $(id -u) == 0 ]] || return 77
    ip -4 addr show | grep -q 'inet 192.168.10.9/' || return 77
    [[ $E != /tmp/* && $E != /var/tmp/* && ! -e $E ]] || return 73
    [[ $(id -u "$RUNNER") != 0 ]] || return 77
    BR=g$RUN WBR=w$RUN CHAIN=G$RUN EARLY=E$RUN RETURN=R$RUN SEEN=S$RUN
    existing=$(docker network inspect $(docker network ls -q) --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}'; ip -4 route show | awk '$1!="default" {print $1}')
    guard_subnets_clear "$existing" || return 70
    if docker ps -a --format '{{.Names}}' | grep -F "gm-$RUN-"; then return 70; fi
    if docker network ls --format '{{.Name}}' | grep -F "gm-$RUN-"; then return 70; fi
    if docker volume ls --format '{{.Name}}' | grep -F "gm-$RUN-"; then return 70; fi
    for bridge in "$BR" "$WBR"; do if ip link show "$bridge" >/dev/null 2>&1; then return 70; fi; done
    for chain in "$CHAIN" "$EARLY" "$RETURN"; do if iptables-save | grep -w "$chain"; then return 70; fi; done
    mkdir -p "$E"; chmod 755 "$E"
    mkdir "$E/control"; chown "$RUNNER" "$E/control"
    printf '%s\n' "$existing" > "$E/subnets-before.txt"
    sha256sum "$source"/tests/docker-network-guard.sh "$source"/tests/docker-network-fixture.sh "$source"/tests/docker-dns-tools.Dockerfile "$source"/tests/test-docker-network.sh > "$E/inputs.sha256"
    git -C "$source" status --short > "$E/git-state.txt" 2>&1 || true
    docker image inspect "$image" "$tools" > "$E/images.json"
    iptables-save -c > "$E/rules-before.txt"
    printf 'Run=%s\nRemove only listed labeled resources and reverse rules.owned after SIGKILL; never flush global tables.\n' "$RUN" > "$E/recovery.txt"
    trap guard_cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    for spec in "filter|$CHAIN" "raw|$EARLY" "raw|$RETURN"; do
        table=${spec%%|*}; chain=${spec#*|}
        iptables -t "$table" -N "$chain"; OWN_CHAINS+=("$spec")
        printf '%s\n' "$spec" >> "$E/chains.owned"
    done
    guard_rule filter -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
    guard_rule filter -A "$CHAIN" -i "$BR" -o "$BR" -s 172.30.243.0/24 -d 172.30.243.0/24 -j ACCEPT
    guard_rule filter -A "$CHAIN" -j DROP
    for parent in INPUT DOCKER-USER; do for bridge in "$BR" "$WBR"; do guard_rule filter -I "$parent" -i "$bridge" -j "$CHAIN"; done; done
    for spec in 'cross-network 172.30.244.53 tcp 19419' 'host-published 172.30.243.1 tcp 49382' 'host-input 172.30.243.1 tcp 49383' 'dns-udp 172.30.244.53 udp 53' 'dns-tcp 172.30.244.53 tcp 53'; do
        read -r label destination proto port <<< "$spec"
        guard_rule raw -A "$EARLY" -s 172.30.243.4 -d "$destination" -p "$proto" --dport "$port" -m comment --comment "$RUN-$label" -j DROP
    done
    guard_rule raw -I PREROUTING -i "$BR" -j "$EARLY"
    guard_rule raw -I PREROUTING -i "$WBR" -j "$RETURN"
    CAL_START=${#OWN_RULES[@]}
    guard_calibration
    # 拒绝规则在临时校准放行之后；撤销只删校准规则。
    guard_rule raw -A "$EARLY" -d 172.30.244.0/24 -j DROP
    guard_rule raw -A "$RETURN" -d 172.30.243.0/24 -j DROP
    iptables-save -c > "$E/rules-ready.txt"
    printf -v command '%q ' env IT_RUN_ID="$RUN" IT_EVIDENCE_DIR="$E" IT_NETWORK="gm-$RUN-net" IT_WITNESS_NETWORK="gm-$RUN-w-net" IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE="$tools" IT_PRODUCT_IMAGE="$image" IT_NETWORK_GUARD_READY=1 bash "$source/tests/test-docker-network.sh" --live
    setsid su -s /bin/bash "$RUNNER" -c "$command" > "$E/run.log" 2>&1 &
    CHILD=$!
    seq=1
    while kill -0 "$CHILD" 2>/dev/null; do
        if [[ -f $E/control/request-$seq ]]; then
            request=$(cat "$E/control/request-$seq")
            case "$request" in
                witness)
                    pid=$(docker inspect -f '{{.State.Pid}}' "gm-$RUN-witness")
                    nsenter -t "$pid" -n iptables -t raw -N "$SEEN"
                    for spec in 'tcp 19419' 'udp 53' 'tcp 53'; do read -r proto port <<< "$spec"; nsenter -t "$pid" -n iptables -t raw -A "$SEEN" -p "$proto" --dport "$port" -j RETURN; done
                    nsenter -t "$pid" -n iptables -t raw -I PREROUTING -j "$SEEN"
                    ;;
                close)
                    guard_close_calibration
                    guard_rule raw -A "$EARLY" -d 172.30.244.0/24 -j DROP
                    guard_rule raw -A "$RETURN" -d 172.30.243.0/24 -j DROP
                    ;;
                snapshot) guard_snapshot "$seq" ;;
                *) exit 65 ;;
            esac
            touch "$E/control/ack-$seq"; seq=$((seq + 1))
        fi
        sleep 0.1
    done
    wait "$CHILD" || rc=$?
    CHILD=''
    printf 'RUNNER_WAIT_EXIT=%s\n' "$rc" >> "$E/exit-status.txt"
    return "$rc"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then guard_main "$@"; fi
