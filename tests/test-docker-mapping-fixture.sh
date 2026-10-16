#!/usr/bin/env bash
# Mapping 网络契约：装载真实映射夹具、guard 与启动包装器，仅替换 Docker/iptables 等外部边界。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-integration-startup.sh"
# 负例注入（真实替换客户端 CA / 服务端叶证书）由断言库提供，本文件的行为断言直接执行该真实代码。
source "$HERE/docker-mapping-assertions.sh"

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
    validation_runner_verify() { return 0; }
    # 降权边界替身：模拟 runner 写入 PID，并按开关发送 READY 或 READY 前的 snapshot 请求。
    su() {
        printf 'pid\t%s\nstart_ticks\t1\nboot_id\tboot\nmanifest_sha256\tdigest\n' "$BASHPID" > "$SCRATCH/evidence/control/runner-handshake.tsv"
        case "${MAPPING_SEND:-ready}" in
            snapshot)
                printf 'mapping-snapshot generation-1 %s %s nonce1\n' "$MAPPING_NETID" "$MAPPING_SHA" > "$SCRATCH/evidence/control/request-1"
                ;;
            ready)
                [[ ${MAPPING_SEND_READY:-0} == 1 ]] || return 0
                printf 'mapping-ready generation-1 %s %s nonce1\n' "$MAPPING_NETID" "$MAPPING_SHA" > "$SCRATCH/evidence/control/request-1"
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
            [[ ! -e $SCRATCH/evidence/control/ack-1 ]] || { printf 'ack created without READY\n'; failed=1; }
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
            [[ -e $SCRATCH/evidence/control/ack-1 ]] || { printf 'ack missing after READY\n'; failed=1; }
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

runner_prepares_before_ready() {
    local profile=$WORK/profile/base.tsv control=$WORK/two-phase log=$WORK/two-phase.log
    mkdir -p "$control"
    IT_CONTROL_DIR=$control
    RESOURCE_LEDGER_DIR=$control/resources
    mapping_profile_load "$profile" || return 1
    mapping_assets_prepare() { printf 'assets\n' >> "$log"; }
    mapping_network_create() { printf 'network\n' >> "$log"; MP_NETWORK_ID=net-1; }
    mapping_fixture_precheck() { printf 'inspect\n' >> "$log"; }
    network_control() {
        printf '%s\n' "$*" >> "$log"
        MAPPING_ACK_GENERATION=generation-1
    }
    mapping_prepare "$profile" mapping-fallback product tools || return 1
    mapping_ready "$profile" net-1 generation-1 || return 1
    [[ $(sed -n '1p' "$log") == assets ]] || return 1
    [[ $(sed -n '2p' "$log") == network ]] || return 1
    [[ $(sed -n '3p' "$log") == inspect ]] || return 1
    [[ $(sed -n '4p' "$log") == 'mapping-ready '* ]] || return 1
}

networked_start_requires_generation_ack() {
    local profile=$WORK/profile/base.tsv control=$WORK/ack log=$WORK/start.log rc=0
    mkdir -p "$control"
    IT_CONTROL_DIR=$control
    mapping_fixture_docker() { printf '%s\n' "$*" >> "$log"; }
    mapping_activate generation-1 >/dev/null 2>&1 || rc=$?
    [[ $rc == 65 && ! -s $log ]]
}

second_generation_rebinds_network() {
    local profile=$WORK/profile/base.tsv log=$WORK/generations.log
    network_control() {
        printf '%s\n' "$*" >> "$log"
        read -r _ MAPPING_ACK_GENERATION _ <<< "$1"
    }
    mapping_ready "$profile" net-1 generation-1 || return 1
    mapping_control_request mapping-release generation-1 net-1 "$(sha256sum "$profile" | cut -d' ' -f1)" || return 1
    mapping_ready "$profile" net-2 generation-2 || return 1
    grep -q '^mapping-ready generation-1 net-1 ' "$log" || return 1
    grep -q '^mapping-release generation-1 net-1 ' "$log" || return 1
    grep -q '^mapping-ready generation-2 net-2 ' "$log"
}

scenario_keeps_control_and_ledger_root() {
    local root=$WORK/run-root scenario=$WORK/scenario
    IT_CONTROL_DIR=$root/control
    RESOURCE_LEDGER_DIR=$root/control/resources
    IT_EVIDENCE_DIR=$scenario
    [[ $(mapping_control_dir) == "$root/control" ]] || return 1
    [[ $(resource_ledger_dir) == "$root/control/resources" ]]
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
    unset IT_EVIDENCE_DIR VE_DOCKER_ENDPOINT
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
    validation_docker() { resource_docker "$@"; }
    id=$(mapping_network_create "$scratch/profile.tsv" "$dir") || rc=$?
    printf 'MAPPING_NETWORK_CREATE rc=%s id=%s\n' "$rc" "$id"
    [[ $rc == 0 && $id == netid-new ]] || { printf 'create+register failed\n'; failed=1; }
    grep -q -- '--label gitdaemon.run=mtest' "$scratch/create.calls" || { printf 'missing run label\n'; failed=1; }
    grep -q -- '--label gitdaemon.scenario=mapping' "$scratch/create.calls" || { printf 'missing scenario label\n'; failed=1; }
    grep -q -- '--label gitdaemon.role=network' "$scratch/create.calls" || { printf 'missing role label\n'; failed=1; }
    # 独立 internal bridge：缺 --internal 时隔离完全依赖 guard 规则，属规格要求的固定形态。
    grep -q -- '--internal' "$scratch/create.calls" || { printf 'mapping network is not internal\n'; failed=1; }
    grep -q -- '--ipv6=false' "$scratch/create.calls" || { printf 'mapping network enables IPv6\n'; failed=1; }
    grep -q -- 'gm-mtest-m-net$' "$scratch/create.calls" || { printf 'network name is not the last argument\n'; failed=1; }
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

# tls-proxy 契约：加载真实映射夹具的资产/代理/DNS 函数，仅替换 Docker、TLS 接受、
# 拨号、中继与客户端探针等外部边界；本地可用可执行件（openssl）用于校验判据本身。
TLS_DIR=''
TLS_ASSETS=''
TLS_SCENARIO_ID='mapping-fallback'

# 记录型 Docker 替身：标签落盘（create 在命令替换子壳中执行，变量无法回传），
# 身份由调用参数推导，exec 读取映射到本地替身目录。
tls_docker() {
    printf '%s\n' "$*" >> "$TLS_DIR/docker.calls"
    local last=${!#} name='' run='mtest' scenario='' role='' labels
    local -a argv=()
    read -ra argv <<< "$*"
    local i arg
    for ((i = 0; i < ${#argv[@]}; i++)); do
        arg=${argv[i]}
        case "$arg" in
            --name) name=${argv[i + 1]} ;;
            gitdaemon.run=*) run=${arg#*=} ;;
            gitdaemon.scenario=*) scenario=${arg#*=} ;;
            gitdaemon.role=*) role=${arg#*=} ;;
        esac
    done
    case "$*" in
        'volume create '*)
            printf '%s\t%s\t%s\n' "$run" "$scenario" "$role" > "$TLS_DIR/labels"
            printf '%s\n' "$last"
            ;;
        'create '*)
            printf '%s\t%s\t%s\n' "$run" "$scenario" "$role" > "$TLS_DIR/labels"
            printf '%s\n' "${name:-$last}"
            ;;
        'exec '*)
            case "$*" in
                *' cat '*)
                    [[ -f $last ]] || return 1
                    command cat -- "$last"
                    ;;
                *) return 0 ;;
            esac
            ;;
        *'.Config.Labels'*|*'.Labels'*)
            labels=$(command cat -- "$TLS_DIR/labels") || return 1
            printf '%s\n' "$labels"
            ;;
        *'CreatedAt'*)
            printf '%s|local|/var/lib/docker/volumes/%s/_data|gitdaemon.run=%s,\n' "$last" "$last" "$run"
            ;;
        *'.State.Running'*) printf 'true\n' ;;
        *'.Name'*) printf '%s\n' "$last" ;;
        *'.Id'*) printf '%s\n' "$last" ;;
        'inspect '*) printf '{"Name":"%s"}\n' "$last" ;;
        *) printf '{}\n' ;;
    esac
    return 0
}

