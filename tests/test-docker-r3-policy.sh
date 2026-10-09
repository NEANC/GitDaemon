#!/usr/bin/env bash
# R3 策略前置契约：使用真实策略函数，仅替换 Docker 边界。
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-fixture.sh"

# 模拟单一已授权普通网络与完整的非 root 容器安全属性。
docker() {
    case "$*" in
        *'.Config.Env'*) printf 'GIT_SSL_CAINFO=/ca/ca.crt\n' ;;
        *'.NetworkSettings.Networks'*) printf '%s ' "$ATTACHMENTS" ;;
        *'.HostConfig.Dns'*) printf '[172.30.243.53]' ;;
        *'.Config.User'*) printf '10001:10001 true false [ALL] [%s]' "$SECURITY_OPT" ;;
        *'.EnableIPv6'*) printf 'false' ;;
        *'.Internal'*) printf 'false' ;;
        *'.HostConfig.Sysctls'*) printf '1' ;;
        *'.HostConfig.ExtraHosts'*) printf '[] []' ;;
        *'.Destination'*) printf 'gm-contract-ca false' ;;
        *'.Mounts'*) printf 'volume gm-contract-data\nvolume gm-contract-ca\n' ;;
        *'id -ru'*) printf '10001 10001' ;;
        exec*) printf 'nameserver 127.0.0.11\n' ;;
        *) return 99 ;;
    esac
}

# 分别核验正向授权、第二附件以及缺失前置，不把期望失败冒充进程异常。
policy_contract() {
    local scenario=$1 expected=$2 actual=0
    local IT_RUN_ID=contract IT_NETWORK=authorized IT_DNS_IP=172.30.243.53
    local IT_NETWORK_GUARD_READY=1 ATTACHMENTS=authorized SECURITY_OPT=no-new-privileges
    case "$scenario" in
        compose-security) SECURITY_OPT=no-new-privileges:true ;;
        disabled-security) SECURITY_OPT=no-new-privileges:false ;;
        secondary) ATTACHMENTS='authorized other' ;;
        missing-guard) unset IT_NETWORK_GUARD_READY ;;
        failed-guard) IT_NETWORK_GUARD_READY=0 ;;
        missing-dns) unset IT_DNS_IP ;;
    esac
    assert_container_network_policy product >/dev/null || actual=$?
    printf '%s EXPECT=%s ACTUAL=%s\n' "$scenario" "$expected" "$actual"
    [[ $actual == "$expected" ]]
}

failed=0
for scenario in authorized compose-security disabled-security secondary missing-guard failed-guard missing-dns; do
    expected=77
    case "$scenario" in authorized|compose-security) expected=0 ;; secondary|disabled-security) expected=1 ;; esac
    ( policy_contract "$scenario" "$expected" ) || failed=1
done
exit "$failed"
