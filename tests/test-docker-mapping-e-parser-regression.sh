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
    local file=$1 target=$2 value=$3 other=${4:-} other_value=${5:-0} key spec proto port dest count
    : > "$file"
    for key in $MAPPING_WITNESS_KEYS; do
        spec=$(mapping_witness_spec "$key")
        IFS=$'\t' read -r proto port dest <<< "$spec"
        count=0
        [[ $key != "$target" ]] || count=$value
        [[ $key != "$other" ]] || count=$other_value
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

receiver_growth_case() (
    local key=$1 receiver=$2 count=0 rc=0
    mkdir -p "$WORK/receiver-$key/control"
    IT_CONTROL_DIR=$WORK/receiver-$key/control MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1
    MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=netid-abc MAPPING_ASSERT_TARGET=$key
    mapping_control_request() {
        count=$((count + 1))
        CONTROL_SEQ=$count
        snapshot_write "$WORK/receiver-$key/mapping-snapshot-$count.rules" "$key" "$((count - 1))"
        witness_write "$WORK/receiver-$key/mapping-snapshot-$count.witness" "$receiver" "$((count - 1))"
    }
    mapping_probe_egress() { [[ $3 == "$key" ]]; }
    mapping_isolation_check product gen1 "$WORK/profile" || rc=$?
    [[ $rc == 1 && $count == 2 ]]
)

shared_target_case() (
    local count=0 rc=0 before after
    mkdir -p "$WORK/shared-target/control"
    IT_CONTROL_DIR=$WORK/shared-target/control MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1
    MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=netid-abc MAPPING_ASSERT_TARGET=cross-network
    mapping_control_request() {
        count=$((count + 1))
        CONTROL_SEQ=$count
        snapshot_write "$WORK/shared-target/mapping-snapshot-$count.rules" cross-network "$((count - 1))" host-published "$((count - 1))"
        witness_write "$WORK/shared-target/mapping-snapshot-$count.witness" none 0
    }
    mapping_probe_egress() { [[ $3 == cross-network ]]; }
    mapping_isolation_check product gen1 "$WORK/profile" || rc=$?
    before=$WORK/shared-target/mapping-snapshot-1.rules
    after=$WORK/shared-target/mapping-snapshot-2.rules
    [[ $rc == 0 && $count == 2 && $(mapping_count "$before" "$WORK/profile" cross-network) == 0 && $(mapping_count "$after" "$WORK/profile" cross-network) == 1 && $(mapping_count "$after" "$WORK/profile" host-published) == 1 ]]
)

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

