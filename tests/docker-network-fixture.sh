#!/usr/bin/env bash
# 普通用户网络夹具；宿主特权操作全部留在固定外层。
SAFE=(--user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges)
NETSAFE=(--sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv4.ip_unprivileged_port_start=0)
CONTROL_SEQ=0
# 白名单覆盖所有附件，不能只检查主网络。
policy_networks() {
    [[ $1 == "$IT_NETWORK" ]]
}
# 请求固定枚举操作并有限等待，握手并不作为防火墙证明。
network_control() {
    local i
    CONTROL_SEQ=$((CONTROL_SEQ + 1))
    printf '%s\n' "$1" > "$IT_EVIDENCE_DIR/control/request-$CONTROL_SEQ" || return $?
    for ((i=0;i<100;i++)); do
        if [[ -f $IT_EVIDENCE_DIR/control/ack-$CONTROL_SEQ ]]; then return 0; fi
        sleep 0.1
    done
    return 75
}
# 以统一安全参数启动具名容器，不创建匿名卷。
network_run() {
    docker run --label "gitdaemon.run=$IT_RUN_ID" "${SAFE[@]}" "$@"
}
# 核查所有附件、安全选项、实际身份及命名卷，不接受额外网络。
assert_container_network_policy() {
    [[ ${IT_NETWORK_GUARD_READY:-} == 1 && -n ${IT_DNS_IP:-} ]] || return 77
    local id=$1 networks value mount mounts
    networks=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id") || return $?
    policy_networks "${networks% }" || return 1
    [[ $(docker inspect -f '{{.HostConfig.Dns}}' "$id") == "[$IT_DNS_IP]" ]] || return 1
    [[ $(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Privileged}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$id") == '10001:10001 true false [ALL] [no-new-privileges]' ]] || return 1
    [[ $(docker network inspect -f '{{.EnableIPv6}}' "$IT_NETWORK") == false ]] || return 1
    [[ $(docker inspect -f '{{index .HostConfig.Sysctls "net.ipv6.conf.all.disable_ipv6"}}' "$id") == 1 ]] || return 1
    [[ $(docker inspect -f '{{.HostConfig.ExtraHosts}} {{.HostConfig.CapAdd}}' "$id") == '[] []' ]] || return 1
    [[ $(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/ca"}}{{.Name}} {{.RW}}{{end}}{{end}}' "$id") == "gm-$IT_RUN_ID-ca false" ]] || return 1
    mounts=$(docker inspect -f '{{range .Mounts}}{{.Type}} {{.Name}}{{println}}{{end}}' "$id") || return $?
    while IFS= read -r mount; do
        [[ -z $mount || $mount == "volume gm-$IT_RUN_ID-"* ]] || return 1
    done <<< "$mounts"
    value=$(docker exec "$id" sh -c 'printf "%s %s" "$(id -ru)" "$(id -u)"') || return $?
    [[ $value == '10001 10001' ]] || return 1
    docker exec "$id" sh -c 'test "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1 && cat /etc/resolv.conf'
}
# 非递归本地 DNS 和见证就绪后才返回，缺少外层时业务创建次数为零。
network_fixture_start() {
    [[ ${IT_NETWORK_GUARD_READY:-} == 1 ]] || { printf 'guard required\n' >&2; return 77; }
    [[ $(id -u) != 0 ]] || return 77
    local prefix=gm-$IT_RUN_ID proto result
    docker network create --label "gitdaemon.run=$IT_RUN_ID" --ipv6=false --subnet 172.30.243.0/24 -o "com.docker.network.bridge.name=g$IT_RUN_ID" "$IT_NETWORK" || return $?
    docker network create --label "gitdaemon.run=$IT_RUN_ID" --ipv6=false --subnet 172.30.244.0/24 -o "com.docker.network.bridge.name=w$IT_RUN_ID" "$IT_WITNESS_NETWORK" || return $?
    network_run --rm --network none --entrypoint sh "$IT_TOOLS_IMAGE" -c 'test "$(id -ru)" = 10001 && test "$(id -u)" = 10001 && dnsmasq --version && dig -v' || return $?
    network_run -d --name "$prefix-dns" --network "$IT_NETWORK" --ip "$IT_DNS_IP" "${NETSAFE[@]}" --dns "$IT_DNS_IP" "$IT_TOOLS_IMAGE" dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon || return $?
    network_run -d --name "$prefix-client" --network "$IT_NETWORK" --ip 172.30.243.3 "${NETSAFE[@]}" --dns "$IT_DNS_IP" "$IT_TOOLS_IMAGE" sleep 600 || return $?
    network_run -d --name "$prefix-witness" --network "$IT_WITNESS_NETWORK" --ip 172.30.244.53 "${NETSAFE[@]}" --dns 172.30.244.53 -p 172.30.243.1:49382:19419 --entrypoint sh "$IT_TOOLS_IMAGE" -c 'busybox nc -lk -p 19419 -e /bin/cat & exec dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon' || return $?
    network_control witness || return $?
    for proto in +notcp +tcp; do
        result=$(docker exec "$prefix-client" dig +time=1 +tries=1 "$proto" "@$IT_DNS_IP" "$IT_RUN_ID-local.invalid" A) || return $?
        [[ $result == *'status: NXDOMAIN'* ]] || return 1
    done
    network_calibrate_dns || return $?
}
# 停止仅属于本轮的资源；异常外层还会以清单兜底。
network_fixture_stop() {
    local id ids status=0
    ids=$(docker ps -aq --filter "label=gitdaemon.run=$IT_RUN_ID") || return $?
    for id in $ids; do docker stop -t 1 "$id" || status=1; done
    return "$status"
}
# 校验完整五条精确 DROP 键后读取指定计数，拒绝缺失或重复证据。
network_count() {
    awk -v run="$IT_RUN_ID" -v wanted="$2" '
    BEGIN {
        split("cross-network host-published host-input dns-udp dns-tcp", keys, " ")
        split("172.30.244.53 172.30.243.1 172.30.243.1 172.30.244.53 172.30.244.53", dst, " ")
        split("tcp tcp tcp udp tcp", proto, " "); split("19419 49382 49383 53 53", port, " ")
    }
    /--comment/ {
        tag=""; source=""; target=""; protocol=""; dport=""; action=""; chain=""
        for(i=2;i<NF;i++) {
            if($i=="--comment"){tag=$(i+1);gsub(/"/,"",tag)}
            if($i=="-s")source=$(i+1); if($i=="-d")target=$(i+1)
            if($i=="-p")protocol=$(i+1); if($i=="--dport")dport=$(i+1)
            if($i=="-j")action=$(i+1); if($i=="-A")chain=$(i+1)
        }
        for(k=1;k<=5;k++)if(tag==run "-" keys[k]) {
            seen[k]++
            if($1!~/^\[[0-9]+:[0-9]+\]$/ || source!="172.30.243.4/32" || target!=dst[k] "/32" || protocol!=proto[k] || dport!=port[k] || action!="DROP" || chain!="E" run)bad=1
            split($1,a,":");gsub(/\[/,"",a[1]);counts[k]=a[1]
        }
    }
    END {
        for(k=1;k<=5;k++){if(seen[k]!=1)bad=1;if(keys[k]==wanted)value=counts[k]}
        if(bad || value=="")exit 1; print value
    }' "$IT_EVIDENCE_DIR/snapshot-$1.rules"
}
# 接收端恰好三个协议端口键，输出固定顺序且只接受非负整数。
network_witness() {
    awk '
    $3=="RETURN" {
        key=$4 ":" $11; n++
        if($1!~/^[0-9]+$/ || $2!~/^[0-9]+$/ || $10!=$4 || $8!="0.0.0.0/0" || $9!="0.0.0.0/0" || (key!="tcp:dpt:19419" && key!="udp:dpt:53" && key!="tcp:dpt:53"))bad=1
        seen[key]++; count[key]=$1
    }
    END {
        if(bad || n!=3 || seen["tcp:dpt:19419"]!=1 || seen["udp:dpt:53"]!=1 || seen["tcp:dpt:53"]!=1)exit 1
        print count["tcp:dpt:19419"];print count["udp:dpt:53"];print count["tcp:dpt:53"]
    }' "$IT_EVIDENCE_DIR/snapshot-$1.witness"
}
# 校准仅允许当前 DNS 协议增长，其他见证项必须不变。
network_witness_delta() {
    local before=$1 after=$2 proto=$3
    awk -v before="$before" -v after="$after" -v proto="$proto" 'BEGIN {
        if(split(before,b,"\n")!=3 || split(after,a,"\n")!=3 || (proto!="udp" && proto!="tcp"))exit 1
        target=(proto=="udp"?2:3)
        for(i=1;i<=3;i++) {
            if(b[i]!~/^[0-9]+$/ || a[i]!~/^[0-9]+$/)exit 1
            if(i==target){if(a[i]+0<=b[i]+0)exit 1}else if(a[i]!=b[i])exit 1
        }
    }'
}
# 每次请求比较目标 DROP 增量和接收端零增量，保留原始退出状态。
network_negative() {
    local label=$1 before after rc=0 key wb wa cb ca; shift
    network_control snapshot || return $?; before=$CONTROL_SEQ
    "$@" || rc=$?
    network_control snapshot || return $?; after=$CONTROL_SEQ
    printf 'NEGATIVE=%s EXIT=%s BEFORE=%s AFTER=%s\n' "$label" "$rc" "$before" "$after"
    wb=$(network_witness "$before") || return $?
    wa=$(network_witness "$after") || return $?
    [[ $rc != 0 && $wb == "$wa" ]] || return 1
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        cb=$(network_count "$before" "$key") || return $?
        ca=$(network_count "$after" "$key") || return $?
        if [[ $key == "$label" ]]; then [[ $ca -gt $cb ]] || return 1
        else [[ $cb == "$ca" ]] || return 1; fi
    done
}
# 产品固定为 .4；每代验证三个受控目的、产品 UDP 及共享 netns 工具 TCP。
assert_product_egress() {
    local id=$1 generation=$2 spec label address tool prefix=gm-$IT_RUN_ID
    DNS_GENERATION=''
    printf 'PRODUCT_GENERATION=%s ID=%s\n' "$generation" "$id"
    assert_container_network_policy "$id" || return $?
    address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id") || return $?
    [[ $address == 172.30.243.4 && ${DNS_CALIBRATED:-0} == 1 ]] || return 1
    for spec in 'cross-network 172.30.244.53:19419' 'host-published 172.30.243.1:49382' 'host-input 172.30.243.1:49383'; do
        read -r label address <<< "$spec"
        network_negative "$label" docker exec "$id" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$address/" || return $?
    done
    network_negative dns-udp docker exec "$id" timeout 4 busybox nslookup "$IT_RUN_ID-$generation-product.invalid" 172.30.244.53 || return $?
    network_run -d --name "$prefix-tcp" --network "container:$id" "$IT_TOOLS_IMAGE" sleep 120 || return $?
    tool=$(docker inspect -f '{{.Id}}' "$prefix-tcp") || return $?
    docker inspect "$tool" || return $?
    [[ $(docker inspect -f '{{.HostConfig.NetworkMode}} {{.Config.User}}' "$tool") == "container:$id 10001:10001" ]] || return 1
    [[ $(docker exec "$tool" sh -c 'printf "%s %s" "$(id -ru)" "$(id -u)"') == '10001 10001' ]] || return 1
    printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$id"
    network_negative dns-tcp docker exec "$tool" dig +time=1 +tries=1 +tcp @172.30.244.53 "$IT_RUN_ID-$generation-tool.invalid" A || return $?
    docker rm -f "$tool" || return $?
    DNS_GENERATION=$generation
}
# 逐代见证只检查已完成的同代出口断言及校准关闭后的零增长，不重开通路。
assert_dns_witness() {
    local current
    [[ ${DNS_CALIBRATED:-0} == 1 && ${DNS_GENERATION:-} == "$1" ]] || return 1
    network_control snapshot || return $?
    current=$(network_witness "$CONTROL_SEQ") || return $?
    [[ $current == "$DNS_BASELINE" ]]
}
# 仅在夹具启动内校准一次；结束关闭通路并保存逐代基准。
network_calibrate_dns() {
    [[ ${DNS_CALIBRATED:-0} == 0 ]] || return 1
    local generation=calibration proto before after result rc=0 prefix=gm-$IT_RUN_ID wb wa protocol
    for proto in +notcp +tcp; do
        network_control snapshot || return $?; before=$CONTROL_SEQ
        result=$(docker exec "$prefix-client" dig +time=1 +tries=1 "$proto" @172.30.244.53 "$IT_RUN_ID-$generation-positive.invalid" A) || return $?
        network_control snapshot || return $?; after=$CONTROL_SEQ
        printf '%s\n' "$result"
        [[ $result == *'status: NXDOMAIN'* ]] || return 1
        wb=$(network_witness "$before") || return $?
        wa=$(network_witness "$after") || return $?
        protocol=udp; [[ $proto != +tcp ]] || protocol=tcp
        network_witness_delta "$wb" "$wa" "$protocol" || return $?
        rc=0; [[ $wb == "$wa" ]] || rc=$?
        [[ $rc == 1 ]] || return 1
        printf 'ZERO_INCREMENT_CONTROL_EXIT=%s PROTOCOL=%s\n' "$rc" "$proto"
    done
    docker pause "$prefix-witness" || return $?
    for proto in +notcp +tcp; do
        rc=0; docker exec "$prefix-client" dig +time=1 +tries=1 "$proto" @172.30.244.53 stopped.invalid A || rc=$?
        [[ $rc != 0 ]] || return 1
        printf 'STOPPED_WITNESS_EXIT=%s PROTOCOL=%s\n' "$rc" "$proto"
    done
    docker unpause "$prefix-witness" || return $?
    for proto in +notcp +tcp; do
        result=$(docker exec "$prefix-client" dig +time=1 +tries=1 "$proto" @172.30.244.53 restored.invalid A) || return $?
        [[ $result == *'status: NXDOMAIN'* ]] || return 1
    done
    network_control close || return $?
    network_control snapshot || return $?
    DNS_BASELINE=$(network_witness "$CONTROL_SEQ") || return $?
    DNS_CALIBRATED=1
}
# 独立命名卷生成短期 CA 与 TLS 端点，产品只挂载 CA 不接触私钥。
network_tls() {
    local prefix=gm-$IT_RUN_ID volume
    for volume in tls ca data; do docker volume create --label "gitdaemon.run=$IT_RUN_ID" "$prefix-$volume"; done
    network_run --rm --network none -v "$prefix-tls:/var/lib/git-daemon" -v "$prefix-ca:/ca" --entrypoint sh "$IT_PRODUCT_IMAGE" -c '
set -e
cd /var/lib/git-daemon
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=R2-CA -keyout ca.key -out ca.crt
openssl req -newkey rsa:2048 -nodes -subj /CN=github.com -keyout server.key -out server.csr
printf "subjectAltName=DNS:github.com\n" > san.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile san.ext -out server.crt
printf "r2-tls-ok\n" > index.html
'
    # CA 卷首次挂载在镜像既有 UID10001 目录继承属主。
    network_run --rm --network none -v "$prefix-tls:/upstream:ro" -v "$prefix-ca:/var/lib/git-daemon" --entrypoint sh "$IT_PRODUCT_IMAGE" -c 'cp /upstream/ca.crt /var/lib/git-daemon/ca.pem'
    network_run -d --name "$prefix-tls" --network "$IT_NETWORK" --network-alias github.com "${NETSAFE[@]}" --dns "$IT_DNS_IP" -v "$prefix-tls:/var/lib/git-daemon:ro" --entrypoint sh "$IT_PRODUCT_IMAGE" -c 'cd /var/lib/git-daemon; exec openssl s_server -quiet -accept 443 -cert server.crt -key server.key -WWW'
    network_run -d --name "$prefix-product" --network "$IT_NETWORK" --ip 172.30.243.4 "${NETSAFE[@]}" --dns "$IT_DNS_IP" -p 127.0.0.1:49383:19419 -v "$prefix-data:/var/lib/git-daemon" -v "$prefix-ca:/ca:ro" --entrypoint sh "$IT_PRODUCT_IMAGE" -c 'exec busybox nc -lk -p 19419 -e /bin/cat'
}
# 发布端口管线立即保存各成员状态，回显成功不能覆盖 timeout 失败。
network_published_check() {
    local result status rc=0
    local -a statuses
    if printf 'r2-published\n' | timeout 3 nc -w 1 127.0.0.1 49383 > "$IT_EVIDENCE_DIR/control/published.txt"; then
        statuses=("${PIPESTATUS[@]}")
    else
        statuses=("${PIPESTATUS[@]}")
    fi
    printf 'PUBLISHED_PIPESTATUS=%s\n' "${statuses[*]}" >> "$IT_EVIDENCE_DIR/control/pipeline-status.txt"
    for status in "${statuses[@]}"; do if (( status != 0 )); then rc=$status; fi; done
    (( rc == 0 )) || return "$rc"
    result=$(cat "$IT_EVIDENCE_DIR/control/published.txt") || return $?
    [[ $result == r2-published ]]
}
# 探针仅验证网络能力，不冒称 O1/full 生命周期已接入。
network_probe() {
    local prefix=gm-$IT_RUN_ID id tool query rc=0
    network_fixture_start
    network_tls
    id=$(docker inspect -f '{{.Id}}' "$prefix-product")
    assert_container_network_policy "$id"
    docker exec "$id" curl --noproxy '*' --cacert /ca/ca.pem --connect-timeout 2 --max-time 5 https://github.com/index.html
    rc=0
    docker exec "$id" curl --noproxy '*' --connect-timeout 2 --max-time 5 https://github.com/index.html || rc=$?
    [[ $rc == 60 ]] || return 1
    printf 'TLS_UNTRUSTED_CONTROL_EXIT=%s\n' "$rc"
    network_published_check || return $?
    printf 'HOST_PUBLISHED_PASS=1\n'
    docker network connect "$IT_WITNESS_NETWORK" "$id"
    rc=0; assert_container_network_policy "$id" || rc=$?
    docker network disconnect "$IT_WITNESS_NETWORK" "$id"
    [[ $rc != 0 ]] || return 1
    printf 'SECONDARY_NETWORK_REJECTED_EXIT=%s\n' "$rc"
    query="$IT_RUN_ID-$RANDOM.invalid"
    docker exec "$id" busybox nslookup "$query" 127.0.0.11 || rc=$?
    docker logs "$prefix-dns" > "$IT_EVIDENCE_DIR/control/dns-query.log" 2>&1 || return $?
    grep -F "$query" "$IT_EVIDENCE_DIR/control/dns-query.log" || return $?
    assert_product_egress "$id" probe
    assert_dns_witness probe
    printf 'NETWORK_PROBE_PASS=1 O1_FULL_NOT_INTEGRATED=1\n'
}
