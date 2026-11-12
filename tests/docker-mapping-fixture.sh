#!/usr/bin/env bash
# Mapping 独立网络、策略与双 CA 夹具。
# 冻结地址档案、独立映射网络、按角色的附件/地址/安全校验、封闭拒绝策略与两端计数解析；
# 双 CA 资产、CONNECT 直拨 U 的代理循环、受控 DNS 与非递归解析。
# 本文件不安装真实规则、不启动业务进程。

MAPPING_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 只读复用产品公网地址校验器，绝不改写或放宽校验规则。
if [[ -z ${MAPPING_FOUNDATION_LOADED:-} && -f $MAPPING_DIR/../scripts/lib/foundation.sh ]]; then
    MAPPING_FOUNDATION_LOADED=1
    source "$MAPPING_DIR/../scripts/lib/foundation.sh"
fi

# 硬编码契约参数。
MAPPING_CONTRACT_SCHEMA_VERSION='1'
MAPPING_PROFILE_KEYS='schema_version run_id cidr gateway P U X D N network_name bridge'
MAPPING_PROFILE_KEY_COUNT=11
MAPPING_ROLES='product upstream proxy dns probe'
MAPPING_WITNESS_KEYS='cross-network host-published host-input dns-udp dns-tcp'
MAPPING_MIN_PREFIX=8
MAPPING_MAX_PREFIX=30
# 资源账本登记用的场景与角色标签；与创建命令携带的三 label 保持一致。
MAPPING_LEDGER_SCENARIO='mapping'
MAPPING_LEDGER_ROLE='network'

# 只读档案字段，由 mapping_profile_load 填充。
MP_SCHEMA_VERSION=''
MP_RUN_ID=''
MP_CIDR=''
MP_GATEWAY=''
MP_P=''
MP_U=''
MP_X=''
MP_D=''
MP_N=''
MP_NETWORK_NAME=''
MP_BRIDGE=''
MP_PROFILE_SHA256=''
MP_NETWORK_INT=''
MP_NETWORK_BROADCAST=''
# 运行状态：创建后冻结的不可变 network ID 与见证校准标记。
MP_NETWORK_ID=''
MP_WITNESS_CALIBRATED=0
MP_WITNESS_BASELINE=''

# 冻结见证表（key / protocol / port / destination）；source=P、bridge=m$RUN 由档案推导。
mapping_witness_rows() {
    printf 'cross-network\ttcp\t19419\t172.30.244.53\n'
    printf 'host-published\ttcp\t49382\t172.30.243.1\n'
    printf 'host-input\ttcp\t49383\t172.30.243.1\n'
    printf 'dns-udp\tudp\t53\t172.30.244.53\n'
    printf 'dns-tcp\ttcp\t53\t172.30.244.53\n'
}

# 单个见证键的协议/端口/目的；未知键返回非零。
mapping_witness_spec() {
    local key=$1 row row_key
    while IFS=$'\t' read -r row_key row; do
        [[ $row_key == "$key" ]] || continue
        printf '%s\n' "$row"
        return 0
    done < <(mapping_witness_rows)
    return 1
}

