#!/usr/bin/env bash
# Mapping 独立网络与策略夹具（网络部分）。
# 冻结地址档案、独立映射网络、按角色的附件/地址/安全校验、封闭拒绝策略与两端计数解析。
# 双 CA、代理与 DNS 资产属后续任务；本文件不安装真实规则、不启动业务进程。

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

# 运行状态文件：创建后追加不可变 network ID，不反写输入档案。
mapping_network_state_file() {
    if [[ -n ${IT_EVIDENCE_DIR:-} ]]; then
        printf '%s\n' "$IT_EVIDENCE_DIR/control/mapping-network.tsv"
        return 0
    fi
    if [[ -n ${MAPPING_LEDGER_DIR:-} ]]; then
        printf '%s\n' "$MAPPING_LEDGER_DIR/mapping-network.tsv"
        return 0
    fi
    return 1
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

# 通过资源账本创建本轮映射网络并登记；身份写入运行状态，返回 network ID。
mapping_network_create() {
    local profile=${1:-} ledger_dir=${2:-} id state
    [[ -n $profile && -n $ledger_dir ]] || return 2
    mapping_profile_load "$profile" || return $?
    state=$(mapping_network_state_file 2>/dev/null) || state=''
    [[ -z $state || ! -s $state ]] || return 2
    if ! declare -F resource_create_register >/dev/null; then return 2; fi
    RESOURCE_LEDGER_DIR=$ledger_dir RESOURCE_RUN=$MP_RUN_ID
    resource_create_register network mapping network -- \
        command docker network create --label "gitdaemon.run=$MP_RUN_ID" --ipv6=false \
        --subnet "$MP_CIDR" -o "com.docker.network.bridge.name=$MP_BRIDGE" \
        "$MP_NETWORK_NAME" || return $?
    id=$RESOURCE_CREATED_ID
    [[ -n $id ]] || return 2
    MP_NETWORK_ID=$id
    if [[ -n $state ]]; then
        printf 'network_id\t%s\n' "$id" >> "$state" || return 2
    fi
    printf '%s\n' "$id"
}

# 发送 READY 握手：payload 只引用冻结档案哈希与 network ID，不携带任意规则。
mapping_ready() {
    local profile=${1:-} network_id=${2:-}
    mapping_profile_load "$profile" || return $?
    [[ -n $network_id ]] || return 2
    network_control "mapping-ready $MP_PROFILE_SHA256 $network_id"
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

# 接收端见证快照解析：恰好三个协议端口键且计数为非负整数。
mapping_witness() {
    local snapshot=${1:-}
    [[ -n $snapshot && -f $snapshot && ! -L $snapshot ]] || return 1
    awk '
    $3 == "RETURN" {
        key = $4 ":" $11
        n++
        if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $10 != $4 || $8 != "0.0.0.0/0" || $9 != "0.0.0.0/0" || (key != "tcp:dpt:19419" && key != "udp:dpt:53" && key != "tcp:dpt:53")) bad = 1
        seen[key]++; count[key] = $1
    }
    END {
        if (bad || n != 3 || seen["tcp:dpt:19419"] != 1 || seen["udp:dpt:53"] != 1 || seen["tcp:dpt:53"] != 1) exit 1
        print count["tcp:dpt:19419"]; print count["udp:dpt:53"]; print count["tcp:dpt:53"]
    }' "$snapshot"
}

# 仅目标协议的见证计数必须增长，其余两项不得变化。
mapping_witness_delta() {
    local before=${1:-} after=${2:-} proto=${3:-}
    awk -v before="$before" -v after="$after" -v proto="$proto" 'BEGIN {
        if (split(before, b, "\n") != 3 || split(after, a, "\n") != 3 || (proto != "udp" && proto != "tcp")) exit 1
        target = (proto == "udp" ? 2 : 3)
        for (i = 1; i <= 3; i++) {
            if (b[i] !~ /^[0-9]+$/ || a[i] !~ /^[0-9]+$/) exit 1
            if (i == target) { if (a[i] + 0 <= b[i] + 0) exit 1 } else if (a[i] != b[i]) exit 1
        }
    }'
}

