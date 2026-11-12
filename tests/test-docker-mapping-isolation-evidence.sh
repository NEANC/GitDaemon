#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

profile_write() {
    printf 'schema_version\t1\nrun_id\tmtest\ncidr\t140.82.112.0/24\ngateway\t140.82.112.1\nP\t140.82.112.10\nU\t140.82.112.11\nX\t140.82.112.12\nD\t140.82.112.13\nN\t140.82.112.14\nnetwork_name\tgm-mtest-m-net\nbridge\tmmtest\n' > "$1"
}

snapshot_write() {
    local file=$1 count=$2 key proto port dest
    : > "$file"
    for key in $MAPPING_WITNESS_KEYS; do
        IFS=$'\t' read -r proto port dest <<< "$(mapping_witness_spec "$key")"
        printf '[%s:0] -A MEmtest -i mmtest -s 140.82.112.10/32 -d %s/32 -p %s --dport %s -m comment --comment "mtest-%s" -j DROP\n' "$count" "$dest" "$proto" "$port" "$key" >> "$file"
    done
}

witness_write() {
    local cross=0 input=0 udp=0 tcp=0
    case "$3" in
        cross-network|host-published) cross=$1 ;;
        host-input) input=$1 ;;
        dns-udp) udp=$1 ;;
        dns-tcp) tcp=$1 ;;
    esac
    printf '%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19420\n%s 0 RETURN udp -- * * 0.0.0.0/0 0.0.0.0/0 udp dpt:53\n%s 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:53\n' "$cross" "$input" "$udp" "$tcp" > "$2"
}

identity_write() {
    local dir=$1
    printf 'run_id\tmtest\nscenario\tmapping-fallback-isolation\ngeneration\tg1\nnetwork_id\tnet-one\nimage_id\timage\nprofile_sha256\t%s\ninput_sha256\tinput\nmanifest_sha256\tmanifest\nunique_commit\tcommit\n' "$MP_PROFILE_SHA256" > "$dir/identity.tsv"
}

isolation_produces_and_consumes_five_bound_cases() (
    local root=$WORK/run dir=$WORK/case key count=0 rc received=0 paused=0
    mkdir -p "$root/control" "$dir"
    IT_CONTROL_DIR=$root/control IT_EVIDENCE_DIR=$dir MAPPING_PROFILE=$WORK/profile.tsv
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_CALIBRATED_GENERATION=g1 MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=net-one
    mapping_profile_load "$MAPPING_PROFILE"
    identity_write "$dir"
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == g1 && $3 == net-one && $4 == "$MP_PROFILE_SHA256" ]] || return 65
        count=$((count + 1)); CONTROL_SEQ=$count
        snapshot_write "$root/mapping-snapshot-$count.rules" "$((count % 5 == 0 ? 20 : 10))"
        witness_write "$received" "$root/mapping-snapshot-$count.witness" "$MAPPING_ASSERT_TARGET"
    }
    mapping_receiver_listener_control() {
        [[ $2 != STOP ]] || paused=1
        [[ $2 != CONT ]] || paused=0
        [[ $2 != CONT || $3 == 123 ]] || return 80
        printf '123\n'
    }
    mapping_receiver_negative_probe() { [[ $paused == 1 ]] || return 80; printf 'connection refused\n'; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_receiver_probe() { [[ $paused == 0 ]] || return 1; received=$((received + 1)); }
    mapping_probe_egress() { printf 'connection timed out\n'; }
    for key in $MAPPING_WITNESS_KEYS; do
        MAPPING_ASSERT_TARGET=$key
        mapping_isolation_check product g1 "$MAPPING_PROFILE" || return 1
        [[ -d $dir/isolation/$key ]] || return 1
        mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || return 1
    done
    [[ $count == 25 ]] || return 1
    key=host-input
    printf 'not a drop rule\n' > "$dir/isolation/$key/after.rules"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    snapshot_write "$dir/isolation/$key/after.rules" 20
    printf '0\n' > "$dir/isolation/$key/seq.after"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf '15\n' > "$dir/isolation/$key/seq.after"
    key=dns-udp
    printf 'target\tother\n' > "$dir/isolation/$key/binding.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=host-published
    printf '0 0 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 tcp dpt:19419\n' > "$dir/isolation/$key/after.witness"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=cross-network
    printf 'wrong\n' > "$dir/isolation/$key/reject.layer"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'policy\n' > "$dir/isolation/$key/reject.layer"
    printf 'probe_exit\t1\n' > "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'probe_exit\t0\n' > "$dir/isolation/$key/negative.tsv"
    printf 'no listener stopped\n' > "$dir/isolation/$key/listener.pid"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    key=dns-tcp
    rm "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'probe_exit\t2\n' > "$dir/isolation/$key/negative.tsv"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    IT_EVIDENCE_DIR=$WORK/no-negative
    mkdir -p "$IT_EVIDENCE_DIR"
    MAPPING_ASSERT_TARGET=cross-network
    mapping_receiver_negative_probe() { return 80; }
    rc=0; mapping_isolation_check product g1 "$MAPPING_PROFILE" || rc=$?
    [[ $rc == 80 && ! -f $IT_EVIDENCE_DIR/isolation/cross-network/reject.layer ]] || return 1
    return 0
)

profile_write "$WORK/profile.tsv"
isolation_produces_and_consumes_five_bound_cases
