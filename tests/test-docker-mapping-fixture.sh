#!/usr/bin/env bash
# Mapping 网络契约：装载真实映射夹具、guard 与启动包装器，仅替换 Docker/iptables 等外部边界。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-integration-startup.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 冻结档案样本：地址仅作替身输入，经未修改的产品校验器判定后才被接受。
profile_write() {
    local file=$1
    printf 'schema_version\t1\n' > "$file"
    printf 'run_id\tmtest\n' >> "$file"
    printf 'cidr\t140.82.112.0/24\n' >> "$file"
    printf 'gateway\t140.82.112.1\n' >> "$file"
    printf 'P\t140.82.112.10\n' >> "$file"
    printf 'U\t140.82.112.11\n' >> "$file"
    printf 'X\t140.82.112.12\n' >> "$file"
    printf 'D\t140.82.112.13\n' >> "$file"
    printf 'N\t140.82.112.14\n' >> "$file"
    printf 'network_name\tgm-mtest-m-net\n' >> "$file"
    printf 'bridge\tmmtest\n' >> "$file"
}

# 替换档案中某个键的值。
profile_set() {
    local file=$1 key=$2 value=$3
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="\t"} $1==k{$2=v} {print}' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# 删除档案中某个键。
profile_del() {
    local file=$1 key=$2
    awk -v k="$key" 'BEGIN{FS="\t"} $1!=k' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# 复制某键形成重复键。
profile_dup() {
    local file=$1 key=$2
    awk -v k="$key" 'BEGIN{FS=OFS="\t"} {print} $1==k{print}' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# 追加未知键。
profile_add() {
    local file=$1 key=$2 value=$3
    printf '%s\t%s\n' "$key" "$value" >> "$file"
}

# 加载档案并比对返回码。
expect_profile_rc() {
    local file=$1 expected=$2 rc=0
    mapping_profile_load "$file" || rc=$?
    printf 'PROFILE %-24s EXPECT=%s ACTUAL=%s\n' "$(basename "$file")" "$expected" "$rc"
    [[ $rc == "$expected" ]]
}

# 合法/非法档案样本。
mapping_profile_rejects_conflict() {
    local dir=$WORK/profile failed=0 f base rc
    mkdir -p "$dir"
    base=$dir/base.tsv
    profile_write "$base"
    expect_profile_rc "$base" 0 || failed=1

    f=$dir/dup-address.tsv; cp "$base" "$f"; profile_set "$f" P 140.82.112.11
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/network-address.tsv; cp "$base" "$f"; profile_set "$f" P 140.82.112.0
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/broadcast-address.tsv; cp "$base" "$f"; profile_set "$f" X 140.82.112.255
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/gateway-conflict.tsv; cp "$base" "$f"; profile_set "$f" U 140.82.112.1
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/gateway-outside.tsv; cp "$base" "$f"; profile_set "$f" gateway 10.0.0.1
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/private-u.tsv; cp "$base" "$f"; profile_set "$f" U 10.0.0.5
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/private-n.tsv; cp "$base" "$f"; profile_set "$f" N 192.168.1.5
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/wrong-network-name.tsv; cp "$base" "$f"; profile_set "$f" network_name gm-other-net
    expect_profile_rc "$f" 70 || failed=1
    f=$dir/wrong-bridge.tsv; cp "$base" "$f"; profile_set "$f" bridge other
    expect_profile_rc "$f" 70 || failed=1

    f=$dir/duplicate-key.tsv; cp "$base" "$f"; profile_dup "$f" P
    expect_profile_rc "$f" 2 || failed=1
    f=$dir/missing-key.tsv; cp "$base" "$f"; profile_del "$f" D
    expect_profile_rc "$f" 2 || failed=1
    f=$dir/unknown-key.tsv; cp "$base" "$f"; profile_add "$f" extra value
    expect_profile_rc "$f" 2 || failed=1
    f=$dir/bad-address.tsv; cp "$base" "$f"; profile_set "$f" P 999.1.1.1
    expect_profile_rc "$f" 2 || failed=1
    f=$dir/bad-cidr.tsv; cp "$base" "$f"; profile_set "$f" cidr 140.82.112.5/24
    expect_profile_rc "$f" 2 || failed=1
    f=$dir/no-such-file.tsv
    expect_profile_rc "$f" 2 || failed=1
    return "$failed"
}

# 映射角色只允许单一映射网络附件；旧产品仍只认旧网络。
mapping_extra_attachment_rejected() {
    local base=$WORK/profile/base.tsv failed=0
    local IT_RUN_ID=old IT_NETWORK=gm-old-net
    policy_networks gm-old-net || { printf 'old network rejected\n'; failed=1; }
    if policy_networks gm-mtest-m-net; then printf 'old policy accepted mapping network\n'; failed=1; fi
    local MAPPING_ATTACH=gm-mtest-m-net MAPPING_IP=140.82.112.10
    docker() {
        case "$*" in
            *'.NetworkID'*) printf 'netid-1 ' ;;
            *'.IPAddress'*) printf '%s ' "$MAPPING_IP" ;;
            *'.NetworkSettings.Networks'*) printf '%s ' "$MAPPING_ATTACH" ;;
            *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]' ;;
            *'.HostConfig.ExtraHosts'*) printf '[] []' ;;
            *'.EnableIPv6'*) printf 'false' ;;
            *) return 99 ;;
        esac
        return 0
    }
    MP_NETWORK_ID=netid-1
    MAPPING_ATTACH='gm-mtest-m-net other'
    if mapping_policy_check cid product "$base"; then printf 'extra attachment accepted\n'; failed=1; fi
    MAPPING_ATTACH=gm-mtest-m-net
    mapping_policy_check cid product "$base" || { printf 'valid product rejected\n'; failed=1; }
    MAPPING_IP=140.82.112.11
    if mapping_policy_check cid product "$base"; then printf 'wrong product address accepted\n'; failed=1; fi
    MAPPING_IP=140.82.112.10
    MP_NETWORK_ID=other-netid
    if mapping_policy_check cid product "$base"; then printf 'foreign network id accepted\n'; failed=1; fi
    MP_NETWORK_ID=netid-1
    if mapping_policy_check cid upstream "$base"; then printf 'wrong role address accepted\n'; failed=1; fi
    MAPPING_IP=140.82.112.11
    mapping_policy_check cid upstream "$base" || { printf 'valid upstream rejected\n'; failed=1; }
    if mapping_policy_check cid unknown "$base"; then printf 'unknown role accepted\n'; failed=1; fi
    return "$failed"
}