# 本地资产生成边界替身：以本地 openssl 在替身资产目录内生成两条独立签发链。
tls_local_asset_exec() {
    MAPPING_ASSET_ROOT=$TLS_ASSETS MAPPING_UPSTREAM_HOST=$MAPPING_UPSTREAM_HOST \
        MAPPING_PROXY_HOST=$MAPPING_PROXY_HOST MAPPING_UPSTREAM_HEALTH=$MAPPING_UPSTREAM_HEALTH \
        sh -c "$1"
}

# CA 发布边界替身：按 -v 挂载解析卷归属，cat 语义从资产卷读源、目标写入客户端 CA 卷，
# 使未替换的 mapping_fixture_ca_publish 真实逻辑可被端到端观测。
tls_publish_docker() {
    printf '%s\n' "$*" >> "$TLS_DIR/publish.calls"
    local -a args=("$@")
    local i entrypoint='' script='' src_dir='' out_dir='' target=''
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            --entrypoint) entrypoint=${args[i + 1]} ;;
            -v)
                case "${args[i + 1]}" in
                    "$(mapping_assets_volume):"*) src_dir=$TLS_ASSETS ;;
                    "$(mapping_ca_volume):"*) out_dir=$TLS_DIR/ca ;;
                esac
                ;;
            -c) script=${args[i + 1]} ;;
        esac
    done
    case "$entrypoint" in
        cat)
            [[ -n $src_dir ]] || return 1
            command cat -- "$src_dir/${args[${#args[@]} - 1]}" 2>/dev/null
            ;;
        /bin/sh)
            [[ -n $out_dir && -n $script ]] || return 1
            target=${script#*cat > \'}
            target=${target%%\'*}
            [[ -n $target ]] || return 1
            mkdir -p "$(dirname -- "$out_dir/$target")" || return 1
            command cat > "$out_dir/$target"
            ;;
        *) return 1 ;;
    esac
}

# 本地替身基础环境：目录、账本、档案与本地资产生成/写入边界；不含 docker 与 CA 发布替换。
tls_local_base() {
    TLS_DIR=$(mktemp -d)
    TLS_ASSETS=$TLS_DIR/assets
    mkdir -p "$TLS_ASSETS/upstream" "$TLS_ASSETS/proxy" "$TLS_DIR/ca" "$TLS_DIR/scenario" "$TLS_DIR/ledger"
    MAPPING_ASSET_ROOT=$TLS_ASSETS
    MAPPING_LEDGER_DIR=$TLS_DIR/ledger
    RESOURCE_LEDGER_DIR=$TLS_DIR/ledger
    unset IT_EVIDENCE_DIR
    profile_write "$TLS_DIR/profile.tsv"
    # 资产生成以本地 openssl 执行；资产卷写入同样落在替身目录。
    mapping_fixture_asset_exec() { tls_local_asset_exec "$1"; }
    mapping_fixture_asset_write() {
        printf '%s' "$2" > "$TLS_ASSETS/$1" || return 1
        chmod 755 "$TLS_ASSETS/$1"
    }
    return 0
}

# 建立本地替身目录与替换边界；容器内路径映射到替身目录，绝不触碰真实 daemon。
tls_env() {
    tls_local_base || return 1
    mapping_fixture_docker() { tls_docker "$@"; }
    resource_docker() { tls_docker "$@"; }
    mapping_fixture_ca_publish() {
        cp "$TLS_ASSETS/upstream/tls/ca.crt" "$TLS_DIR/ca/upstream-ca.crt" || return 1
        cp "$TLS_ASSETS/proxy/tls/ca.crt" "$TLS_DIR/ca/proxy-ca.crt" || return 1
    }
    return 0
}

# 完整 tls 契约环境：资产准备 + 夹具启动，并预置两端口独立计数文件与 CONNECT 日志。
tls_setup() {
    tls_env || return 1
    mapping_assets_prepare "$TLS_DIR/profile.tsv" "$TLS_SCENARIO_ID" product "$TLS_DIR/ledger" || {
        printf 'mapping_assets_prepare failed\n'
        return 1
    }
    mkdir -p "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID"
    printf '0\n' > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/accept.count"
    printf '0\n' > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/reject.count"
    : > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/connect.log"
    mapping_fixture_start "$TLS_DIR/profile.tsv" "$TLS_SCENARIO_ID" product tools || {
        printf 'mapping_fixture_start failed\n'
        return 1
    }
    return 0
}

# 校准探针替身：两端口探针成功并按 <grow|static> 决定计数是否增长；
# 以全局记录场景目录与增长开关，避免依赖已返回函数的局部作用域。
TLS_PROBE_GROW='grow'
TLS_PROBE_SCENARIO=''
tls_calibrate_probe_stubs() {
    TLS_PROBE_SCENARIO=$1
    TLS_PROBE_GROW=$2
    mapping_proxy_probe_accept() {
        local file
        file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_ACCEPT_PORT") || return 1
        if [[ $TLS_PROBE_GROW == grow ]]; then
            printf '%s\n' "$(( $(command cat -- "$file") + 1 ))" > "$file" || return 1
        fi
        printf 'mapping-upstream-ok\n' > "$TLS_PROBE_SCENARIO/proxy.probe-accept" || return 1
        return 0
    }
    mapping_proxy_probe_reject() {
        local file
        file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_REJECT_PORT") || return 1
        if [[ $TLS_PROBE_GROW == grow ]]; then
            printf '%s\n' "$(( $(command cat -- "$file") + 1 ))" > "$file" || return 1
        fi
        printf '403 Forbidden\n' > "$TLS_PROBE_SCENARIO/proxy.probe-reject" || return 1
        return 0
    }
    return 0
}