# 见证键是否合法。
mapping_witness_key_valid() {
    case " $MAPPING_WITNESS_KEYS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 传给解析器的见证表串：key|proto|port|dest;...
mapping_witness_table_string() {
    local key spec proto port dest out=''
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key") || continue
        IFS=$'\t' read -r proto port dest <<< "$spec"
        out+="$key|$proto|$port|$dest;"
    done
    printf '%s\n' "${out%;}"
}

# IPv4 转整数；非法输入返回非零。
mapping_ipv4_int() {
    local ip=$1 a b c d
    gm_validate_address "$ip" >/dev/null 2>&1 || return 1
    [[ $ip != *:* ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    [[ -n $a && -n $b && -n $c && -n $d ]] || return 1
    printf '%s\n' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

# 计算 CIDR 的网络地址与广播地址；要求给定地址即网络地址本身。
mapping_cidr_bounds() {
    local cidr=$1 ip prefix mask base
    [[ $cidr == */* ]] || return 1
    ip=${cidr%%/*}
    prefix=${cidr#*/}
    [[ $ip != "$cidr" && $prefix =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#$prefix >= MAPPING_MIN_PREFIX && 10#$prefix <= MAPPING_MAX_PREFIX )) || return 1
    base=$(mapping_ipv4_int "$ip") || return 1
    mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    MP_NETWORK_INT=$(( base & mask ))
    MP_NETWORK_BROADCAST=$(( MP_NETWORK_INT | (~mask & 0xFFFFFFFF) ))
    (( base == MP_NETWORK_INT )) || return 1
    return 0
}

# 地址是否严格位于子网内（排除网络地址与广播地址）。
mapping_in_subnet() {
    local value
    value=$(mapping_ipv4_int "$1") || return 1
    (( value > MP_NETWORK_INT && value < MP_NETWORK_BROADCAST ))
}

# 复用产品校验器判定公网地址，不新增任何放宽。
mapping_public_address() {
    gm_hosts_public_address "$1"
}

# 严格解析冻结档案：返回 0，格式错误 2，冲突 70；成功后填充只读 MP_* 字段。
mapping_profile_load() {
    local path=${1:-} line key value want count i
    local -a keys=() values=()
    [[ $# == 1 && -n $path ]] || return 2
    [[ -f $path && ! -L $path && -r $path ]] || return 2
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 2
        [[ $line != *$'\r'* ]] || return 2
        key=${line%%$'\t'*}
        value=${line#*$'\t'}
        [[ $key != "$line" && -n $key && -n $value ]] || return 2
        [[ $value != *$'\t'* ]] || return 2
        keys+=("$key")
        values+=("$value")
    done < "$path"
    [[ ${#keys[@]} == "$MAPPING_PROFILE_KEY_COUNT" ]] || return 2
    for want in $MAPPING_PROFILE_KEYS; do
        count=0
        for key in "${keys[@]}"; do
            if [[ $key == "$want" ]]; then count=$((count + 1)); fi
        done
        [[ $count == 1 ]] || return 2
    done
    MP_SCHEMA_VERSION='' MP_RUN_ID='' MP_CIDR='' MP_GATEWAY=''
    MP_P='' MP_U='' MP_X='' MP_D='' MP_N=''
    MP_NETWORK_NAME='' MP_BRIDGE='' MP_PROFILE_SHA256=''
    MP_NETWORK_INT='' MP_NETWORK_BROADCAST=''
    for i in "${!keys[@]}"; do
        case "${keys[i]}" in
            schema_version) MP_SCHEMA_VERSION=${values[i]} ;;
            run_id) MP_RUN_ID=${values[i]} ;;
            cidr) MP_CIDR=${values[i]} ;;
            gateway) MP_GATEWAY=${values[i]} ;;
            P) MP_P=${values[i]} ;;
            U) MP_U=${values[i]} ;;
            X) MP_X=${values[i]} ;;
            D) MP_D=${values[i]} ;;
            N) MP_N=${values[i]} ;;
            network_name) MP_NETWORK_NAME=${values[i]} ;;
            bridge) MP_BRIDGE=${values[i]} ;;
            *) return 2 ;;
        esac
    done
    [[ $MP_SCHEMA_VERSION == "$MAPPING_CONTRACT_SCHEMA_VERSION" ]] || return 2
    [[ $MP_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 2
    mapping_cidr_bounds "$MP_CIDR" || return 2
    [[ $MP_NETWORK_NAME == "gm-$MP_RUN_ID-m-net" ]] || return 70
    [[ $MP_BRIDGE == "m$MP_RUN_ID" ]] || return 70
    local -a hosts=()
    for value in "$MP_GATEWAY" "$MP_P" "$MP_U" "$MP_X" "$MP_D" "$MP_N"; do
        gm_validate_address "$value" >/dev/null 2>&1 || return 2
        [[ $value != *:* ]] || return 2
    done
    mapping_in_subnet "$MP_GATEWAY" || return 70
    for key in MP_P MP_U MP_X MP_D MP_N; do
        value=${!key}
        mapping_in_subnet "$value" || return 70
        [[ $value != "$MP_GATEWAY" ]] || return 70
        for want in "${hosts[@]}"; do
            [[ $want != "$value" ]] || return 70
        done
        hosts+=("$value")
    done
    # U 与负例用的未分配地址 N 必须通过未修改的产品公网校验器。
    mapping_public_address "$MP_U" || return 70
    mapping_public_address "$MP_N" || return 70
    MP_PROFILE_SHA256=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1) || return 2
    [[ -n $MP_PROFILE_SHA256 ]] || return 2
    return 0
}

# 状态目录：优先证据控制目录，其次映射账本目录；两处都不存在即拒绝。
mapping_state_dir() {
    if [[ -n ${IT_CONTROL_DIR:-} ]]; then
        printf '%s\n' "$IT_CONTROL_DIR"
        return 0
    fi
    if [[ -n ${MAPPING_LEDGER_DIR:-} ]]; then
        printf '%s\n' "$MAPPING_LEDGER_DIR"
        return 0
    fi
    return 1
}

mapping_path_is_symlink() {
    [[ -L $1 ]]
}

# 运行状态文件：创建后追加不可变 network ID，不反写输入档案。
mapping_network_state_file() {
    local dir file generation=${MAPPING_ASSERT_GENERATION:-${MAPPING_GENERATION:-}}
    dir=$(mapping_state_dir) || return 1
    [[ $generation =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]] || return 1
    [[ $dir == /* && -d $dir ]] || return 1
    [[ $(readlink -f -- "$dir") == "$dir" ]] || return 1
    [[ ! -e $dir/generations || ( -d $dir/generations && ! -L $dir/generations ) ]] || return 1
    [[ ! -e $dir/generations/$generation || ( -d $dir/generations/$generation && ! -L $dir/generations/$generation ) ]] || return 1
    file=$dir/generations/$generation/mapping-network.tsv
    ! mapping_path_is_symlink "$file" || return 1
    [[ ! -e $file || -f $file ]] || return 1
    printf '%s\n' "$file"
}

# 读取已冻结的本轮 network ID（缺失返回非零）。
mapping_network_id_load() {
    local file line key value
    file=$(mapping_network_state_file) || return 1
    [[ -f $file && ! -L $file ]] || return 1
    while IFS=$'\t' read -r key value; do
        [[ $key == network_id && -n $value ]] || continue
        printf '%s\n' "$value"
        return 0
    done < "$file"
    return 1
}

# 通过资源账本创建本轮映射网络并登记；创建命令必须携带 run/scenario/role 三 label。
# 独立 internal bridge：外部路由由 Docker 侧先隔离，guard 的精确规则是附加约束而非唯一防线。
# 身份写入运行状态，返回 network ID。调用者由编排接线提供。
mapping_network_create() {
    local profile=${1:-} ledger_dir=${2:-} scenario=${3:-$MAPPING_LEDGER_SCENARIO} id state
    [[ -n $profile && -n $ledger_dir ]] || return 2
    [[ $scenario == "$MAPPING_LEDGER_SCENARIO" ]] || mapping_scenario_valid "$scenario" || return 2
    mapping_profile_load "$profile" || return $?
    state=$(mapping_network_state_file 2>/dev/null) || return 2
    [[ -z $state || ! -s $state ]] || return 2
    if ! declare -F resource_create_register >/dev/null; then return 2; fi
    RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$MP_RUN_ID
    resource_create_register network "$scenario" "$MAPPING_LEDGER_ROLE" -- \
        resource_docker network create \
        --label "gitdaemon.run=$MP_RUN_ID" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$MAPPING_LEDGER_ROLE" \
        --ipv6=false --internal --subnet "$MP_CIDR" -o "com.docker.network.bridge.name=$MP_BRIDGE" \
        "$MP_NETWORK_NAME" || return $?
    id=$RESOURCE_CREATED_ID
    [[ -n $id ]] || return 2
    MP_NETWORK_ID=$id
    if [[ -n $state ]]; then
        mkdir -p "${state%/*}" || return 2
        printf 'network_id\t%s\n' "$id" >> "$state" || return 2
    fi
    printf '%s\n' "$id"
}

# 发送 READY 握手：payload 只引用冻结档案哈希与 network ID，不携带任意规则。
mapping_ready() {
    local profile=${1:-} network_id=${2:-} generation=${3:-}
    mapping_profile_load "$profile" || return $?
    [[ -n $network_id && -n $generation ]] || return 2
    mapping_control_request mapping-ready "$generation" "$network_id" "$MP_PROFILE_SHA256"
}

# 准备阶段只登记离线资产与网络，不启动任何联网容器。
mapping_prepare() {
    local profile=${1:-} scenario=${2:-} product_image=${3:-} tools_image=${4:-} ledger witness_id network_id attachment facts key entry
    [[ -n $profile && -n $scenario && -n $product_image && -n $tools_image ]] || return 80
    mapping_scenario_valid "$scenario" || return 80
    mapping_profile_load "$profile" || return 80
    ledger=$(resource_ledger_dir) || return 80
    mapping_assets_prepare "$profile" "$scenario" "$product_image" "$ledger" || return 80
    mapping_evidence_volume_prepare "$tools_image" || return 80
    mapping_evidence_volume_verify "$tools_image" || return 80
    mapping_network_create "$profile" "$ledger" "$scenario" >/dev/null || return 80
    mapping_fixture_precheck || return 80
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_crosscheck "$ledger" || return 80
    witness_id=$(mapping_fixture_docker inspect -f '{{.Id}}' "gm-$MP_RUN_ID-witness" 2>/dev/null) || witness_id=''
    network_id=$(resource_docker network inspect -f '{{.Id}}' "gm-$MP_RUN_ID-w-net" 2>/dev/null) || network_id=''
    if [[ -n $witness_id || -n $network_id ]]; then
        [[ $witness_id =~ ^[0-9a-f]{64}$ && $network_id =~ ^[0-9a-f]{64}$ ]] || return 80
        [[ ${RESOURCE_LEDGER_ACTIVE["container|$witness_id"]:-} == *'|mapping|witness|'* && ${RESOURCE_LEDGER_ACTIVE["network|$network_id"]:-} == *'|mapping|witness-network|'* ]] || return 80
        resource_verify_object container "$witness_id" mapping witness '' || return 80
        resource_verify_object network "$network_id" mapping witness-network '' || return 80
        facts=$(mapping_fixture_docker inspect -f '{{.HostConfig.NetworkMode}}|{{.State.Running}}' "$witness_id") || return 80
        [[ $facts == "gm-$MP_RUN_ID-w-net|true" ]] || return 80
        attachment=$(mapping_fixture_docker inspect -f '{{(index .NetworkSettings.Networks "gm-'"$MP_RUN_ID"'-w-net").NetworkID}}' "$witness_id") || return 80
        [[ $attachment == "$network_id" ]] || return 80
        return 0
    fi
    for key in "${!RESOURCE_LEDGER_ACTIVE[@]}"; do
        entry=${RESOURCE_LEDGER_ACTIVE[$key]:-}
        [[ $entry != *'|mapping|witness|'* && $entry != *'|mapping|witness-network|'* ]] || return 80
    done
    resource_create_register network mapping witness-network -- \
        resource_docker network create \
        --label "gitdaemon.run=$MP_RUN_ID" --label gitdaemon.scenario=mapping \
        --label gitdaemon.role=witness-network --ipv6=false \
        --subnet 172.30.244.0/24 -o "com.docker.network.bridge.name=w$MP_RUN_ID" \
        "gm-$MP_RUN_ID-w-net" || return 80
    mapping_fixture_run mapping witness -d --name "gm-$MP_RUN_ID-witness" \
        $MAPPING_SAFE_OPTIONS --network "gm-$MP_RUN_ID-w-net" --ip 172.30.244.53 \
        --dns 172.30.244.53 -p 172.30.243.1:49382:19419 -p 172.30.243.1:49383:19420 \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$MAPPING_DNS_PORT" \
        --entrypoint /bin/sh "$tools_image" \
        -c 'busybox nc -lk -p 19419 -e /bin/cat & busybox nc -lk -p 19420 -e /bin/cat & exec dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon' >/dev/null || return 80
    mapping_fixture_wait "gm-$MP_RUN_ID-witness" || return 80
    return 0
}

# generation 获得 guard ACK 后才允许启动联网夹具。
mapping_activate() {
    local generation=${1:-}
    [[ -n $generation && ${MAPPING_ACK_GENERATION:-} == "$generation" ]] || return 65
    return 0
}

# 角色化策略校验：单一映射网络附件、冻结地址、非 root 只读安全属性。
# 返回 0 通过，1 表示实际配置不符；缺少前置或档案错误返回原错误。
mapping_policy_check() {
    local id=${1:-} role=${2:-} profile=${3:-} expected_ip networks ip netid value
    [[ -n $id && -n $role && -n $profile ]] || return 1
    mapping_profile_load "$profile" || return $?
    case " $MAPPING_ROLES " in
        *" $role "*) ;;
        *) return 1 ;;
    esac
    case "$role" in
        product|probe) expected_ip=$MP_P ;;
        upstream) expected_ip=$MP_U ;;
        proxy) expected_ip=$MP_X ;;
        dns) expected_ip=$MP_D ;;
    esac
    networks=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id") || return $?
    [[ ${networks% } == "$MP_NETWORK_NAME" ]] || return 1
    netid=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}} {{end}}' "$id") || return $?
    netid=${netid% }
    if [[ -n ${MP_NETWORK_ID:-} ]]; then
        [[ $netid == "$MP_NETWORK_ID" ]] || return 1
    fi
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$id") || return $?
    [[ ${ip% } == "$expected_ip" ]] || return 1
    value=$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Privileged}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$id") || return $?
    case "$value" in
        '10001:10001 true false [ALL] [no-new-privileges]'|'10001:10001 true false [ALL] [no-new-privileges:true]') ;;
        *) return 1 ;;
    esac
    [[ $(docker inspect -f '{{.HostConfig.ExtraHosts}} {{.HostConfig.CapAdd}}' "$id") == '[] []' ]] || return 1
    [[ $(docker network inspect -f '{{.EnableIPv6}}' "$MP_NETWORK_NAME") == false ]] || return 1
    return 0
}

# 解析映射 DROP 快照并返回指定键的计数；缺键、重复键、错误协议/来源/桥/目标一律非零。
# 计数只认冻结档案里的源地址 P 与桥 m$RUN，绝不读取旧 .4 规则。
mapping_count() {
    local snapshot=${1:-} profile=${2:-} key=${3:-} table
    [[ -n $snapshot && -n $key && -n $profile ]] || return 1
    mapping_profile_load "$profile" || return $?
    mapping_witness_key_valid "$key" || return 1
    [[ -f $snapshot && ! -L $snapshot ]] || return 1
    table=$(mapping_witness_table_string) || return 1
    awk -v run="$MP_RUN_ID" -v src="$MP_P/32" -v br="$MP_BRIDGE" \
        -v chain="ME$MP_RUN_ID" -v wanted="$key" -v table="$table" '
    BEGIN {
        n = split(table, rows, ";")
        for (i = 1; i <= n; i++) { split(rows[i], f, "|"); key[i] = f[1]; proto[i] = f[2]; dport[i] = f[3]; host[i] = f[4] }
    }
    {
        count = ""; tag = ""; s = ""; d = ""; pr = ""; dp = ""; iface = ""; tgt = ""; ch = ""
        if (match($0, /^\[[0-9]+:[0-9]+\]/)) count = substr($0, 2, RLENGTH - 2)
        for (i = 1; i <= NF; i++) {
            if ($i == "-A") ch = $(i + 1)
            if ($i == "-i") iface = $(i + 1)
            if ($i == "-s") s = $(i + 1)
            if ($i == "-d") d = $(i + 1)
            if ($i == "-p") pr = $(i + 1)
            if ($i == "--dport") dp = $(i + 1)
            if ($i == "-j") tgt = $(i + 1)
            if ($i == "--comment") { tag = $(i + 1); gsub(/"/, "", tag) }
        }
        for (i = 1; i <= n; i++) {
            if (tag != run "-" key[i]) continue
            seen[i]++
            if (count == "" || iface != br || s != src || d != host[i] "/32" || pr != proto[i] || dp != dport[i] || tgt != "DROP" || ch != chain) bad = 1
            split(count, a, ":"); value[i] = a[1]
        }
    }
    END {
        for (i = 1; i <= n; i++) { if (seen[i] != 1) bad = 1; if (key[i] == wanted) result = value[i] }
        if (bad || result == "") exit 1
        print result
    }' "$snapshot"
}

# 接收端见证计数：复用统一解析入口，输入为映射见证快照文件，不复制旧检查实现。
mapping_witness() {
    witness_chain_counts "${1:-}" mapping
}

# 单协议增量校验：复用统一入口，仅换入参来源。
mapping_witness_delta() {
    witness_protocol_delta "$1" "$2" "$3"
}

# 三协议键计数必须全部严格增长；零增量或非整数一律失败。
mapping_witness_growth() {
    local before=${1:-} after=${2:-} key=${3:-}
    awk -v before="$before" -v after="$after" -v key="$key" 'BEGIN {
        if (split(before, b, "\n") != 4 || split(after, a, "\n") != 4) exit 1
        if (key == "cross-network" || key == "host-published") target=1
        else if (key == "host-input") target=2
        else if (key == "dns-udp") target=3
        else if (key == "dns-tcp") target=4
        else exit 1
        for (i = 1; i <= 4; i++) {
            if (b[i] !~ /^[0-9]+$/ || a[i] !~ /^[0-9]+$/) exit 1
            if (i == target) { if (a[i] + 0 <= b[i] + 0) exit 1 }
            else if (a[i] != b[i]) exit 1
        }
    }'
}

# 接收端见证链计数：使用 guard 的只读 netns 快照，普通 runner 不进入特权命名空间。
mapping_receiver_witness_counts() {
    local root key=${1:-} generation=${MAPPING_ASSERT_GENERATION:-${MAPPING_GENERATION:-}}
    mapping_witness_key_valid "$key" || return 80
    [[ -n ${IT_CONTROL_DIR:-} && -n $generation ]] || return 80
    root=${IT_CONTROL_DIR%/control}
    [[ $root != "$IT_CONTROL_DIR" ]] || return 80
    if [[ -z $MP_NETWORK_ID ]]; then MP_NETWORK_ID=$(mapping_network_id_load) || return 80; fi
    mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || return 80
    mapping_witness "$root/mapping-snapshot-$CONTROL_SEQ.witness" || return 80
}

# 单个见证接收端的正校准探针，全部经 docker exec 边界。
mapping_receiver_probe() {
    local key=${1:-} spec proto port dest receiver generation token result id network_id facts ledger
    mapping_witness_key_valid "$key" || return 80
    generation=${MAPPING_ASSERT_GENERATION:-${MAPPING_GENERATION:-}}
    [[ -n $generation ]] || return 80
    spec=$(mapping_witness_spec "$key") || return 80
    IFS=$'\t' read -r proto port dest <<< "$spec"
    receiver="gm-$MP_RUN_ID-witness"
    ledger=$(resource_ledger_dir) || return 80
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_crosscheck "$ledger" || return 80
    id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$receiver") || return 80
    network_id=$(mapping_fixture_docker network inspect -f '{{.Id}}' "gm-$MP_RUN_ID-w-net") || return 80
    [[ $id =~ ^[0-9a-f]{64}$ && $network_id =~ ^[0-9a-f]{64}$ ]] || return 80
    resource_verify_object container "$id" mapping witness '' || return 80
    resource_verify_object network "$network_id" mapping witness-network '' || return 80
    facts=$(mapping_fixture_docker inspect -f '{{.HostConfig.NetworkMode}}|{{.State.Running}}|{{(index .NetworkSettings.Networks "gm-'"$MP_RUN_ID"'-w-net").NetworkID}}' "$id") || return 80
    [[ $facts == "gm-$MP_RUN_ID-w-net|true|$network_id" ]] || return 80
    token="$MP_RUN_ID-$generation-$key"
    case "$key" in
        cross-network|host-published|host-input)
            [[ $key != host-input ]] || port=49383
            result=$(mapping_fixture_docker exec "$id" sh -c "printf '%s' '$token' | busybox nc -w 2 '$dest' '$port'") || return 80
            [[ $result == "$token" ]] || return 80
            ;;
        dns-udp|dns-tcp)
            if [[ $key == dns-udp ]]; then proto=+notcp; else proto=+tcp; fi
            result=$(mapping_fixture_docker exec "$id" dig +time=1 +tries=1 "$proto" "@$dest" "$token.invalid" A) || return 80
            [[ $result == *'status: NXDOMAIN,'* && $result == *";$token.invalid."* && $result == *"SERVER: $dest#53("* ]] || return 80
            ;;
    esac
    [[ $(mapping_fixture_docker inspect -f '{{.Id}}' "$receiver") == "$id" ]] || return 80
    return 0
}
mapping_receiver_listener_container_id() {
    local receiver="gm-$MP_RUN_ID-witness" ledger id
    ledger=$(resource_ledger_dir) || return 80
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_crosscheck "$ledger" || return 80
    id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$receiver") || return 80
    [[ $id =~ ^[0-9a-f]{64}$ ]] || return 80
    resource_verify_object container "$id" mapping witness '' || return 80
    [[ $(mapping_fixture_docker inspect -f '{{.Id}}' "$id") == "$id" ]] || return 80
    [[ $(mapping_fixture_docker inspect -f '{{.Id}}' "$receiver") == "$id" ]] || return 80
    printf '%s\n' "$id"
}


# 按账本登记容器与监听进程特征获取唯一 PID，拒绝猜测信号目标。
mapping_receiver_listener_pid() {
    local key=${1:-} expected_id=${2:-} port process pids id
    mapping_witness_key_valid "$key" || return 80
    case "$key" in
        cross-network|host-published) port=19419; process=nc ;;
        host-input) port=19420; process=nc ;;
        dns-udp|dns-tcp) port=53; process=dnsmasq ;;
    esac
    id=$(mapping_receiver_listener_container_id) || return 80
    [[ -z $expected_id || $id == "$expected_id" ]] || return 80
    pids=$(mapping_fixture_docker exec "$id" sh -c '
        for path in /proc/[0-9]*; do
            IFS= read -r comm < "$path/comm" 2>/dev/null || continue
            case "$comm" in "$1"|busybox) ;; *) continue ;; esac
            args=$(tr "\000" " " < "$path/cmdline" 2>/dev/null) || continue
            case "$args" in
                *"nc -lk -p $2 -e /bin/cat"*) [ "$1" = nc ] || continue ;;
                dnsmasq\ *|*/dnsmasq\ *)
                    [ "$1" = dnsmasq ] || continue
                    case "$args" in
                        "dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon "|"/usr/sbin/dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon ") ;;
                        *) continue ;;
                    esac
                    udp=$(awk '\''$2 ~ /:0035$/ && $4 == "07" {print $10}'\'' /proc/net/udp /proc/net/udp6 2>/dev/null) || exit 80
                    tcp=$(awk '\''$2 ~ /:0035$/ && $4 == "0A" {print $10}'\'' /proc/net/tcp /proc/net/tcp6 2>/dev/null) || exit 80
                    [ -n "$udp" ] && [ -n "$tcp" ] || exit 80
                    found_udp=0 found_tcp=0
                    for fd in "$path"/fd/*; do
                        socket=$(readlink "$fd" 2>/dev/null) || continue
                        case "$socket" in socket:\[*\])
                            inode=${socket#socket:[}; inode=${inode%]}
                            for item in $udp; do [ "$item" != "$inode" ] || found_udp=1; done
                            for item in $tcp; do [ "$item" != "$inode" ] || found_tcp=1; done
                            ;;
                        esac
                    done
                    [ "$found_udp" = 1 ] && [ "$found_tcp" = 1 ] || continue
                    ;;
                *) continue ;;
            esac
            printf "%s\n" "${path##*/}"
        done
    ' sh "$process" "$port" "$key") || return 80
    [[ $pids =~ ^[0-9]+$ ]] || return 80
    printf '%s\n' "$pids"
}