# 映射模式专属驱动：替换宿主查询、Docker、iptables、su 与集合，只保留真实 guard 逻辑。
contract_mapping_driver() {
    source "$HERE/docker-network-guard.sh"
    source "$HERE/docker-network-fixture.sh"
    id() { if [[ $# == 1 ]]; then printf '0\n'; else printf '10001\n'; fi; }
    ip() { return 0; }
    chown() { return 0; }
    iptables-save() { return 0; }
    iptables() { printf '%s\n' "$*" >> "$SCRATCH/rules"; }
    docker() {
        case "$*" in
            'network inspect '*)
                case "$*" in
                    *'.Name'*) printf 'gm-mtest-m-net\n' ;;
                    *'bridge.name'*) printf 'mmtest\n' ;;
                esac
                ;;
            'image inspect '*) printf '{}\n' ;;
            *) return 0 ;;
        esac
        return 0
    }
    resource_docker() { docker "$@"; }
    validation_environment_verify() { return 0; }
    # 降权边界替身：模拟 runner 写入 PID，并按开关发送 READY 或 READY 前的 snapshot 请求。
    su() {
        printf '%s\n' "$BASHPID" > "$SCRATCH/evidence/control/runner.pid"
        case "${MAPPING_SEND:-ready}" in
            snapshot)
                printf 'mapping-snapshot %s nonce1\n' "$MAPPING_SHA" > "$SCRATCH/evidence/control/request-1"
                ;;
            ready)
                [[ ${MAPPING_SEND_READY:-0} == 1 ]] || return 0
                printf 'mapping-ready %s %s nonce1\n' "$MAPPING_SHA" "$MAPPING_NETID" > "$SCRATCH/evidence/control/request-1"
                ;;
            *) return 0 ;;
        esac
        local i
        for ((i = 0; i < 200; i++)); do
            [[ ! -f $SCRATCH/evidence/control/ack-1 ]] || return 0
            [[ ! -f $SCRATCH/evidence/control/stop ]] || return 75
            sleep 0.05
        done
        return 75
    }
    setsid() { "$@"; }
    export -f docker su resource_docker
    guard_main --run-id mtest --evidence-dir "$SCRATCH/evidence" \
        --source-dir "$(cd "$HERE/.." && pwd)" --runner-user gmtest --mode mapping-probe \
        --product-image product --tools-image tools --environment-manifest "$SCRATCH/env.tsv" \
        --offline-attestation "$SCRATCH/att" --mapping-profile "$SCRATCH/profile.tsv"
}

