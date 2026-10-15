#!/usr/bin/env bash
# 授权宿主专属规则外层；不接受任意业务命令。
set -Eeuo pipefail
GUARD_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 环境授权库与资源账本库与 guard 同目录；缺库时由入口拒绝，不创建任何资源。
[[ ! -f $GUARD_DIR/docker-validation-environment.sh ]] || source "$GUARD_DIR/docker-validation-environment.sh"
[[ ! -f $GUARD_DIR/docker-resource-ledger.sh ]] || source "$GUARD_DIR/docker-resource-ledger.sh"
OWN_RULES=() OWN_CHAINS=()
PENDING_SIGNAL=0
GUARD_BOUND=0
GUARD_SOURCE=''
GUARD_MANIFEST=''
GUARD_ATTESTATION=''
GUARD_PROFILE=''
# 仅在所有权登记及启动握手安全点处理可捕获信号。
guard_signal_checkpoint() {
    if (( PENDING_SIGNAL != 0 )); then exit "$PENDING_SIGNAL"; fi
}
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
    guard_signal_checkpoint
}
# 实际以普通宿主用户调用 Docker，记录 su 直接状态；清除继承的 Docker 覆盖。
guard_gm() {
    local cmd rc=0
    printf -v cmd '%q ' "$@"
    su -s /bin/bash "$RUNNER" -c "unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; $cmd" || rc=$?
    printf 'SU_EXIT=%s\n' "$rc" >> "$E/su-status.log"
    return "$rc"
}
# 为本次失败生成独立恢复脚本；冻结账本及库哈希，只按登记账本精确恢复。
# 恢复脚本复用同一资源库，先复核同一 VM/runner/socket/daemon 并要求 runner 已停止。
guard_write_recovery() {
    local ledger_dir=$E/control/resources lib_hash='' ledger_hash=''
    lib_hash=$(sha256sum "$GUARD_DIR/docker-resource-ledger.sh" 2>/dev/null | cut -d' ' -f1)
    [[ ! -f $ledger_dir/ledger.tsv ]] || ledger_hash=$(sha256sum "$ledger_dir/ledger.tsv" | cut -d' ' -f1)
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'RUN=%q\nRUNNER=%q\n' "$RUN" "$RUNNER"
        printf 'SOURCE=%q\nMANIFEST=%q\nATTESTATION=%q\n' "$GUARD_SOURCE" "$GUARD_MANIFEST" "$GUARD_ATTESTATION"
        printf 'LEDGER_DIR=%q\nLIB_HASH=%q\nLEDGER_HASH=%q\n' "$ledger_dir" "$lib_hash" "$ledger_hash"
        declare -p OWN_RULES OWN_CHAINS
        declare -f guard_remove_rules
        resource_recovery_embed
        cat <<'RECOVERY'
# 管理员须先确认本轮 runner 已停止，再显式授权恢复。
[[ ${1:-} == --runner-stopped ]] || exit 64
[[ $(id -u) == 0 ]] || exit 77
# 绑定路径必须先复核同一 VM/runner/socket/daemon，再触碰任何对象。
if [[ -n $MANIFEST ]]; then
    [[ -n $SOURCE ]] || exit 77
    source "$SOURCE/tests/docker-validation-environment.sh" || exit 77
    validation_environment_verify "$MANIFEST" "$ATTESTATION" || exit 77
fi
# 冻结库哈希：只加载经核验的同一库，不复制旧 label-only 删除逻辑。
[[ -n $SOURCE && -f $SOURCE/tests/docker-resource-ledger.sh && -n $LIB_HASH ]] || exit 77
[[ $(sha256sum "$SOURCE/tests/docker-resource-ledger.sh" | cut -d' ' -f1) == "$LIB_HASH" ]] || exit 77
# 冻结账本：内容与生成时刻一致才允许继续。
if [[ -n $LEDGER_HASH ]]; then
    [[ -f $LEDGER_DIR/ledger.tsv ]] || exit 77
    [[ $(sha256sum "$LEDGER_DIR/ledger.tsv" | cut -d' ' -f1) == "$LEDGER_HASH" ]] || exit 77
fi
RESOURCE_LEDGER_DIR=$LEDGER_DIR RESOURCE_RUN=$RUN
resource_cleanup "$LEDGER_DIR" || exit 2
guard_remove_rules
RECOVERY
    } > "$E/recover.sh"
}
# 清理前先保存输入关联的容器状态、日志与规则计数；删除统一走资源账本交叉验证。
guard_cleanup() {
    local primary=$? clean=0 item ids kind residual isolated=1 bound=1
    trap '' TERM INT
    trap - EXIT
    set +e
    if [[ -n ${CHILD:-} ]]; then
        # 未获启动许可的 runner 只接受停止请求，不会创建业务。
        touch "$E/control/stop"
        if [[ -f $E/control/runner.pid ]]; then
            guard_gm kill -TERM "$(cat "$E/control/runner.pid")" 2>/dev/null
        fi
        wait "$CHILD"; printf 'SETSID_WAIT_EXIT=%s\n' "$?" >> "$E/exit-status.txt"
    fi
    iptables-save -c > "$E/rules-before-cleanup.txt" || clean=2
    # 绑定路径先复核同一 VM/runner/socket/daemon；漂移时保留隔离，不触碰未知端点。
    if [[ $GUARD_BOUND == 1 ]]; then
        validation_environment_verify "$GUARD_MANIFEST" "$GUARD_ATTESTATION" || bound=0
    fi
    if (( bound == 0 )); then
        printf 'ENVIRONMENT_DRIFT=1\nRUN=%s\n' "$RUN" >> "$E/recovery.txt"
        clean=2
        isolated=0
    else
        ids=$(docker ps -aq --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
        for item in $ids; do
            docker inspect "$item" > "$E/inspect-$item.json" || clean=2
            docker logs "$item" > "$E/container-$item.log" 2>&1 || clean=2
        done
        # 精确删除：交叉验证通过与登记身份/标签、卷身份摘要一致才删除；差异即停止。
        RESOURCE_LEDGER_DIR=$E/control/resources RESOURCE_RUN=$RUN
        if ! resource_cleanup "$E/control/resources"; then
            clean=2
            isolated=0
        fi
        residual=$(docker ps -aq --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
        printf '%s\n' "$residual" > "$E/residual-containers.txt"
        [[ -z $residual ]] || { clean=2; isolated=0; }
        for kind in network volume; do
            residual=$(docker "$kind" ls -q --filter "label=gitdaemon.run=$RUN") || { clean=2; isolated=0; }
            printf '%s\n' "$residual" > "$E/residual-${kind}s.txt"
            [[ -z $residual ]] || { clean=2; isolated=0; }
        done
    fi
    if [[ -f $E/control/integration-status.txt ]]; then
        grep -qx 'INTEGRATION_CLEANUP_EXIT=0' "$E/control/integration-status.txt" || { clean=2; isolated=0; }
    fi
    [[ ! -s $E/control/integration-failures.log ]] || { clean=2; isolated=0; }
    if (( isolated )); then
        guard_remove_rules || clean=2
    else
        printf 'ISOLATION_RETAINED=1\nRUN=%s\nRecovery: confirm runner stopped, then run bash recover.sh --runner-stopped as the authorized host administrator. The script loads the frozen ledger and library, re-verifies the same VM/runner/socket/daemon, cross-checks registered identities against ownership labels and requires empty resources before reversing the embedded active rule/chain manifest. Never flush global tables.\n' "$RUN" >> "$E/recovery.txt"
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
# 生成固定入口命令；新路径由子入口独立复核本地 daemon，full 由子入口再查延期请求。
guard_runner_command() {
    local mode=$1 source=$2 run=$3 evidence=$4 image=$5 tools=$6
    local manifest=${7:-} attestation=${8:-} profile=${9:-}
    local script=''
    [[ $# -le 9 ]] || return 2
    local -a filter=(-u IT_FILTER) entry=(--integration) extra=()
    case "$mode" in
        o1) filter=(IT_FILTER=o1) ;;
        c2) filter=(IT_FILTER=c2) ;;
        full|mapping-fallback|mapping-direct|mapping-probe)
            [[ -n $manifest && -n $attestation && -n $profile ]] || return 2
            extra=(IT_MAPPING_PROFILE="$profile")
            script='set -e'
            [[ $mode != full ]] || script+=$'\n''[[ ${IT_DEFER_MAPPING:-} != 1 ]] || exit 2'
            script+=$'\n''endpoint=unix:///var/run/docker.sock'
            script+=$'\n''daemon=$(grep "^daemon_id" "$2" | cut -f2)'
            script+=$'\n''[[ -n $daemon ]] || exit 77'
            script+=$'\n''actual=$(env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host "$endpoint" info -f '"'"'{{.ID}}'"'"')'
            script+=$'\n''[[ $actual == "$daemon" ]] || exit 77'
            script+=$'\n''exec bash "$1/tests/test-docker-network.sh" --integration'
            printf '%q ' env "${filter[@]}" IT_RUN_ID="$run" IT_EVIDENCE_DIR="$evidence" IT_NETWORK="gm-$run-net" IT_WITNESS_NETWORK="gm-$run-w-net" IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE="$tools" IT_PRODUCT_IMAGE="$image" IT_NETWORK_GUARD_READY=1 "${extra[@]}" bash -c "$script" _ "$source" "$manifest" "$attestation"
            return 0
            ;;
        probe) entry=(--live) ;;
        startup) entry=(--startup-integration) ;;
        *) return 2 ;;
    esac
    printf '%q ' env "${filter[@]}" IT_RUN_ID="$run" IT_EVIDENCE_DIR="$evidence" IT_NETWORK="gm-$run-net" IT_WITNESS_NETWORK="gm-$run-w-net" IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE="$tools" IT_PRODUCT_IMAGE="$image" IT_NETWORK_GUARD_READY=1 bash "$source/tests/test-docker-network.sh" "${entry[@]}"
}
# 固定入口解析、宿主预检、规则安装以及降权执行。
guard_main() {
    local mode='' source='' image='' tools='' manifest='' attestation='' profile='' existing table chain parent bridge seq request token pid command rc=0 ids routes resources links rules
    RUN='' E='' RUNNER=''
    while (( $# )); do
        [[ $# -ge 2 ]] || return 2
        case "$1" in
            --run-id) RUN=$2 ;; --evidence-dir) E=$2 ;; --source-dir) source=$2 ;;
            --runner-user) RUNNER=$2 ;; --mode) mode=$2 ;; --product-image) image=$2 ;; --tools-image) tools=$2 ;;
            --environment-manifest) manifest=$2 ;; --offline-attestation) attestation=$2 ;; --mapping-profile) profile=$2 ;;
            *) return 2 ;;
        esac
        shift 2
    done
    [[ $RUN =~ ^[a-zA-Z0-9-]{1,10}$ && $RUNNER == gmtest && $E == /* && $source == /* && -n $image && -n $tools ]] || return 2
    case "$mode" in probe|o1|c2|full|startup|mapping-fallback|mapping-direct|mapping-probe) ;; *) return 2 ;; esac
    # 新 full/mapping 路径必须绑定环境授权清单，缺参即拒绝。
    case "$mode" in
        full|mapping-fallback|mapping-direct|mapping-probe)
            [[ -n $manifest && -n $attestation && -n $profile ]] || return 77 ;;
    esac
    # full 的延期请求属纯输入校验，先于 root 检查，避免延期语义与 root 耦合。
    if [[ $mode == full && ${IT_DEFER_MAPPING:-} == 1 ]]; then return 2; fi
    [[ $(id -u) == 0 ]] || return 77
    # 恢复脚本需要用同一源码目录核验资源库；所有模式统一登记。
    GUARD_SOURCE=$source
    case "$mode" in
        full)
            GUARD_MANIFEST=$manifest GUARD_ATTESTATION=$attestation GUARD_PROFILE=$profile
            validation_environment_verify "$manifest" "$attestation" || return $?
            GUARD_BOUND=1
            ;;
        mapping-fallback|mapping-direct|mapping-probe)
            GUARD_MANIFEST=$manifest GUARD_ATTESTATION=$attestation GUARD_PROFILE=$profile
            validation_environment_verify "$manifest" "$attestation" || return $?
            # mapping 拒绝证据与独立网络尚未接入，不得安装旧业务网规则。
            return 77
            ;;
        *)
            ip -4 addr show | grep -q 'inet 192.168.10.9/' || return 77
            ;;
    esac
    [[ $E != /tmp/* && $E != /var/tmp/* && ! -e $E ]] || return 73
    [[ $(id -u "$RUNNER") != 0 ]] || return 77
    BR=g$RUN WBR=w$RUN CHAIN=G$RUN EARLY=E$RUN RETURN=R$RUN SEEN=S$RUN
    ids=$(docker network ls -q) || return $?
    existing=''
    if [[ -n $ids ]]; then
        existing=$(docker network inspect $ids --format '{{range .IPAM.Config}}{{.Subnet}}{{println}}{{end}}') || return $?
    fi
    routes=$(ip -4 route show) || return $?
    routes=$(awk '$1!="default" {print $1}' <<< "$routes") || return $?
    existing+=$'\n'"$routes"
    guard_subnets_clear "$existing" || return 70
    resources=$(docker ps -a --format '{{.Names}}') || return $?
    if grep -F "gm-$RUN-" <<< "$resources"; then return 70; fi
    resources=$(docker network ls --format '{{.Name}}') || return $?
    if grep -F "gm-$RUN-" <<< "$resources"; then return 70; fi
    resources=$(docker volume ls --format '{{.Name}}') || return $?
    if grep -F "gm-$RUN-" <<< "$resources"; then return 70; fi
    links=$(ip link show) || return $?
    for bridge in "$BR" "$WBR"; do if grep -Eq "^[0-9]+: ${bridge}(@[^:]+)?:" <<< "$links"; then return 70; fi; done
    rules=$(iptables-save) || return $?
    for chain in "$CHAIN" "$EARLY" "$RETURN"; do if grep -w "$chain" <<< "$rules"; then return 70; fi; done
    mkdir -p "$E"; chmod 755 "$E"
    mkdir "$E/control"; chown "$RUNNER" "$E/control"
    printf '%s\n' "$existing" > "$E/subnets-before.txt"
    sha256sum "$source"/tests/*.sh "$source"/tests/docker-dns-tools.Dockerfile "$source"/Dockerfile "$source"/compose.yml > "$E/inputs.sha256"
    if [[ -d $source/.git ]]; then
        git -C "$source" status --short > "$E/git-state.txt"
    else
        cp "$source/input-git-state.txt" "$E/git-state.txt"
    fi
    docker image inspect "$image" "$tools" > "$E/images.json"
    iptables-save -c > "$E/rules-before.txt"
    printf 'Run=%s\nRemove only listed labeled resources and reverse rules.owned after SIGKILL; never flush global tables.\n' "$RUN" > "$E/recovery.txt"
    trap guard_cleanup EXIT
    trap 'PENDING_SIGNAL=143' TERM
    trap 'PENDING_SIGNAL=130' INT
    for spec in "filter|$CHAIN" "raw|$EARLY" "raw|$RETURN"; do
        table=${spec%%|*}; chain=${spec#*|}
        iptables -t "$table" -N "$chain"; OWN_CHAINS+=("$spec")
        printf '%s\n' "$spec" >> "$E/chains.owned"
        guard_signal_checkpoint
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
    command=$(guard_runner_command "$mode" "$source" "$RUN" "$E" "$image" "$tools" "$manifest" "$attestation" "$profile")
    printf -v command 'su -s /bin/bash %q -c %q; rc=$?; printf "BUSINESS_SU_EXIT=%%s\\n" "$rc" > %q; exit "$rc"' "$RUNNER" "$command" "$E/business-su-status.txt"
    setsid bash -c "$command" > "$E/run.log" 2>&1 &
    CHILD=$!
    guard_signal_checkpoint
    while [[ ! -f $E/control/runner.pid ]]; do
        guard_signal_checkpoint
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 0.1
    done
    guard_signal_checkpoint
    [[ ! -f $E/control/runner.pid ]] || touch "$E/control/start"
    seq=1
    while kill -0 "$CHILD" 2>/dev/null; do
        guard_signal_checkpoint
        if [[ -f $E/control/request-$seq ]]; then
            read -r request token < "$E/control/request-$seq"
            [[ -n $token ]] || exit 65
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
            printf '%s\n' "$token" > "$E/control/ack-$seq.tmp"
            mv "$E/control/ack-$seq.tmp" "$E/control/ack-$seq"
            seq=$((seq + 1))
        fi
        sleep 0.1
    done
    wait "$CHILD" || rc=$?
    guard_signal_checkpoint
    CHILD=''
    printf 'SETSID_WAIT_EXIT=%s\n' "$rc" >> "$E/exit-status.txt"
    return "$rc"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then guard_main "$@"; fi