dns_tcp_case() (
    local response=$1 expected=$2 rc=0
    local -a removed=()
    MP_RUN_ID=mtest MP_NETWORK_NAME=gm-mtest-m-net MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=tools
    mapping_fixture_state_load() { return 0; }
    resource_ledger_dir() { printf '%s\n' "$WORK"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { return 0; }
    mapping_fixture_create() { printf '%064d\n' 2; }
    resource_remove() { removed+=("$1:$2"); }
    mapping_fixture_docker() {
        case "$1" in
            inspect)
                if [[ $* == *'{{.Id}}'* ]]; then printf '%064d\n' 1
                elif [[ $* == *'{{.HostConfig.NetworkMode}}|{{.State.Running}}'* ]]; then printf 'gm-mtest-m-net|true\n'
                else printf 'container:%064d|10001:10001|true|tools|true|["ALL"]|["no-new-privileges"]\n' 1; fi ;;
            start) return 0 ;;
            exec)
                printf '%s\n' "$response"
                return 9 ;;
        esac
    }
    mapping_probe_egress product gen1 dns-tcp >/dev/null || rc=$?
    [[ $rc == "$expected" && ${#removed[@]} == 1 && ${removed[0]} == "container:$(printf '%064d' 2)" ]]
)

dns_tcp_remove_failure_case() (
    local response=$1 fixture_tool fixture_product rc=0 ledger
    fixture_tool=$(printf '%064d' 2)
    fixture_product=$(printf '%064d' 1)
    ledger=$WORK/remove-failure-$(printf '%s' "$response" | sha256sum | cut -d' ' -f1)
    mkdir -p "$ledger"
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=mtest
    MP_RUN_ID=mtest MP_NETWORK_NAME=gm-mtest-m-net MPF_SCENARIO=mapping-fallback MPF_TOOLS_IMAGE=tools
    mapping_fixture_state_load() { return 0; }
    resource_docker() {
        case "$1" in
            ps)
                printf '%s\n' "$fixture_product"
                [[ ! -f $ledger/objects/2-container.json ]] || printf '%s\n' "$fixture_tool" ;;
            network|volume) return 0 ;;
            inspect)
                if [[ ${2:-} == -f ]]; then
                    case "$3" in
                        '{{.Id}}') printf '%s\n' "$4" ;;
                        *'.Config.Labels'*)
                            if [[ $4 == "$fixture_product" ]]; then printf 'mtest\tmapping-fallback\tproduct\n'
                            else printf 'mtest\tmapping-fallback\ttcp-dns\n'; fi ;;
                        *) return 2 ;;
                    esac
                else printf '{"Id":"%s"}\n' "$2"; fi ;;
            rm) printf '%s\n' "$3" >> "$ledger/delete-attempts"; return 9 ;;
            *) return 2 ;;
        esac
    }
    mapping_fixture_create() {
        resource_register container "$fixture_tool" mapping-fallback tcp-dns || return 2
        printf '%s\n' "$fixture_tool"
    }
    mapping_fixture_docker() {
        case "$1" in
            inspect)
                if [[ $* == *'{{.Id}}'* ]]; then printf '%s\n' "$fixture_product"
                elif [[ $* == *'{{.HostConfig.NetworkMode}}|{{.State.Running}}'* ]]; then printf 'gm-mtest-m-net|true\n'
                else printf 'container:%s|10001:10001|true|tools|true|["ALL"]|["no-new-privileges"]\n' "$fixture_product"; fi ;;
            start) return 0 ;;
            exec) printf '%s\n' "$response"; return 9 ;;
            *) return 2 ;;
        esac
    }
    resource_register container "$fixture_product" mapping-fallback product || return 1
    mapping_probe_egress product gen1 dns-tcp >/dev/null || rc=$?
    [[ $rc == 80 && $(cat "$ledger/delete-attempts") == "$fixture_tool" ]] || return 1
    resource_crosscheck "$ledger" || return 1
    [[ -n ${RESOURCE_LEDGER_ACTIVE["container|$fixture_product"]:-} && -n ${RESOURCE_LEDGER_ACTIVE["container|$fixture_tool"]:-} && -z ${RESOURCE_LEDGER_REMOVED["container|$fixture_tool"]:-} ]]
)

profile_write
failed=0
for row in 'healthy cross-network 0' 'shared-other host-published 1' 'receiver-cross 19419 1' 'receiver-input 19420 1' 'receiver-udp udp 1' 'receiver-tcp tcp 1'; do
    read -r mode target expected <<< "$row"
    isolation_case "$mode" "$target" "$expected" || { printf 'FAIL %s\n' "$mode"; failed=1; }
done
for row in 'cross-network 19419' 'host-published 19419' 'host-input 19420' 'dns-udp udp' 'dns-tcp tcp'; do
    read -r key receiver <<< "$row"
    receiver_growth_case "$key" "$receiver" || { printf 'FAIL receiver-%s\n' "$key"; failed=1; }
done
shared_target_case || { printf 'FAIL shared-target\n'; failed=1; }
dns_tcp_case $';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached\n;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 10' 80 || { printf 'FAIL dns-tcp-mixed-error\n'; failed=1; }
dns_tcp_case $';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached' 0 || { printf 'FAIL dns-tcp-timeout\n'; failed=1; }
dns_tcp_remove_failure_case $';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached' || { printf 'FAIL dns-tcp-remove-timeout\n'; failed=1; }
dns_tcp_remove_failure_case $';; communications error to 172.30.244.53#53: timed out\n;; no servers could be reached\n;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 10' || { printf 'FAIL dns-tcp-remove-mixed\n'; failed=1; }
exit "$failed"