# 未 READY 时不得创建启动许可；READY 绑定档案哈希与 network ID 后才放行，且产品地址不被改写。
mapping_requires_ready() {
    local failed=0 ready actual
    for ready in 0 1; do
        SCRATCH=$(mktemp -d)
        profile_write "$SCRATCH/profile.tsv"
        MAPPING_SHA=$(sha256sum "$SCRATCH/profile.tsv" | cut -d' ' -f1)
        MAPPING_NETID=netid-abc
        MAPPING_SEND_READY=$ready
        export SCRATCH MAPPING_SHA MAPPING_NETID MAPPING_SEND_READY HERE
        export -f contract_mapping_driver
        actual=0
        bash -c contract_mapping_driver > "$SCRATCH/out" 2>&1 || actual=$?
        if [[ $ready == 0 ]]; then
            printf 'NO_READY exit=%s\n' "$actual"
            [[ ! -e $SCRATCH/evidence/control/start ]] || { printf 'start created without READY\n'; failed=1; }
            if grep -q -- '--comment mtest-' "$SCRATCH/rules" 2>/dev/null; then printf 'rules installed without READY\n'; failed=1; fi
            # READY 前只允许建空链并由清理撤销：断言无规则挂载且建链与撤链数量等价。
            if grep -Eq -- '-(A|I) .*(MEmtest|Mtest|MRmtest)' "$SCRATCH/rules" 2>/dev/null; then
                printf 'mapping rules referenced without READY\n'; failed=1
            fi
            local created removed
            created=$(grep -c -- '-N ' "$SCRATCH/rules" 2>/dev/null || true)
            removed=$(grep -c -- '-X ' "$SCRATCH/rules" 2>/dev/null || true)
            [[ ${created:-0} == "${removed:-0}" ]] || { printf 'chains not reversed: created=%s removed=%s\n' "$created" "$removed"; failed=1; }
        else
            printf 'WITH_READY exit=%s\n' "$actual"
            [[ -e $SCRATCH/evidence/control/start ]] || { printf 'start missing after READY\n'; failed=1; }
            grep -q -- '--comment mtest-dns-udp' "$SCRATCH/rules" || { printf 'mapping drop rules missing\n'; failed=1; }
            grep -q -- '-s 140.82.112.10/32 -d 140.82.112.11/32 -p tcp --dport 443' "$SCRATCH/rules" || { printf 'mapping accept rules missing\n'; failed=1; }
        fi
        rm -rf "$SCRATCH"
    done
    # 启动包装器按角色赋冻结地址：product 用 P，其余角色不得被赋 P。
    mkdir -p "$WORK/profile"
    [[ -f $WORK/profile/base.tsv ]] || profile_write "$WORK/profile/base.tsv"
    local IT_RUN_ID=mtest IT_NETWORK=gm-mtest-m-net IT_NETWORK_GUARD_READY=1 IT_MAPPING=1 IT_DNS_IP=172.30.243.53
    IT_MAPPING_PROFILE=$WORK/profile/base.tsv
    unset IT_EVIDENCE_DIR RESOURCE_LEDGER_DIR
    command() {
        [[ $1 == docker ]] || { builtin command "$@"; return $?; }
        shift
        printf '%s\n' "$*"
    }
    local out spec role name ip
    out=$(docker run -d --name gm-mtest-product --network "$IT_NETWORK" --user 10001:10001 \
        --read-only --cap-drop ALL --security-opt no-new-privileges product)
    printf 'WRAPPER_IP=%s\n' "$out"
    [[ $out == *'--ip 140.82.112.10'* ]] || { printf 'wrapper lost frozen P\n'; failed=1; }
    [[ $out != *'172.30.243.4'* ]] || { printf 'wrapper rewrote P to legacy address\n'; failed=1; }
    for spec in 'upstream 140.82.112.11' 'proxy 140.82.112.12' 'dns 140.82.112.13'; do
        read -r role ip <<< "$spec"
        name=gm-mtest-$role
        out=$(docker run -d --name "$name" --network "$IT_NETWORK" --user 10001:10001 \
            --read-only --cap-drop ALL --security-opt no-new-privileges product)
        printf 'WRAPPER_IP_%s=%s\n' "$role" "$out"
        [[ $out == *"--ip $ip"* ]] || { printf 'wrapper lost frozen %s address\n' "$role"; failed=1; }
        [[ $out != *'--ip 140.82.112.10'* ]] || { printf 'wrapper assigned P to %s\n' "$role"; failed=1; }
    done
    unset -f command
    return "$failed"
}