mapping_receiver_listener_control() {
    local key=${1:-} signal=${2:-} expected=${3:-} pids identity saved file id
    [[ $signal == STOP || $signal == CONT ]] || return 80
    id=$(mapping_receiver_listener_container_id) || return 80
    pids=$(mapping_receiver_listener_pid "$key" "$id") || return 80
    [[ $signal != CONT || $expected == "$pids" ]] || return 80
    file=${IT_CONTROL_DIR:-}/listener-$([[ $key == dns-* ]] && printf dns || printf '%s' "$key").identity
    [[ -n ${IT_CONTROL_DIR:-} && -d $IT_CONTROL_DIR && ! -L $file ]] || return 80
    identity=$(mapping_receiver_listener_identity "$pids" "$key" "$id") || return 80
    if [[ $signal == CONT ]]; then
        [[ -f $file ]] || return 80
        saved=$(cat -- "$file") || return 80
        [[ $saved == "$identity" ]] || return 80
    fi
    mapping_receiver_listener_state "$pids" "$([[ $signal == STOP ]] && printf R || printf T)" "$id" || return 80
    if [[ $signal == STOP ]]; then
        printf '%s\n' "$identity" > "$file" || return 80
    fi
    [[ $(mapping_receiver_listener_container_id) == "$id" ]] || return 80
    mapping_fixture_docker exec "$id" kill -"$signal" "$pids" >/dev/null || return 80
    mapping_receiver_listener_state "$pids" "$([[ $signal == STOP ]] && printf T || printf R)" "$id" || return 80
    if [[ $signal == CONT ]]; then rm -f -- "$file" || return 80; fi
    printf '%s\n' "$pids"
}

mapping_receiver_listener_identity() {
    local pid=$1 key=$2 id=${3:-}
    [[ -n $id ]] || id=$(mapping_receiver_listener_container_id) || return 80
    [[ $(mapping_receiver_listener_container_id) == "$id" ]] || return 80
    mapping_fixture_docker exec "$id" sh -c '
        IFS= read -r stat < "/proc/$1/stat" || exit 80
        pid=$1
        key=$2
        set -- ${stat##*) }
        shift 19
        start=$1
        [ -n "$start" ] || exit 80
        case "$key" in
            dns-*) port=0035 ;;
            host-input) port=4BDC ;;
            *) port=4BDB ;;
        esac
        if [ "$port" = 0035 ]; then
            udp=$(awk '\''$2 ~ /:0035$/ && $4 == "07" {print $10}'\'' /proc/net/udp /proc/net/udp6 2>/dev/null) || exit 80
        else
            udp=unused
        fi
        tcp=$(awk -v port=":$port" '\''index($2, port) == length($2) - length(port) + 1 && $4 == "0A" {print $10}'\'' /proc/net/tcp /proc/net/tcp6 2>/dev/null) || exit 80
        found_udp= found_tcp=
        for fd in "/proc/$pid/fd/"*; do
            socket=$(readlink "$fd" 2>/dev/null) || continue
            case "$socket" in socket:\[*\]) inode=${socket#socket:[}; inode=${inode%]} ;; *) continue ;; esac
            for item in $udp; do [ "$item" != "$inode" ] || found_udp="$found_udp $inode"; done
            for item in $tcp; do [ "$item" != "$inode" ] || found_tcp="$found_tcp $inode"; done
        done
        [ "$port" != 0035 ] || [ -n "$found_udp" ] || exit 80
        [ -n "$found_tcp" ] || exit 80
        printf "%s|%s|%s\n" "$start" "$(printf "%s\n" $found_udp | sort -u | tr "\n" ,)" "$(printf "%s\n" $found_tcp | sort -u | tr "\n" ,)"
    ' sh "$pid" "$key"
}

mapping_receiver_listener_state() {
    local pid=$1 expected_state=$2 id=${3:-}
    [[ $pid =~ ^[0-9]+$ ]] || return 80
    [[ -n $id ]] || id=$(mapping_receiver_listener_container_id) || return 80
    [[ $(mapping_receiver_listener_container_id) == "$id" ]] || return 80
    mapping_fixture_docker exec "$id" sh -c '
        IFS= read -r stat < "/proc/$1/stat" || exit 80
        state=${stat##*) }; state=${state%% *}
        case "$2:$state" in T:T|R:R|R:S|R:D|R:I) exit 0 ;; *) exit 80 ;; esac
    ' sh "$pid" "$expected_state" >/dev/null 2>&1 || return 80
}

mapping_receiver_negative_probe() {
    local key=${1:-} dir=${2:-} spec proto port dest output status=0 token
    spec=$(mapping_witness_spec "$key") || return 80
    IFS=$'\t' read -r proto port dest <<< "$spec"
    token="$MP_RUN_ID-${MAPPING_ASSERT_GENERATION:-}-${key}"
    case "$key" in
        cross-network|host-published|host-input)
            [[ $key != host-input ]] || port=49383
            output=$(mapping_fixture_docker exec "gm-$MP_RUN_ID-witness" sh -c "printf '%s' '$token' | busybox nc -w 2 '$dest' '$port'" 2>&1) || status=$?
            ;;
        dns-udp|dns-tcp)
            [[ $key != dns-udp ]] || proto=+notcp
            [[ $key != dns-tcp ]] || proto=+tcp
            output=$(mapping_fixture_docker exec "gm-$MP_RUN_ID-witness" dig +time=1 +tries=1 "$proto" "@$dest" "$token.invalid" A 2>&1) || status=$?
            ;;
    esac
    if [[ -n $dir ]]; then
        mkdir -p "$dir/negative" || return 80
        printf '%s\n' "$status" > "$dir/negative/raw.exit" || return 80
        printf '%s\n' "$output" > "$dir/negative/raw.log" || return 80
    fi
    case "$key" in
        dns-*) [[ $status == 9 && $output == *'no servers could be reached'* && $output != *'Error response from daemon:'* ]] || return 80 ;;
        *) [[ $status != 0 && $output != *'Error response from daemon:'* && ( $output == *'refused'* || $output == *'timed out'* ) ]] || return 80 ;;
    esac
    printf '%s\n' "$output"
}

# 正校准接收端并覆盖 UDP/TCP：先取接收端基线，逐项探测后要求计数严格增长。
# 接收端在跑但不计数（零增量）不得通过校准。
mapping_calibrate_witness() {
    local profile=${1:-} key spec proto port before after
    MP_WITNESS_CALIBRATED=0
    mapping_profile_load "$profile" || return $?
    for key in $MAPPING_WITNESS_KEYS; do
        before=$(mapping_receiver_witness_counts "$key") || return 80
        spec=$(mapping_witness_spec "$key") || return 1
        IFS=$'\t' read -r proto port _ <<< "$spec"
        mapping_receiver_probe "$key" || { case $? in 1) return 1 ;; *) return 80 ;; esac; }
        after=$(mapping_receiver_witness_counts "$key") || return 80
        mapping_witness_growth "$before" "$after" "$key" || return 1
        printf 'WITNESS_PROBE=%s PROTOCOL=%s PORT=%s\n' "$key" "$proto" "$port"
    done
    MP_WITNESS_CALIBRATED=1
    return 0
}

# 从产品 netns 发起五类目标探测；TCP DNS 由登记工具共享 netns 发起。
mapping_probe_egress() {
    local product=$1 generation=$2 target=${3:-} dir=${4:-} key spec proto port dest tool facts ledger output status probe_rc remove_rc product_id write_rc
    [[ -n $product && -n $generation ]] || return 80
    for key in $MAPPING_WITNESS_KEYS; do
        [[ -z $target || $target == "$key" ]] || continue
        spec=$(mapping_witness_spec "$key") || return 80
        IFS=$'\t' read -r proto port dest <<< "$spec"
        case "$key" in
            dns-udp)
                status=0
                output=$(mapping_fixture_docker exec "$product" timeout 4 busybox nslookup "$MP_RUN_ID-$generation.invalid" "$dest" 2>&1) || status=$?
                printf '%s\n' "$output"
                if [[ -n $dir ]]; then
                    printf '%s\n' "$status" > "$dir/probe/raw.exit" || return 80
                    printf '%s\n' "$output" > "$dir/probe/raw.log" || return 80
                fi
                if [[ $status == 0 ]]; then return 1; fi
                [[ $output != *'Error response from daemon:'* && ( $status == 124 || ( $status == 1 && $output == *'connection timed out'* ) ) ]] || return 80
                ;;
            dns-tcp)
                mapping_fixture_state_load || return 80
                ledger=$(resource_ledger_dir) || return 80
                RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
                resource_crosscheck "$ledger" || return 80
                product_id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$product") || return 80
                [[ $product_id =~ ^[0-9a-f]{64}$ ]] || return 80
                resource_verify_object container "$product_id" "$MPF_SCENARIO" product '' || return 80
                facts=$(mapping_fixture_docker inspect -f '{{.HostConfig.NetworkMode}}|{{.State.Running}}' "$product_id") || return 80
                [[ $facts == "$MP_NETWORK_NAME|true" ]] || return 80
                tool=$(mapping_fixture_create "$MPF_SCENARIO" tcp-dns -d --name "gm-$MP_RUN_ID-$generation-tcp-dns" \
                    --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges \
                    --network "container:$product_id" \
                    --entrypoint sleep "$MPF_TOOLS_IMAGE" 120) || {
                    printf 'TCP_DNS_TOOL_IDENTITY_UNCERTAIN stage=create name=%s\n' "gm-$MP_RUN_ID-$generation-tcp-dns" >&2
                    return 80
                }
                probe_rc=80
                if [[ $tool =~ ^[0-9a-f]{64}$ ]] && resource_crosscheck "$ledger" &&
                    resource_verify_object container "$tool" "$MPF_SCENARIO" tcp-dns ''; then
                    if mapping_fixture_docker start "$tool" >/dev/null; then
                        facts=$(mapping_fixture_docker inspect -f '{{.HostConfig.NetworkMode}}|{{.Config.User}}|{{.State.Running}}|{{.Image}}|{{.HostConfig.ReadonlyRootfs}}|{{json .HostConfig.CapDrop}}|{{json .HostConfig.SecurityOpt}}' "$tool") || facts=''
                        if [[ $facts == "container:$product_id|10001:10001|true|$MPF_TOOLS_IMAGE|true|[\"ALL\"]|[\"no-new-privileges\"]" || $facts == "container:$product_id|10001:10001|true|$MPF_TOOLS_IMAGE|true|[\"ALL\"]|[\"no-new-privileges:true\"]" ]]; then
                            printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$product_id"
                            status=0
                            output=$(mapping_fixture_docker exec "$tool" dig +time=1 +tries=1 +tcp "@$dest" "$MP_RUN_ID-$generation.invalid" A 2>&1) || status=$?
                            printf '%s\n' "$output"
                            write_rc=0
                            if [[ -n $dir ]]; then
                                printf '%s\n' "$status" > "$dir/probe/raw.exit" || write_rc=80
                                printf '%s\n' "$output" > "$dir/probe/raw.log" || write_rc=80
                            fi
                            if [[ $write_rc == 0 && $status == 0 && $output == *"SERVER: $dest#53("* && $output =~ status:\ (NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR|NOTIMP), ]]; then
                                probe_rc=1
                            elif [[ $write_rc == 0 && $status == 9 && $output != *'Error response from daemon:'* && ! $output =~ status:\ (NOERROR|NXDOMAIN|SERVFAIL|REFUSED|FORMERR|NOTIMP), && $output == *"communications error to $dest#53: timed out"* && $output == *'no servers could be reached'* ]]; then
                                probe_rc=0
                            fi
                        fi
                    fi
                fi
                remove_rc=0
                if [[ $tool =~ ^[0-9a-f]{64}$ ]] && resource_crosscheck "$ledger" &&
                    resource_verify_object container "$tool" "$MPF_SCENARIO" tcp-dns ''; then
                    resource_remove container "$tool" || remove_rc=$?
                else
                    printf 'TCP_DNS_TOOL_IDENTITY_UNCERTAIN id=%s\n' "$tool" >&2
                    remove_rc=80
                fi
                [[ $remove_rc == 0 ]] || return 80
                [[ $probe_rc == 0 ]] || return "$probe_rc"
                ;;
            *)
                status=0
                output=$(mapping_fixture_docker exec "$product" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$dest:$port/" 2>&1) || status=$?
                printf '%s\n' "$output"
                if [[ -n $dir ]]; then
                    printf '%s\n' "$status" > "$dir/probe/raw.exit" || return 80
                    printf '%s\n' "$output" > "$dir/probe/raw.log" || return 80
                fi
                if [[ $status == 0 ]]; then return 1; fi
                [[ $output != *'Error response from daemon:'* && $status == 28 && ( $output == *'Connection timed out'* || $output == *'Operation timed out'* || $output == *'Timeout was reached'* ) ]] || return 80
                ;;
        esac
    done
    return 0
}

