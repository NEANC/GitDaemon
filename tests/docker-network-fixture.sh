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
}
# 停止仅属于本轮的资源；异常外层还会以清单兜底。
network_fixture_stop() {
    local id ids status=0
    ids=$(docker ps -aq --filter "label=gitdaemon.run=$IT_RUN_ID") || return $?
    for id in $ids; do docker stop -t 1 "$id" || status=1; done
    return "$status"
}
# 从外层原始快照读取限定源目的规则的单条计数。
network_count() {
    awk -v tag="$IT_RUN_ID-$2" 'index($0,"--comment " tag " ") && /-j DROP/ {split($1,a,":");gsub(/\[/,"",a[1]);print a[1];n++} END{if(n!=1)exit 1}' "$IT_EVIDENCE_DIR/snapshot-$1.rules"
}
# 接收端协议向量独立于宿主 DROP 计数。
network_witness() {
    awk '$3=="RETURN" {print $1}' "$IT_EVIDENCE_DIR/snapshot-$1.witness"
}
# 每次请求比较目标 DROP 增量和接收端零增量，保留原始退出状态。
network_negative() {
    local label=$1 before after rc=0 key; shift
    network_control snapshot || return $?; before=$CONTROL_SEQ
    "$@" || rc=$?
    network_control snapshot || return $?; after=$CONTROL_SEQ
    printf 'NEGATIVE=%s EXIT=%s BEFORE=%s AFTER=%s\n' "$label" "$rc" "$before" "$after"
    [[ $rc != 0 && $(network_count "$after" "$label") -gt $(network_count "$before" "$label") && $(network_witness "$before") == "$(network_witness "$after")" ]] || return 1
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        if [[ $key != "$label" ]]; then [[ $(network_count "$before" "$key") == "$(network_count "$after" "$key")" ]] || return 1; fi
    done
}
# 产品内 curl 逐个验证三个受控目的；不向真实公网发送探测。
assert_product_egress() {
    local id=$1 generation=$2 spec label address
    printf 'PRODUCT_GENERATION=%s ID=%s\n' "$generation" "$id"
    assert_container_network_policy "$id" || return $?
    for spec in 'cross-network 172.30.244.53:19419' 'host-published 172.30.243.1:49382' 'host-input 172.30.243.1:49383'; do
        read -r label address <<< "$spec"
        network_negative "$label" docker exec "$id" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$address/" || return $?
    done
}
# 校准两协议见证，包括健康负对照；结束撤销通路，产品尚未启动。
assert_dns_witness() {
    local generation=$1 proto before after result rc=0 prefix=gm-$IT_RUN_ID
    for proto in +notcp +tcp; do
        network_control snapshot || return $?; before=$CONTROL_SEQ
        result=$(docker exec "$prefix-client" dig +time=1 +tries=1 "$proto" @172.30.244.53 "$IT_RUN_ID-$generation-positive.invalid" A) || return $?
        network_control snapshot || return $?; after=$CONTROL_SEQ
        printf '%s\n' "$result"
        [[ $result == *'status: NXDOMAIN'* && $(network_witness "$before") != "$(network_witness "$after")" ]] || return 1
        rc=0; [[ $(network_witness "$before") == "$(network_witness "$after")" ]] || rc=$?
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
    network_control close
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
# 探针仅验证网络能力，不冒称 O1/full 生命周期已接入。
network_probe() {
    local prefix=gm-$IT_RUN_ID id tool query rc=0
    network_fixture_start
    assert_dns_witness probe
    network_tls
    id=$(docker inspect -f '{{.Id}}' "$prefix-product")
    assert_container_network_policy "$id"
    docker exec "$id" curl --noproxy '*' --cacert /ca/ca.pem --connect-timeout 2 --max-time 5 https://github.com/index.html
    rc=0
    docker exec "$id" curl --noproxy '*' --connect-timeout 2 --max-time 5 https://github.com/index.html || rc=$?
    [[ $rc == 60 ]] || return 1
    printf 'TLS_UNTRUSTED_CONTROL_EXIT=%s\n' "$rc"
    result=$(printf 'r2-published\n' | timeout 3 nc -w 1 127.0.0.1 49383)
    [[ $result == r2-published ]] || return 1
    printf 'HOST_PUBLISHED_PASS=1\n'
    docker network connect "$IT_WITNESS_NETWORK" "$id"
    rc=0; assert_container_network_policy "$id" || rc=$?
    docker network disconnect "$IT_WITNESS_NETWORK" "$id"
    [[ $rc != 0 ]] || return 1
    printf 'SECONDARY_NETWORK_REJECTED_EXIT=%s\n' "$rc"
    query="$IT_RUN_ID-$RANDOM.invalid"
    docker exec "$id" busybox nslookup "$query" 127.0.0.11 || rc=$?
    docker logs "$prefix-dns" 2>&1 | grep -F "$query"
    assert_product_egress "$id" probe
    network_negative dns-udp docker exec "$id" timeout 4 busybox nslookup "$IT_RUN_ID-product.invalid" 172.30.244.53
    network_run -d --name "$prefix-tcp" --network "container:$id" "$IT_TOOLS_IMAGE" sleep 120
    tool=$(docker inspect -f '{{.Id}}' "$prefix-tcp")
    docker inspect "$tool"
    [[ $(docker inspect -f '{{.HostConfig.NetworkMode}} {{.Config.User}}' "$tool") == "container:$id 10001:10001" ]]
    [[ $(docker exec "$tool" sh -c 'printf "%s %s" "$(id -ru)" "$(id -u)"') == '10001 10001' ]]
    printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$id"
    network_negative dns-tcp docker exec "$tool" dig +time=1 +tries=1 +tcp @172.30.244.53 "$IT_RUN_ID-tool.invalid" A
    printf 'NETWORK_PROBE_PASS=1 O1_FULL_NOT_INTEGRATED=1\n'
}