# 写入映射 DROP 快照：五键、源 P、指定桥、链 MEmtest；可指定计数基数用于增量样本。
write_mapping_snapshot_base() {
    local file=$1 base=${2:-0} bridge=${3:-mmtest}
    printf '[%s:180] -A MEmtest -i %s -s 140.82.112.10/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 19419 -m comment --comment "mtest-cross-network" -j DROP\n' "$((base + 3))" "$bridge" > "$file"
    printf '[%s:240] -A MEmtest -i %s -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49382 -m comment --comment "mtest-host-published" -j DROP\n' "$((base + 4))" "$bridge" >> "$file"
    printf '[%s:60] -A MEmtest -i %s -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49383 -m comment --comment "mtest-host-input" -j DROP\n' "$((base + 1))" "$bridge" >> "$file"
    printf '[%s:300] -A MEmtest -i %s -s 140.82.112.10/32 -d 172.30.244.53/32 -p udp -m udp --dport 53 -m comment --comment "mtest-dns-udp" -j DROP\n' "$((base + 5))" "$bridge" >> "$file"
    printf '[%s:360] -A MEmtest -i %s -s 140.82.112.10/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 53 -m comment --comment "mtest-dns-tcp" -j DROP\n' "$((base + 6))" "$bridge" >> "$file"
}

# 写入合法映射 DROP 快照：五键、源 P、桥 mmtest、链 MEmtest。
write_mapping_snapshot() {
    write_mapping_snapshot_base "$1"
}

# 整行替换：命中 match 的行换成 repl。
replace_line() {
    local file=$1 match=$2 repl=$3 line out=''
    while IFS= read -r line; do
        if [[ $line == *"$match"* ]]; then out+="$repl"$'\n'; else out+="$line"$'\n'; fi
    done < "$file"
    printf '%s' "$out" > "$file"
}

# 删除命中 match 的行。
drop_line() {
    local file=$1 match=$2 line out=''
    while IFS= read -r line; do
        [[ $line == *"$match"* ]] && continue
        out+="$line"$'\n'
    done < "$file"
    printf '%s' "$out" > "$file"
}

