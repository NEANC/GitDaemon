#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WITNESS_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WITNESS_NET_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

profile_write() {
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$1"
}

docker_double() {
    printf '%s\n' "$*" >> "$WORK/docker.calls"
    local kind=${1:-} id=${3:-${2:-}} run='' scenario='' role='' token
    case "$kind" in
        create)
            [[ $* == *'--name gm-mtest-witness'* ]] || return 1
            [[ $* == *'--network gm-mtest-w-net'* ]] || return 1
            [[ $* == *'--ip 172.30.244.53'* && $* == *'--dns 172.30.244.53'* ]] || return 1
            [[ $* == *'-p 172.30.243.1:49382:19419'* && $* == *'dnsmasq'* && $* == *'nc -lk -p 19419'* ]] || return 1
            for token in "$@"; do
                case "$token" in
                    gitdaemon.run=*) run=${token#*=} ;;
                    gitdaemon.scenario=*) scenario=${token#*=} ;;
                    gitdaemon.role=*) role=${token#*=} ;;
                esac
            done
            printf '%s\t%s\t%s\n' "$run" "$scenario" "$role" > "$WORK/labels"
            printf '%s\n' "$WITNESS_ID"
            ;;
        inspect)
            [[ ${2:-} != -f ]] || id=${4:-}
            [[ $id == "$WITNESS_ID" || $id == gm-mtest-witness || $id == "$WITNESS_NET_ID" ]] || return 1
            case "${2:-}" in
                -f)
                    case "$*" in
                        *'HostConfig.NetworkMode'* ) printf '%s|mtest|mapping|witness|%s|123|true\n' "$WITNESS_ID" "${WITNESS_NETWORK:-gm-mtest-w-net}" ;;
                        *'gitdaemon.run'*) if [[ $id == "$WITNESS_NET_ID" ]]; then cat "$WORK/network-labels"; else cat "$WORK/labels"; fi ;;
                        *'State.Running'*) printf '%s\n' "${WITNESS_RUNNING:-true}" ;;
                        *) if [[ $id == gm-mtest-witness ]]; then printf '%s\n' "$WITNESS_ID"; else printf '%s\n' "$id"; fi ;;
                    esac
                    ;;
                *) printf '{"Id":"%s"}\n' "$id" ;;
            esac
            ;;
        start) [[ ${2:-} != "$WITNESS_ID" || ${START_FAIL:-0} != 1 ]] ;;
        rm) printf '%s\n' "$*" >> "$WORK/removed" ;;
        network)
            case "$*" in
                'network create '*)
                    [[ $* == *'--subnet 172.30.244.0/24'* && $* == *'com.docker.network.bridge.name=wmtest'* ]] || return 1
                    [[ $* == *'gm-mtest-w-net' ]] || return 1
                    for token in "$@"; do
                        case "$token" in
                            gitdaemon.run=*) run=${token#*=} ;;
                            gitdaemon.scenario=*) scenario=${token#*=} ;;
                            gitdaemon.role=*) role=${token#*=} ;;
                        esac
                    done
                    printf '%s\t%s\t%s\n' "$run" "$scenario" "$role" > "$WORK/network-labels"
                    printf '%s\n' "$WITNESS_NET_ID"
                    ;;
                *'.Name'*) printf 'gm-mtest-m-net\n' ;;
                *'com.docker.network.bridge.name'*) printf 'mmtest\n' ;;
                'network rm '*) printf '%s\n' "$*" >> "$WORK/removed" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