# CONNECT 证据行写入：经真实登记边界落盘，authority 与拨号目的由调用方指定。
tls_connect_log_write() {
    local accept_authority=$1 accept_dial=$2 reject_authority=$3 reject_dial=$4
    local accept_file reject_file log
    accept_file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_ACCEPT_PORT") || return 1
    reject_file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_REJECT_PORT") || return 1
    log=$(mapping_proxy_log_path "$TLS_SCENARIO_ID") || return 1
    : > "$log" || return 1
    mapping_proxy_record "$accept_file" "$accept_authority" accept "$accept_dial" || return 1
    mapping_proxy_record "$reject_file" "$reject_authority" reject "$reject_dial" || return 1
    return 0
}

# 以给定 CA 生成负例叶证书（本任务用于校验判据本身）。
tls_make_leaf() {
    local out=$1 cn=$2 san=$3 ca=$4 ca_key=$5
    mkdir -p "$out" || return 1
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$cn" -keyout "$out/leaf.key" -out "$out/leaf.csr" >/dev/null 2>&1 || return 1
    printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:%s\n' "$san" > "$out/leaf.ext"
    openssl x509 -req -in "$out/leaf.csr" -CA "$ca" -CAkey "$ca_key" -CAcreateserial -days 2 \
        -extfile "$out/leaf.ext" -out "$out/leaf.crt" >/dev/null 2>&1 || return 1
    rm -f "$out/leaf.csr" "$out/leaf.ext" "$out/leaf.srl"
    return 0
}

# 负例注入的本地执行边界：容器挂载点映射到替身目录，脚本正文（openssl 生成与写入）原样执行，
# 使「注入确实替换了文件」可被本地行为断言观测，而不依赖替身直接改写同步退出码。
tls_negative_injection_docker() {
    local -a args=("$@")
    local i entrypoint='' script='' caname='' which='' host='' use_ca=''
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            --entrypoint) entrypoint=${args[i + 1]} ;;
            -e)
                case "${args[i + 1]}" in
                    MAPPING_NEG_CANAME=*) caname=${args[i + 1]#*=} ;;
                    MAPPING_NEG_WHICH=*) which=${args[i + 1]#*=} ;;
                    MAPPING_NEG_HOST=*) host=${args[i + 1]#*=} ;;
                esac
                ;;
            -v)
                case "${args[i + 1]}" in
                    *":$MAPPING_CA_MOUNT") use_ca=1 ;;
                esac
                ;;
        esac
    done
    [[ $entrypoint == /bin/sh ]] || return 1
    script=$(command cat) || return 1
    printf '%s\n' "$script" >> "$TLS_DIR/neg.scripts"
    if [[ $use_ca == 1 ]]; then
        # 只把容器内 /ca 挂载点换成替身 CA 目录，注入脚本其余内容原样执行。
        local mapped=${script//\/ca\//$TLS_DIR/ca/}
        MAPPING_NEG_CANAME=$caname sh -c "$mapped" 2> "$TLS_DIR/inject.err" \
            || { printf 'CA injection script failed: %s\n' "$(tr '\n' '|' < "$TLS_DIR/inject.err")"; return 1; }
        return 0
    fi
    MAPPING_ASSET_ROOT=$TLS_ASSETS MAPPING_NEG_WHICH=$which MAPPING_NEG_HOST=${host:-other-host.invalid} \
        sh -c "$script" 2> "$TLS_DIR/inject.err" \
        || { printf 'SAN injection script failed: %s\n' "$(tr '\n' '|' < "$TLS_DIR/inject.err")"; return 1; }
    return 0
}