# 五类 DROP 精确解析；错误协议、错误桥、错误来源与旧 .4 规则都必须失败。
mapping_rule_keys_exact() {
    local base=$WORK/profile/base.tsv dir=$WORK/rules failed=0 f key rc
    mkdir -p "$dir"
    f=$dir/good.rules
    write_mapping_snapshot "$f"
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        rc=$(mapping_count "$f" "$base" "$key") || { printf 'key %s unparsed\n' "$key"; failed=1; continue; }
        printf 'COUNT %s=%s\n' "$key" "$rc"
    done
    [[ $(mapping_count "$f" "$base" cross-network) == 3 ]] || { printf 'cross-network count mismatch\n'; failed=1; }
    [[ $(mapping_count "$f" "$base" dns-udp) == 5 ]] || { printf 'dns-udp count mismatch\n'; failed=1; }
    # 错误协议：dns-udp 规则改为 tcp，必须失败。
    f=$dir/wrong-protocol.rules; write_mapping_snapshot "$f"
    replace_line "$f" 'comment "mtest-dns-udp"' '[5:300] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 53 -m comment --comment "mtest-dns-udp" -j DROP'
    if mapping_count "$f" "$base" dns-udp >/dev/null 2>&1; then printf 'wrong protocol accepted\n'; failed=1; fi
    # 错误桥：host-input 规则改为 mtest，必须失败。
    f=$dir/wrong-bridge.rules; write_mapping_snapshot "$f"
    replace_line "$f" 'comment "mtest-host-input"' '[1:60] -A MEmtest -i mtest -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49383 -m comment --comment "mtest-host-input" -j DROP'
    if mapping_count "$f" "$base" host-input >/dev/null 2>&1; then printf 'wrong bridge accepted\n'; failed=1; fi
    # 错误来源：cross-network 规则改为旧 .4，必须失败（不得读取旧规则）。
    f=$dir/legacy-source.rules; write_mapping_snapshot "$f"
    replace_line "$f" 'comment "mtest-cross-network"' '[3:180] -A MEmtest -i mmtest -s 172.30.243.4/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 19419 -m comment --comment "mtest-cross-network" -j DROP'
    if mapping_count "$f" "$base" cross-network >/dev/null 2>&1; then printf 'legacy .4 source accepted\n'; failed=1; fi
    # 整份旧 .4 快照不得被认作映射证据。
    f=$dir/legacy-only.rules
    printf '[3:180] -A Eold -s 172.30.243.4/32 -d 172.30.244.53/32 -p tcp --dport 19419 -m comment --comment "mtest-cross-network" -j DROP\n' > "$f"
    if mapping_count "$f" "$base" cross-network >/dev/null 2>&1; then printf 'legacy-only snapshot accepted\n'; failed=1; fi
    return "$failed"
}

# 缺键或重复键的计数解析必须失败。
mapping_counter_missing_or_duplicate_fails() {
    local base=$WORK/profile/base.tsv dir=$WORK/count failed=0 f
    mkdir -p "$dir"
    f=$dir/missing.rules
    write_mapping_snapshot "$f"
    [[ $(mapping_count "$f" "$base" host-input) == 1 ]] || { printf 'control count mismatch\n'; failed=1; }
    drop_line "$f" 'comment "mtest-host-input"'
    if mapping_count "$f" "$base" cross-network >/dev/null 2>&1; then printf 'missing key accepted\n'; failed=1; fi
    f=$dir/duplicate.rules
    write_mapping_snapshot "$f"
    printf '[0:0] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49383 -m comment --comment "mtest-host-input" -j DROP\n' >> "$f"
    if mapping_count "$f" "$base" host-input >/dev/null 2>&1; then printf 'duplicate key accepted\n'; failed=1; fi
    f=$dir/empty.rules
    : > "$f"
    if mapping_count "$f" "$base" dns-tcp >/dev/null 2>&1; then printf 'empty snapshot accepted\n'; failed=1; fi
    if mapping_count "$dir/absent.rules" "$base" dns-tcp >/dev/null 2>&1; then printf 'absent snapshot accepted\n'; failed=1; fi
    return "$failed"
}

