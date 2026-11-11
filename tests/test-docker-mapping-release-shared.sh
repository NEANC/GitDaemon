#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
WITNESS_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WNET_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PRODUCT_ID=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

setup_release() {
    local directory=$WORK/$1
    mkdir -p "$directory/control/resources/objects"
    E=$directory RUN=mtest RESOURCE_RUN=mtest RESOURCE_LEDGER_DIR=$directory/control/resources
    IT_CONTROL_DIR=$directory/control MAPPING_PROFILE=$directory/profile.tsv
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$MAPPING_PROFILE"
    mapping_profile_load "$MAPPING_PROFILE"
    MP_NETWORK_ID=net-one GUARD_MANIFEST=manifest GUARD_ATTESTATION=attestation
    GUARD_MAPPING_STATE=ACTIVE GUARD_MAPPING_GENERATION=g1 GUARD_MAPPING_NETWORK_ID=net-one
    GUARD_MAPPING_LAST_GENERATION='' GUARD_MAPPING_CONTROL_IDENTITY=identity
    OWN_RULES=('filter|-A GEN -j DROP') OWN_NS_RULES=() OWN_NS_CHAINS=()
    GUARD_MAPPING_WITNESS_ID=$WITNESS_ID
    PRODUCT_RUN=mtest WNET_ROLE=witness-network WNET_ATTACHMENT=$WNET_ID EXTRA_ID='' WITNESS_PRESENT=1 WNET_PRESENT=1
    : > "$directory/actions"
    printf '1\tregister\tcontainer\t%s\tmtest\tmapping\twitness\thash\t%s\tpath\n2\tregister\tnetwork\t%s\tmtest\tmapping\twitness-network\thash\t%s\tpath\n3\tregister\tcontainer\t%s\tmtest\tmapping-direct\tproduct\thash\t%s\tpath\n' "$WITNESS_ID" "$WITNESS_ID" "$WNET_ID" "$WNET_ID" "$PRODUCT_ID" "$PRODUCT_ID" > "$RESOURCE_LEDGER_DIR/ledger.tsv"
}