# 四类 TLS 负例的接线与判据：分层判定必须可区分，且失败层不得被校准认作成功。
tls_negative_case() {
    local expect_verdict=$1 grow=$2 probe_fail=$3
    local failed=0 rc=0 scenario_dir before after verdict probe_rc=0
    tls_setup || return 1
    scenario_dir=$TLS_DIR/scenario
    mapping_fixture_state_load || { printf 'fixture state unreadable\n'; return 1; }
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 1
    mapping_proxy_probe_accept() {
        if [[ $grow == 1 ]]; then
            printf '%s\n' "$((before + 1))" > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/accept.count"
            printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' \
                >> "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/connect.log"
        fi
        printf 'curl: (%s) TLS failure before CONNECT\n' "$probe_fail" > "$scenario_dir/proxy.probe-accept"
        return "$probe_fail"
    }
    mapping_proxy_probe_reject() { return 0; }
    mapping_proxy_probe_accept "$scenario_dir" || probe_rc=$?
    printf 'NEGATIVE_PROBE_EXIT=%s EXPECT=%s\n' "$probe_rc" "$probe_fail"
    [[ $probe_rc == "$probe_fail" ]] || { printf 'probe exit %s != %s\n' "$probe_rc" "$probe_fail"; failed=1; }
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 1
    verdict=$(mapping_proxy_layer_verdict "$before" "$after" "$probe_rc") || { printf 'layer verdict rejected\n'; return 1; }
    printf 'TLS_LAYER=%s CONNECT_BEFORE=%s CONNECT_AFTER=%s\n' "$verdict" "$before" "$after"
    [[ $verdict == "$expect_verdict" ]] || { printf 'layer verdict %s != %s\n' "$verdict" "$expect_verdict"; failed=1; }
    if [[ $grow == 1 ]]; then
        ((after > before)) || { printf 'legal CONNECT not observed\n'; failed=1; }
    else
        [[ $after == "$before" ]] || { printf 'CONNECT grew without outer TLS success\n'; failed=1; }
    fi
    rc=0
    mapping_proxy_calibrate "$scenario_dir" || rc=$?
    printf 'CALIBRATE_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'failed TLS layer still calibrated: %s\n' "$rc"; failed=1; }
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 上游连接取证必须落在独立可写卷：资产卷对上游只读，requests.log/serve.log 若仍写在资产卷
# 则在只读文件系统上重定向失败、证据永不生成。断言挂载、登记与计数读取路径三处一致。
upstream_evidence_volume_writable() {
    local failed=0 line script rc=0
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    line=$(grep -m1 -- '--name gm-mtest-upstream' "$TLS_DIR/docker.calls") || { printf 'upstream run missing\n'; return 1; }
    printf 'UPSTREAM_EVIDENCE_RUN=%s\n' "$line"
    case "$line" in
        *"-v gm-mtest-mapping-assets:$MAPPING_ASSET_ROOT:ro"*) ;;
        *) printf 'upstream asset volume is not read-only\n'; failed=1 ;;
    esac
    case "$line" in
        *"-v gm-mtest-mapping-evidence:$MAPPING_EVIDENCE_MOUNT "*) ;;
        *) printf 'upstream lacks the writable evidence volume\n'; failed=1 ;;
    esac
    case "$line" in
        *"$MAPPING_EVIDENCE_MOUNT:ro"*) printf 'evidence volume mounted read-only\n'; failed=1 ;;
    esac
    [[ $MAPPING_UPSTREAM_REQUESTS == "$MAPPING_EVIDENCE_MOUNT/requests.log" ]] \
        || { printf 'evidence count path is not on the rw volume: %s\n' "$MAPPING_UPSTREAM_REQUESTS"; failed=1; }
    grep -q $'register\tvolume\tgm-mtest-mapping-evidence\tmtest\tmapping\tevidence\t' "$TLS_DIR/ledger/ledger.tsv" \
        || { printf 'evidence volume not registered\n'; failed=1; }
    # 生成的服务脚本必须只向证据卷写入；只读资产卷上的写重定向会失败并让循环空转。
    script=$(mapping_upstream_serve_script) || { printf 'serve script generation failed\n'; return 1; }
    [[ $script == *'E=${MAPPING_EVIDENCE_ROOT:?}'* ]] || { printf 'serve script ignores the evidence root\n'; failed=1; }
    [[ $script != *'$R/upstream/requests.log'* && $script != *'$R/upstream/serve.log'* ]] \
        || { printf 'serve script writes into the read-only asset volume\n'; failed=1; }
    # 计数读取的是 rw 路径，且文件缺失时返回非零而不是默认 0。
    mapping_upstream_evidence_count "$TLS_SCENARIO_ID" || rc=$?
    printf 'UPSTREAM_EVIDENCE_EXIT=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'missing evidence file was accepted as a count\n'; failed=1; }
    grep -q "wc -l < '$MAPPING_EVIDENCE_MOUNT/requests.log'" "$TLS_DIR/docker.calls" \
        || { printf 'evidence count does not read the rw path\n'; failed=1; }
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 负例注入必须真实替换文件：客户端 CA 被换成不受信根、服务端叶证书被换成错 SAN 叶证书，
# 且真实校验链在相应 TLS 层失败（不能只靠替身把同步置为失败冒充拒绝）。
negative_injection_replaces_files() {
    local failed=0 before_fp after_fp srv_before srv_after
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    # 负例注入按产品镜像执行脚本；夹具契约里显式给出与 tls_setup 一致的产品镜像。
    MAPPING_PRODUCT_IMAGE=product
    mapping_fixture_docker() { tls_negative_injection_docker "$@"; }
    before_fp=$(mapping_cert_fingerprint "$TLS_DIR/ca/upstream-ca.crt") || failed=1
    mapping_negative_wrong_ca upstream-ca.crt || { printf 'wrong CA injection failed\n'; return 1; }
    after_fp=$(mapping_cert_fingerprint "$TLS_DIR/ca/upstream-ca.crt") || failed=1
    printf 'NEG_CA_FP before=%s after=%s\n' "$before_fp" "$after_fp"
    [[ -n $after_fp && $after_fp != "$before_fp" ]] || { printf 'client CA was not replaced\n'; failed=1; }
    openssl x509 -in "$TLS_DIR/ca/upstream-ca.crt" -noout -subject 2>/dev/null | grep -q 'GM-Mapping-Untrusted-CA' \
        || { printf 'replaced client CA is not the untrusted root\n'; failed=1; }
    # 真实校验链：原上游叶证书在替换后的根下必须验证失败。
    if mapping_cert_verifies_with "$TLS_ASSETS/upstream/tls/srv.crt" "$TLS_DIR/ca/upstream-ca.crt"; then
        printf 'untrusted CA still verified the upstream leaf\n'
        failed=1
    fi
    printf 'NEG_CA_CHAIN_REJECTED=1\n'
    srv_before=$(mapping_cert_fingerprint "$TLS_ASSETS/upstream/tls/srv.crt") || failed=1
    MAPPING_NEG_HOST='other-host.invalid' mapping_negative_wrong_san upstream \
        || { printf 'wrong SAN injection failed\n'; return 1; }
    srv_after=$(mapping_cert_fingerprint "$TLS_ASSETS/upstream/tls/srv.crt") || failed=1
    printf 'NEG_SAN_FP before=%s after=%s\n' "$srv_before" "$srv_after"
    [[ -n $srv_after && $srv_after != "$srv_before" ]] || { printf 'server leaf was not replaced\n'; failed=1; }
    if mapping_cert_san_has "$TLS_ASSETS/upstream/tls/srv.crt" "$MAPPING_UPSTREAM_HOST"; then
        printf 'replaced leaf still carries the expected SAN\n'
        failed=1
    fi
    mapping_cert_san_has "$TLS_ASSETS/upstream/tls/srv.crt" other-host.invalid \
        || { printf 'replaced leaf lost its injected SAN\n'; failed=1; }
    # 链仍由真实 CA 签发 ⇒ 拒绝只能来自主机名不匹配（正确的内层 TLS 判据）。
    mapping_cert_verifies_with "$TLS_ASSETS/upstream/tls/srv.crt" "$TLS_ASSETS/upstream/tls/ca.crt" \
        || { printf 'replaced leaf chain must still verify\n'; failed=1; }
    printf 'NEG_SAN_HOSTNAME_MISMATCH=1\n'
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 接受端口只在拨号成功后回 200，且拨号目的只能是冻结地址 U:443。
proxy_accept_dials_frozen_u() {
    local dir failed=0 rc=0
    dir=$(mktemp -d)
    printf '0\n' > "$dir/accept.count"
    : > "$dir/dials"
    mapping_proxy_tls_start() { exec 3>"$dir/replies"; }
    mapping_proxy_dial() { printf '%s:%s\n' "$1" "$2" >> "$dir/dials"; return 0; }
    mapping_proxy_relay() { return 0; }
    printf 'CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n' \
        | mapping_proxy_serve 8443 "$dir/cert" "$dir/key" "$dir/accept.count" 140.82.112.11 accept || rc=$?
    printf 'ACCEPT_SERVE_EXIT=%s\n' "$rc"
    [[ $rc == 0 ]] || failed=1
    [[ $(cat "$dir/dials") == '140.82.112.11:443' ]] || { printf 'dial target not frozen U:443: %s\n' "$(cat "$dir/dials")"; failed=1; }
    [[ $(cat "$dir/replies") == *'200 Connection Established'* ]] || { printf 'accept port did not return 200\n'; failed=1; }
    [[ $(cat "$dir/accept.count") == 1 ]] || { printf 'accept counter not incremented\n'; failed=1; }
    grep -q $'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443' "$dir/connect.log" \
        || { printf 'connect evidence missing frozen U\n'; failed=1; }
    # 拨号地址只能是字面量：主机名上游必须在拨号前被拒绝。
    : > "$dir/dials"
    rc=0
    printf 'CONNECT github.com:443 HTTP/1.1\r\n\r\n' \
        | mapping_proxy_serve 8443 "$dir/cert" "$dir/key" "$dir/accept.count" github.com accept >/dev/null 2>&1 || rc=$?
    printf 'HOSTNAME_DIAL_EXIT=%s\n' "$rc"
    [[ $rc != 0 ]] || { printf 'hostname upstream accepted\n'; failed=1; }
    [[ ! -s $dir/dials ]] || { printf 'dial attempted for hostname upstream\n'; failed=1; }
    rm -rf "$dir"
    return "$failed"
}

# 拒绝端口对合法 CONNECT 计数并回 403，绝不拨号；两端口计数文件相互独立并求和保存。
proxy_reject_never_dials() {
    local dir failed=0 rc=0
    dir=$(mktemp -d)
    printf '0\n' > "$dir/reject.count"
    printf '0\n' > "$dir/accept.count"
    : > "$dir/dials"
    mapping_proxy_tls_start() { exec 3>"$dir/replies"; }
    mapping_proxy_dial() { printf '%s:%s\n' "$1" "$2" >> "$dir/dials"; return 0; }
    mapping_proxy_relay() { return 0; }
    printf 'CONNECT github.com:443 HTTP/1.1\r\n\r\n' \
        | mapping_proxy_serve 8444 "$dir/cert" "$dir/key" "$dir/reject.count" 140.82.112.11 reject || rc=$?
    printf 'REJECT_SERVE_EXIT=%s\n' "$rc"
    [[ $rc == 0 ]] || failed=1
    [[ $(cat "$dir/replies") == *'403 Forbidden'* ]] || { printf 'reject port did not return 403\n'; failed=1; }
    [[ ! -s $dir/dials ]] || { printf 'reject port dialed upstream\n'; failed=1; }
    [[ $(cat "$dir/reject.count") == 1 ]] || { printf 'reject counter not incremented\n'; failed=1; }
    grep -q $'authority=github.com:443\tmode=reject\tdial_target=-' "$dir/connect.log" \
        || { printf 'reject evidence missing\n'; failed=1; }
    : > "$dir/replies"
    printf 'CONNECT github.com:443 HTTP/1.1\r\n\r\n' \
        | mapping_proxy_serve 8443 "$dir/cert" "$dir/key" "$dir/accept.count" 140.82.112.11 accept || rc=$?
    [[ $(cat "$dir/accept.count") == 1 && $(cat "$dir/reject.count") == 1 ]] \
        || { printf 'port counters are not independent\n'; failed=1; }
    mapping_proxy_baseline_write "$dir" 1 1 || failed=1
    [[ $(mapping_proxy_baseline_total "$dir/proxy.before") == 2 ]] || { printf 'baseline sum wrong\n'; failed=1; }
    rm -rf "$dir"
    return "$failed"
}

# 非精确 authority（含错误端口）一律 502 且不拨号，两个模式都如此。
proxy_other_authority_never_dials() {
    local dir failed=0 rc=0 spec mode port target
    dir=$(mktemp -d)
    : > "$dir/dials"
    mapping_proxy_tls_start() { exec 3>"$dir/replies"; }
    mapping_proxy_dial() { printf '%s:%s\n' "$1" "$2" >> "$dir/dials"; return 0; }
    mapping_proxy_relay() { return 0; }
    for spec in \
        'accept 8443 example.test:443' \
        'accept 8443 github.com:8443' \
        'accept 8443 140.82.112.11:443' \
        'reject 8444 example.test:443' \
        'reject 8444 github.com:8443'; do
        read -r mode port target <<< "$spec"
        printf '0\n' > "$dir/count"
        : > "$dir/replies"
        : > "$dir/dials"
        rc=0
        printf 'CONNECT %s HTTP/1.1\r\n\r\n' "$target" \
            | mapping_proxy_serve "$port" "$dir/cert" "$dir/key" "$dir/count" 140.82.112.11 "$mode" || rc=$?
        printf 'OTHER_AUTHORITY mode=%s target=%s EXIT=%s\n' "$mode" "$target" "$rc"
        [[ $rc == 0 ]] || failed=1
        [[ $(cat "$dir/replies") == *'502 Bad Gateway'* ]] || { printf 'authority %s not rejected with 502\n' "$target"; failed=1; }
        [[ ! -s $dir/dials ]] || { printf 'authority %s dialed upstream\n' "$target"; failed=1; }
        [[ $(cat "$dir/count") == 1 ]] || { printf 'authority %s not counted as attempt\n' "$target"; failed=1; }
    done
    rm -rf "$dir"
    return "$failed"
}

# 代理读数损坏或缺失必须失败：进程侧返回 80，校准侧一律 80 且绝不默认成 0。
proxy_bad_count_fails() {
    local dir failed=0 rc=0 scenario_dir
    dir=$(mktemp -d)
    mapping_proxy_tls_start() { exec 3>"$dir/replies"; }
    mapping_proxy_dial() { return 0; }
    mapping_proxy_relay() { return 0; }
    printf 'not-a-number\n' > "$dir/accept.count"
    rc=0
    printf 'CONNECT github.com:443 HTTP/1.1\r\n\r\n' \
        | mapping_proxy_serve 8443 "$dir/cert" "$dir/key" "$dir/accept.count" 140.82.112.11 accept >/dev/null 2>&1 || rc=$?
    printf 'CORRUPT_COUNT_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'corrupt counter not rejected with 80\n'; failed=1; }
    [[ ! -e $dir/replies ]] || { printf 'corrupt counter still served\n'; failed=1; }
    printf -- '-1\n' > "$dir/accept.count"
    rc=0
    printf 'CONNECT github.com:443 HTTP/1.1\r\n\r\n' \
        | mapping_proxy_serve 8443 "$dir/cert" "$dir/key" "$dir/accept.count" 140.82.112.11 accept >/dev/null 2>&1 || rc=$?
    printf 'NEGATIVE_COUNT_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'negative counter not rejected with 80\n'; failed=1; }
    rm -rf "$dir"
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    scenario_dir=$TLS_DIR/scenario
    mapping_proxy_probe_accept() { printf 'mapping-upstream-ok\n' > "$scenario_dir/proxy.probe-accept"; return 0; }
    mapping_proxy_probe_reject() { printf '403 Forbidden\n' > "$scenario_dir/proxy.probe-reject"; return 0; }
    printf 'broken\n' > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/accept.count"
    rc=0
    mapping_proxy_calibrate "$scenario_dir" || rc=$?
    printf 'CALIBRATE_CORRUPT_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'corrupt read accepted by calibrate\n'; failed=1; }
    printf '0\n' > "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/accept.count"
    rm -f "$TLS_ASSETS/proxy/scenarios/$TLS_SCENARIO_ID/reject.count"
    rc=0
    mapping_proxy_calibrate "$scenario_dir" || rc=$?
    printf 'CALIBRATE_MISSING_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'missing counter accepted by calibrate\n'; failed=1; }
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 客户端信任分离两条链：根证书互不相同、SAN 各自匹配、证书不得跨链验证、客户端卷只含公开 CA。
client_trust_separates_two_ca() {
    local failed=0 line extra fp_up fp_px up_ca px_ca rc=0 dns_line
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    up_ca=$TLS_DIR/ca/upstream-ca.crt
    px_ca=$TLS_DIR/ca/proxy-ca.crt
    [[ -f $up_ca && -f $px_ca ]] || { printf 'client CA files missing\n'; failed=1; }
    fp_up=$(mapping_cert_fingerprint "$up_ca") || failed=1
    fp_px=$(mapping_cert_fingerprint "$px_ca") || failed=1
    printf 'UPSTREAM_CA=%s\nPROXY_CA=%s\n' "$fp_up" "$fp_px"
    [[ -n $fp_up && -n $fp_px && $fp_up != "$fp_px" ]] || { printf 'two roots are not distinct\n'; failed=1; }
    extra=$(ls -A "$TLS_DIR/ca" | grep -v -x -e upstream-ca.crt -e proxy-ca.crt || true)
    [[ -z $extra ]] || { printf 'client CA volume carries extra material: %s\n' "$extra"; failed=1; }
    if grep -rlq 'PRIVATE KEY' "$TLS_DIR/ca" 2>/dev/null; then printf 'client CA volume carries a private key\n'; failed=1; fi
    mapping_cert_san_has "$TLS_ASSETS/upstream/tls/srv.crt" github.com || { printf 'upstream SAN missing github.com\n'; failed=1; }
    mapping_cert_san_has "$TLS_ASSETS/proxy/tls/srv.crt" gm-proxy || { printf 'proxy SAN missing gm-proxy\n'; failed=1; }
    if mapping_cert_san_has "$TLS_ASSETS/proxy/tls/srv.crt" github.com; then printf 'proxy cert claims github.com\n'; failed=1; fi
    mapping_cert_verifies_with "$TLS_ASSETS/upstream/tls/srv.crt" "$up_ca" || { printf 'upstream chain not verifiable\n'; failed=1; }
    if mapping_cert_verifies_with "$TLS_ASSETS/upstream/tls/srv.crt" "$px_ca"; then printf 'upstream cert accepted by proxy CA\n'; failed=1; fi
    mapping_cert_verifies_with "$TLS_ASSETS/proxy/tls/srv.crt" "$px_ca" || { printf 'proxy chain not verifiable\n'; failed=1; }
    if mapping_cert_verifies_with "$TLS_ASSETS/proxy/tls/srv.crt" "$up_ca"; then printf 'proxy cert accepted by upstream CA\n'; failed=1; fi
    [[ -f $TLS_ASSETS/upstream/tls/ca.key && -f $TLS_ASSETS/proxy/tls/ca.key ]] || { printf 'fixture CA keys missing\n'; failed=1; }
    [[ ! -e $TLS_DIR/ca/upstream-ca.key && ! -e $TLS_DIR/ca/proxy-ca.key ]] || { printf 'client CA volume carries a CA key\n'; failed=1; }
    [[ -x $TLS_ASSETS/proxy/proxy.sh ]] || { printf 'proxy script missing in asset volume\n'; failed=1; }
    # 行为断言：生成的代理脚本必须把参数交给夹具入口——非法模式应返回用法错误 2。
    rc=0
    bash "$TLS_ASSETS/proxy/proxy.sh" "$MAPPING_PROXY_ACCEPT_PORT" "$TLS_DIR/absent.crt" "$TLS_DIR/absent.key" \
        "$TLS_DIR/scenario/accept.count" 140.82.112.11 bogus >/dev/null 2>&1 || rc=$?
    printf 'PROXY_SCRIPT_USAGE_EXIT=%s\n' "$rc"
    [[ $rc == 2 ]] || { printf 'proxy script did not delegate to fixture entrypoint\n'; failed=1; }
    rc=0
    bash "$TLS_ASSETS/proxy/proxy.sh" "$MAPPING_PROXY_ACCEPT_PORT" "$TLS_DIR/absent.crt" "$TLS_DIR/absent.key" \
        "$TLS_DIR/scenario/accept.count" github.com accept >/dev/null 2>&1 || rc=$?
    printf 'PROXY_SCRIPT_HOSTNAME_EXIT=%s\n' "$rc"
    [[ $rc == 2 ]] || { printf 'proxy script forwarded a hostname upstream\n'; failed=1; }
    line=$(grep -m1 -- '--name gm-mtest-upstream' "$TLS_DIR/docker.calls") || failed=1
    printf 'UPSTREAM_RUN=%s\n' "$line"
    case "$line" in
        *'--network-alias github.com'*) printf 'upstream carries github.com alias\n'; failed=1 ;;
        *"-v gm-mtest-mapping-assets:$MAPPING_ASSET_ROOT:ro"*) ;;
        *) printf 'upstream asset mount wrong\n'; failed=1 ;;
    esac
    case "$line" in
        *'mapping-ca'*) printf 'upstream mounts the client CA volume\n'; failed=1 ;;
    esac
    line=$(grep -m1 -- '--name gm-mtest-proxy' "$TLS_DIR/docker.calls") || failed=1
    printf 'PROXY_RUN=%s\n' "$line"
    case "$line" in
        *"-v gm-mtest-mapping-assets:$MAPPING_ASSET_ROOT "*|*"-v gm-mtest-mapping-assets:$MAPPING_ASSET_ROOT --entrypoint"*) ;;
        *) printf 'proxy asset mount wrong\n'; failed=1 ;;
    esac
    case "$line" in
        *'mapping-ca'*) printf 'proxy mounts the client CA volume\n'; failed=1 ;;
    esac
    line=$(grep -m1 -- '--name gm-mtest-probe' "$TLS_DIR/docker.calls") || failed=1
    printf 'PROBE_RUN=%s\n' "$line"
    case "$line" in
        *"-v gm-mtest-mapping-ca:$MAPPING_CA_MOUNT:ro"*) ;;
        *) printf 'probe does not mount only the public CA volume\n'; failed=1 ;;
    esac
    case "$line" in
        *'mapping-assets'*) printf 'probe mounts private asset volume\n'; failed=1 ;;
    esac
    # 代理端口由独立计数文件承载：接受端口用 accept.count，拒绝端口用 reject.count。
    grep -q "proxy.sh $MAPPING_PROXY_ACCEPT_PORT $MAPPING_ASSET_ROOT/proxy/tls/srv.crt $MAPPING_ASSET_ROOT/proxy/tls/srv.key $MAPPING_ASSET_ROOT/proxy/scenarios/$TLS_SCENARIO_ID/accept.count" \
        "$TLS_DIR/docker.calls" || { printf 'accept port counter wiring wrong\n'; failed=1; }
    grep -q "proxy.sh $MAPPING_PROXY_REJECT_PORT $MAPPING_ASSET_ROOT/proxy/tls/srv.crt $MAPPING_ASSET_ROOT/proxy/tls/srv.key $MAPPING_ASSET_ROOT/proxy/scenarios/$TLS_SCENARIO_ID/reject.count" \
        "$TLS_DIR/docker.calls" || { printf 'reject port counter wiring wrong\n'; failed=1; }
    # 受控 DNS：gm-proxy 指向 X，其余名称不可解析，不递归。
    grep -q -- "--address=/gm-proxy/140.82.112.12" "$TLS_DIR/docker.calls" || { printf 'controlled DNS mapping missing\n'; failed=1; }
    grep -q -- '--address=/#/' "$TLS_DIR/docker.calls" || { printf 'controlled DNS catch-all missing\n'; failed=1; }
    grep -q -- '--no-resolv' "$TLS_DIR/docker.calls" || { printf 'controlled DNS recurses upstream\n'; failed=1; }
    # cap-drop ALL 下必须下移非特权端口起点，DNS 才能在 53 监听（与上游 443 同款 sysctl）。
    dns_line=$(grep -m1 -- '--name gm-mtest-dns' "$TLS_DIR/docker.calls") || failed=1
    printf 'DNS_RUN=%s\n' "$dns_line"
    case "$dns_line" in
        *"--sysctl net.ipv4.ip_unprivileged_port_start=$MAPPING_DNS_PORT"*) ;;
        *) printf 'dns container cannot bind 53 under cap-drop ALL\n'; failed=1 ;;
    esac
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 校准成功路径：探针成功且两端口计数增长、authority 精确相等 → 返回 0 并写出与计数一致的
# proxy.before；探针成功但计数不增长时必须 80 且不得留下基线。
proxy_calibrate_writes_baseline() {
    local failed=0 rc=0 scenario_dir accept_file reject_file exp_accept exp_reject dial
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    scenario_dir=$TLS_DIR/scenario
    mapping_fixture_state_load || { printf 'fixture state unreadable\n'; return 1; }
    accept_file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_ACCEPT_PORT") || return 1
    reject_file=$(mapping_proxy_count_path "$TLS_SCENARIO_ID" "$MAPPING_PROXY_REJECT_PORT") || return 1
    printf '5\n' > "$accept_file"
    printf '3\n' > "$reject_file"
    dial="$MPF_UPSTREAM_IP:$MAPPING_UPSTREAM_PORT"
    tls_calibrate_probe_stubs "$scenario_dir" grow
    tls_connect_log_write "$MAPPING_PROXY_AUTHORITY" "$dial" "$MAPPING_PROXY_AUTHORITY" -
    rc=0
    mapping_proxy_calibrate "$scenario_dir" || rc=$?
    printf 'CALIBRATE_SUCCESS_EXIT=%s\n' "$rc"
    [[ $rc == 0 ]] || { printf 'calibration success path rejected: %s\n' "$rc"; failed=1; }
    [[ -f $scenario_dir/proxy.before ]] || { printf 'proxy.before not written\n'; failed=1; }
    exp_accept=$(command cat -- "$accept_file")
    exp_reject=$(command cat -- "$reject_file")
    printf 'PROXY_BEFORE=%s\n' "$(tr '\n' ' ' < "$scenario_dir/proxy.before")"
    grep -qx $'accept\t'"$exp_accept" "$scenario_dir/proxy.before" || { printf 'baseline accept != probe count\n'; failed=1; }
    grep -qx $'reject\t'"$exp_reject" "$scenario_dir/proxy.before" || { printf 'baseline reject != probe count\n'; failed=1; }
    [[ $(mapping_proxy_baseline_total "$scenario_dir/proxy.before") == "$((exp_accept + exp_reject))" ]] \
        || { printf 'baseline total != counter sum\n'; failed=1; }
    # 反例：探针成功但计数不增长，校准必须 80 且不得写基线。
    rm -f "$scenario_dir/proxy.before"
    printf '7\n' > "$accept_file"
    printf '2\n' > "$reject_file"
    tls_calibrate_probe_stubs "$scenario_dir" static
    rc=0
    mapping_proxy_calibrate "$scenario_dir" || rc=$?
    printf 'CALIBRATE_NO_GROWTH_EXIT=%s\n' "$rc"
    [[ $rc == 80 ]] || { printf 'zero-increment calibration accepted: %s\n' "$rc"; failed=1; }
    [[ ! -e $scenario_dir/proxy.before ]] || { printf 'baseline written without growth\n'; failed=1; }
    rm -rf "$TLS_DIR"
    return "$failed"
}