# 核验 CONT 后原监听 PID 仍存在且不处于停止态。
mapping_receiver_listener_running() {
    local key=$1 pid=$2 id
    id=$(mapping_receiver_listener_container_id) || return 80
    mapping_receiver_listener_identity "$pid" "$key" "$id" >/dev/null || return 80
    mapping_fixture_docker exec "$id" sh -c '
        kill -0 "$1" 2>/dev/null || exit 1
        IFS= read -r stat < "/proc/$1/stat" || exit 1
        state=${stat##*) }
        state=${state%% *}
        [ "$state" != T ] && [ "$state" != t ] && [ "$state" != Z ]
    ' sh "$pid" >/dev/null 2>&1
}

mapping_receiver_listener_observed_state() {
    local key=$1 pid=$2 id
    id=$(mapping_receiver_listener_container_id) || return 80
    mapping_receiver_listener_identity "$pid" "$key" "$id" >/dev/null || return 80
    mapping_fixture_docker exec "$id" sh -c '
        IFS= read -r stat < "/proc/$1/stat" || exit 80
        state=${stat##*) }; state=${state%% *}
        printf "%s\n" "$state"
    ' sh "$pid"
}

# 保留原失败阶段及恢复结果；恢复不可靠时拒绝继续下一例。
mapping_isolation_resume() {
    local key=$1 dir=$2 stage=$3 original_rc=$4 pid=$5 restore_rc=0 running_rc=0
    mapping_receiver_listener_control "$key" CONT "$pid" > "$dir/listener.restored.pid" || restore_rc=$?
    mapping_receiver_listener_running "$key" "$pid" || running_rc=$?
    if [[ $restore_rc == 0 && $running_rc == 0 ]]; then
        mapping_receiver_listener_observed_state "$key" "$pid" > "$dir/listener.restored.state" || running_rc=80
    fi
    printf 'failure_stage\t%s\noriginal_exit\t%s\nrestore_exit\t%s\nrunning_exit\t%s\n' \
        "$stage" "$original_rc" "$restore_rc" "$running_rc" > "$dir/stop.outcome.tsv" || return 80
    [[ $restore_rc == 0 && $running_rc == 0 ]] || return 80
    return 0
}

# STOP 结果不确定时仅恢复登记身份可确认的监听，并记录恢复结果。
mapping_isolation_stop_failure() {
    local key=$1 dir=$2 original_rc=$3 pid restore_rc=80 running_rc=80
    pid=$(mapping_receiver_listener_pid "$key") || pid=''
    if [[ $pid =~ ^[0-9]+$ ]]; then
        mapping_isolation_resume "$key" "$dir" stop "$original_rc" "$pid"
        return 80
    fi
    printf 'failure_stage\tstop\noriginal_exit\t%s\nrestore_exit\t%s\nrunning_exit\t%s\n' \
        "$original_rc" "$restore_rc" "$running_rc" > "$dir/stop.outcome.tsv" || return 80
    return 80
}

# 隔离判定：五类 DROP 计数均增长、接收端计数零变化；未完成正校准不得通过。
mapping_isolation_check() {
    local product=${1:-} generation=${2:-} profile=${3:-}
    local before after wb wa key cb ca seq_before seq_after base dir negative_rc name stage original_rc pid spec proto port dest
    [[ -n $product && -n $generation && -n $profile ]] || return 1
    [[ $MP_WITNESS_CALIBRATED == 1 && ${MAPPING_ASSERT_CALIBRATED_GENERATION:-} == "$generation" ]] || return 1
    [[ $generation == "${MAPPING_ASSERT_GENERATION:-}" ]] || return 1
    mapping_profile_load "$profile" || return 80
    if [[ -z $MP_NETWORK_ID ]]; then MP_NETWORK_ID=$(mapping_network_id_load) || return 80; fi
    [[ -n ${IT_CONTROL_DIR:-} ]] || return 80
    base=${IT_CONTROL_DIR%/control}
    [[ -n $base && $base != "$IT_CONTROL_DIR" ]] || return 80
    for key in $MAPPING_WITNESS_KEYS; do
        [[ -z ${MAPPING_ASSERT_TARGET:-} || $MAPPING_ASSERT_TARGET == "$key" ]] || continue
        dir=${IT_EVIDENCE_DIR:-}/isolation/$key
        [[ -n ${IT_EVIDENCE_DIR:-} && ! -e $dir && ! -L $dir ]] || return 80
        mkdir -p "$dir" || return 80
        spec=$(mapping_witness_spec "$key") || return 80
        IFS=$'\t' read -r proto port dest <<< "$spec"
        printf 'target\t%s\nprotocol\t%s\nport\t%s\ndestination\t%s\n' "$key" "$proto" "$port" "$dest" > "$dir/probe.target.tsv" || return 80
        cp -- "$dir/probe.target.tsv" "$dir/negative.target.tsv" || return 80
        mkdir -p "$dir/probe" "$dir/negative" || return 80
        mapping_receiver_probe "$key" || return 80
        mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || return 80
        for name in rules witness receipt; do
            cp -- "$base/mapping-snapshot-$CONTROL_SEQ.$name" "$dir/calibration.before.$name" || return 80
        done
        mapping_receiver_probe "$key" || return 80
        mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || return 80
        for name in rules witness receipt; do
            cp -- "$base/mapping-snapshot-$CONTROL_SEQ.$name" "$dir/calibration.after.$name" || return 80
        done
        wb=$(mapping_witness "$dir/calibration.before.witness") || return 80
        wa=$(mapping_witness "$dir/calibration.after.witness") || return 80
        mapping_witness_growth "$wb" "$wa" "$key" || return 1
        original_rc=0
        mapping_receiver_listener_control "$key" STOP > "$dir/listener.pid" || original_rc=$?
        pid=$(cat "$dir/listener.pid")
        if [[ $original_rc != 0 || ! $pid =~ ^[0-9]+$ ]]; then
            mapping_isolation_stop_failure "$key" "$dir" "${original_rc:-80}"
            return 80
        fi
        mapping_receiver_listener_observed_state "$key" "$pid" > "$dir/listener.stopped.state" || { mapping_isolation_resume "$key" "$dir" stopped-state 80 "$pid"; return 80; }
        [[ $(cat "$dir/listener.stopped.state") == T ]] || { mapping_isolation_resume "$key" "$dir" stopped-state 1 "$pid"; return 80; }
        stage=none original_rc=0
        negative_rc=0
        mapping_receiver_negative_probe "$key" "$dir" > "$dir/negative.log" || negative_rc=$?
        if ! printf '%s\n' "$negative_rc" > "$dir/negative.exit"; then
            stage=negative-exit original_rc=80
        elif [[ $negative_rc != 0 ]]; then
            stage=negative-probe original_rc=$negative_rc
        fi
        if [[ $stage == none ]]; then
            mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || { original_rc=$?; stage=snapshot; }
        fi
        if [[ $stage == none ]]; then
            for name in rules witness receipt; do
                cp -- "$base/mapping-snapshot-$CONTROL_SEQ.$name" "$dir/negative.$name" || { original_rc=$?; stage=snapshot-copy; break; }
            done
        fi
        mapping_isolation_resume "$key" "$dir" "$stage" "$original_rc" "$pid" || return 80
        [[ $stage == none ]] || return 80
        printf 'probe_exit\t%s\n' "$negative_rc" > "$dir/negative.tsv" || return 80
        mapping_receiver_probe "$key" || return 80
        mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || return 80
        seq_before=${CONTROL_SEQ:-0}
        printf '%s\n' "$seq_before" > "$dir/seq.before" || return 80
        mapping_probe_egress "$product" "$generation" "$key" "$dir" > "$dir/probe.log" 2>&1 || { case $? in 1) return 1 ;; *) return 80 ;; esac; }
        mapping_control_request mapping-snapshot "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" "$key" || return 80
        seq_after=${CONTROL_SEQ:-0}
        printf '%s\n' "$seq_after" > "$dir/seq.after" || return 80
        before=$base/mapping-snapshot-$seq_before.rules
        after=$base/mapping-snapshot-$seq_after.rules
        for name in rules witness receipt; do
            cp -- "$base/mapping-snapshot-$seq_before.$name" "$dir/before.$name" || return 80
            cp -- "$base/mapping-snapshot-$seq_after.$name" "$dir/after.$name" || return 80
        done
        wb=$(mapping_witness "$dir/before.witness") || return 80
        wa=$(mapping_witness "$dir/after.witness") || return 80
        [[ $wb == "$wa" ]] || return 1
        cb=$(mapping_count "$before" "$profile" "$key") || return 1
        ca=$(mapping_count "$after" "$profile" "$key") || return 1
        [[ $ca -gt $cb ]] || return 1
        printf 'target\t%s\ngeneration\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\n' "$key" "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" > "$dir/binding.tsv" || return 80
        printf 'policy\n' > "$dir/reject.layer" || return 80
    done
    return 0
}

# 双 CA、代理与 DNS 契约参数（接口 D）。
MAPPING_FIXTURE_MOUNT='/var/lib/git-daemon'
MAPPING_ASSET_ROOT="$MAPPING_FIXTURE_MOUNT"
# 上游连接取证的独立可写卷挂载点：资产卷对上游只读，serve.sh 的写重定向必须落到该 rw 卷，
# 否则只读文件系统上重定向失败、requests.log 永不生成。
MAPPING_EVIDENCE_MOUNT='/ev'
MAPPING_CA_MOUNT='/ca'
MAPPING_SCENARIO_RE='^mapping-[a-z0-9-]{1,32}$'
MAPPING_UPSTREAM_HOST='github.com'
MAPPING_PROXY_HOST='gm-proxy'
MAPPING_UPSTREAM_PORT=443
MAPPING_DNS_PORT=53
MAPPING_PROXY_ACCEPT_PORT=8443
MAPPING_PROXY_REJECT_PORT=8444
MAPPING_PROXY_AUTHORITY="$MAPPING_UPSTREAM_HOST:$MAPPING_UPSTREAM_PORT"
MAPPING_PROXY_MODES='accept reject'
MAPPING_UPSTREAM_HEALTH='mapping-upstream-ok'
MAPPING_CLIENT_UPSTREAM_CA="$MAPPING_CA_MOUNT/upstream-ca.crt"
MAPPING_CLIENT_PROXY_CA="$MAPPING_CA_MOUNT/proxy-ca.crt"
MAPPING_ASSET_VOLUME_ROLE='assets'
MAPPING_CA_VOLUME_ROLE='ca'
MAPPING_EVIDENCE_VOLUME_ROLE='evidence'
MAPPING_SAFE_OPTIONS='--user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges --sysctl net.ipv6.conf.all.disable_ipv6=1'
# 上游 U:443 连接取证与上游 Git 助手：serve.sh 逐连接记录 requests.log；
# git 助手在服务目录内初始化并推进受控 dumb HTTP 仓库，供 refs/HEAD 预期读取。
MAPPING_UPSTREAM_OWNER='gitdaemon'
MAPPING_UPSTREAM_REPO='fixture'
MAPPING_UPSTREAM_PATH="$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO.git"
MAPPING_UPSTREAM_REF='refs/heads/main'
MAPPING_UPSTREAM_REQUESTS="$MAPPING_EVIDENCE_MOUNT/requests.log"
MAPPING_UPSTREAM_SERVE_LOG="$MAPPING_EVIDENCE_MOUNT/serve.log"
# 受控 DNS 的假绿开关：默认留空；仅安全负例显式设置后，指定名称才解析到指定地址。
MAPPING_DNS_FAKE_HOST=''
MAPPING_DNS_FAKE_IP=''
# 本轮代理证据分段：由编排按 run/generation 设置，保证重跑不复用上一轮计数与 CONNECT 日志。
MAPPING_PROXY_RUN_ID=''
MAPPING_FAILURE=80
MAPPING_USAGE=2

# 夹具只读字段，由 mapping_fixture_state_load 填充。
MPF_RUN_ID=''
MPF_SCENARIO=''
MPF_PRODUCT_IMAGE=''
MPF_TOOLS_IMAGE=''
MPF_UPSTREAM_IP=''

# 夹具状态文件：只追加冻结状态，不反写输入档案。
mapping_fixture_state_file() {
    local dir generation=${MAPPING_ASSERT_GENERATION:-${MAPPING_GENERATION:-}}
    dir=$(mapping_state_dir) || return 1
    if [[ -n $generation ]]; then
        mapping_network_state_file >/dev/null || return 1
        printf '%s\n' "$dir/generations/$generation/mapping-fixture.tsv"
        return 0
    fi
    printf '%s\n' "$dir/mapping-fixture.tsv"
}