validation_environment_verify() { return 0; }
resource_lock() { return 0; }
resource_unlock() { return 0; }
docker() {
    case "$*" in
        *'gm-mtest-witness'*)
            [[ $WITNESS_PRESENT == 1 ]] || return 1
            if [[ $* == *'.NetworkID'* ]]; then printf '%s\n' "$WNET_ATTACHMENT"
            elif [[ $* == *'HostConfig.NetworkMode'* ]]; then
                printf '%s|mtest|mapping|witness|gm-mtest-w-net|123|true\n' "$WITNESS_ID"
            else printf '%s\n' "$WITNESS_ID"; fi ;;
        *'gm-mtest-w-net'*) printf '%s\n' "$WNET_ID" ;;
        *) return 1 ;;
    esac
}
resource_docker() {
    local action=$1 id=${3:-${2:-}}
    case "$action" in
        ps) [[ ! -e $E/product ]] || printf '%s\n' "$PRODUCT_ID"; [[ $WITNESS_PRESENT != 1 ]] || printf '%s\n' "$WITNESS_ID"; [[ -z $EXTRA_ID ]] || printf '%s\n' "$EXTRA_ID" ;;
        network) case "$2" in ls) [[ $WNET_PRESENT != 1 ]] || printf '%s\n' "$WNET_ID" ;; rm) printf 'network rm %s\n' "$3" >> "$E/actions"; WNET_PRESENT=0 ;; *) return 2 ;; esac ;;
        volume) [[ $2 == ls ]] ;;
        inspect)
            [[ $2 != -f ]] || id=$4
            [[ ( $id == "$WITNESS_ID" && $WITNESS_PRESENT == 1 ) || ( $id == "$WNET_ID" && $WNET_PRESENT == 1 ) || ( $id == "$PRODUCT_ID" && -e $E/product ) ]] || return 1
            if [[ $2 == -f && $3 == *gitdaemon.run* ]]; then
                if [[ $id == "$PRODUCT_ID" ]]; then printf '%s\tmapping-direct\tproduct\n' "${PRODUCT_RUN:-mtest}"
                elif [[ $id == "$WNET_ID" ]]; then printf 'mtest\tmapping\t%s\n' "$WNET_ROLE"
                else printf 'mtest\tmapping\twitness\n'; fi
            else printf '%s\n' "$id"; fi ;;
        rm)
            printf 'rm %s\n' "$3" >> "$E/actions"
            if [[ $3 == "$PRODUCT_ID" ]]; then rm "$E/product";
            elif [[ $3 == "$WITNESS_ID" ]]; then WITNESS_PRESENT=0;
            else return 2; fi ;;
        *) return 2 ;;
    esac
}
iptables() { printf 'rule %s\n' "$*" >> "$E/actions"; }
release_preserves_shared_and_enables_next_generation() (
    setup_release success
    : > "$E/product"
    resource_cleanup_scenario "$RESOURCE_LEDGER_DIR" mapping-direct || return 1
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 || return 1
    [[ $GUARD_MAPPING_STATE == RELEASED && $GUARD_MAPPING_LAST_GENERATION == g1 ]] || return 1
    [[ $(cat "$E/actions") == *"rm $PRODUCT_ID"* && $(cat "$E/actions") != *"rm $WITNESS_ID"* ]] || return 1
    [[ ${#OWN_RULES[@]} == 0 ]] || return 1
    GUARD_MAPPING_STATE=PREPARING
    guard_mapping_generation mapping-ready g2 net-two "$MP_PROFILE_SHA256"
)

release_rejects_missing_receipt_without_unrules() (
    setup_release missing
    local rc=0
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 || rc=$?
    [[ $rc != 0 && $GUARD_MAPPING_STATE == ACTIVE && ! -s $E/actions ]]
)

release_rejects_identity_drift_without_unrules() (
    setup_release drift
    : > "$E/product"
    PRODUCT_RUN=other
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 >/dev/null 2>&1 && return 1
    [[ $GUARD_MAPPING_STATE == ACTIVE && ! -s $E/actions ]]
)

release_rejects_witness_network_drift_without_unrules() (
    setup_release network-drift
    WNET_ROLE=other
    local rc=0
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 && $GUARD_MAPPING_STATE == ACTIVE && ! -s $E/actions ]]
)

release_rejects_witness_attachment_drift_without_unrules() (
    setup_release attachment-drift
    WNET_ATTACHMENT=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    local rc=0
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 && $GUARD_MAPPING_STATE == ACTIVE && ! -s $E/actions ]]
)

release_rejects_unregistered_residual_without_unrules() (
    setup_release residual
    EXTRA_ID=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    local rc=0
    guard_mapping_release g1 net-one "$MP_PROFILE_SHA256" 0 >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 && $GUARD_MAPPING_STATE == ACTIVE && ! -s $E/actions ]]
)

outer_cleanup_removes_shared_after_release() (
    setup_release outer
    printf '3\tremoved\tcontainer\t%s\tmtest\tmapping-direct\tproduct\thash\t%s\t\n' "$PRODUCT_ID" "$PRODUCT_ID" >> "$RESOURCE_LEDGER_DIR/ledger.tsv"
    resource_cleanup "$RESOURCE_LEDGER_DIR" || return 1
    [[ $(cat "$E/actions") == *"rm $WITNESS_ID"* && $(cat "$E/actions") == *"network rm $WNET_ID"* ]]
)

prepare_failure_exit_trap_refuses_identity_drift() (
    setup_release prepare-failure
    : > "$E/product"
    PRODUCT_RUN=other
    local rc=0
    (
        trap 'resource_cleanup "$RESOURCE_LEDGER_DIR"' EXIT
        exit 80
    ) >/dev/null 2>&1 || rc=$?
    [[ $rc != 0 && ! -s $E/actions && -e $E/product ]]
)

failed=0
for test in release_preserves_shared_and_enables_next_generation release_rejects_missing_receipt_without_unrules release_rejects_identity_drift_without_unrules release_rejects_witness_network_drift_without_unrules release_rejects_witness_attachment_drift_without_unrules release_rejects_unregistered_residual_without_unrules outer_cleanup_removes_shared_after_release prepare_failure_exit_trap_refuses_identity_drift; do
    rc=0; "$test" || rc=$?
    printf '%s EXIT=%s\n' "$test" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