# 见证校准：以接收端计数增量为判据；接收端在跑但计数不增长必须被判失败。
mapping_witness_pause_detected() {
    local base=$WORK/profile/base.tsv failed=0 rc=0 file=$WORK/witness.txt counter=$WORK/wcount
    printf '0\n' > "$counter"
    WITNESS_STATIC=0
    docker() {
        case "$*" in
            *'nvxL'*)
                local n=0
                if [[ ${WITNESS_STATIC:-0} != 1 ]]; then
                    n=$(cat "$counter")
                    n=$((n + 1))
                    printf '%s\n' "$n" > "$counter"
                fi
                printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' "$n"
                printf '%s 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n' "$n"
                printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' "$n"
                ;;
            *) return 0 ;;
        esac
    }
    MP_WITNESS_CALIBRATED=0
    mapping_calibrate_witness "$base" || { printf 'healthy calibration failed\n'; failed=1; }
    [[ $MP_WITNESS_CALIBRATED == 1 ]] || { printf 'calibration flag unset\n'; failed=1; }
    # 接收端在跑（探针成功）但计数零增长：校准必须失败。
    WITNESS_STATIC=1
    MP_WITNESS_CALIBRATED=0
    mapping_calibrate_witness "$base" || rc=$?
    printf 'PAUSED_WITNESS_EXIT=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'paused witness accepted\n'; failed=1; }
    [[ $MP_WITNESS_CALIBRATED == 0 ]] || { printf 'paused witness marked calibrated\n'; failed=1; }
    WITNESS_STATIC=0
    # 双端见证：接收端计数解析与 UDP/TCP 协议校准。
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' > "$file"
    printf '0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n' >> "$file"
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' >> "$file"
    [[ $(mapping_witness "$file" | tr '\n' ' ') == '0 0 0 ' ]] || { printf 'witness parse failed\n'; failed=1; }
    mapping_witness_delta $'0\n0\n0' $'0\n1\n0' udp || { printf 'udp delta rejected\n'; failed=1; }
    mapping_witness_delta $'0\n0\n0' $'0\n0\n1' tcp || { printf 'tcp delta rejected\n'; failed=1; }
    if mapping_witness_delta $'0\n0\n0' $'0\n0\n1' udp; then printf 'tcp growth accepted as udp\n'; failed=1; fi
    if mapping_witness_delta $'0\n0\n0' $'0\n1\n1' udp; then printf 'multi growth accepted\n'; failed=1; fi
    mapping_witness_growth $'0\n0\n0' $'1\n2\n3' || { printf 'growth rejected\n'; failed=1; }
    if mapping_witness_growth $'0\n0\n0' $'1\n2\n0'; then printf 'zero increment accepted\n'; failed=1; fi
    return "$failed"
}

