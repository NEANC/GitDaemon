#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_tcp_dns_raw() (
    local mode=$1 expected=$2 rc=0 removals=0 file=$WORK/$1 fixture_tool fixture_product
    fixture_tool=$(printf '%064d' 2)
    fixture_product=$(printf '%064d' 1)
    mkdir -p "$file/probe"
    MP_RUN_ID=mtest MP_NETWORK_NAME=gm-mtest-m-net MP_NETWORK_ID=net-one MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=tools CONTROL_SEQ=4
    mapping_fixture_state_load() { return 0; }
    resource_ledger_dir() { printf '%s\n' "$WORK"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { return 0; }
    mapping_fixture_create() { printf '%s\n' "$fixture_tool"; }
    resource_remove() { [[ $1 == container && $2 == "$fixture_tool" ]] || return 80; removals=$((removals + 1)); }
    mapping_fixture_docker() {
        local rendered=$*
        case "$1" in
            inspect)
                if [[ $rendered == *'{{.Id}}'* ]]; then printf '%s\n' "$fixture_product"
                elif [[ $rendered == *'{{.HostConfig.NetworkMode}}|{{.State.Running}}'* ]]; then printf 'gm-mtest-m-net|true\n'
                else printf 'container:%s|10001:10001|true|tools|true|["ALL"]|["no-new-privileges"]\n' "$fixture_product"; fi ;;
            start) return 0 ;;
            exec)
                [[ $2 == "$fixture_tool" ]] || return 80
                if [[ $mode == timeout ]]; then
                    printf ';; communications error to 172.30.244.53#53: timed out\0\n;; no servers could be reached\n\n'
                    return 9
                fi
                printf 'Error response from daemon: no servers could be reached\0\n\n'
                return 23 ;;
        esac
    }
    mapping_probe_egress product g1 dns-tcp "$file" > "$file/probe.log" || rc=$?
    [[ $rc == "$expected" && $removals == 1 ]] || return 1
    if [[ $mode == timeout ]]; then
        printf ';; communications error to 172.30.244.53#53: timed out\0\n;; no servers could be reached\n\n' > "$WORK/expected"
        [[ $(cat "$file/probe/raw.exit") == 9 ]] || return 1
    else
        printf 'Error response from daemon: no servers could be reached\0\n\n' > "$WORK/expected"
        [[ $(cat "$file/probe/raw.exit") == 23 ]] || return 1
    fi
    cmp -s "$WORK/expected" "$file/probe/raw.log" || return 1
    tail -n +2 "$file/probe.log" | cmp -s - "$file/probe/raw.log" || return 1
    [[ $(awk -F '\t' '$1 == "exit" {print $2}' "$file/probe/command.tsv") == "$(cat "$file/probe/raw.exit")" ]] || return 1
    [[ $(awk -F '\t' '$1 == "raw_sha256" {print $2}' "$file/probe/command.tsv") == "$(sha256sum "$file/probe/raw.log" | cut -d' ' -f1)" ]]
)

failed=0
for row in 'timeout 0' 'docker-error 80'; do
    read -r mode expected <<< "$row"
    rc=0; check_tcp_dns_raw "$mode" "$expected" || rc=$?
    printf 'tcp-dns %s EXIT=%s\n' "$mode" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
