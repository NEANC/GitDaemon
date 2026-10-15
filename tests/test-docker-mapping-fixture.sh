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
    # 降权边界替身：模拟 runner 写入 PID，并按开关发送绑定档案哈希与 network ID 的 READY。
    su() {
        printf '%s\n' "$BASHPID" > "$SCRATCH/evidence/control/runner.pid"
        [[ ${MAPPING_SEND_READY:-0} == 1 ]] || return 0
        printf 'mapping-ready %s %s nonce1\n' "$MAPPING_SHA" "$MAPPING_NETID" > "$SCRATCH/evidence/control/request-1"
        local i
        for ((i = 0; i < 200; i++)); do
            [[ ! -f $SCRATCH/evidence/control/ack-1 ]] || return 0
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
        else
            printf 'WITH_READY exit=%s\n' "$actual"
            [[ -e $SCRATCH/evidence/control/start ]] || { printf 'start missing after READY\n'; failed=1; }
            grep -q -- '--comment mtest-dns-udp' "$SCRATCH/rules" || { printf 'mapping drop rules missing\n'; failed=1; }
            grep -q -- '-s 140.82.112.10/32 -d 140.82.112.11/32 -p tcp --dport 443' "$SCRATCH/rules" || { printf 'mapping accept rules missing\n'; failed=1; }
        fi
        rm -rf "$SCRATCH"
    done
    # 启动包装器必须保留冻结档案 P，绝不改写为旧网络固定地址。
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
    local out
    out=$(docker run -d --name product --network "$IT_NETWORK" --user 10001:10001 \
        --read-only --cap-drop ALL --security-opt no-new-privileges product)
    printf 'WRAPPER_IP=%s\n' "$out"
    [[ $out == *'--ip 140.82.112.10'* ]] || { printf 'wrapper lost frozen P\n'; failed=1; }
    [[ $out != *'172.30.243.4'* ]] || { printf 'wrapper rewrote P to legacy address\n'; failed=1; }
    unset -f command
    return "$failed"
}

# 写入合法映射 DROP 快照：五键、源 P、桥 mmtest、链 MEmtest。
write_mapping_snapshot() {
    local file=$1
    printf '[3:180] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 19419 -m comment --comment "mtest-cross-network" -j DROP\n' > "$file"
    printf '[4:240] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49382 -m comment --comment "mtest-host-published" -j DROP\n' >> "$file"
    printf '[1:60] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.243.1/32 -p tcp -m tcp --dport 49383 -m comment --comment "mtest-host-input" -j DROP\n' >> "$file"
    printf '[5:300] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.244.53/32 -p udp -m udp --dport 53 -m comment --comment "mtest-dns-udp" -j DROP\n' >> "$file"
    printf '[6:360] -A MEmtest -i mmtest -s 140.82.112.10/32 -d 172.30.244.53/32 -p tcp -m tcp --dport 53 -m comment --comment "mtest-dns-tcp" -j DROP\n' >> "$file"
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

# 见证正校准必须逐项通过；接收端暂停时校准失败，零计数不得被认作通过。
mapping_witness_pause_detected() {
    local base=$WORK/profile/base.tsv failed=0 rc=0 file=$WORK/witness.txt
    docker() {
        [[ ${WITNESS_PAUSED:-0} != 1 ]] || return 1
        return 0
    }
    MP_WITNESS_CALIBRATED=0
    mapping_calibrate_witness "$base" || { printf 'healthy calibration failed\n'; failed=1; }
    [[ $MP_WITNESS_CALIBRATED == 1 ]] || { printf 'calibration flag unset\n'; failed=1; }
    WITNESS_PAUSED=1
    MP_WITNESS_CALIBRATED=0
    mapping_calibrate_witness "$base" || rc=$?
    printf 'PAUSED_WITNESS_EXIT=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'paused witness accepted\n'; failed=1; }
    [[ $MP_WITNESS_CALIBRATED == 0 ]] || { printf 'paused witness marked calibrated\n'; failed=1; }
    unset WITNESS_PAUSED
    # 双端见证：接收端计数解析与 UDP/TCP 协议校准。
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' > "$file"
    printf '0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n' >> "$file"
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' >> "$file"
    [[ $(mapping_witness "$file" | tr '\n' ' ') == '0 0 0 ' ]] || { printf 'witness parse failed\n'; failed=1; }
    mapping_witness_delta $'0\n0\n0' $'0\n1\n0' udp || { printf 'udp delta rejected\n'; failed=1; }
    mapping_witness_delta $'0\n0\n0' $'0\n0\n1' tcp || { printf 'tcp delta rejected\n'; failed=1; }
    if mapping_witness_delta $'0\n0\n0' $'0\n0\n1' udp; then printf 'tcp growth accepted as udp\n'; failed=1; fi
    if mapping_witness_delta $'0\n0\n0' $'0\n1\n1' udp; then printf 'multi growth accepted\n'; failed=1; fi
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
    mapping_witness_pause_detected; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