# 映射网络创建必须经资源账本、带齐三 label 创建并登记；空身份即拒绝且不写账本。
mapping_network_create_registers() {
    local failed=0 scratch dir rc=0 id
    scratch=$(mktemp -d)
    dir=$scratch/ledger
    mkdir -p "$dir"
    profile_write "$scratch/profile.tsv"
    unset IT_EVIDENCE_DIR
    MAPPING_LEDGER_DIR=$dir
    CREATE_NOID=0
    # 兼容旧实现经 `command docker` 创建：拦截后仍只走替身，绝不触碰真实 daemon。
    command() {
        [[ $1 == docker ]] || { builtin command "$@"; return $?; }
        shift
        resource_docker "$@"
    }
    resource_docker() {
        case "$*" in
            'network create '*)
                printf '%s\n' "$*" >> "$scratch/create.calls"
                [[ ${CREATE_NOID:-0} != 1 ]] || return 0
                local -a a=()
                read -ra a <<< "$*"
                local i lab
                : > "$scratch/labels"
                for ((i = 0; i < ${#a[@]}; i++)); do
                    [[ ${a[i]} == --label ]] || continue
                    lab=${a[i + 1]}
                    case "$lab" in
                        gitdaemon.*) printf '%s\n' "$lab" >> "$scratch/labels" ;;
                    esac
                done
                printf 'netid-new\n'
                ;;
            *'{{.Id}}'*) printf 'netid-new\n' ;;
            *'gitdaemon.run'*)
                local r='' s='' o='' l
                if [[ -f $scratch/labels ]]; then
                    while IFS= read -r l; do
                        case "$l" in
                            gitdaemon.run=*) r=${l#*=} ;;
                            gitdaemon.scenario=*) s=${l#*=} ;;
                            gitdaemon.role=*) o=${l#*=} ;;
                        esac
                    done < "$scratch/labels"
                fi
                printf '%s\t%s\t%s\n' "$r" "$s" "$o"
                ;;
            'inspect netid-new') printf '{"Id":"netid-new"}\n' ;;
            *) printf '{}\n' ;;
        esac
    }
    id=$(mapping_network_create "$scratch/profile.tsv" "$dir") || rc=$?
    printf 'MAPPING_NETWORK_CREATE rc=%s id=%s\n' "$rc" "$id"
    [[ $rc == 0 && $id == netid-new ]] || { printf 'create+register failed\n'; failed=1; }
    grep -q -- '--label gitdaemon.run=mtest' "$scratch/create.calls" || { printf 'missing run label\n'; failed=1; }
    grep -q -- '--label gitdaemon.scenario=mapping' "$scratch/create.calls" || { printf 'missing scenario label\n'; failed=1; }
    grep -q -- '--label gitdaemon.role=network' "$scratch/create.calls" || { printf 'missing role label\n'; failed=1; }
    grep -q $'register\tnetwork\tnetid-new\tmtest\tmapping\tnetwork\t' "$dir/ledger.tsv" || { printf 'ledger record missing\n'; failed=1; }
    grep -qx $'network_id\tnetid-new' "$dir/mapping-network.tsv" || { printf 'state id missing\n'; failed=1; }
    # 创建返回空身份：network ID 核验失败即拒绝，且不写账本。
    local dir2=$scratch/ledger2
    mkdir -p "$dir2"
    MAPPING_LEDGER_DIR=$dir2 CREATE_NOID=1
    rc=0
    id=$(mapping_network_create "$scratch/profile.tsv" "$dir2") || rc=$?
    printf 'MAPPING_NETWORK_NOID rc=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'empty network id accepted\n'; failed=1; }
    [[ ! -e $dir2/ledger.tsv ]] || { printf 'ledger written without id\n'; failed=1; }
    rm -rf "$scratch"
    return "$failed"
}

# 隔离判定：五类 DROP 计数增长且接收端零变化才通过；桥名核验失败即拒绝。
mapping_isolation_check_behavior() {
    local base=$WORK/profile/base.tsv failed=0 scratch
    scratch=$(mktemp -d)
    IT_EVIDENCE_DIR=$scratch
    MP_WITNESS_CALIBRATED=1
    ISOLATION_BRIDGE=mmtest
    network_control() {
        CONTROL_SEQ=$((CONTROL_SEQ + 1))
        write_mapping_snapshot_base "$scratch/mapping-snapshot-$CONTROL_SEQ.rules" "$((CONTROL_SEQ * 10))" "$ISOLATION_BRIDGE"
        {
            printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n'
            printf '0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n'
            printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n'
        } > "$scratch/mapping-snapshot-$CONTROL_SEQ.witness"
    }
    mapping_probe_egress() { return 0; }
    CONTROL_SEQ=0
    mapping_isolation_check product-id gen1 "$base" || { printf 'valid isolation rejected\n'; failed=1; }
    # 桥名核验失败：DROP 规则的桥不是冻结桥 m$RUN，计数解析必须拒绝。
    CONTROL_SEQ=0
    ISOLATION_BRIDGE=mtest
    if mapping_isolation_check product-id gen1 "$base"; then printf 'wrong bridge accepted\n'; failed=1; fi
    rm -rf "$scratch"
    return "$failed"
}

