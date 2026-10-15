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
                *'.NetworkMode'*) printf 'gm-helper-net\n' ;;
                *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]\n' ;;
                *'.Config.Labels'*) printf 'helper\n' ;;
                *'.Id'*) printf 'helper-id\n' ;;
                *'.NetworkSettings.Networks'*) printf 'gm-helper-net \n' ;;
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