# 追加一条冻结状态。
mapping_fixture_state_write() {
    local key=${1:-} value=${2:-} file
    [[ -n $key && -n $value ]] || return 1
    [[ $value != *$'\t'* && $value != *$'\n'* ]] || return 1
    file=$(mapping_fixture_state_file) || return 1
    mkdir -p "$(dirname -- "$file")" || return 1
    printf '%s\t%s\n' "$key" "$value" >> "$file"
}

# 严格读取夹具状态：每键恰好一次、无未知键、值非空，缺项一律非零。
mapping_fixture_state_load() {
    local file line key value
    file=$(mapping_fixture_state_file) || return 1
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    MPF_RUN_ID='' MPF_SCENARIO='' MPF_PRODUCT_IMAGE='' MPF_TOOLS_IMAGE='' MPF_UPSTREAM_IP=''
    while IFS=$'\t' read -r key value || [[ -n $key ]]; do
        [[ -n $key && -n $value && $value != *$'\t'* ]] || return 1
        case "$key" in
            run_id) [[ -z $MPF_RUN_ID ]] || return 1; MPF_RUN_ID=$value ;;
            scenario) [[ -z $MPF_SCENARIO ]] || return 1; MPF_SCENARIO=$value ;;
            product_image) [[ -z $MPF_PRODUCT_IMAGE ]] || return 1; MPF_PRODUCT_IMAGE=$value ;;
            tools_image) [[ -z $MPF_TOOLS_IMAGE ]] || return 1; MPF_TOOLS_IMAGE=$value ;;
            upstream_ip) [[ -z $MPF_UPSTREAM_IP ]] || return 1; MPF_UPSTREAM_IP=$value ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ $MPF_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 1
    mapping_scenario_valid "$MPF_SCENARIO" || return 1
    [[ -n $MPF_PRODUCT_IMAGE && -n $MPF_TOOLS_IMAGE ]] || return 1
    mapping_proxy_upstream_literal "$MPF_UPSTREAM_IP" || return 1
    return 0
}

# 场景标识形状：固定前缀加安全分量，负例以其独立后缀表达。
mapping_scenario_valid() {
    [[ ${1:-} =~ $MAPPING_SCENARIO_RE ]]
}

# 本轮 run id：优先夹具冻结状态，其次冻结档案字段。
mapping_fixture_run_id() {
    if [[ -n ${MPF_RUN_ID:-} ]]; then printf '%s\n' "$MPF_RUN_ID"; return 0; fi
    if [[ -n ${MP_RUN_ID:-} ]]; then printf '%s\n' "$MP_RUN_ID"; return 0; fi
    return 1
}

# Docker 外部边界：优先统一端点包装器，缺库时退回命令行。
mapping_fixture_docker() {
    if declare -F validation_docker >/dev/null 2>&1; then
        validation_docker "$@"
        return $?
    fi
    command docker "$@"
}

# 资产卷与客户端 CA 卷名；客户端 CA 卷名固定，供产品 /ca 挂载核验。
mapping_assets_volume() {
    printf 'gm-%s-mapping-assets\n' "$(mapping_fixture_run_id)"
}

mapping_ca_volume() {
    printf 'gm-%s-mapping-ca\n' "$(mapping_fixture_run_id)"
}

# 上游连接取证卷（rw）：资产卷对上游只读，须另挂一个可写卷承载 requests.log/serve.log。
mapping_evidence_volume() {
    printf 'gm-%s-mapping-evidence\n' "$(mapping_fixture_run_id)"
}

# 创建、登记、运行并删除一个封闭的 network-none 证据卷助手。
mapping_evidence_helper_run() {
    local role=${1:-} image=${2:-} mount=${3:-} script=${4:-} output=${5:-}
    local scenario=${MPF_SCENARIO:-$MAPPING_LEDGER_SCENARIO} id rc=0 remove_rc=0
    [[ -n $role && -n $image && -n $script && -n $output ]] || return "$MAPPING_FAILURE"
    mapping_scenario_valid "$scenario" || return "$MAPPING_FAILURE"
    RESOURCE_LEDGER_DIR=$(resource_ledger_dir) RESOURCE_RUN=$(mapping_fixture_run_id)
    resource_create_register container "$scenario" "$role" -- \
        resource_docker create \
        --label "gitdaemon.run=$RESOURCE_RUN" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$role" \
        $MAPPING_SAFE_OPTIONS --network none \
        ${mount:+-v "$mount"} --entrypoint /bin/sh "$image" -c "$script" || return "$MAPPING_FAILURE"
    id=$RESOURCE_CREATED_ID
    [[ -n $id ]] || return "$MAPPING_FAILURE"
    resource_docker start -a "$id" > "$output" 2>&1 || rc=$?
    resource_remove container "$id" || remove_rc=$?
    (( rc == 0 && remove_rc == 0 )) || return "$MAPPING_FAILURE"
    return 0
}

# 以镜像内 10001 所有目录的空卷 copy-up 初始化本轮证据卷。
mapping_evidence_volume_prepare() {
    local image=${1:-} volume ledger scenario check_output init_output
    [[ -n $image ]] || return "$MAPPING_FAILURE"
    volume=$(mapping_evidence_volume) || return "$MAPPING_FAILURE"
    ledger=$(resource_ledger_dir) || return "$MAPPING_FAILURE"
    scenario=${MPF_SCENARIO:-$MAPPING_LEDGER_SCENARIO}
    check_output=$(mktemp) || return "$MAPPING_FAILURE"
    init_output=$(mktemp) || { rm -f "$check_output"; return "$MAPPING_FAILURE"; }
    if ! mapping_evidence_helper_run evidence-image-check "$image" '' \
        "test -d '$MAPPING_FIXTURE_MOUNT' && test ! -L '$MAPPING_FIXTURE_MOUNT' && test -w '$MAPPING_FIXTURE_MOUNT' && stat -c '%u:%g' '$MAPPING_FIXTURE_MOUNT'" "$check_output"; then
        rm -f "$check_output" "$init_output"
        return "$MAPPING_FAILURE"
    fi
    if ! grep -Fxq '10001:10001' "$check_output"; then
        rm -f "$check_output" "$init_output"
        return "$MAPPING_FAILURE"
    fi
    if resource_exists volume "$volume"; then
        rm -f "$check_output" "$init_output"
        return "$MAPPING_FAILURE"
    elif [[ $? != 1 ]]; then
        rm -f "$check_output" "$init_output"
        return "$MAPPING_FAILURE"
    fi
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$(mapping_fixture_run_id)
    resource_create_register volume "$scenario" "$MAPPING_EVIDENCE_VOLUME_ROLE" -- \
        resource_docker volume create \
        --label "gitdaemon.run=$RESOURCE_RUN" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$MAPPING_EVIDENCE_VOLUME_ROLE" \
        "$volume" || { rm -f "$check_output" "$init_output"; return "$MAPPING_FAILURE"; }
    if ! mapping_evidence_helper_run evidence-init "$image" "$volume:$MAPPING_FIXTURE_MOUNT" \
        "test \"\$(stat -c '%u:%g' '$MAPPING_FIXTURE_MOUNT')\" = 10001:10001" "$init_output"; then
        rm -f "$check_output" "$init_output"
        return "$MAPPING_FAILURE"
    fi
    rm -f "$check_output" "$init_output"
    return 0
}

# 在实际 /ev 挂载下验证属主、读写、追加、比对、删除和 FIFO 生命周期。
mapping_evidence_volume_verify() {
    local image=${1:-} volume output mounts id scenario token script rc=0 remove_rc=0
    [[ -n $image && -n ${IT_EVIDENCE_DIR:-} ]] || return "$MAPPING_FAILURE"
    volume=$(mapping_evidence_volume) || return "$MAPPING_FAILURE"
    scenario=${MPF_SCENARIO:-$MAPPING_LEDGER_SCENARIO}
    token="mapping-evidence-$(mapping_fixture_run_id)-$$"
    output=$IT_EVIDENCE_DIR/mapping-evidence-volume.txt
    script="set -eu; test \"\$(stat -c '%u:%g' /ev)\" = 10001:10001; printf 'payload' > '/ev/$token.file'; printf '%s' '-append' >> '/ev/$token.file'; printf 'payload-append' > '/ev/$token.expected'; cmp '/ev/$token.file' '/ev/$token.expected'; rm '/ev/$token.expected'; mkfifo '/ev/$token.fifo'; test -p '/ev/$token.fifo'; rm '/ev/$token.fifo'; cat '/ev/$token.file'; rm '/ev/$token.file'; printf '\nuid=10001 gid=10001\nowner=10001:10001\nwrite=PASS\nfifo=PASS\n'"
    RESOURCE_LEDGER_DIR=$(resource_ledger_dir) RESOURCE_RUN=$(mapping_fixture_run_id)
    resource_create_register container "$scenario" evidence-verify -- \
        resource_docker create \
        --label "gitdaemon.run=$RESOURCE_RUN" \
        --label "gitdaemon.scenario=$scenario" \
        --label 'gitdaemon.role=evidence-verify' \
        $MAPPING_SAFE_OPTIONS --network none -v "$volume:$MAPPING_EVIDENCE_MOUNT" \
        --entrypoint /bin/sh "$image" -c "$script" || return "$MAPPING_FAILURE"
    id=$RESOURCE_CREATED_ID
    [[ -n $id ]] || return "$MAPPING_FAILURE"
    mounts=$(resource_docker inspect -f '{{json .Mounts}}' "$id" 2>/dev/null) || rc=$?
    if (( rc == 0 )); then
        [[ $mounts == *'"Destination":"/ev"'* && $mounts == *'"RW":true'* ]] || rc=1
    fi
    if (( rc == 0 )); then
        mkdir -p "$IT_EVIDENCE_DIR" || rc=1
    fi
    if (( rc == 0 )); then
        resource_docker start -a "$id" > "$output.tmp" 2>&1 || rc=$?
    fi
    if (( rc == 0 )); then
        grep -Fxq 'owner=10001:10001' "$output.tmp" && \
            grep -Fxq 'write=PASS' "$output.tmp" && grep -Fxq 'fifo=PASS' "$output.tmp" || rc=1
    fi
    if (( rc == 0 )); then mv "$output.tmp" "$output" || rc=1; else rm -f "$output.tmp"; fi
    resource_remove container "$id" || remove_rc=$?
    (( rc == 0 && remove_rc == 0 )) || return "$MAPPING_FAILURE"
    return 0
}

# 夹具容器名：上游 U、代理 X、DNS D、校准探针 P。
mapping_upstream_container() { printf 'gm-%s-upstream\n' "$(mapping_fixture_run_id)"; }
mapping_proxy_container() { printf 'gm-%s-proxy\n' "$(mapping_fixture_run_id)"; }
mapping_dns_container() { printf 'gm-%s-dns\n' "$(mapping_fixture_run_id)"; }
mapping_probe_container() { printf 'gm-%s-probe\n' "$(mapping_fixture_run_id)"; }

# 单一场景的代理证据目录（容器内绝对路径）：按 run 分段，未设置分段时退回场景目录。
# 分段使同一 scenario 重跑不复用上一轮的计数文件与 CONNECT 日志。
mapping_proxy_scenario_dir() {
    local scenario=${1:-}
    [[ $scenario == "$MAPPING_LEDGER_SCENARIO" ]] || mapping_scenario_valid "$scenario" || return 1
    if [[ -n ${MAPPING_PROXY_RUN_ID:-} ]]; then
        printf '%s/proxy/scenarios/%s/%s\n' "$MAPPING_ASSET_ROOT" "$scenario" "$MAPPING_PROXY_RUN_ID"
    else
        printf '%s/proxy/scenarios/%s\n' "$MAPPING_ASSET_ROOT" "$scenario"
    fi
}

# 单一场景下的代理计数文件路径；两个端口各用独立计数文件，且随 run 分段。
mapping_proxy_count_path() {
    local scenario=${1:-} port=${2:-} name dir
    dir=$(mapping_proxy_scenario_dir "$scenario") || return 1
    case "$port" in
        "$MAPPING_PROXY_ACCEPT_PORT") name=accept ;;
        "$MAPPING_PROXY_REJECT_PORT") name=reject ;;
        *) return 1 ;;
    esac
    printf '%s/%s.count\n' "$dir" "$name"
}

# 单一场景下的 CONNECT 日志路径；随 run 分段，避免读取上一轮残留。
mapping_proxy_log_path() {
    local scenario=${1:-} dir
    dir=$(mapping_proxy_scenario_dir "$scenario") || return 1
    printf '%s/connect.log\n' "$dir"
}