# 冻结档案的 run_id 必须与 --run-id 一致，不一致即拒绝且不建链、不放行。
mapping_run_id_binding() {
    local failed=0 SCRATCH actual
    SCRATCH=$(mktemp -d)
    profile_write "$SCRATCH/profile.tsv"
    profile_set "$SCRATCH/profile.tsv" run_id other
    profile_set "$SCRATCH/profile.tsv" network_name gm-other-m-net
    profile_set "$SCRATCH/profile.tsv" bridge mother
    MAPPING_SHA=$(sha256sum "$SCRATCH/profile.tsv" | cut -d' ' -f1)
    MAPPING_NETID=netid-abc
    MAPPING_SEND=ready MAPPING_SEND_READY=1
    export SCRATCH MAPPING_SHA MAPPING_NETID MAPPING_SEND MAPPING_SEND_READY HERE
    export -f contract_mapping_driver
    actual=0
    bash -c contract_mapping_driver > "$SCRATCH/out" 2>&1 || actual=$?
    printf 'RUNID_MISMATCH exit=%s\n' "$actual"
    [[ $actual != 0 ]] || { printf 'run_id mismatch accepted\n'; failed=1; }
    [[ ! -e $SCRATCH/evidence/control/start ]] || { printf 'start created on mismatch\n'; failed=1; }
    [[ ! -e $SCRATCH/rules ]] || { printf 'chains created on mismatch\n'; failed=1; }
    rm -rf "$SCRATCH"
    return "$failed"
}

# READY 前不得接受 mapping-snapshot：拒绝且不产生 ack 或启动许可。
mapping_snapshot_requires_ready() {
    local failed=0 SCRATCH actual
    SCRATCH=$(mktemp -d)
    profile_write "$SCRATCH/profile.tsv"
    MAPPING_SHA=$(sha256sum "$SCRATCH/profile.tsv" | cut -d' ' -f1)
    MAPPING_NETID=netid-abc
    MAPPING_SEND=snapshot
    export SCRATCH MAPPING_SHA MAPPING_NETID MAPPING_SEND HERE
    export -f contract_mapping_driver
    actual=0
    bash -c contract_mapping_driver > "$SCRATCH/out" 2>&1 || actual=$?
    printf 'SNAPSHOT_BEFORE_READY exit=%s\n' "$actual"
    [[ $actual != 0 ]] || { printf 'snapshot accepted before READY\n'; failed=1; }
    [[ ! -e $SCRATCH/evidence/control/start ]] || { printf 'start created on snapshot\n'; failed=1; }
    [[ ! -e $SCRATCH/evidence/control/ack-1 ]] || { printf 'snapshot acked before READY\n'; failed=1; }
    # 未 READY 前连取证都不允许发生：不得留下任何映射快照文件。
    if compgen -G "$SCRATCH/evidence/mapping-snapshot-*.rules" >/dev/null; then
        printf 'snapshot taken before READY\n'; failed=1
    fi
    rm -rf "$SCRATCH"
    return "$failed"
}

mkdir -p "$WORK/profile"
profile_write "$WORK/profile/base.tsv"

failed=0
for name in \
    mapping_profile_rejects_conflict \
    mapping_extra_attachment_rejected \
    mapping_requires_ready \
    mapping_rule_keys_exact \
    mapping_counter_missing_or_duplicate_fails \
    mapping_witness_pause_detected \
    mapping_network_create_registers \
    mapping_isolation_check_behavior \
    mapping_run_id_binding \
    mapping_snapshot_requires_ready; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
