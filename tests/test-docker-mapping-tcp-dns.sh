#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-resource-ledger.sh"
source "$HERE/docker-mapping-fixture.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PRODUCT=$(printf 'a%.0s' {1..64})
TOOL=$(printf 'b%.0s' {1..64})

# 运行真实账本、创建与清理逻辑，仅替换 Docker 边界。
check_probe() (
    local mode=$1 expected=$2 rc=0 id format
    MP_RUN_ID=mtest MPF_RUN_ID=mtest MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=sha256:tools
    RESOURCE_LEDGER_DIR=$WORK/ledger RESOURCE_RUN=mtest
    mkdir -p "$RESOURCE_LEDGER_DIR"
    MP_NETWORK_NAME=gm-mtest-m-net
    mapping_fixture_state_load() { return 0; }
    resource_docker() {
        printf '%s\n' "$*" >> "$WORK/docker"
        case "$1" in
            create)
                printf '%s\n' "$*" >> "$WORK/create"
                if [[ $mode == create-fail ]]; then return 1; fi
                printf '%s\n' "$TOOL" ;;
            start) if [[ $mode == drift ]]; then : > "$WORK/started"; fi; [[ $mode != start-fail ]] ;;
            rm) printf '%s\n' "$3" > "$WORK/removed" ;;
            ps) printf '%s\n' "$PRODUCT"; if [[ -s $WORK/create && $mode != create-fail && $mode != uncertain && ! -f $WORK/removed ]]; then printf '%s\n' "$TOOL"; fi ;;
            network|volume) [[ $2 == ls ]] ;;
            inspect)
                id=${@: -1}
                [[ $id == gm-mtest-product ]] && id=$PRODUCT
                [[ $id != "$TOOL" || ! -f $WORK/removed ]] || return 1
                format=${3:-}
                if [[ $format == *'gitdaemon.run'* ]]; then
                    if [[ $id == "$TOOL" && ( $mode == uncertain || ( $mode == drift && -f $WORK/started ) ) ]]; then printf 'foreign\tmapping-fallback\ttcp-dns\n';
                    elif [[ $id == "$TOOL" ]]; then printf 'mtest\tmapping-fallback\ttcp-dns\n';
                    else printf 'mtest\tmapping-fallback\tproduct\n'; fi
                elif [[ $format == '{{.Id}}' ]]; then printf '%s\n' "$id"
                elif [[ $format == *'HostConfig.NetworkMode'* && $id == "$PRODUCT" ]]; then printf '%s|true\n' "$MP_NETWORK_NAME"
                elif [[ $format == *'HostConfig.NetworkMode'* ]]; then
                    if [[ $mode == identity ]]; then printf 'other-network|10001:10001|true|sha256:tools|true|["ALL"]|["no-new-privileges"]\n';
                    elif [[ $mode == unsafe ]]; then printf 'container:%s|10001:10001|true|sha256:tools|false|["ALL"]|["no-new-privileges"]\n' "$PRODUCT";
                    elif [[ $mode == caps ]]; then printf 'container:%s|10001:10001|true|sha256:tools|true|[]|["no-new-privileges"]\n' "$PRODUCT";
                    elif [[ $mode == privilege ]]; then printf 'container:%s|10001:10001|true|sha256:tools|true|["ALL"]|[]\n' "$PRODUCT";
                    elif [[ $mode == uid ]]; then printf 'container:%s|0:0|true|sha256:tools|true|["ALL"]|["no-new-privileges"]\n' "$PRODUCT";
                    else printf 'container:%s|10001:10001|true|sha256:tools|true|["ALL"]|["no-new-privileges"]\n' "$PRODUCT"; fi
                else printf '{"Id":"%s"}\n' "$id"; fi ;;
            exec)
                case "$mode" in
                    ok|wrong-timeout) printf ';; communications error to %s#53: timed out\n;; no servers could be reached\n' "$([[ $mode == ok ]] && printf 172.30.244.53 || printf 1.2.3.4)"; return 9 ;;
                    exec) printf 'dig: command not found\n' >&2; return 127 ;;
                    malformed) printf 'unexpected\n'; return 9 ;;
                    response|wrong-server|bare-response|bad-rcode|dig-error)
                        [[ $mode == bare-response ]] || printf ';; SERVER: %s#53(172.30.244.53)\n' "$([[ $mode == wrong-server ]] && printf 1.2.3.4 || printf 172.30.244.53)"
                        printf ';; ->>HEADER<<- opcode: QUERY, status: %s, id: 123\n' "$([[ $mode == bad-rcode ]] && printf GARBAGE || printf NXDOMAIN)"
                        [[ $mode != dig-error ]] ;;
                esac ;;
        esac
    }
    mapping_fixture_docker() { resource_docker "$@"; }
    resource_register container "$PRODUCT" mapping-fallback product || return 1
    mapping_witness_spec() { printf 'tcp\t53\t172.30.244.53\n'; }
    MAPPING_WITNESS_KEYS=dns-tcp
    mapping_probe_egress gm-mtest-product gen1 2> "$WORK/notice" || rc=$?
    [[ $rc == "$expected" ]] || { printf '%s actual=%s expected=%s\n' "$mode" "$rc" "$expected"; return 1; }
    if [[ $mode != create-fail ]]; then
        [[ $(cat "$WORK/create") == *"--network container:$PRODUCT"* ]] || return 1
        [[ $(cat "$WORK/create") != *'--sysctl'* ]] || return 1
    fi
    if [[ $mode == uncertain || $mode == create-fail || $mode == drift ]]; then
        [[ ! -f $WORK/removed ]] || return 1
        [[ -s $WORK/notice ]] || return 1
        if [[ $mode == drift ]]; then
            resource_ledger_load "$RESOURCE_LEDGER_DIR"
            [[ -n ${RESOURCE_LEDGER_ACTIVE["container|$TOOL"]:-} ]] || return 1
        fi
    else
        [[ $(cat "$WORK/removed" 2>/dev/null) == "$TOOL" ]] || return 1
        resource_ledger_load "$RESOURCE_LEDGER_DIR"
        [[ ${RESOURCE_LEDGER_REMOVED["container|$TOOL"]:-} == 1 ]] || return 1
    fi
    [[ $(cat "$WORK/create" 2>/dev/null) != *'--network gm-mtest-w-net'* ]]
)

failed=0
for spec in 'ok 0' 'exec 80' 'identity 80' 'unsafe 80' 'caps 80' 'privilege 80' 'uid 80' 'malformed 80' 'response 1' 'bare-response 80' 'wrong-server 80' 'bad-rcode 80' 'dig-error 80' 'wrong-timeout 80' 'start-fail 80' 'create-fail 80' 'uncertain 80' 'drift 80'; do
    rm -rf "$WORK/ledger" "$WORK/removed" "$WORK/notice" "$WORK/started"
    : > "$WORK/create"; : > "$WORK/docker"
    if check_probe $spec; then printf '%s PASS\n' "$spec"; else printf '%s FAIL\n' "$spec"; failed=1; fi
done
exit "$failed"
