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

# 映射角色使用冻结档案与单一网络 ID 判定；额外附件、错误地址与未知网络 ID 均拒绝。
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
PROFILE=$scratch/mapping-profile.tsv
printf 'schema_version\t1\n' > "$PROFILE"
printf 'run_id\tcontract\n' >> "$PROFILE"
printf 'cidr\t140.82.112.0/24\n' >> "$PROFILE"
printf 'gateway\t140.82.112.1\n' >> "$PROFILE"
printf 'P\t140.82.112.10\n' >> "$PROFILE"
printf 'U\t140.82.112.11\n' >> "$PROFILE"
printf 'X\t140.82.112.12\n' >> "$PROFILE"
printf 'D\t140.82.112.13\n' >> "$PROFILE"
printf 'N\t140.82.112.14\n' >> "$PROFILE"
printf 'network_name\tgm-contract-m-net\n' >> "$PROFILE"
printf 'bridge\tmcontract\n' >> "$PROFILE"

mapping_policy_contract() {
    local scenario=$1 expected=$2 actual=0
    local IT_RUN_ID=contract IT_MAPPING=1 IT_MAPPING_PROFILE=$PROFILE
    local ATT='gm-contract-m-net' IP=140.82.112.10
    case "$scenario" in
        secondary) ATT='gm-contract-m-net other' ;;
        wrong-ip) IP=140.82.112.99 ;;
    esac
    docker() {
        case "$*" in
            *'.NetworkID'*) printf 'netid-1 ' ;;
            *'.IPAddress'*) printf '%s ' "$IP" ;;
            *'.NetworkSettings.Networks'*) printf '%s ' "$ATT" ;;
            *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]' ;;
            *'.HostConfig.ExtraHosts'*) printf '[] []' ;;
            *'.EnableIPv6'*) printf 'false' ;;
            *) return 99 ;;
        esac
        return 0
    }
    case "$scenario" in
        foreign-id) MP_NETWORK_ID=other-netid ;;
        *) MP_NETWORK_ID=netid-1 ;;
    esac
    mapping_policy_check product-id product "$PROFILE" >/dev/null || actual=$?
    printf 'mapping-%s EXPECT=%s ACTUAL=%s\n' "$scenario" "$expected" "$actual"
    [[ $actual == "$expected" ]]
}
for scenario in valid secondary wrong-ip foreign-id; do
    expected=0
    case "$scenario" in secondary|wrong-ip|foreign-id) expected=1 ;; esac
    ( mapping_policy_contract "$scenario" "$expected" ) || failed=1
done
exit "$failed"
