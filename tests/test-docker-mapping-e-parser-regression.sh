#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

profile_write() {
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$WORK/profile"
}

snapshot_write() {
    local file=$1 target=$2 value=$3 key spec proto port dest count
    : > "$file"
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key")
        IFS=$'\t' read -r proto port dest <<< "$spec"
        count=0
        [[ $key != "$target" ]] || count=$value
        printf '[%s:0] -A MEmtest -i mmtest -s 140.82.112.10/32 -d %s/32 -p %s --dport %s -m comment --comment "mtest-%s" -j DROP\n' "$count" "$dest" "$proto" "$port" "$key" >> "$file"
    done
}

witness_write() {
    local file=$1 target=$2 value=$3 port count
    : > "$file"
    for port in 19419 19420 udp tcp; do
        count=0
        [[ $port != "$target" ]] || count=$value
        case "$port" in
            udp|tcp) printf '%s 0 RETURN %s -- * * 0.0.0.0/0 0.0.0.0/0 %s dpt:53\n' "$count" "$port" "$port" >> "$file" ;;
            *) printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:%s\n' "$count" "$port" >> "$file" ;;
        esac
    done
}

isolation_case() (
    local mode=$1 target=$2 expected=$3 count=0 rc=0
    mkdir -p "$WORK/$mode/control"
    IT_CONTROL_DIR=$WORK/$mode/control MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1
    MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=netid-abc MAPPING_ASSERT_TARGET=cross-network
    mapping_control_request() {
        count=$((count + 1))
        CONTROL_SEQ=$count
        snapshot_write "$WORK/$mode/mapping-snapshot-$count.rules" "$target" "$((count - 1))"
        witness_write "$WORK/$mode/mapping-snapshot-$count.witness" "$target" "$((count - 1))"
    }
    mapping_probe_egress() { [[ $3 == cross-network ]]; }
    mapping_isolation_check product gen1 "$WORK/profile" || rc=$?
    [[ $rc == "$expected" && $count == 2 ]]
)

dns_tcp_mixed_error() (
    local rc=0
    MP_RUN_ID=mtest MP_NETWORK_NAME=gm-mtest-m-net MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=tools
    mapping_fixture_state_load() { return 0; }
    resource_ledger_dir() { printf '%s\n' "$WORK"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { return 0; }
    mapping_fixture_create() { printf '%064d\n' 2; }
    resource_remove() { return 0; }
    mapping_fixture_docker() {
        case "$1" in
            inspect)
                if [[ $* == *'{{.Id}}'* ]]; then printf '%064d\n' 1
                elif [[ $* == *'{{.HostConfig.NetworkMode}}|{{.State.Running}}'* ]]; then printf 'gm-mtest-m-net|true\n'
                else printf 'container:%064d|10001:10001|true|tools|true|["ALL"]|["no-new-privileges"]\n' 1; fi ;;
            start) return 0 ;;
            exec)
                printf ';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached\n;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 10\n'
                return 9 ;;
        esac
    }
    mapping_probe_egress product gen1 dns-tcp >/dev/null || rc=$?
    [[ $rc == 80 ]]
)

profile_write
failed=0
for row in 'healthy cross-network 0' 'shared-other host-published 1' 'receiver-cross 19419 1' 'receiver-input 19420 1' 'receiver-udp udp 1' 'receiver-tcp tcp 1'; do
    read -r mode target expected <<< "$row"
    isolation_case "$mode" "$target" "$expected" || { printf 'FAIL %s\n' "$mode"; failed=1; }
done
dns_tcp_mixed_error || { printf 'FAIL dns-tcp-mixed-error\n'; failed=1; }
exit "$failed"
