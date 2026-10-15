#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-integration-startup.sh"
IT_RUN_ID=helper IT_NETWORK=gm-helper-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
IT_EVIDENCE_DIR=$scratch
mkdir -p "$scratch/control"

# 仅替换 Docker 外部命令，真实包装器必须检查并归档后才删除客户端。
command() {
    [[ $1 == docker ]] || { builtin command "$@"; return $?; }
    shift
    printf '%s\n' "$*" >> "$scratch/calls"
    case "$1" in
        create|run) printf 'helper-id\n' ;;
        inspect)
            case "$*" in
                *'.NetworkMode'*) printf '%s\n' "${NETMODE:-gm-helper-net}" ;;
                *'.NetworkID'*) printf 'netid-1\n' ;;
                *'.IPAddress'*) printf '%s\n' "${NETIP:-140.82.112.10}" ;;
                *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]\n' ;;
                *'gitdaemon.role'*) printf 'helper\thelper\thelper\n' ;;
                *'gitdaemon.run'*) printf 'helper\n' ;;
                *'.Id'*) printf 'helper-id\n' ;;
                *'.NetworkSettings.Networks'*) printf '%s\n' "${NETWORKS:-gm-helper-net }" ;;
                *'.HostConfig.Dns'*) printf '[172.30.243.53]\n' ;;
                *'.Sysctls'*) printf '1\n' ;;
                *'.ExtraHosts'*) printf '[] []\n' ;;
                *'.Mounts'*) printf 'volume gm-helper-ca\n' ;;
                *) printf '{}\n' ;;
            esac ;;
        network) printf 'false\n' ;;
        logs) printf 'HELPER_UID=10001:10001\n' ;;
        start) return 0 ;;
    esac
    return 0
}
docker run --rm --network "$IT_NETWORK" --entrypoint git image ls-remote https://github.com/acme/demo
grep -q '^inspect ' "$scratch/calls"
grep -q '^logs ' "$scratch/calls"
[[ -n $(find "$scratch/control" -name inspect.json -print) ]]
: > "$scratch/calls"
docker run --rm --network none --entrypoint sh image -c true
grep -q '^inspect ' "$scratch/calls"
grep -q '^logs ' "$scratch/calls"

# 映射角色：共享 netns 只允许匹配本轮登记产品的单一映射网络附件。
PROFILE=$scratch/mapping-profile.tsv
printf 'schema_version\t1\n' > "$PROFILE"
printf 'run_id\thelper\n' >> "$PROFILE"
printf 'cidr\t140.82.112.0/24\n' >> "$PROFILE"
printf 'gateway\t140.82.112.1\n' >> "$PROFILE"
printf 'P\t140.82.112.10\n' >> "$PROFILE"
printf 'U\t140.82.112.11\n' >> "$PROFILE"
printf 'X\t140.82.112.12\n' >> "$PROFILE"
printf 'D\t140.82.112.13\n' >> "$PROFILE"
printf 'N\t140.82.112.14\n' >> "$PROFILE"
printf 'network_name\tgm-helper-m-net\n' >> "$PROFILE"
printf 'bridge\tmhelper\n' >> "$PROFILE"
IT_MAPPING=1 IT_MAPPING_PROFILE=$PROFILE IT_NETWORK=gm-helper-m-net
NETMODE='container:product-id' NETWORKS='gm-helper-m-net ' NETIP='140.82.112.10'
failed=0
: > "$scratch/calls"
rc=0
docker run --rm --network container:product-id --entrypoint sh image -c true || rc=$?
printf 'HELPER_MAPPING_VALID=%s\n' "$rc"
[[ $rc == 0 ]] || failed=1
grep -q '^inspect ' "$scratch/calls" || failed=1
# 额外附件必须让共享 netns 策略失败并保留策略退出码。
NETWORKS='gm-helper-m-net other '
rc=0
docker run --rm --network container:product-id --entrypoint sh image -c true >/dev/null 2>&1 || rc=$?
printf 'HELPER_MAPPING_EXTRA=%s\n' "$rc"
[[ $rc == 2 ]] || failed=1
exit "$failed"