# 单个见证接收端的正校准探针，全部经 docker exec 边界。
mapping_receiver_probe() {
    local key=${1:-} spec proto port dest receiver
    mapping_witness_key_valid "$key" || return 1
    spec=$(mapping_witness_spec "$key") || return 1
    IFS=$'\t' read -r proto port dest <<< "$spec"
    receiver="gm-$MP_RUN_ID-witness"
    case "$key" in
        cross-network) docker exec "$receiver" sh -c "printf ping | nc -w1 -q1 $dest $port" ;;
        host-published) docker exec "$receiver" sh -c "printf ping | nc -w1 -q1 $dest $port" ;;
        host-input) docker exec "$receiver" sh -c "printf ping | nc -w1 -q1 $dest $port" ;;
        dns-udp) docker exec "$receiver" dig +time=1 +tries=1 +notcp "@$dest" "$MP_RUN_ID-witness.invalid" A ;;
        dns-tcp) docker exec "$receiver" dig +time=1 +tries=1 +tcp "@$dest" "$MP_RUN_ID-witness.invalid" A ;;
        *) return 1 ;;
    esac
}

# 逐项正校准接收端并覆盖 UDP/TCP；任一端未运行即失败，零计数不得被当作通过。
mapping_calibrate_witness() {
    local profile=${1:-} key spec proto port
    mapping_profile_load "$profile" || return $?
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key") || return 1
        IFS=$'\t' read -r proto port _ <<< "$spec"
        mapping_receiver_probe "$key" || return 1
        printf 'WITNESS_CALIBRATED=%s PROTOCOL=%s PORT=%s\n' "$key" "$proto" "$port"
    done
    MP_WITNESS_CALIBRATED=1
    return 0
}

# 从产品 netns 发起五类目标探测；预期全部被拒绝。
mapping_probe_egress() {
    local product=$1 generation=$2 spec proto port dest rc=0
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key") || return 1
        IFS=$'\t' read -r proto port dest <<< "$spec"
        case "$key" in
            dns-udp) docker exec "$product" timeout 4 busybox nslookup "$MP_RUN_ID-$generation.invalid" "$dest" || true ;;
            dns-tcp) docker exec "$product" timeout 4 busybox nslookup -tcp "$MP_RUN_ID-$generation.invalid" "$dest" || true ;;
            *) docker exec "$product" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$dest:$port/" || true ;;
        esac
    done
    return "$rc"
}

# 隔离判定：五类 DROP 计数均增长、接收端计数零变化；未完成正校准不得通过。
mapping_isolation_check() {
    local product=${1:-} generation=${2:-} profile=${3:-}
    local before after wb wa key cb ca seq_before seq_after base
    [[ -n $product && -n $generation && -n $profile ]] || return 1
    [[ $MP_WITNESS_CALIBRATED == 1 ]] || return 1
    base=${IT_EVIDENCE_DIR:-}
    [[ -n $base ]] || return 1
    network_control mapping-snapshot || return $?
    seq_before=${CONTROL_SEQ:-0}
    mapping_probe_egress "$product" "$generation" || return 1
    network_control mapping-snapshot || return $?
    seq_after=${CONTROL_SEQ:-0}
    before=$base/mapping-snapshot-$seq_before.rules
    after=$base/mapping-snapshot-$seq_after.rules
    wb=$(mapping_witness "$base/mapping-snapshot-$seq_before.witness") || return 1
    wa=$(mapping_witness "$base/mapping-snapshot-$seq_after.witness") || return 1
    [[ $wb == "$wa" ]] || return 1
    for key in $MAPPING_WITNESS_KEYS; do
        cb=$(mapping_count "$before" "$profile" "$key") || return 1
        ca=$(mapping_count "$after" "$profile" "$key") || return 1
        [[ $ca -gt $cb ]] || return 1
    done
    return 0
}