setup_case() {
    local dir=$WORK/$1
    mkdir -p "$dir/control/resources"
    profile_write "$dir/profile.tsv"
    MAPPING_PROFILE=$dir/profile.tsv MAPPING_PRODUCT_IMAGE=product MAPPING_TOOLS_IMAGE=tools
    MAPPING_ASSERT_GENERATION=g1 IT_CONTROL_DIR=$dir/control IT_EVIDENCE_DIR=$dir
    RESOURCE_LEDGER_DIR=$dir/control/resources RESOURCE_RUN=mtest RUN=mtest E=$dir
    GUARD_PROFILE=$MAPPING_PROFILE GUARD_MAPPING_CONTROL_IDENTITY=identity
    GUARD_MAPPING_STATE=PREPARING seq=1 last_nonce='' rules_start=0
    OWN_RULES=() OWN_CHAINS=() OWN_NS_RULES=() OWN_NS_CHAINS=()
    : > "$WORK/docker.calls"
    : > "$WORK/removed"
    resource_docker() { docker_double "$@"; }
    mapping_fixture_docker() { docker_double "$@"; }
    docker() { docker_double "$@"; }
    iptables() { return 0; }
    nsenter() { return 0; }
    guard_mapping_state_write() { return 0; }
    guard_mapping_ack_publish() { printf 'ACK\n' >> "$WORK/acks"; }
    mapping_assets_prepare() { return 0; }
    mapping_evidence_volume_prepare() { return 0; }
    mapping_evidence_volume_verify() { return 0; }
    mapping_fixture_precheck() { return 0; }
    mapping_network_create() {
        local state
        state=$(mapping_network_state_file) || return 1
        mkdir -p "${state%/*}"
        printf 'network_id\tnet-one\n' > "$state"
        printf 'net-one\n'
    }
    mapping_proxy_evidence_reset() { return 0; }
    mapping_negative_prepare() { return 0; }
    mapping_control_request() { guard_mapping_request_handle "$1" "$2" "$3" "$4" nonce1; MAPPING_ACK_GENERATION=$2; }
    mapping_fixture_start() { return 0; }
}

prepare_ready_registers_witness() (
    setup_case ready
    : > "$WORK/acks"
    mapping_scenario_fixture_prepare direct mapping-direct "$E" || return 1
    [[ $(awk -F '\t' -v id="$WITNESS_ID" '$2=="register" && $3=="container" && $4==id && $5=="mtest" && $6=="mapping" && $7=="witness" {n++} END {print n+0}' "$RESOURCE_LEDGER_DIR/ledger.tsv") == 1 ]] || return 1
    [[ $(awk -F '\t' -v id="$WITNESS_NET_ID" '$2=="register" && $3=="network" && $4==id && $5=="mtest" && $6=="mapping" && $7=="witness-network" {n++} END {print n+0}' "$RESOURCE_LEDGER_DIR/ledger.tsv") == 1 ]] || return 1
    grep -Fq "start $WITNESS_ID" "$WORK/docker.calls" || return 1
    [[ $(wc -l < "$WORK/acks") == 1 ]] || return 1
    [[ $MAPPING_ACK_GENERATION == g1 && $GUARD_MAPPING_STATE == ACTIVE ]] || return 1
    guard_mapping_witness_remove || return 1
    resource_remove container "$WITNESS_ID" || return 1
    resource_remove network "$WITNESS_NET_ID" || return 1
    grep -Fq "$WITNESS_ID" "$WORK/removed" && grep -Fq "$WITNESS_NET_ID" "$WORK/removed"
)

wrong_network_cannot_ack() (
    setup_case wrong-network
    : > "$WORK/acks"
    mapping_prepare "$MAPPING_PROFILE" mapping-direct product tools || return 1
    WITNESS_NETWORK=other
    local rc=0
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || rc=$?
    [[ $rc == 80 && ! -s $WORK/acks ]]
)

start_failure_cannot_ready() (
    setup_case start-failure
    START_FAIL=1
    : > "$WORK/acks"
    local rc=0
    mapping_scenario_fixture_prepare direct mapping-direct "$E" || rc=$?
    [[ $rc == 80 && ! -s $WORK/acks ]]
)

failed=0
for test in prepare_ready_registers_witness wrong_network_cannot_ack start_failure_cannot_ready; do
    rc=0; "$test" || rc=$?
    printf '%s EXIT=%s\n' "$test" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
