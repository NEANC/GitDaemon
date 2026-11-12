#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WITNESS_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

profile_write() {
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$1"
}

setup_guard() {
    RUN=mtest E=$WORK/evidence GUARD_PROFILE=$WORK/profile.tsv RUNNER=gmtest
    mkdir -p "$E/control"
    mapping_profile_load "$GUARD_PROFILE"
    GUARD_MAPPING_CONTROL_IDENTITY=identity
    OWN_RULES=() OWN_CHAINS=() OWN_NS_RULES=() OWN_NS_CHAINS=()
    seq=1 last_nonce='' rules_start=0
    GUARD_MAPPING_STATE=PREPARING
    : > "$WORK/calls"
}

docker() {
    printf 'docker %s\n' "$*" >> "$WORK/calls"
    case "$*" in
        *'network inspect'*'.Name'*) printf 'gm-mtest-m-net\n' ;;
        *'network inspect'*'com.docker.network.bridge.name'*) printf 'mmtest\n' ;;
        *'inspect -f {{.Id}} gm-mtest-witness'*) printf '%s\n' "$WITNESS_ID" ;;
        *'inspect'*'gm-mtest-witness'*) printf '%s|mtest|mapping|witness|gm-mtest-w-net|123|true\n' "$WITNESS_ID" ;;
        *) return 1 ;;
    esac
}

iptables() {
    printf 'iptables %s\n' "$*" >> "$WORK/calls"
    if [[ ${FAIL_RULE:-} == 1 && $* == *'-A MSmtest'*'--dport 53'* ]]; then return 1; fi
    if [[ ${MISSING_CHAIN:-} == 1 && $* == *'-nvxL MSmtest'* ]]; then return 1; fi
    if [[ ${EMPTY_CHAIN:-} == 1 && $* == *'-nvxL MSmtest'* ]]; then return 0; fi
    if [[ $* == *'-nvxL MSmtest'* ]]; then printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n0 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n'; fi
    return 0
}

nsenter() {
    printf 'nsenter %s\n' "$*" >> "$WORK/calls"
    iptables "${@:5}"
}

iptables-save() { printf 'rules\n'; }
guard_mapping_state_write() { return 0; }
guard_mapping_ack_publish() { printf 'ack\n' >> "$WORK/calls"; }
resource_ledger_load() {
    RESOURCE_LEDGER_ACTIVE=(["container|$WITNESS_ID"]='1|mapping|witness|hash|digest|mtest')
}
resource_verify_object() {
    [[ $1 == container && $2 == "$WITNESS_ID" && $3 == mapping && $4 == witness ]]
}

ready_snapshot_installs_owned_rules_before_ack() (
    setup_guard
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || return 1
    [[ ${#OWN_RULES[@]} == 17 ]] || return 1
    [[ ${#OWN_NS_RULES[@]} == 5 && ${OWN_NS_CHAINS[0]} == 'raw|MSmtest' ]] || return 1
    [[ $(awk '$1=="nsenter" && /-A MSmtest/ { n++ } END { print n+0 }' "$WORK/calls") == 4 ]] || return 1
    [[ $(awk '$1=="nsenter" && /-I PREROUTING -j MSmtest/ { n++ } END { print n+0 }' "$WORK/calls") == 1 ]] || return 1
    [[ $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 1 ]] || return 1
    guard_mapping_request_handle mapping-snapshot g1 net-one "$MP_PROFILE_SHA256" nonce2 host-input || return 1
    [[ -s $E/mapping-snapshot-2.witness && $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 2 ]] || return 1
    grep -Fq 'raw|-A MSmtest -p tcp --dport 19419 -j RETURN' "$E/witness-rules.owned" || return 1
    grep -Fq 'raw|-I PREROUTING -j MSmtest' "$E/witness-rules.owned"
)

missing_chain_rejects_snapshot_without_ack() (
    setup_guard
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || return 1
    MISSING_CHAIN=1
    local rc=0
    guard_mapping_request_handle mapping-snapshot g1 net-one "$MP_PROFILE_SHA256" nonce2 host-input || rc=$?
    [[ $rc == 80 && $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 1 ]]
)

empty_chain_rejects_snapshot_without_ack() (
    setup_guard
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || return 1
    EMPTY_CHAIN=1
    local rc=0
    guard_mapping_request_handle mapping-snapshot g1 net-one "$MP_PROFILE_SHA256" nonce2 host-input || rc=$?
    [[ $rc == 80 && $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 1 ]]
)

failed_install_rolls_back_exact_rules_without_ack() (
    setup_guard
    FAIL_RULE=1
    local rc=0
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || rc=$?
    [[ $rc == 80 && $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 0 ]] || return 1
    FAIL_RULE=0
    guard_mapping_witness_remove || return 1
    guard_remove_rules_since 0 || return 1
    [[ $(awk '$1=="nsenter" && /-X MSmtest/ { n++ } END { print n+0 }' "$WORK/calls") == 1 ]]
)

wrong_witness_identity_rejects_before_nsenter() (
    setup_guard
    docker() {
        if [[ $* == *'gm-mtest-witness'* && $* == *'{{.Id}}'* && $* != *'|'* ]]; then printf '%s\n' "$WITNESS_ID"; elif [[ $* == *'gm-mtest-witness'* ]]; then printf '%s|mtest|mapping|witness|wrong-network|123|true\n' "$WITNESS_ID"; elif [[ $* == *com.docker.network.bridge.name* ]]; then
            printf 'mmtest\n'; else printf 'gm-mtest-m-net\n'; fi
    }
    local rc=0
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || rc=$?
    [[ $rc == 80 && $(awk '$1=="nsenter" { n++ } END { print n+0 }' "$WORK/calls") == 0 ]]
)

release_removes_witness_rules_before_host_rules() (
    setup_guard
    guard_mapping_request_handle mapping-ready g1 net-one "$MP_PROFILE_SHA256" nonce1 || return 1
    guard_mapping_release_verify() { return 0; }
    guard_mapping_request_handle mapping-release g1 net-one "$MP_PROFILE_SHA256" nonce2 || return 1
    [[ ${#OWN_NS_RULES[@]} == 0 && ${#OWN_NS_CHAINS[@]} == 0 ]] || return 1
    [[ $(awk '$1=="nsenter" && /-X MSmtest/ { n++ } END { print n+0 }' "$WORK/calls") == 1 ]] || return 1
    [[ $GUARD_MAPPING_STATE == RELEASED && $(awk '$1=="ack" { n++ } END { print n+0 }' "$WORK/calls") == 2 ]]
)

profile_write "$WORK/profile.tsv"
failed=0
for test in ready_snapshot_installs_owned_rules_before_ack missing_chain_rejects_snapshot_without_ack empty_chain_rejects_snapshot_without_ack failed_install_rolls_back_exact_rules_without_ack wrong_witness_identity_rejects_before_nsenter release_removes_witness_rules_before_host_rules; do
    rc=0; "$test" || rc=$?
    printf '%s EXIT=%s\n' "$test" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