# 场景开始时重建本轮代理证据：清空上一轮残留的 CONNECT 日志（计数文件随新分段自然为空）。
mapping_proxy_evidence_reset() {
    local scenario=${1:-} image=${2:-} dir rel
    mapping_scenario_valid "$scenario" || return 1
    [[ -n $image ]] || return 1
    dir=$(mapping_proxy_scenario_dir "$scenario") || return 1
    rel=${dir#"$MAPPING_ASSET_ROOT"/}
    mapping_fixture_asset_write "$rel/connect.log" '' "$image" || return 1
    return 0
}

# 拨号地址必须是 IPv4 字面量：拒绝主机名，杜绝代理侧对 CONNECT 目标做 DNS 解析。
mapping_proxy_upstream_literal() {
    local ip=${1:-} octet
    local -a parts=()
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a parts <<< "$ip"
    for octet in "${parts[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# 计数解析：缺失视为新文件起始 0，存在但非非负整数即失败，绝不默认为零。
mapping_proxy_count_read() {
    local file=${1:-} raw
    [[ -n $file ]] || return 1
    if [[ ! -e $file ]]; then printf '0\n'; return 0; fi
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    raw=$(cat -- "$file" 2>/dev/null) || return 1
    mapping_proxy_count_strict "$raw"
}

mapping_proxy_count_strict() {
    local raw=${1:-}
    [[ $raw =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$raw"
}

# 计数递增：读改同一文件只允许端口进程内串行；两端口各自文件，绝不同文件并发读改。
mapping_proxy_count_bump() {
    local file=${1:-} value
    value=$(mapping_proxy_count_read "$file") || return 1
    printf '%s\n' "$((value + 1))" > "$file.new" || return 1
    mv -- "$file.new" "$file" || return 1
    return 0
}

# CONNECT 证据行：只记录 authority、模式与拨号目的，不记录凭据。
mapping_proxy_record() {
    local count_file=${1:-} authority=${2:-} mode=${3:-} dial_target=${4:-} log
    log=$(mapping_proxy_log_path_from_count "$count_file") || return 1
    printf 'authority=%s\tmode=%s\tdial_target=%s\n' "$authority" "$mode" "$dial_target" >> "$log"
}

mapping_proxy_log_path_from_count() {
    local count_file=${1:-}
    [[ -n $count_file ]] || return 1
    printf '%s\n' "$(dirname -- "$count_file")/connect.log"
}

# 响应只写 fd 3（TLS 通道）；200 只在拨号成功后发送。
mapping_proxy_reply() {
    case "${1:-}" in
        200) printf 'HTTP/1.1 200 Connection Established\r\n\r\n' >&3 ;;
        403) printf 'HTTP/1.1 403 Forbidden\r\n\r\n' >&3 ;;
        405) printf 'HTTP/1.1 405 Method Not Allowed\r\n\r\n' >&3 ;;
        502) printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n' >&3 ;;
        *) return 1 ;;
    esac
    return 0
}

# 拨号边界：只接受字面量地址，直接连冻结 U:443，不解析 CONNECT 目标主机名。
mapping_proxy_dial() {
    local ip=${1:-} port=${2:-} coproc_in coproc_out
    mapping_proxy_upstream_literal "$ip" || return 1
    [[ $port == "$MAPPING_UPSTREAM_PORT" ]] || return 1
    coproc { timeout 60 busybox nc -q 60 "$ip" "$port"; }
    MAPPING_PROXY_DIAL_PID=$COPROC_PID
    coproc_in=${COPROC[1]}
    coproc_out=${COPROC[0]}
    exec 4>&"$coproc_in" 5<&"$coproc_out"
    exec {coproc_in}>&- {coproc_out}<&-
}

# 中继边界：内层 TLS 不终结，仅透传字节。
mapping_proxy_relay() {
    local relay_timeout=${MAPPING_PROXY_RELAY_TIMEOUT:-60} upload_pid download_pid dial_pid=${MAPPING_PROXY_DIAL_PID:-} completed='' first_rc=0 second_rc=0 interrupted=0
    [[ $relay_timeout =~ ^[1-9][0-9]*$ ]] || return "$MAPPING_FAILURE"
    timeout "$relay_timeout" cat <&0 >&4 &
    upload_pid=$!
    timeout "$relay_timeout" cat <&5 >&3 &
    download_pid=$!
    trap 'interrupted=1; kill -TERM "$upload_pid" "$download_pid" ${dial_pid:-} 2>/dev/null || true' TERM INT HUP
    wait -n -p completed "$upload_pid" "$download_pid" || first_rc=$?
    if [[ $completed == "$download_pid" ]]; then
        kill -TERM "$upload_pid" 2>/dev/null || true
        wait "$upload_pid" 2>/dev/null || true
    else
        exec 4>&-
        wait "$download_pid" || second_rc=$?
    fi
    trap - TERM INT HUP
    kill -TERM "$upload_pid" "$download_pid" 2>/dev/null || true
    wait "$upload_pid" 2>/dev/null || true
    wait "$download_pid" 2>/dev/null || true
    exec 4>&- 5<&- 3>&-
    if [[ $dial_pid =~ ^[1-9][0-9]*$ ]]; then
        wait "$dial_pid" 2>/dev/null || true
    fi
    MAPPING_PROXY_DIAL_PID=''
    (( interrupted == 0 && first_rc == 0 && second_rc == 0 )) || return "$MAPPING_FAILURE"
    return 0
}

# 回收当前端口的单连接 TLS 子进程与 FIFO。
mapping_proxy_tls_stop() {
    local dir=${MAPPING_PROXY_RUNTIME_DIR:-} pid=${MAPPING_PROXY_TLS_PID:-}
    exec 3>&- 0<&-
    if [[ $pid =~ ^[1-9][0-9]*$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    MAPPING_PROXY_TLS_PID=''
    [[ -z $dir ]] || rm -f "$dir/in" "$dir/out"
    return 0
}

# TLS 接受边界：openssl s_server 终结外层 TLS，请求走 fd 0、响应走 fd 3。
# 真实判定由实机验证；契约测试替换本边界以校验接线与判据。
mapping_proxy_tls_start() {
    local port=${1:-} cert=${2:-} key=${3:-} dir=${MAPPING_PROXY_RUNTIME_DIR:-} in_fifo out_fifo
    [[ -n $port && -n $cert && -n $key && -n $dir ]] || return 1
    [[ -f $cert && -f $key ]] || return 1
    mkdir -p "$dir" || return 1
    rm -f "$dir/in" "$dir/out"
    mkfifo "$dir/in" "$dir/out" || return 1
    in_fifo=$dir/in
    out_fifo=$dir/out
    openssl s_server -quiet -naccept 1 -accept "$port" -cert "$cert" -key "$key" <"$in_fifo" >"$out_fifo" 2>/dev/null &
    MAPPING_PROXY_TLS_PID=$!
    exec 3>"$in_fifo"
    exec 0<"$out_fifo"
    return 0
}

# CONNECT 循环：合法 authority 才拨号；拒绝模式与不匹配 authority 一律不拨号。
mapping_proxy_loop() {
    local count_file=${1:-} upstream=${2:-} mode=${3:-} line header target dial_target
    while IFS= read -r line; do
        line=${line%$'\r'}
        while IFS= read -r header; do
            header=${header%$'\r'}
            [[ -n $header ]] || break
        done
        case "$line" in
            CONNECT\ *) ;;
            *)
                mapping_proxy_reply 405 || return "$MAPPING_FAILURE"
                return 0
                ;;
        esac
        target=${line#CONNECT }
        target=${target%% *}
        mapping_proxy_count_bump "$count_file" || return "$MAPPING_FAILURE"
        dial_target='-'
        if [[ $target != "$MAPPING_PROXY_AUTHORITY" ]]; then
            mapping_proxy_record "$count_file" "$target" "$mode" "$dial_target" || return "$MAPPING_FAILURE"
            mapping_proxy_reply 502 || return "$MAPPING_FAILURE"
            return 0
        fi
        if [[ $mode != accept ]]; then
            mapping_proxy_record "$count_file" "$target" "$mode" "$dial_target" || return "$MAPPING_FAILURE"
            mapping_proxy_reply 403 || return "$MAPPING_FAILURE"
            return 0
        fi
        mapping_proxy_record "$count_file" "$target" "$mode" "$upstream:$MAPPING_UPSTREAM_PORT" || return "$MAPPING_FAILURE"
        if ! mapping_proxy_dial "$upstream" "$MAPPING_UPSTREAM_PORT"; then
            mapping_proxy_reply 502 || return "$MAPPING_FAILURE"
            return 0
        fi
        mapping_proxy_reply 200 || return "$MAPPING_FAILURE"
        mapping_proxy_relay || return "$MAPPING_FAILURE"
        return 0
    done
    return 0
}

# 代理进程入口（接口 D）：读数损坏返回 80，用法错误返回 2。
# 参数：<端口> <证书> <私钥> <计数文件> <上游地址> <accept|reject>
mapping_proxy_serve() {
    local port=${1:-} cert=${2:-} key=${3:-} count_file=${4:-} upstream=${5:-} mode=${6:-} rc=0 connections=0
    [[ $# == 6 && $port =~ ^[0-9]{1,5}$ && -n $cert && -n $key && -n $count_file ]] || return "$MAPPING_USAGE"
    case " $MAPPING_PROXY_MODES " in
        *" $mode "*) ;;
        *) return "$MAPPING_USAGE" ;;
    esac
    mapping_proxy_upstream_literal "$upstream" || return "$MAPPING_USAGE"
    mkdir -p "$(dirname -- "$count_file")" || return "$MAPPING_FAILURE"
    [[ -e $count_file ]] || printf '0\n' > "$count_file" || return "$MAPPING_FAILURE"
    mapping_proxy_count_read "$count_file" >/dev/null || return "$MAPPING_FAILURE"
    MAPPING_PROXY_RUNTIME_DIR=$(dirname -- "$count_file")/rt/$port
    trap 'mapping_proxy_tls_stop; exit "$MAPPING_FAILURE"' TERM INT HUP
    while :; do
        mapping_proxy_tls_start "$port" "$cert" "$key" || { trap - TERM INT HUP; return "$MAPPING_FAILURE"; }
        rc=0
        mapping_proxy_loop "$count_file" "$upstream" "$mode" || rc=$?
        mapping_proxy_tls_stop
        [[ $rc == 0 ]] || { trap - TERM INT HUP; return "$MAPPING_FAILURE"; }
        connections=$((connections + 1))
        [[ ${MAPPING_PROXY_ONCE:-0} != 1 ]] || break
        if [[ ${MAPPING_PROXY_CONNECTION_LIMIT:-} =~ ^[1-9][0-9]*$ ]] \
            && (( connections >= MAPPING_PROXY_CONNECTION_LIMIT )); then
            break
        fi
    done
    trap - TERM INT HUP
    return 0
}

# 分层判据：外层 TLS 失败时不得增长；内层 TLS 失败必须有合法 CONNECT 但请求失败。
mapping_proxy_layer_verdict() {
    local before=${1:-} after=${2:-} request_exit=${3:-}
    [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ && $request_exit =~ ^[0-9]+$ ]] || return 1
    (( after >= before )) || return 1
    if (( request_exit == 0 )); then
        (( after > before )) || return 1
        printf 'ok\n'
        return 0
    fi
    if (( after > before )); then printf 'inner-failure\n'; return 0; fi
    printf 'outer-failure\n'
    return 0
}

