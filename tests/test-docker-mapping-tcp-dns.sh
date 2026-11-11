#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-resource-ledger.sh"
source "$HERE/docker-mapping-fixture.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PRODUCT=$(printf 'a%.0s' {1..64})
TOOL=$(printf 'b%.0s' {1..64})

# 运行真实探测函数，仅替换 Docker、登记账本与冻结输入的外部事实。
check_probe() (
    local mode=$1 expected=$2 rc=0
    MP_RUN_ID=mtest MPF_RUN_ID=mtest MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=sha256:tools
    RESOURCE_LEDGER_ACTIVE=(["container|$PRODUCT"]='|mapping-fallback|product|')
    MP_NETWORK_NAME=gm-mtest-m-net
    mapping_fixture_state_load() { return 0; }
    resource_ledger_dir() { printf '%s\n' "$WORK"; }
    resource_crosscheck() { RESOURCE_LEDGER_ACTIVE["container|$TOOL"]='|mapping-fallback|tcp-dns|'; }
    resource_verify_object() { [[ $1 == container && $3 == mapping-fallback ]] && { [[ $2 == "$TOOL" && $4 == tcp-dns ]] || [[ $2 == "$PRODUCT" && $4 == product ]]; }; }
    resource_remove() { printf 'remove %s %s\n' "$1" "$2" >> "$WORK/docker"; }
    mapping_fixture_run() {
        printf '%s\n' "$*" >> "$WORK/create"
        printf '%s\n' "$TOOL"
    }
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$WORK/docker"
        case "$*" in
            *'inspect -f {{.Id}} gm-mtest-product') printf '%s\n' "$PRODUCT" ;;
            *'inspect'*"$PRODUCT") printf 'gm-mtest-m-net|true\n' ;;
            *'inspect'*"$TOOL")
                if [[ $mode == identity ]]; then printf 'other-network|10001:10001|true|sha256:tools\n';
                else printf 'container:%s|10001:10001|true|sha256:tools\n' "$PRODUCT"; fi ;;
            *'dig +time=1 +tries=1 +tcp'*)
                case "$mode" in
                    ok) printf ';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached\n'; return 9 ;;
                    exec) printf 'dig: command not found\n' >&2; return 127 ;;
                    malformed) printf 'unexpected\n'; return 9 ;;
                    response) printf ';; ->>HEADER<<- status: NOERROR\n'; return 0 ;;
                esac ;;
        esac
    }
    mapping_witness_spec() { printf 'tcp\t53\t172.30.244.53\n'; }
    MAPPING_WITNESS_KEYS=dns-tcp
    mapping_probe_egress gm-mtest-product gen1 || rc=$?
    [[ $rc == "$expected" ]] || return 1
    if [[ $mode != identity ]]; then
        [[ $(cat "$WORK/create") == *"--network container:$PRODUCT"* ]] || return 1
        [[ $(cat "$WORK/create") != *'--sysctl'* ]] || return 1
        [[ $(cat "$WORK/docker") == *"exec $TOOL dig +time=1 +tries=1 +tcp @172.30.244.53 mtest-gen1.invalid A"* ]] || return 1
        [[ $(cat "$WORK/docker") == *"remove container $TOOL"* ]] || return 1
    fi
    [[ $(cat "$WORK/create" 2>/dev/null) != *'--network gm-mtest-w-net'* ]]
)

failed=0
for spec in 'ok 0' 'exec 80' 'identity 80' 'malformed 80' 'response 1'; do
    : > "$WORK/create"; : > "$WORK/docker"
    if check_probe $spec; then printf '%s PASS\n' "$spec"; else printf '%s FAIL\n' "$spec"; failed=1; fi
done
exit "$failed"
