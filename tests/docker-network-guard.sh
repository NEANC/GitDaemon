#!/usr/bin/env bash
# 授权宿主专属规则外层；不接受任意业务命令。
set -Eeuo pipefail
GUARD_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 环境授权库与资源账本库与 guard 同目录；缺库时由入口拒绝，不创建任何资源。
[[ ! -f $GUARD_DIR/docker-validation-environment.sh ]] || source "$GUARD_DIR/docker-validation-environment.sh"
[[ ! -f $GUARD_DIR/docker-resource-ledger.sh ]] || source "$GUARD_DIR/docker-resource-ledger.sh"
[[ ! -f $GUARD_DIR/docker-mapping-fixture.sh ]] || source "$GUARD_DIR/docker-mapping-fixture.sh"
[[ ! -f $GUARD_DIR/docker-network-fixture.sh ]] || source "$GUARD_DIR/docker-network-fixture.sh"
OWN_RULES=() OWN_CHAINS=() OWN_NS_RULES=() OWN_NS_CHAINS=()
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
guard_mapping_witness_identity() {
    local identity run scenario role network pid running entry facts
    facts=$(docker inspect -f '{{.Id}}|{{index .Config.Labels "gitdaemon.run"}}|{{index .Config.Labels "gitdaemon.scenario"}}|{{index .Config.Labels "gitdaemon.role"}}|{{.HostConfig.NetworkMode}}|{{.State.Pid}}|{{.State.Running}}' "gm-$RUN-witness") || return 80
    IFS='|' read -r identity run scenario role network pid running <<< "$facts"
    [[ $identity =~ ^[0-9a-f]{64}$ && $run == "$RUN" && $scenario == mapping && $role == witness && $network == "gm-$RUN-w-net" && $pid =~ ^[1-9][0-9]*$ && $running == true ]] || return 80
    RESOURCE_RUN=$RUN resource_ledger_load "$E/control/resources" || return 80
    entry=${RESOURCE_LEDGER_ACTIVE["container|$identity"]:-}
    [[ $entry == *'|mapping|witness|'* && $entry == *"|$RUN" ]] || return 80
    RESOURCE_RUN=$RUN resource_verify_object container "$identity" mapping witness '' || return 80
    if [[ -n ${GUARD_MAPPING_WITNESS_ID:-} && $identity != "$GUARD_MAPPING_WITNESS_ID" ]]; then return 80; fi
    printf '%s\n' "$pid"
}
guard_mapping_witness_remove() {
    local i table rule status=0 pid
    local -a args
    if [[ ${#OWN_NS_RULES[@]} == 0 && ${#OWN_NS_CHAINS[@]} == 0 ]]; then return 0; fi
    pid=$(guard_mapping_witness_identity) || return 2
    for ((i=${#OWN_NS_RULES[@]}-1;i>=0;i--)); do
        table=${OWN_NS_RULES[i]%%|*}; rule=${OWN_NS_RULES[i]#*|}
        read -ra args <<< "$rule"; args[0]=-D
        nsenter -t "$pid" -n iptables -t "$table" "${args[@]}" || status=2
    done
    for ((i=${#OWN_NS_CHAINS[@]}-1;i>=0;i--)); do
        table=${OWN_NS_CHAINS[i]%%|*}; rule=${OWN_NS_CHAINS[i]#*|}
        nsenter -t "$pid" -n iptables -t "$table" -X "$rule" || status=2
    done
    if (( status == 0 )); then OWN_NS_RULES=() OWN_NS_CHAINS=(); fi
    return "$status"
}
guard_mapping_witness_install() {
    local pid proto port spec chain="MS$RUN"
    GUARD_MAPPING_WITNESS_ID=$(docker inspect -f '{{.Id}}' "gm-$RUN-witness") || return 80
    pid=$(guard_mapping_witness_identity) || return 80
    nsenter -t "$pid" -n iptables -t raw -N "$chain" || return 80
    OWN_NS_CHAINS+=("raw|$chain")
    printf 'raw|%s\n' "$chain" >> "$E/witness-chains.owned" || return 80
    for spec in 'tcp 19419' 'tcp 19420' 'udp 53' 'tcp 53'; do
        read -r proto port <<< "$spec"
        nsenter -t "$pid" -n iptables -t raw -A "$chain" -p "$proto" --dport "$port" -j RETURN || return 80
        OWN_NS_RULES+=("raw|-A $chain -p $proto --dport $port -j RETURN")
        printf 'raw|-A %s -p %s --dport %s -j RETURN\n' "$chain" "$proto" "$port" >> "$E/witness-rules.owned" || return 80
    done
    nsenter -t "$pid" -n iptables -t raw -I PREROUTING -j "$chain" || return 80
    OWN_NS_RULES+=("raw|-I PREROUTING -j $chain")
    printf 'raw|-I PREROUTING -j %s\n' "$chain" >> "$E/witness-rules.owned" || return 80
    return 0
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
    local ledger_dir=$E/control/resources lib_hash='' ledger_hash='' recovery_hash
    lib_hash=$(sha256sum "$GUARD_DIR/docker-resource-ledger.sh" 2>/dev/null | cut -d' ' -f1)
    [[ ! -f $ledger_dir/ledger.tsv ]] || ledger_hash=$(sha256sum "$ledger_dir/ledger.tsv" | cut -d' ' -f1)
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'RUN=%q\nRUNNER=%q\n' "$RUN" "$RUNNER"
        printf 'SOURCE=%q\nMANIFEST=%q\nATTESTATION=%q\n' "$GUARD_SOURCE" "$GUARD_MANIFEST" "$GUARD_ATTESTATION"
        printf 'LEDGER_DIR=%q\nLIB_HASH=%q\nLEDGER_HASH=%q\n' "$ledger_dir" "$lib_hash" "$ledger_hash"
        declare -p OWN_RULES OWN_CHAINS OWN_NS_RULES OWN_NS_CHAINS
        printf 'GUARD_MAPPING_WITNESS_ID=%q\nE=%q\n' "${GUARD_MAPPING_WITNESS_ID:-}" "$E"
        declare -f guard_remove_rules guard_mapping_witness_identity guard_mapping_witness_remove
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
guard_mapping_witness_remove || exit 2
resource_cleanup "$LEDGER_DIR" || exit 2
guard_remove_rules
RECOVERY
    } > "$E/recover.sh"
    chmod 600 "$E/recover.sh" || return 2
    recovery_hash=$(sha256sum "$E/recover.sh" 2>/dev/null | cut -d' ' -f1)
    [[ $recovery_hash =~ ^[0-9a-f]{64}$ ]] || return 2
    {
        printf 'run_id\t%s\nrecover_sha256\t%s\n' "$RUN" "$recovery_hash"
    } > "$E/recovery-binding.tsv.tmp" || return 2
    chmod 600 "$E/recovery-binding.tsv.tmp" || return 2
    mv "$E/recovery-binding.tsv.tmp" "$E/recovery-binding.tsv" || return 2
}
# 清理前先保存输入关联的容器状态、日志与规则计数；删除统一走资源账本交叉验证。
guard_cleanup() {
    local primary=$? clean=0 item ids kind residual isolated=1 bound=1 runner_pid='' wait_count=0
    trap '' TERM INT
    trap - EXIT
    set +e
    if [[ -n ${CHILD:-} ]]; then
        # 未获启动许可的 runner 只接受停止请求，不会创建业务。
        touch "$E/control/stop"
        if [[ -f $E/control/runner-handshake.tsv ]]; then
            runner_pid=$(awk -F'\t' '$1=="pid"{print $2}' "$E/control/runner-handshake.tsv")
        elif [[ -f $E/control/runner.pid ]]; then
            runner_pid=$(cat "$E/control/runner.pid")
        fi
        [[ -z $runner_pid ]] || guard_gm kill -TERM "$runner_pid" 2>/dev/null
        kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null || true
        while kill -0 "$CHILD" 2>/dev/null && (( wait_count < 50 )); do
            sleep 0.1
            wait_count=$((wait_count + 1))
        done
        kill -KILL -- "-$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null || true
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
        if [[ ${#OWN_NS_RULES[@]} != 0 || ${#OWN_NS_CHAINS[@]} != 0 ]]; then
            guard_mapping_witness_remove || { clean=2; isolated=0; }
        fi
        RESOURCE_LEDGER_DIR=$E/control/resources RESOURCE_RUN=$RUN
        if (( isolated )); then
            if ! resource_cleanup "$E/control/resources"; then
                clean=2
                isolated=0
            fi
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
    local manifest=${7:-} attestation=${8:-} profile=${9:-} net=''
    local script='' routing='--integration' order=${IT_MAPPING_ORDER:-}
    [[ $# -le 9 ]] || return 2
    local -a filter=(-u IT_FILTER) entry=(--integration) extra=()
    case "$mode" in
        o1) filter=(IT_FILTER=o1) ;;
        c2) filter=(IT_FILTER=c2) ;;
        full|mapping-fallback|mapping-direct|mapping-probe|mapping-sequence)
            [[ -n $manifest && -n $attestation && -n $profile ]] || return 2
            extra=(IT_MAPPING=1 IT_MAPPING_PROFILE="$profile" IT_CONTROL_DIR="$evidence/control" RESOURCE_LEDGER_DIR="$evidence/control/resources")
            net="gm-$run-net"
            script='set -e'
            if [[ $mode == mapping-sequence ]]; then
                [[ $order == fallback,direct || $order == direct,fallback ]] || return 2
                extra+=(IT_MAPPING_ORDER="$order")
                routing='--mapping-sequence'
            elif [[ $mode == full ]]; then
                script+=$'\n''[[ ${IT_DEFER_MAPPING:-} != 1 ]] || exit 2'
            else
                # 单项 mapping 模式各自独立入口，不跑旧业务断言；未接线时由入口 fail-closed。
                # 单项 mode 与集成入口共用 IT_MAPPING_SCENARIO：据此只选择对应场景，绝不退化为 full。
                extra+=(IT_MAPPING_SCENARIO="${mode#mapping-}")
                net="gm-$run-m-net"
                routing="--$mode"
            fi
            script+=$'\n''source "$1/tests/docker-validation-environment.sh"'
            script+=$'\n''validation_environment_verify "$2" "$3" || exit $?'
            script+=$'\n''validation_docker info -f '"'"'{{.ID}}'"'"' >/dev/null || exit $?'
            script+=$'\n'"exec bash \"\$1/tests/test-docker-network.sh\" $routing"
            printf '%q ' env -u VE_DOCKER_ENDPOINT "${filter[@]}" IT_RUN_ID="$run" IT_EVIDENCE_DIR="$evidence" IT_NETWORK="$net" IT_WITNESS_NETWORK="gm-$run-w-net" IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE="$tools" IT_PRODUCT_IMAGE="$image" IT_NETWORK_GUARD_READY=1 GUARD_RUNNER_MANIFEST="$manifest" GUARD_RUNNER_ATTESTATION="$attestation" "${extra[@]}" bash -c "$script" _ "$source" "$manifest" "$attestation"
            return 0
            ;;
        probe) entry=(--live) ;;
        startup) entry=(--startup-integration) ;;
        *) return 2 ;;
    esac
    printf '%q ' env "${filter[@]}" IT_RUN_ID="$run" IT_EVIDENCE_DIR="$evidence" IT_NETWORK="gm-$run-net" IT_WITNESS_NETWORK="gm-$run-w-net" IT_DNS_IP=172.30.243.53 IT_TOOLS_IMAGE="$tools" IT_PRODUCT_IMAGE="$image" IT_NETWORK_GUARD_READY=1 bash "$source/tests/test-docker-network.sh" "${entry[@]}"
}

# 撤销指定下标之后安装的 generation 规则，保留基础链。
guard_remove_rules_since() {
    local start=$1 i table rule status=0
    local -a args keep=() retained=()
    for ((i=${#OWN_RULES[@]}-1;i>=start;i--)); do
        table=${OWN_RULES[i]%%|*}; rule=${OWN_RULES[i]#*|}
        read -ra args <<< "$rule"; args[0]=-D
        if ! iptables -t "$table" "${args[@]}"; then
            status=2
            retained+=("${OWN_RULES[i]}")
        fi
    done
    for ((i=0;i<start;i++)); do keep+=("${OWN_RULES[i]}"); done
    for ((i=${#retained[@]}-1;i>=0;i--)); do keep+=("${retained[i]}"); done
    OWN_RULES=("${keep[@]}")
    return "$status"
}

# 校验 PREPARING→ACTIVE→RELEASED generation 状态与绑定字段。
guard_mapping_generation() {
    local action=${1:-} generation=${2:-} network_id=${3:-} profile_sha256=${4:-}
    [[ $generation =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]] || return 65
    [[ -n $network_id && $profile_sha256 == "$MP_PROFILE_SHA256" ]] || return 65
    case "$action" in
        mapping-ready)
            [[ ${GUARD_MAPPING_STATE:-PREPARING} != ACTIVE ]] || return 65
            [[ $generation != "${GUARD_MAPPING_LAST_GENERATION:-}" ]] || return 65
            GUARD_MAPPING_STATE=ACTIVE GUARD_MAPPING_GENERATION=$generation GUARD_MAPPING_NETWORK_ID=$network_id
            ;;
        mapping-snapshot)
            [[ ${GUARD_MAPPING_STATE:-} == ACTIVE && $generation == "$GUARD_MAPPING_GENERATION" && $network_id == "$GUARD_MAPPING_NETWORK_ID" ]] || return 65
            ;;
        mapping-release)
            [[ ${GUARD_MAPPING_STATE:-} == ACTIVE && $generation == "$GUARD_MAPPING_GENERATION" && $network_id == "$GUARD_MAPPING_NETWORK_ID" ]] || return 65
            GUARD_MAPPING_STATE=RELEASED GUARD_MAPPING_LAST_GENERATION=$generation
            ;;
        *) return 65 ;;
    esac
    return 0
}

guard_mapping_release_verify() {
    local generation=${1:-} network_id=${2:-} profile_sha256=${3:-}
    local ledger kind ids key witness_id witness_net_id entry attachment
    [[ ${GUARD_MAPPING_STATE:-} == ACTIVE && $generation == "${GUARD_MAPPING_GENERATION:-}" && $network_id == "${GUARD_MAPPING_NETWORK_ID:-}" ]] || return 65
    [[ -n $generation && -n $network_id && $profile_sha256 == "$MP_PROFILE_SHA256" ]] || return 65
    validation_environment_verify "$GUARD_MANIFEST" "$GUARD_ATTESTATION" || return 2
    ledger=$E/control/resources
    [[ ${RESOURCE_LEDGER_DIR:-$ledger} == "$ledger" ]] || return 2
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$RUN
    resource_crosscheck "$ledger" || return 2
    resource_ledger_load "$ledger" || return 2
    witness_id=$(docker inspect -f '{{.Id}}' "gm-$RUN-witness") || return 2
    witness_net_id=$(docker network inspect -f '{{.Id}}' "gm-$RUN-w-net") || return 2
    [[ $witness_id =~ ^[0-9a-f]{64}$ && $witness_net_id =~ ^[0-9a-f]{64}$ ]] || return 2
    [[ $witness_id == "${GUARD_MAPPING_WITNESS_ID:-}" ]] || return 2
    entry=${RESOURCE_LEDGER_ACTIVE["container|$witness_id"]:-}
    [[ $entry == *'|mapping|witness|'* && $entry == *"|$RUN" ]] || return 2
    entry=${RESOURCE_LEDGER_ACTIVE["network|$witness_net_id"]:-}
    [[ $entry == *'|mapping|witness-network|'* && $entry == *"|$RUN" ]] || return 2
    resource_verify_object network "$witness_net_id" mapping witness-network '' || return 2
    guard_mapping_witness_identity >/dev/null || return 2
    attachment=$(docker inspect -f '{{(index .NetworkSettings.Networks "gm-'"$RUN"'-w-net").NetworkID}}' "$witness_id") || return 2
    [[ $attachment == "$witness_net_id" ]] || return 2
    for key in "${!RESOURCE_LEDGER_ACTIVE[@]}"; do
        [[ -z ${RESOURCE_LEDGER_ACTIVE[$key]:-} || $key == "container|$witness_id" || $key == "network|$witness_net_id" ]] || return 2
    done
    for kind in $RESOURCE_KINDS; do
        ids=$(resource_enumerate "$kind" "$RUN") || return 2
        case "$kind" in
            container) [[ $ids == "$witness_id" ]] || return 2 ;;
            network) [[ $ids == "$witness_net_id" ]] || return 2 ;;
            volume) [[ -z ${ids//[[:space:]]/} ]] || return 2 ;;
        esac
    done
    return 0
}

guard_mapping_release() {
    local generation=${1:-} network_id=${2:-} profile_sha256=${3:-} rules_start=${4:-}
    guard_mapping_release_verify "$generation" "$network_id" "$profile_sha256" || return $?
    if [[ ${#OWN_NS_RULES[@]} != 0 || ${#OWN_NS_CHAINS[@]} != 0 ]]; then
        guard_mapping_witness_remove || return 2
    fi
    guard_remove_rules_since "$rules_start" || return $?
    guard_mapping_generation mapping-release "$generation" "$network_id" "$profile_sha256"
}
# 映射网精确策略：只放行同网所需通信，其余 INPUT/转发、跨网、外 DNS 与 IPv6 一律拒绝。
# 源地址 P、桥接口与见证目标全部来自冻结档案，不复制旧 .4 规则。
guard_mapping_rules() {
    local profile=$1 network_id=$2
    local name bridge chain parent table c item key spec proto port dest
    [[ -n $profile && -n $network_id ]] || return 2
    mapping_profile_load "$profile" || return $?
    name=$(docker network inspect -f '{{.Name}}' "$network_id") || return $?
    [[ $name == "$MP_NETWORK_NAME" ]] || return 1
    bridge=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$network_id") || return $?
    [[ $bridge == "$MP_BRIDGE" ]] || return 1
    chain=M$MP_RUN_ID
    # 必要回复与精确允许：产品→U:443、产品→X:8443/8444、产品→D:53 U/TCP、代理→U:443。
    guard_rule filter -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_P/32" -d "$MP_U/32" -p tcp --dport 443 -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_P/32" -d "$MP_X/32" -p tcp --dport 8443 -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_P/32" -d "$MP_X/32" -p tcp --dport 8444 -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_P/32" -d "$MP_D/32" -p udp --dport 53 -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_P/32" -d "$MP_D/32" -p tcp --dport 53 -j ACCEPT
    guard_rule filter -A "$chain" -i "$bridge" -o "$bridge" -s "$MP_X/32" -d "$MP_U/32" -p tcp --dport 443 -j ACCEPT
    # 五类见证目标精确 DROP：源为 P、桥为 m$RUN，评论键与本轮 run 绑定。
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key") || return 1
        IFS=$'\t' read -r proto port dest <<< "$spec"
        guard_rule raw -A "ME$MP_RUN_ID" -i "$bridge" -s "$MP_P/32" -d "$dest/32" -p "$proto" -m "$proto" --dport "$port" -m comment --comment "$MP_RUN_ID-$key" -j DROP
    done
    guard_rule filter -A "$chain" -j DROP
    for parent in INPUT DOCKER-USER FORWARD; do
        guard_rule filter -I "$parent" -i "$bridge" -j "$chain"
    done
    guard_rule raw -I PREROUTING -i "$bridge" -j "ME$MP_RUN_ID"
    return 0
}
# 保存映射两端原始计数：发起端 iptables-save -c 与接收端见证链。
guard_mapping_snapshot() {
    local seq=$1 generation=$2 network_id=$3 profile_sha256=$4 target=${5:-} pid counts receipt temporary rules_sha witness_sha
    mapping_witness_key_valid "$target" || return 80
    iptables-save -c > "$E/mapping-snapshot-$seq.rules" || return 80
    pid=$(guard_mapping_witness_identity) || return 80
    nsenter -t "$pid" -n iptables -t raw -nvxL "MS$RUN" > "$E/mapping-snapshot-$seq.witness" || return 80
    counts=$(mapping_witness "$E/mapping-snapshot-$seq.witness") || return 80
    [[ -n $counts ]] || return 80
    chmod a+r "$E/mapping-snapshot-$seq.rules" "$E/mapping-snapshot-$seq.witness" || return 80
    rules_sha=$(sha256sum "$E/mapping-snapshot-$seq.rules") || return 80
    witness_sha=$(sha256sum "$E/mapping-snapshot-$seq.witness") || return 80
    rules_sha=${rules_sha%% *}
    witness_sha=${witness_sha%% *}
    [[ $rules_sha =~ ^[0-9a-f]{64}$ && $witness_sha =~ ^[0-9a-f]{64}$ ]] || return 80
    receipt="$E/mapping-snapshot-$seq.receipt"
    [[ ! -e $receipt && ! -L $receipt ]] || return 80
    temporary=$(mktemp "$E/.mapping-snapshot-$seq.XXXXXXXX") || return 80
    if ! printf 'target\t%s\nseq\t%s\ngeneration\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s\n' \
        "$target" "$seq" "$generation" "$network_id" "$profile_sha256" "$rules_sha" "$witness_sha" > "$temporary" || \
        ! chmod 644 "$temporary" || ! mv -T -- "$temporary" "$receipt"; then
        rm -f -- "$temporary"
        return 80
    fi
    return 0
}

# 固定目录的设备号、inode 与规范路径，供 READY 状态写入各阶段复核。
guard_mapping_directory_identity() {
    local directory=$1 canonical device inode
    [[ -d $directory && ! -L $directory ]] || return 1
    canonical=$(readlink -f -- "$directory") || return 1
    [[ $canonical == "$directory" ]] || return 1
    read -r device inode < <(stat -Lc '%d %i' -- "$directory") || return 1
    [[ -n $device && -n $inode ]] || return 1
    printf '%s\t%s\t%s\n' "$device" "$inode" "$canonical"
}

guard_mapping_state_write() {
    local state=$1 generation=$2 network_id=$3 profile_sha256=$4 temporary parent generations runner_gid identity
    parent=${state%/*}
    generations=${parent%/*}
    ! mapping_path_is_symlink "$state" || return 80
    runner_gid=$(id -g "$RUNNER") || return 80
    identity=$(guard_mapping_directory_identity "$generations") || return 80
    chown -h "0:$runner_gid" "$generations" || return 80
    chmod 1770 "$generations" || return 80
    [[ $(guard_mapping_directory_identity "$generations") == "$identity" ]] || return 80
    identity=$(guard_mapping_directory_identity "$parent") || return 80
    chown -h "0:$runner_gid" "$parent" || return 80
    chmod 750 "$parent" || return 80
    [[ $(guard_mapping_directory_identity "$parent") == "$identity" ]] || return 80
    temporary=$(mktemp "$parent/.mapping-network.XXXXXXXX") || return 80
    if ! printf 'generation\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\n' "$generation" "$network_id" "$profile_sha256" > "$temporary"; then
        rm -f -- "$temporary"
        return 80
    fi
    if [[ $(guard_mapping_directory_identity "$parent") != "$identity" ]] || mapping_path_is_symlink "$state" || ! mv -T -- "$temporary" "$state"; then
        rm -f -- "$temporary"
        return 80
    fi
    if [[ $(guard_mapping_directory_identity "$parent") != "$identity" ]] || mapping_path_is_symlink "$state" || [[ ! -f $state ]]; then
        return 80
    fi
    chown -h "0:$runner_gid" "$state" || return 80
    chmod 640 "$state" || return 80
    [[ $(guard_mapping_directory_identity "$parent") == "$identity" ]] || return 80
    guard_gm test -r "$state" || return 80
    return 0
}

# 以 root 独占临时文件和不可覆盖硬链接原子发布 ACK。
guard_mapping_ack_publish() {
    local control=$1 identity=$2 ack_seq=$3 nonce=$4 generation=$5 target temporary runner_gid
    target=$control/ack-$ack_seq
    [[ $(guard_mapping_directory_identity "$control") == "$identity" ]] || return 80
    [[ ! -e $target && ! -L $target ]] || return 80
    runner_gid=$(id -g "$RUNNER") || return 80
    temporary=$(mktemp "$control/.ack-$ack_seq.XXXXXXXX") || return 80
    if ! chown -h "0:$runner_gid" "$temporary" || ! chmod 640 "$temporary" || ! printf '%s %s\n' "$nonce" "$generation" > "$temporary"; then
        rm -f -- "$temporary"
        return 80
    fi
    if [[ $(guard_mapping_directory_identity "$control") != "$identity" ]] || [[ -e $target || -L $target ]] || ! ln -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 80
    fi
    rm -f -- "$temporary" || return 80
    [[ $(guard_mapping_directory_identity "$control") == "$identity" && -f $target && ! -L $target ]] || return 80
    guard_gm test -r "$target" || return 80
    guard_gm test ! -w "$target" || return 80
    return 0
}

# 创建 root:runner 1770 控制根，供 runner 新建请求且不能替换其他主体的目录项。
guard_mapping_control_prepare() {
    local runner_gid
    runner_gid=$(id -g "$RUNNER") || return 80
    mkdir "$E/control" || return 80
    chown "0:$runner_gid" "$E/control" || return 80
    chmod 1770 "$E/control" || return 80
    GUARD_MAPPING_CONTROL_IDENTITY=$(guard_mapping_directory_identity "$E/control") || return 80
}

# 激活 READY：先迁移状态并安装规则，再通过安全写入器固化本代 network state。
guard_mapping_ready_activate() {
    local generation=$1 network_id=$2 profile_sha256=$3 state
    guard_mapping_generation mapping-ready "$generation" "$network_id" "$profile_sha256" || return $?
    rules_start=${#OWN_RULES[@]}
    guard_mapping_rules "$GUARD_PROFILE" "$network_id" || return $?
    guard_mapping_witness_install || return 80
    IT_CONTROL_DIR=$E/control
    state=$(MAPPING_ASSERT_GENERATION="$generation" mapping_network_state_file) || return 80
    mkdir -p "${state%/*}" || return 80
    guard_mapping_state_write "$state" "$generation" "$network_id" "$profile_sha256" || return $?
    return 0
}

# 统一处理专用 mapping 与 full 的三类 mapping 控制请求，并在成功后写 ACK。
guard_mapping_request_handle() {
    local request=$1 generation=$2 network_id=$3 profile_sha256=$4 nonce=$5 target=${6:-}
    [[ -n $nonce && $nonce != "$last_nonce" ]] || return 65
    case "$request" in
        mapping-ready) guard_mapping_ready_activate "$generation" "$network_id" "$profile_sha256" || return $? ;;
        mapping-snapshot)
            mapping_witness_key_valid "$target" || return 65
            guard_mapping_generation "$request" "$generation" "$network_id" "$profile_sha256" || return $?
            guard_mapping_snapshot "$seq" "$generation" "$network_id" "$profile_sha256" "$target" || return $?
            ;;
        mapping-release) guard_mapping_release "$generation" "$network_id" "$profile_sha256" "$rules_start" || return $? ;;
        *) return 65 ;;
    esac
    [[ -n ${GUARD_MAPPING_CONTROL_IDENTITY:-} ]] || return 80
    guard_mapping_ack_publish "$E/control" "$GUARD_MAPPING_CONTROL_IDENTITY" "$seq" "$nonce" "$generation" || return $?
    last_nonce=$nonce
    seq=$((seq + 1))
    return 0
}

# full 控制循环只通过统一处理器分派 mapping 请求。
guard_full_mapping_request() {
    guard_mapping_request_handle "$@"
}
# 映射模式专属生命周期：冻结档案、建立拒绝基线、READY 绑定档案哈希与 network ID 后才放行业务。
guard_mapping_main() {
    local mode=$1 source=$2 run=$3 evidence=$4 image=$5 tools=$6 manifest=$7 attestation=$8 profile=$9
    local bridge chain early returnc seq=1 ready=0 rc=0 request nonce sha netid generation target rules_start last_nonce='' state
    local existing routes resources links rules table c ids parent command
    [[ -n $profile && -f $profile ]] || return 2
    mapping_profile_load "$profile" || return $?
    # 冻结档案的 run_id 必须与 --run-id 一致，否则链名与规则评论键将互相错位。
    [[ $MP_RUN_ID == "$RUN" ]] || return 70
    GUARD_SOURCE=$source
    GUARD_MANIFEST=$manifest
    GUARD_ATTESTATION=$attestation
    GUARD_PROFILE=$profile
    GUARD_BOUND=1
    [[ $E != /tmp/* && $E != /var/tmp/* && ! -e $E ]] || return 73
    [[ $(id -u "$RUNNER") != 0 ]] || return 77
    bridge=$MP_BRIDGE
    chain=M$RUN early=ME$RUN returnc=MR$RUN seen=MS$RUN
    ids=$(docker network ls -q) || return $?
    existing=''
    if [[ -n $ids ]]; then
        existing=$(docker network inspect $ids --format '{{range .IPAM.Config}}{{if .Subnet}}{{.Subnet}}{{println}}{{end}}{{end}}') || return $?
    fi
    routes=$(ip -4 route show) || return $?
    routes=$(awk '$1!="default" {print $1}' <<< "$routes") || return $?
    existing+=$'\n'"$routes"
    guard_subnets_clear "$existing" || return 70
    resources=$(docker ps -a --format '{{.Names}}') || return $?
    if grep -F "gm-$RUN-" <<< "$resources"; then return 70; fi
    resources=$(docker network ls --format '{{.Name}}') || return $?
    if grep -Fx "$MP_NETWORK_NAME" <<< "$resources"; then return 70; fi
    resources=$(docker volume ls --format '{{.Name}}') || return $?
    if grep -F "gm-$RUN-" <<< "$resources"; then return 70; fi
    links=$(ip link show) || return $?
    if grep -Eq "^[0-9]+: ${bridge}(@[^:]+)?:" <<< "$links"; then return 70; fi
    rules=$(iptables-save) || return $?
    for c in "$chain" "$early" "$returnc"; do
        if grep -w "$c" <<< "$rules"; then return 70; fi
    done
    mkdir -p "$E"
    chmod 755 "$E"
    guard_mapping_control_prepare || return $?
    printf '%s\n' "$existing" > "$E/subnets-before.txt"
    sha256sum "$source"/tests/*.sh "$source"/tests/docker-dns-tools.Dockerfile "$source"/Dockerfile "$source"/compose.yml > "$E/inputs.sha256" || return 80
    sha256sum "$E/inputs.sha256" | cut -d' ' -f1 > "$E/inputs.sha256.digest" || return 80
    chmod 644 "$E/inputs.sha256" "$E/inputs.sha256.digest" || return 80
    if [[ -d $source/.git ]]; then
        git -C "$source" status --short > "$E/git-state.txt"
    else
        cp "$source/input-git-state.txt" "$E/git-state.txt"
    fi
    docker image inspect "$image" "$tools" > "$E/images.json"
    iptables-save -c > "$E/rules-before.txt"
    printf 'Run=%s\nOnly reverse listed rules and remove registered resources after SIGKILL; never flush global tables.\n' "$RUN" > "$E/recovery.txt"
    trap guard_cleanup EXIT
    trap 'PENDING_SIGNAL=143' TERM
    trap 'PENDING_SIGNAL=130' INT
    for spec in "filter|$chain" "raw|$early" "raw|$returnc"; do
        table=${spec%%|*}
        c=${spec#*|}
        iptables -t "$table" -N "$c"
        OWN_CHAINS+=("$spec")
        printf '%s\n' "$spec" >> "$E/chains.owned"
        guard_signal_checkpoint
    done
    command=$(guard_runner_command "$mode" "$source" "$RUN" "$E" "$image" "$tools" "$manifest" "$attestation" "$profile")
    printf -v command 'su -s /bin/bash %q -c %q; rc=$?; printf "BUSINESS_SU_EXIT=%%s\\n" "$rc" > %q; exit "$rc"' "$RUNNER" "$command" "$E/business-su-status.txt"
    setsid bash -c "$command" > "$E/run.log" 2>&1 &
    CHILD=$!
    guard_signal_checkpoint
    while [[ ! -f $E/control/runner-handshake.tsv ]]; do
        guard_signal_checkpoint
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 0.1
    done
    guard_signal_checkpoint
    validation_runner_verify "$manifest" "$E/control/runner-handshake.tsv" || exit $?
    touch "$E/control/prepare-start"
    while kill -0 "$CHILD" 2>/dev/null; do
        guard_signal_checkpoint
        if [[ -f $E/control/request-$seq ]]; then
            read -r request generation netid sha target nonce < "$E/control/request-$seq"
            case "$request" in
                mapping-ready|mapping-release)
                    guard_mapping_request_handle "$request" "$generation" "$netid" "$sha" "$target" || exit $?
                    [[ $request != mapping-ready ]] || ready=1
                    [[ $request != mapping-release ]] || ready=0
                    ;;
                mapping-snapshot)
                    guard_mapping_request_handle "$request" "$generation" "$netid" "$sha" "$nonce" "$target" || exit $?
                    ;;
                *) exit 65 ;;
            esac
        fi
        sleep 0.1
    done
    guard_signal_checkpoint
    [[ ${GUARD_MAPPING_STATE:-} == RELEASED || $mode == mapping-probe ]] || exit 65
    wait "$CHILD" || rc=$?
    guard_signal_checkpoint
    CHILD=''
    printf 'SETSID_WAIT_EXIT=%s\n' "$rc" >> "$E/exit-status.txt"
    return "$rc"
}
# 固定入口解析、宿主预检、规则安装以及降权执行。
guard_main() {
    local mode='' source='' image='' tools='' manifest='' attestation='' profile='' existing table chain parent bridge seq request token pid command rc=0 ids routes resources links rules
    local generation netid sha nonce rules_start last_nonce=''
    RUN='' E='' RUNNER='' GUARD_MAPPING_CONTROL_IDENTITY=''
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
    case "$mode" in probe|o1|c2|full|startup|mapping-fallback|mapping-direct|mapping-probe|mapping-sequence) ;; *) return 2 ;; esac
    # 新 full/mapping 路径必须绑定环境授权清单，缺参即拒绝。
    case "$mode" in
        full|mapping-fallback|mapping-direct|mapping-probe|mapping-sequence)
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
            mapping_profile_load "$profile" || return $?
            [[ $MP_RUN_ID == "$RUN" ]] || return 70
            GUARD_BOUND=1
            ;;
        mapping-sequence)
            GUARD_MANIFEST=$manifest GUARD_ATTESTATION=$attestation GUARD_PROFILE=$profile
            validation_environment_verify "$manifest" "$attestation" || return $?
            GUARD_BOUND=1
            guard_mapping_main "$mode" "$source" "$RUN" "$E" "$image" "$tools" "$manifest" "$attestation" "$profile"
            return $?
            ;;
        mapping-fallback|mapping-direct|mapping-probe)
            GUARD_MANIFEST=$manifest GUARD_ATTESTATION=$attestation GUARD_PROFILE=$profile
            validation_environment_verify "$manifest" "$attestation" || return $?
            # 映射网络与拒绝证据按接口 C 接入：先冻结档案与拒绝基线，READY 后再放行业务。
            guard_mapping_main "$mode" "$source" "$RUN" "$E" "$image" "$tools" "$manifest" "$attestation" "$profile"
            return $?
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
    if [[ $mode == full ]]; then
        guard_mapping_control_prepare || return $?
    else
        mkdir "$E/control"; chown "$RUNNER" "$E/control"
    fi
    printf '%s\n' "$existing" > "$E/subnets-before.txt"
    sha256sum "$source"/tests/*.sh "$source"/tests/docker-dns-tools.Dockerfile "$source"/Dockerfile "$source"/compose.yml > "$E/inputs.sha256" || return 80
    sha256sum "$E/inputs.sha256" | cut -d' ' -f1 > "$E/inputs.sha256.digest" || return 80
    chmod 644 "$E/inputs.sha256" "$E/inputs.sha256.digest" || return 80
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
    if [[ $mode == full ]]; then
        for spec in "filter|M$RUN" "raw|ME$RUN" "raw|MR$RUN"; do
            table=${spec%%|*}; chain=${spec#*|}
            iptables -t "$table" -N "$chain"; OWN_CHAINS+=("$spec")
            printf '%s\n' "$spec" >> "$E/chains.owned"
            guard_signal_checkpoint
        done
    fi
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
    while [[ ! -f $E/control/runner-handshake.tsv && ! -f $E/control/runner.pid ]]; do
        guard_signal_checkpoint
        kill -0 "$CHILD" 2>/dev/null || break
        sleep 0.1
    done
    guard_signal_checkpoint
    if [[ -f $E/control/runner-handshake.tsv ]]; then
        validation_runner_verify "$manifest" "$E/control/runner-handshake.tsv" || exit $?
        touch "$E/control/prepare-start"
    else
        touch "$E/control/start"
    fi
    seq=1
    while kill -0 "$CHILD" 2>/dev/null; do
        guard_signal_checkpoint
        if [[ -f $E/control/request-$seq ]]; then
            read -r request token netid sha nonce < "$E/control/request-$seq"
            case "$request" in
                mapping-ready|mapping-snapshot|mapping-release)
                    generation=$token
                    guard_full_mapping_request "$request" "$generation" "$netid" "$sha" "$nonce" || exit $?
                    ;;
                witness)
                    [[ -n $token ]] || exit 65
                    pid=$(docker inspect -f '{{.State.Pid}}' "gm-$RUN-witness")
                    nsenter -t "$pid" -n iptables -t raw -N "$SEEN"
                    for spec in 'tcp 19419' 'udp 53' 'tcp 53'; do read -r proto port <<< "$spec"; nsenter -t "$pid" -n iptables -t raw -A "$SEEN" -p "$proto" --dport "$port" -j RETURN; done
                    nsenter -t "$pid" -n iptables -t raw -I PREROUTING -j "$SEEN"
                    ;;
                close)
                    [[ -n $token ]] || exit 65
                    guard_close_calibration
                    guard_rule raw -A "$EARLY" -d 172.30.244.0/24 -j DROP
                    guard_rule raw -A "$RETURN" -d 172.30.243.0/24 -j DROP
                    ;;
                snapshot)
                    [[ -n $token ]] || exit 65
                    guard_snapshot "$seq"
                    ;;
                *) exit 65 ;;
            esac
            if [[ $request != mapping-* ]]; then
                printf '%s\n' "$token" > "$E/control/ack-$seq.tmp"
                mv "$E/control/ack-$seq.tmp" "$E/control/ack-$seq"
                seq=$((seq + 1))
            fi
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