# authority 判据可执行且精确：日志必须含精确 authority 的接受与拒绝各一行、拨号目的只能是
# U:443；任一不匹配即校准 80，即使探针成功、计数增长。
proxy_log_check_authority_exact() {
    local failed=0 rc=0 scenario_dir spec auth dial
    tls_setup || { printf 'tls setup failed\n'; return 1; }
    scenario_dir=$TLS_DIR/scenario
    mapping_fixture_state_load || { printf 'fixture state unreadable\n'; return 1; }
    tls_calibrate_probe_stubs "$scenario_dir" grow
    dial="$MPF_UPSTREAM_IP:$MAPPING_UPSTREAM_PORT"
    tls_connect_log_write "$MAPPING_PROXY_AUTHORITY" "$dial" "$MAPPING_PROXY_AUTHORITY" -
    mapping_proxy_log_check || { printf 'exact authority rejected\n'; failed=1; }
    printf 'LOG_CHECK_EXACT_AUTHORITY=0\n'
    for spec in \
        'github.com:8443 140.82.112.11:443' \
        'other.test:443 140.82.112.11:443' \
        'github.com:443 140.82.112.99:443'; do
        read -r auth dial <<< "$spec"
        tls_connect_log_write "$auth" "$dial" "$MAPPING_PROXY_AUTHORITY" - || failed=1
        if mapping_proxy_log_check; then printf 'authority judgement accepted mismatch: %s\n' "$spec"; failed=1; fi
        printf 'LOG_CHECK_REJECT auth=%s dial=%s\n' "$auth" "$dial"
        rc=0
        mapping_proxy_calibrate "$scenario_dir" || rc=$?
        printf 'CALIBRATE_MISMATCH_EXIT auth=%s dial=%s rc=%s\n' "$auth" "$dial" "$rc"
        [[ $rc == 80 ]] || { printf 'mismatched authority still calibrated: %s\n' "$spec"; failed=1; }
    done
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 真实 CA 发布逻辑（不替换 mapping_fixture_ca_publish）：客户端 CA 卷只出现公开证书，
# 不含 PRIVATE KEY、不含 *.key，且无额外文件。
ca_publish_excludes_private_key() {
    local failed=0 extra
    tls_local_base || return 1
    mapping_profile_load "$TLS_DIR/profile.tsv" || { printf 'profile load failed\n'; return 1; }
    mapping_fixture_docker() { tls_publish_docker "$@"; }
    mapping_fixture_asset_exec "$(mapping_asset_script)" product || { printf 'asset script failed\n'; failed=1; }
    [[ -f $TLS_ASSETS/upstream/tls/ca.key && -f $TLS_ASSETS/proxy/tls/ca.key ]] \
        || { printf 'asset volume lacks CA keys\n'; failed=1; }
    mapping_fixture_ca_publish product || { printf 'ca publish failed\n'; failed=1; }
    printf 'PUBLISHED=%s\n' "$(ls -A "$TLS_DIR/ca" | tr '\n' ' ')"
    extra=$(ls -A "$TLS_DIR/ca" | grep -v -x -e upstream-ca.crt -e proxy-ca.crt || true)
    [[ -z $extra ]] || { printf 'client CA volume carries extra material: %s\n' "$extra"; failed=1; }
    if compgen -G "$TLS_DIR/ca/*.key" >/dev/null; then printf 'client CA volume carries a .key file\n'; failed=1; fi
    if grep -rlq 'PRIVATE KEY' "$TLS_DIR/ca" 2>/dev/null; then printf 'client CA volume carries a private key\n'; failed=1; fi
    cmp -s "$TLS_ASSETS/upstream/tls/ca.crt" "$TLS_DIR/ca/upstream-ca.crt" \
        || { printf 'published upstream CA is not the public cert\n'; failed=1; }
    cmp -s "$TLS_ASSETS/proxy/tls/ca.crt" "$TLS_DIR/ca/proxy-ca.crt" \
        || { printf 'published proxy CA is not the public cert\n'; failed=1; }
    if grep -q -- '\.key' "$TLS_DIR/publish.calls" 2>/dev/null; then printf 'publish boundary read a private key path\n'; failed=1; fi
    rm -rf "$TLS_DIR"
    return "$failed"
}

# 外层 TLS：代理证书由不受信任的 CA 签发，链校验失败 → CONNECT 不增长、校准拒绝。
wrong_proxy_ca() {
    local failed=0 dir
    tls_setup || return 1
    dir=$TLS_DIR/neg
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=GM-Mapping-Untrusted-CA \
        -addext 'basicConstraints=critical,CA:TRUE' -keyout "$dir/ca.key" -out "$dir/ca.crt" >/dev/null 2>&1 || failed=1
    tls_make_leaf "$dir" gm-proxy gm-proxy "$dir/ca.crt" "$dir/ca.key" || failed=1
    mapping_cert_san_has "$dir/leaf.crt" gm-proxy || { printf 'negative proxy cert lost its SAN\n'; failed=1; }
    if mapping_cert_verifies_with "$dir/leaf.crt" "$TLS_DIR/ca/proxy-ca.crt"; then
        printf 'untrusted proxy CA still verified\n'
        failed=1
    fi
    printf 'PROXY_CA_NEG_VERIFY_FAILED=1\n'
    rm -rf "$TLS_DIR"
    [[ $failed == 0 ]] || return 1
    tls_negative_case outer-failure 0 60
}

# 外层 TLS：代理 SAN 不匹配 gm-proxy，主机名校验失败 → CONNECT 不增长、校准拒绝。
wrong_proxy_san() {
    local failed=0 dir
    tls_setup || return 1
    dir=$TLS_DIR/neg
    tls_make_leaf "$dir" gm-proxy other-host.test "$TLS_ASSETS/proxy/tls/ca.crt" "$TLS_ASSETS/proxy/tls/ca.key" || failed=1
    if mapping_cert_san_has "$dir/leaf.crt" gm-proxy; then printf 'negative SAN accepted for gm-proxy\n'; failed=1; fi
    mapping_cert_verifies_with "$dir/leaf.crt" "$TLS_DIR/ca/proxy-ca.crt" || { printf 'proxy CA chain must still verify\n'; failed=1; }
    printf 'PROXY_SAN_NEG_REJECTED=1\n'
    rm -rf "$TLS_DIR"
    [[ $failed == 0 ]] || return 1
    tls_negative_case outer-failure 0 60
}

# 内层 TLS：上游证书由不受信任的 CA 签发 → 有合法 CONNECT 但内层获取失败、校准拒绝。
wrong_upstream_ca() {
    local failed=0 dir
    tls_setup || return 1
    dir=$TLS_DIR/neg
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=GM-Mapping-Untrusted-Upstream-CA \
        -addext 'basicConstraints=critical,CA:TRUE' -keyout "$dir/ca.key" -out "$dir/ca.crt" >/dev/null 2>&1 || failed=1
    tls_make_leaf "$dir" github.com github.com "$dir/ca.crt" "$dir/ca.key" || failed=1
    mapping_cert_san_has "$dir/leaf.crt" github.com || { printf 'negative upstream cert lost its SAN\n'; failed=1; }
    if mapping_cert_verifies_with "$dir/leaf.crt" "$TLS_DIR/ca/upstream-ca.crt"; then
        printf 'untrusted upstream CA still verified\n'
        failed=1
    fi
    printf 'UPSTREAM_CA_NEG_VERIFY_FAILED=1\n'
    rm -rf "$TLS_DIR"
    [[ $failed == 0 ]] || return 1
    tls_negative_case inner-failure 1 60
}

# 内层 TLS：上游 SAN 不匹配 github.com → 有合法 CONNECT 但内层获取失败、校准拒绝。
wrong_upstream_san() {
    local failed=0 dir
    tls_setup || return 1
    dir=$TLS_DIR/neg
    tls_make_leaf "$dir" github.com other-host.test "$TLS_ASSETS/upstream/tls/ca.crt" "$TLS_ASSETS/upstream/tls/ca.key" || failed=1
    if mapping_cert_san_has "$dir/leaf.crt" github.com; then printf 'negative SAN accepted for github.com\n'; failed=1; fi
    mapping_cert_verifies_with "$dir/leaf.crt" "$TLS_DIR/ca/upstream-ca.crt" || { printf 'upstream CA chain must still verify\n'; failed=1; }
    printf 'UPSTREAM_SAN_NEG_REJECTED=1\n'
    rm -rf "$TLS_DIR"
    [[ $failed == 0 ]] || return 1
    tls_negative_case inner-failure 1 60
}

mkdir -p "$WORK/profile"
profile_write "$WORK/profile/base.tsv"

MAPPING_NETWORK_TESTS='mapping_profile_rejects_conflict
mapping_extra_attachment_rejected
mapping_requires_ready
runner_prepares_before_ready
networked_start_requires_generation_ack
second_generation_rebinds_network
scenario_keeps_control_and_ledger_root
mapping_rule_keys_exact
mapping_counter_missing_or_duplicate_fails
mapping_witness_pause_detected
mapping_network_create_registers
mapping_isolation_check_behavior
mapping_run_id_binding
mapping_snapshot_requires_ready'

MAPPING_TLS_TESTS='upstream_evidence_volume_writable
negative_injection_replaces_files
proxy_accept_dials_frozen_u
proxy_reject_never_dials
proxy_other_authority_never_dials
proxy_bad_count_fails
proxy_calibrate_writes_baseline
proxy_log_check_authority_exact
client_trust_separates_two_ca
ca_publish_excludes_private_key
wrong_proxy_ca
wrong_proxy_san
wrong_upstream_ca
wrong_upstream_san'

case "${1:-all}" in
    network) TESTS=$MAPPING_NETWORK_TESTS ;;
    tls-proxy) TESTS=$MAPPING_TLS_TESTS ;;
    all) TESTS="$MAPPING_NETWORK_TESTS
$MAPPING_TLS_TESTS" ;;
    *)
        printf 'unknown subset: %s\n' "$1" >&2
        exit 2
        ;;
esac

failed=0
for name in $TESTS; do
    rc=0
    ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