# 资产生成脚本：两条独立签发链、SAN、静态上游健康文件。变量经 env 注入，不写入镜像。
mapping_asset_script() {
    cat <<'MAPPING_ASSET'
set -eu
umask 022
R=${MAPPING_ASSET_ROOT:?}
up=$R/upstream
px=$R/proxy
mkdir -p "$up/tls" "$up/web" "$px/tls"
rm -f "$up/tls"/* "$px/tls"/*
gen_chain() {
    dir=$1
    caname=$2
    cn=$3
    san=$4
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$caname" \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
        -keyout "$dir/tls/ca.key" -out "$dir/tls/ca.crt" >/dev/null 2>&1
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$cn" -keyout "$dir/tls/srv.key" -out "$dir/tls/srv.csr" >/dev/null 2>&1
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$san" > "$dir/tls/srv.ext"
    openssl x509 -req -in "$dir/tls/srv.csr" -CA "$dir/tls/ca.crt" -CAkey "$dir/tls/ca.key" \
        -CAcreateserial -days 2 -extfile "$dir/tls/srv.ext" -out "$dir/tls/srv.crt" >/dev/null 2>&1
    rm -f "$dir/tls/srv.csr" "$dir/tls/srv.ext" "$dir/tls/ca.srl"
}
gen_chain "$up" GM-Mapping-Upstream-CA "$MAPPING_UPSTREAM_HOST" "$MAPPING_UPSTREAM_HOST"
gen_chain "$px" GM-Mapping-Proxy-CA "$MAPPING_PROXY_HOST" "$MAPPING_PROXY_HOST"
printf '%s\n' "${MAPPING_UPSTREAM_HEALTH:?}" > "$up/web/health.txt"
MAPPING_ASSET
}

# 代理脚本：由既有函数体生成，避免整块复制到卷内。
mapping_proxy_script() {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'MAPPING_PROXY_AUTHORITY=%q\n' "$MAPPING_PROXY_AUTHORITY"
    printf 'MAPPING_UPSTREAM_PORT=%q\n' "$MAPPING_UPSTREAM_PORT"
    printf 'MAPPING_PROXY_MODES=%q\n' "$MAPPING_PROXY_MODES"
    printf 'MAPPING_FAILURE=%q\n' "$MAPPING_FAILURE"
    printf 'MAPPING_USAGE=%q\n' "$MAPPING_USAGE"
    declare -f mapping_proxy_upstream_literal mapping_proxy_count_strict mapping_proxy_count_read \
        mapping_proxy_count_bump mapping_proxy_log_path_from_count mapping_proxy_record \
        mapping_proxy_reply mapping_proxy_dial mapping_proxy_relay mapping_proxy_tls_stop mapping_proxy_tls_start \
        mapping_proxy_loop mapping_proxy_serve
    printf 'mapping_proxy_serve "$@"\n'
}

# 资产生成容器边界：单个资产卷挂在镜像既有的 10001 属主目录上，脚本以 UID 10001 运行。
mapping_fixture_asset_exec() {
    local script=${1:-} image=${2:-}
    [[ -n $script && -n $image ]] || return 1
    mapping_fixture_docker run --rm --user 10001:10001 --network none \
        -e "MAPPING_ASSET_ROOT=$MAPPING_ASSET_ROOT" \
        -e "MAPPING_UPSTREAM_HOST=$MAPPING_UPSTREAM_HOST" \
        -e "MAPPING_PROXY_HOST=$MAPPING_PROXY_HOST" \
        -e "MAPPING_UPSTREAM_HEALTH=$MAPPING_UPSTREAM_HEALTH" \
        -v "$(mapping_assets_volume):$MAPPING_ASSET_ROOT" --entrypoint /bin/sh "$image" -c "$script"
}

# 资产卷内写文件边界：内容经标准输入送入容器，不落宿主路径。
mapping_fixture_asset_write() {
    local relpath=${1:-} content=${2:-} image=${3:-} status=0
    [[ -n $relpath && -n $image ]] || return 1
    printf '%s' "$content" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" \
        -c "umask 022; mkdir -p \"\$(dirname -- '$relpath')\"; cat > '$relpath' && chmod 755 '$relpath'" || status=$?
    [[ $status == 0 ]] || return 1
    return 0
}

# 客户端 CA 卷只发布公开根证书：从资产卷读取证书再写入 CA 卷，私钥绝不进入客户端卷。
mapping_fixture_ca_publish() {
    local image=${1:-} spec role source target status=0
    [[ -n $image ]] || return 1
    for spec in 'upstream upstream/tls/ca.crt upstream-ca.crt' 'proxy proxy/tls/ca.crt proxy-ca.crt'; do
        read -r role source target <<< "$spec"
        mapping_fixture_docker run --rm --user 10001:10001 --network none \
            -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint cat "$image" "$source" \
            | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
                -v "$(mapping_ca_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" \
                -c "umask 022; cat > '$target'" || status=$?
        [[ $status == 0 ]] || return 1
        printf 'MAPPING_CA_PUBLISH=%s -> %s\n' "$role" "$target"
    done
    return 0
}

# 资产卷经资源账本创建并登记：账本目录不可解析或身份为空一律拒绝。
# 三个卷角色固定 assets（只读资产）、ca（客户端公开 CA）、evidence（上游连接取证，rw）。
mapping_assets_volumes_create() {
    local ledger=${1:-} scenario=${2:-$MAPPING_LEDGER_SCENARIO} spec role volume
    [[ -n $ledger ]] || return 1
    mapping_scenario_valid "$scenario" || return 1
    for spec in "$MAPPING_ASSET_VOLUME_ROLE:$(mapping_assets_volume)" \
        "$MAPPING_CA_VOLUME_ROLE:$(mapping_ca_volume)"; do
        role=${spec%%:*}
        volume=${spec#*:}
        [[ -n $role && -n $volume ]] || return 1
        RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
        resource_create_register volume "$scenario" "$role" -- \
            resource_docker volume create \
            --label "gitdaemon.run=$MP_RUN_ID" \
            --label "gitdaemon.scenario=$scenario" \
            --label "gitdaemon.role=$role" \
            "$volume" || return 1
        [[ -n $RESOURCE_CREATED_ID ]] || return 1
    done
    return 0
}

# 资产准备（接口 D）：两条独立签发链、SAN、客户端公开 CA 卷与代理脚本。
# 返回 0 或 80；冻结档案或场景标识非法同样按夹具失败返回。
mapping_assets_prepare() {
    local profile=${1:-} scenario=${2:-} product_image=${3:-} ledger=${4:-} script
    [[ $# == 4 && -n $profile && -n $scenario && -n $product_image && -n $ledger ]] || return "$MAPPING_FAILURE"
    mapping_scenario_valid "$scenario" || return "$MAPPING_FAILURE"
    mapping_profile_load "$profile" || return "$MAPPING_FAILURE"
    mapping_state_dir >/dev/null || return "$MAPPING_FAILURE"
    mapping_assets_volumes_create "$ledger" "$scenario" || return "$MAPPING_FAILURE"
    script=$(mapping_asset_script) || return "$MAPPING_FAILURE"
    mapping_fixture_asset_exec "$script" "$product_image" || return "$MAPPING_FAILURE"
    mapping_fixture_asset_write 'upstream/serve.sh' "$(mapping_upstream_serve_script)" "$product_image" || return "$MAPPING_FAILURE"
    mapping_fixture_asset_write 'proxy/proxy.sh' "$(mapping_proxy_script)" "$product_image" || return "$MAPPING_FAILURE"
    mapping_fixture_ca_publish "$product_image" || return "$MAPPING_FAILURE"
    mapping_fixture_state_write run_id "$MP_RUN_ID" || return "$MAPPING_FAILURE"
    mapping_fixture_state_write scenario "$scenario" || return "$MAPPING_FAILURE"
    mapping_fixture_state_write product_image "$product_image" || return "$MAPPING_FAILURE"
    return 0
}

# 受控 DNS 参数：gm-proxy 指向 X，其余（含 github.com）不解析，且不递归外部。
# 仅当假绿开关被显式设置时，才额外把指定名称解析到指定地址（安全负例专用）。
mapping_dns_daemon_args() {
    local profile=${1:-} fake=''
    mapping_profile_load "$profile" || return 1
    if [[ -n ${MAPPING_DNS_FAKE_HOST:-} && -n ${MAPPING_DNS_FAKE_IP:-} ]]; then
        fake="--address=/$MAPPING_DNS_FAKE_HOST/$MAPPING_DNS_FAKE_IP"
    fi
    printf '%s\n' dnsmasq --keep-in-foreground --no-resolv --no-hosts \
        "--address=/$MAPPING_PROXY_HOST/$MP_X" '--address=/#/' $fake \
        --log-queries --log-facility=- --pid-file= --user=git-daemon
}

mapping_dns_set() {
    local mode=${1:-} scenario=${2:-} dir=${3:-} name id args client state observed
    [[ $mode == nxdomain || $mode == upstream ]] || return "$MAPPING_FAILURE"
    [[ -n $scenario && -d $dir && -n ${MAPPING_PROFILE:-} && -n ${MAPPING_TOOLS_IMAGE:-} ]] || return "$MAPPING_FAILURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_FAILURE"
    name=$(mapping_dns_container) || return "$MAPPING_FAILURE"
    id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$name") || return "$MAPPING_FAILURE"
    [[ -n $id ]] || return "$MAPPING_FAILURE"
    resource_remove container "$id" || return "$MAPPING_FAILURE"
    if [[ $mode == upstream ]]; then
        MAPPING_DNS_FAKE_HOST=$MAPPING_UPSTREAM_HOST MAPPING_DNS_FAKE_IP=$MP_U
    else
        MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    fi
    args=$(mapping_dns_daemon_args "$MAPPING_PROFILE") || return "$MAPPING_FAILURE"
    mapping_fixture_run "$scenario" dns -d --name "$name" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_D" \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$MAPPING_DNS_PORT" \
        "$MAPPING_TOOLS_IMAGE" $args >/dev/null || return "$MAPPING_FAILURE"
    mapping_fixture_wait "$name" || return "$MAPPING_FAILURE"
    for client in ${MAPPING_ASSERT_PRODUCT:+"$MAPPING_ASSERT_PRODUCT"}; do
        mapping_fixture_docker restart "$client" >/dev/null || return "$MAPPING_FAILURE"
        mapping_fixture_wait "$client" || return "$MAPPING_FAILURE"
    done
    state=$dir/dns-rebuild-$mode.tsv
    mapping_scenario_dns_state "${MAPPING_ASSERT_KIND:-fallback}" "$scenario" "$dir" > "$state" || return "$MAPPING_FAILURE"
    if [[ -n ${MAPPING_ASSERT_PRODUCT:-} ]]; then
        observed=$dir/dns-client-$mode.tsv
        : > "$observed" || return "$MAPPING_FAILURE"
        mapping_scenario_dns_client_probe "$MAPPING_ASSERT_PRODUCT" "$dir" "$observed" || return "$MAPPING_FAILURE"
        cmp -s "$state" "$observed" || return "$MAPPING_FAILURE"
    fi
    if [[ $mode == nxdomain ]]; then
        mapping_assert_dns_file "$state" || return "$MAPPING_FAILURE"
    else
        grep -Fqx "$(printf '%s\tA\t%s' "$MAPPING_UPSTREAM_HOST" "$MP_U")" "$state" || return "$MAPPING_FAILURE"
        grep -Fqx "$(printf '%s\tAAAA\tNXDOMAIN' "$MAPPING_UPSTREAM_HOST")" "$state" || return "$MAPPING_FAILURE"
    fi
    return 0
}

# 上游服务脚本：逐连接接受一次并记录 requests.log，供 U:443 实际连接计数取证。
# 请求日志与 serve.log 落在独立可写证据卷（MAPPING_EVIDENCE_ROOT），证书私钥仍留在只读资产卷；
# 只读文件系统上的写重定向会失败并使循环空转，因此两者必须分开挂载。
# 以 -naccept 1 循环使每次接受的连接恰好落一行证据，不依赖外部递归。
mapping_upstream_serve_script() {
    cat <<'MAPPING_SERVE'
set -u
R=${MAPPING_ASSET_ROOT:?}
E=${MAPPING_EVIDENCE_ROOT:?}
mkdir -p "$E" || exit 1
cd "$R/upstream/web" || exit 1
if test ! -f "$E/requests.log"; then : > "$E/requests.log" || exit 1; fi
while :; do
    openssl s_server -quiet -naccept 1 -accept 443 \
        -cert "$R/upstream/tls/srv.crt" -key "$R/upstream/tls/srv.key" -WWW \
        >"$E/serve.log" 2>&1
    printf '%s\n' connection >> "$E/requests.log"
done
MAPPING_SERVE
}

# 上游 U:443 实际连接计数：经 docker exec 读取 requests.log，缺失或损坏一律非零，
# 绝不默认为零，从而拒绝「未取到上游连接证据」的空跑。
mapping_upstream_evidence_count() {
    local scenario=${1:-} raw
    mapping_scenario_valid "$scenario" || return 1
    raw=$(mapping_fixture_docker exec "$(mapping_upstream_container)" \
        sh -c "wc -l < '$MAPPING_UPSTREAM_REQUESTS'" 2>/dev/null) || return 1
    mapping_proxy_count_strict "$raw"
}

# 上游 Git 助手脚本：在资产卷内的 dumb HTTP 服务目录初始化并推进受控仓库。
# 变量经 env 注入，不写入镜像；助手只在容器内运行。
mapping_upstream_git_script() {
    cat <<'MAPPING_GIT'
set -eu
R=${MAPPING_ASSET_ROOT:?}
repo="$R/upstream/web/${MAPPING_UPSTREAM_PATH:?}"
action=${1:-}
case "$action" in
    init)
        mkdir -p "$repo"
        git init -q --bare "$repo"
        git --git-dir="$repo" symbolic-ref HEAD "${MAPPING_UPSTREAM_REF:?}"
        ;;
    commit)
        msg=${2:-}
        [ -n "$msg" ] || exit 2
        work=$(mktemp -d)
        git clone -q "$repo" "$work"
        printf '%s\n' "$msg" > "$work/commit.txt"
        git -C "$work" add commit.txt
        git -C "$work" -c user.email=fixture@example.invalid -c user.name=fixture \
            commit -q -m "$msg"
        git -C "$work" push -q origin "HEAD:${MAPPING_UPSTREAM_REF:?}"
        rm -rf "$work"
        git --git-dir="$repo" update-server-info
        git --git-dir="$repo" rev-parse "${MAPPING_UPSTREAM_REF:?}"
        ;;
    refs)
        git --git-dir="$repo" for-each-ref --format='%(objectname)%09%(refname)'
        ;;
    head)
        git --git-dir="$repo" rev-parse "${MAPPING_UPSTREAM_REF:?}"
        ;;
    update)
        git --git-dir="$repo" update-server-info
        ;;
    *) exit 2 ;;
esac
exit 0
MAPPING_GIT
}

# 上游 Git 助手执行边界：网络 none、UID 10001，只挂资产卷，绝不联网、不触真实 daemon 之外资源。
mapping_upstream_git_run() {
    local image=${1:-} action=${2:-} msg=${3:-} script
    [[ -n $image && -n $action ]] || return 1
    script=$(mapping_upstream_git_script) || return 1
    printf '%s' "$script" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -e "MAPPING_ASSET_ROOT=$MAPPING_ASSET_ROOT" \
        -e "MAPPING_UPSTREAM_PATH=$MAPPING_UPSTREAM_PATH" \
        -e "MAPPING_UPSTREAM_REF=$MAPPING_UPSTREAM_REF" \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" \
        -s "$action" ${msg:+"$msg"}
}

# 夹具前置核验：映射网络与三个资产/取证卷必须已存在且身份相符。
mapping_fixture_precheck() {
    local name value
    value=$(mapping_fixture_docker network inspect -f '{{.Name}}' "$MP_NETWORK_NAME" 2>/dev/null) || return 1
    [[ $value == "$MP_NETWORK_NAME" ]] || return 1
    for name in "$(mapping_assets_volume)" "$(mapping_ca_volume)" "$(mapping_evidence_volume)"; do
        value=$(mapping_fixture_docker volume inspect -f '{{.Name}}' "$name" 2>/dev/null) || return 1
        [[ $value == "$name" ]] || return 1
    done
    return 0
}

# 夹具容器统一经登记边界创建（不启动）：create 返回身份 → 登记；失败即非零。
# 参数：<场景> <角色> <docker create 其余参数...>
mapping_fixture_create() {
    local scenario=${1:-} role=${2:-} id
    shift 2
    [[ -n $scenario && -n $role ]] || return 1
    RESOURCE_LEDGER_DIR=$(resource_ledger_dir) || return 1
    RESOURCE_RUN=$MP_RUN_ID
    resource_create_register container "$scenario" "$role" -- \
        resource_docker create \
        --label "gitdaemon.run=$MP_RUN_ID" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$role" "$@" || return 1
    id=$RESOURCE_CREATED_ID
    [[ -n $id ]] || return 1
    printf '%s\n' "$id"
}

# 夹具容器统一经登记边界创建并启动：create 返回身份 → 登记 → start。
# 参数：<场景> <角色> <docker create 其余参数...>
mapping_fixture_run() {
    local scenario=${1:-} role=${2:-} id
    shift 2
    id=$(mapping_fixture_create "$scenario" "$role" "$@") || return 1
    mapping_fixture_docker start "$id" >/dev/null || return 1
    printf '%s\n' "$id"
}

# 等待夹具容器保持运行；短超时即失败。
mapping_fixture_wait() {
    local name=$1 i
    for ((i = 0; i < 20; i++)); do
        [[ $(mapping_fixture_docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]] && return 0
        sleep 0.5
    done
    return 1
}

# 夹具启动（接口 D）：上游 U（无 github.com 别名）、代理 X（两端口独立计数文件）、
# 受控 DNS D 与校准探针 P；返回 0 或 80。
mapping_fixture_start() {
    local profile=${1:-} scenario=${2:-} product_image=${3:-} tools_image=${4:-}
    local root="$MAPPING_ASSET_ROOT" accept_count reject_count proxy_cmd dns_args
    [[ $# == 4 && -n $profile && -n $scenario && -n $product_image && -n $tools_image ]] || return "$MAPPING_FAILURE"
    mapping_scenario_valid "$scenario" || return "$MAPPING_FAILURE"
    mapping_profile_load "$profile" || return "$MAPPING_FAILURE"
    mapping_fixture_precheck || return "$MAPPING_FAILURE"
    dns_args=$(mapping_dns_daemon_args "$profile") || return "$MAPPING_FAILURE"
    accept_count=$(mapping_proxy_count_path "$scenario" "$MAPPING_PROXY_ACCEPT_PORT") || return "$MAPPING_FAILURE"
    reject_count=$(mapping_proxy_count_path "$scenario" "$MAPPING_PROXY_REJECT_PORT") || return "$MAPPING_FAILURE"
    # 上游：固定地址 U，资产卷只读（证书私钥只在此）、连接证据卷可写；绝不带 github.com 网络别名。
    mapping_fixture_run "$scenario" upstream -d --name "$(mapping_upstream_container)" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_U" \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$MAPPING_UPSTREAM_PORT" \
        -v "$(mapping_assets_volume):$root:ro" \
        -v "$(mapping_evidence_volume):$MAPPING_EVIDENCE_MOUNT" \
        -e "MAPPING_EVIDENCE_ROOT=$MAPPING_EVIDENCE_MOUNT" \
        --entrypoint /bin/sh "$tools_image" \
        -c "exec $root/upstream/serve.sh" \
        >/dev/null || return "$MAPPING_FAILURE"
    # 代理：固定地址 X；接受/拒绝端口各用独立计数文件，同一进程不并发读改同一文件。
    proxy_cmd="$root/proxy/proxy.sh $MAPPING_PROXY_ACCEPT_PORT $root/proxy/tls/srv.crt $root/proxy/tls/srv.key $accept_count $MP_U accept &"
    proxy_cmd+=" $root/proxy/proxy.sh $MAPPING_PROXY_REJECT_PORT $root/proxy/tls/srv.crt $root/proxy/tls/srv.key $reject_count $MP_U reject & wait"
    mapping_fixture_run "$scenario" proxy -d --name "$(mapping_proxy_container)" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_X" --dns "$MP_D" \
        -v "$(mapping_assets_volume):$root" --entrypoint /bin/bash "$tools_image" \
        -c "$proxy_cmd" >/dev/null || return "$MAPPING_FAILURE"
    # 受控 DNS：gm-proxy → X，github.com 与其他名称均不可解析，不递归外部。
    # cap-drop ALL 下绑定 53 需同上游 443 一样下移非特权端口起点，否则真实环境无法监听。
    mapping_fixture_run "$scenario" dns -d --name "$(mapping_dns_container)" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_D" \
        --sysctl "net.ipv4.ip_unprivileged_port_start=$MAPPING_DNS_PORT" \
        "$tools_image" $dns_args >/dev/null || return "$MAPPING_FAILURE"
    # 校准探针：无产品时以登记 probe 使用冻结地址 P，只读挂载公开 CA 卷。
    mapping_fixture_run "$scenario" probe -d --name "$(mapping_probe_container)" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_P" --dns "$MP_D" \
        -v "$(mapping_ca_volume):$MAPPING_CA_MOUNT:ro" --entrypoint /bin/sh "$product_image" \
        -c 'sleep 900' >/dev/null || return "$MAPPING_FAILURE"
    mapping_fixture_wait "$(mapping_upstream_container)" || return "$MAPPING_FAILURE"
    mapping_fixture_wait "$(mapping_proxy_container)" || return "$MAPPING_FAILURE"
    mapping_fixture_wait "$(mapping_dns_container)" || return "$MAPPING_FAILURE"
    mapping_fixture_wait "$(mapping_probe_container)" || return "$MAPPING_FAILURE"
    mapping_fixture_state_write tools_image "$tools_image" || return "$MAPPING_FAILURE"
    mapping_fixture_state_write upstream_ip "$MP_U" || return "$MAPPING_FAILURE"
    return 0
}

# 读取单个端口的代理计数：经 docker exec 读卷内文件，缺失/损坏一律非零，绝不默认成 0。
mapping_proxy_count_read_remote() {
    local port=${1:-} file raw
    file=$(mapping_proxy_count_path "$MPF_SCENARIO" "$port") || return 1
    raw=$(mapping_fixture_docker exec "$(mapping_proxy_container)" cat "$file" 2>/dev/null) || return 1
    mapping_proxy_count_strict "$raw"
}

# 接受端口正校准：经 gm-proxy:8443 完成内层 HTTPS 获取，期望 200 且内容匹配。
# 参数：<场景证据目录>；客户端探针边界可在契约测试中替换。
mapping_proxy_probe_accept() {
    local scenario_dir=${1:-} out rc=0
    [[ -n $scenario_dir && -d $scenario_dir ]] || return 1
    out=$(mapping_fixture_docker exec "$(mapping_probe_container)" \
        curl --silent --show-error --fail \
        --proxy "https://$MAPPING_PROXY_HOST:$MAPPING_PROXY_ACCEPT_PORT" \
        --proxy-cacert "$MAPPING_CLIENT_PROXY_CA" --cacert "$MAPPING_CLIENT_UPSTREAM_CA" \
        "https://$MAPPING_UPSTREAM_HOST/health.txt" 2>&1) || rc=$?
    printf '%s\n' "$out" > "$scenario_dir/proxy.probe-accept" || return 1
    (( rc == 0 )) || return 1
    [[ $out == *"$MAPPING_UPSTREAM_HEALTH"* ]] || return 1
    return 0
}

# 拒绝端口校准：合法 CONNECT 必须收到 403，且不接受 200。
mapping_proxy_probe_reject() {
    local scenario_dir=${1:-} out rc=0
    [[ -n $scenario_dir && -d $scenario_dir ]] || return 1
    out=$(mapping_fixture_docker exec "$(mapping_probe_container)" \
        curl --silent --show-error \
        --proxy "https://$MAPPING_PROXY_HOST:$MAPPING_PROXY_REJECT_PORT" \
        --proxy-cacert "$MAPPING_CLIENT_PROXY_CA" \
        "https://$MAPPING_UPSTREAM_HOST/health.txt" 2>&1) || rc=$?
    printf '%s\n' "$out" > "$scenario_dir/proxy.probe-reject" || return 1
    (( rc != 0 )) || return 1
    [[ $out == *403* ]] || return 1
    return 0
}

# CONNECT 证据核验：authority 精确相等，拨号目的只能是冻结 U:443，拒绝端口不得拨号。
mapping_proxy_log_check() {
    local log target
    target="$MPF_UPSTREAM_IP:$MAPPING_UPSTREAM_PORT"
    log=$(mapping_fixture_docker exec "$(mapping_proxy_container)" \
        cat "$(mapping_proxy_log_path "$MPF_SCENARIO")" 2>/dev/null) || return 1
    awk -v authority="$MAPPING_PROXY_AUTHORITY" -v target="$target" '
    NF == 0 { next }
    {
        auth = ""; mode = ""; dial = ""
        n = split($0, field, "\t")
        for (i = 1; i <= n; i++) {
            if (field[i] ~ /^authority=/) auth = substr(field[i], 11)
            if (field[i] ~ /^mode=/) mode = substr(field[i], 6)
            if (field[i] ~ /^dial_target=/) dial = substr(field[i], 13)
        }
        if (auth == "" || mode == "" || dial == "") bad = 1
        if (dial != "-" && dial != target) bad = 1
        if (dial != "-" && auth != authority) bad = 1
        if (auth == authority && mode == "accept" && dial == target) seen_accept = 1
        if (auth == authority && mode == "reject" && dial == "-") seen_reject = 1
    }
    END { if (bad || !seen_accept || !seen_reject) exit 1 }
    ' <<< "$log"
}

# 基线：两端口计数求和后一并保存，读取时校验求和一致。
mapping_proxy_baseline_write() {
    local scenario_dir=${1:-} accept=${2:-} reject=${3:-}
    [[ -n $scenario_dir && -d $scenario_dir ]] || return 1
    [[ $accept =~ ^[0-9]+$ && $reject =~ ^[0-9]+$ ]] || return 1
    {
        printf 'accept\t%s\n' "$accept"
        printf 'reject\t%s\n' "$reject"
        printf 'total\t%s\n' "$((accept + reject))"
    } > "$scenario_dir/proxy.before.tmp" || return 1
    mv -- "$scenario_dir/proxy.before.tmp" "$scenario_dir/proxy.before"
}

mapping_proxy_baseline_total() {
    local file=${1:-} key value accept='' reject='' total=''
    [[ -n $file && -f $file && ! -L $file ]] || return 1
    while IFS=$'\t' read -r key value || [[ -n $key ]]; do
        case "$key" in
            accept) [[ -z $accept ]] || return 1; accept=$value ;;
            reject) [[ -z $reject ]] || return 1; reject=$value ;;
            total) [[ -z $total ]] || return 1; total=$value ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ $accept =~ ^[0-9]+$ && $reject =~ ^[0-9]+$ && $total =~ ^[0-9]+$ ]] || return 1
    (( total == accept + reject )) || return 1
    printf '%s\n' "$total"
}

# 代理校准（接口 D）：先证明接受端口可达、拒绝端口 403、两端口计数增长且 authority 精确，
# 再保存基线；任一读数缺失、损坏或非非负整数一律返回 80。
mapping_proxy_calibrate() {
    local scenario_dir=${1:-} before_accept before_reject after_accept after_reject
    [[ -n $scenario_dir && -d $scenario_dir && ! -L $scenario_dir ]] || return "$MAPPING_FAILURE"
    mapping_fixture_state_load || return "$MAPPING_FAILURE"
    before_accept=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return "$MAPPING_FAILURE"
    before_reject=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_REJECT_PORT") || return "$MAPPING_FAILURE"
    mapping_proxy_probe_accept "$scenario_dir" || return "$MAPPING_FAILURE"
    mapping_proxy_probe_reject "$scenario_dir" || return "$MAPPING_FAILURE"
    after_accept=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return "$MAPPING_FAILURE"
    after_reject=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_REJECT_PORT") || return "$MAPPING_FAILURE"
    (( after_accept > before_accept )) || return "$MAPPING_FAILURE"
    (( after_reject > before_reject )) || return "$MAPPING_FAILURE"
    mapping_proxy_log_check || return "$MAPPING_FAILURE"
    mapping_proxy_baseline_write "$scenario_dir" "$after_accept" "$after_reject" || return "$MAPPING_FAILURE"
    return 0
}

# 证书判据（真实拓扑判据属实机验证；此处校验判据本身）：SAN 精确包含指定主机名。
mapping_cert_san_has() {
    local cert=${1:-} host=${2:-} san
    [[ -n $cert && -n $host && -f $cert && ! -L $cert ]] || return 1
    san=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) || return 1
    awk -v want="DNS:$host" '{ n = split($0, item, /[ ,]+/); for (i = 1; i <= n; i++) if (item[i] == want) found = 1 } END { exit found ? 0 : 1 }' <<< "$san"
}

# 证书链判据：叶证书必须能由给定 CA 验证通过。
mapping_cert_verifies_with() {
    local cert=${1:-} ca=${2:-}
    [[ -n $cert && -n $ca && -f $cert && -f $ca ]] || return 1
    openssl verify -CAfile "$ca" "$cert" >/dev/null 2>&1
}

# 证书指纹：用于证明两条根证书互不相同。
mapping_cert_fingerprint() {
    local cert=${1:-}
    [[ -n $cert && -f $cert ]] || return 1
    openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null
}
