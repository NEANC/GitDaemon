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
        printf 'seq\t%s\ngeneration\tg1\nnetwork_id\tnet-one\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s\n' "$count" "$MP_PROFILE_SHA256" \
            "$(sha256sum "$root/mapping-snapshot-$count.rules" | cut -d' ' -f1)" \
            "$(sha256sum "$root/mapping-snapshot-$count.witness" | cut -d' ' -f1)" > "$root/mapping-snapshot-$count.receipt"
    }
    mapping_receiver_listener_control() {
        [[ $2 != STOP ]] || paused=1
        [[ $2 != CONT ]] || paused=0
        [[ $2 != CONT || $3 == 123 ]] || return 80
        printf '123\n'
    }
    mapping_receiver_negative_probe() { [[ $paused == 1 ]] || return 80; printf 'connection refused\n'; }
    mapping_receiver_listener_running() { [[ $paused == 0 ]]; }
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
    for key in $MAPPING_WITNESS_KEYS; do
        [[ -s $dir/isolation/$key/calibration.before.receipt && -s $dir/isolation/$key/calibration.after.receipt \
            && -s $dir/isolation/$key/negative.receipt && -s $dir/isolation/$key/before.receipt \
            && -s $dir/isolation/$key/after.receipt ]] || return 1
    done
    cp "$dir/isolation/host-input/before.rules" "$WORK/original.rules"
    cp "$dir/isolation/dns-udp/after.rules" "$dir/isolation/host-input/before.rules"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/original.rules" "$dir/isolation/host-input/before.rules"
    cp "$dir/isolation/dns-udp/before.receipt" "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-19.receipt" "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-19.receipt" "$WORK/receipt"
    rm "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 80 ]] || return 1
    cp "$WORK/receipt" "$dir/isolation/host-input/before.receipt"
    sed -i 's/generation\tg1/generation\tg2/' "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/receipt" "$dir/isolation/host-input/before.receipt"
    sed -i 's/network_id\tnet-one/network_id\tnet-two/' "$dir/isolation/host-input/before.receipt"
    rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$root/mapping-snapshot-14.receipt" "$dir/isolation/host-input/before.receipt"
    for key in before.rules negative.exit; do
        cp "$dir/isolation/host-input/$key" "$WORK/$key"
        rm "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf '%s missing: %s\n' "$key" "$rc" >&2; return 1; }
        : > "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        [[ $rc == 80 ]] || { printf '%s empty: %s\n' "$key" "$rc" >&2; return 1; }
        printf 'invalid\n' > "$dir/isolation/host-input/$key"
        rc=0; mapping_negative_case_evidence_accept isolation/host-input mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
        if [[ $key == before.rules ]]; then
            [[ $rc == 1 ]] || { printf '%s invalid: %s\n' "$key" "$rc" >&2; return 1; }
        else
            [[ $rc == 80 ]] || { printf '%s invalid: %s\n' "$key" "$rc" >&2; return 1; }
        fi
        cp "$WORK/$key" "$dir/isolation/host-input/$key"
    done
    key=host-input
    cp "$dir/isolation/$key/after.rules" "$WORK/after.rules"
    printf 'not a drop rule\n' > "$dir/isolation/$key/after.rules"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    snapshot_write "$dir/isolation/$key/after.rules" 10
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$WORK/after.rules" "$dir/isolation/$key/after.rules"
    printf '0\n' > "$dir/isolation/$key/seq.after"
    rc=0; mapping_negative_case_evidence_accept "isolation/$key" mtest mapping-fallback-isolation g1 manifest input "$dir" || rc=$?
    [[ $rc == 1 ]] || return 1
    printf '20\n' > "$dir/isolation/$key/seq.after"
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

isolation_stop_failure_restores_or_blocks() (
    local mode=$1 root dir rc=0 paused=0 resumes=0 probes=0
    root=$WORK/$mode dir=$WORK/$mode/evidence
    mkdir -p "$root/control" "$dir"
    IT_CONTROL_DIR=$root/control IT_EVIDENCE_DIR=$dir MAPPING_PROFILE=$WORK/profile.tsv
    MAPPING_ASSERT_GENERATION=g1 MAPPING_ASSERT_CALIBRATED_GENERATION=g1 MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=net-one
    mapping_profile_load "$MAPPING_PROFILE"
    mapping_receiver_probe() { probes=$((probes + 1)); [[ $paused == 0 ]] || return 80; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_control_request() {
        [[ $mode != snapshot_failure || $paused == 0 ]] || return 77
        CONTROL_SEQ=$(( ${CONTROL_SEQ:-0} + 1 ))
        snapshot_write "$root/mapping-snapshot-$CONTROL_SEQ.rules" 10
        witness_write "$probes" "$root/mapping-snapshot-$CONTROL_SEQ.witness" cross-network
        printf 'seq\t%s\ngeneration\tg1\nnetwork_id\tnet-one\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s\n' "$CONTROL_SEQ" "$MP_PROFILE_SHA256" \
            "$(sha256sum "$root/mapping-snapshot-$CONTROL_SEQ.rules" | cut -d' ' -f1)" \
            "$(sha256sum "$root/mapping-snapshot-$CONTROL_SEQ.witness" | cut -d' ' -f1)" > "$root/mapping-snapshot-$CONTROL_SEQ.receipt"
        if [[ $mode == snapshot_copy_failure && $paused == 1 ]]; then
            rm "$root/mapping-snapshot-$CONTROL_SEQ.witness"
        fi
    }
    mapping_receiver_listener_control() {
        if [[ $2 == STOP ]]; then
            paused=1
            [[ $mode != stop_output_failure ]] || return 0
            [[ $mode != stop_error && $mode != stop_unknown && $mode != stop_resume_failure ]] || return 77
            printf '123\n'
            return 0
        fi
        resumes=$((resumes + 1))
        [[ $mode != cont_failure && $mode != stop_resume_failure ]] || return 77
        paused=0
        printf '123\n'
    }
    mapping_receiver_listener_pid() {
        printf 'lookup\n' >> "$root/lookups"
        [[ $mode != stop_unknown ]] || return 80
        printf '123\n'
    }
    mapping_receiver_listener_running() { [[ $paused == 0 && $mode != running_failure ]]; }
    mapping_receiver_negative_probe() { [[ $mode != negative_failure ]] || return 77; printf 'connection refused\n'; }
    mapping_isolation_check product g1 "$MAPPING_PROFILE" || rc=$?
    [[ $rc == 80 && $probes == 2 ]] || return 1
    [[ -f $dir/isolation/cross-network/stop.outcome.tsv ]] || return 1
    [[ ! -e $dir/isolation/host-published ]] || return 1
    case "$mode" in
        stop_error|stop_unknown|stop_output_failure|stop_resume_failure)
            [[ $(wc -l < "$root/lookups") == 1 && $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tstop'* ]] || return 1
            if [[ $mode == stop_unknown || $mode == stop_resume_failure ]]; then
                [[ $paused == 1 ]] || return 1
                [[ $mode != stop_unknown || $resumes == 0 ]] || return 1
                [[ $mode != stop_resume_failure || ( $resumes == 1 && $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'restore_exit\t77'*$'running_exit\t1'* ) ]] || return 1
                return 0
            fi
            [[ $resumes == 1 && $paused == 0 ]] || return 1
            ;;
        negative_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tnegative-probe'*$'original_exit\t77'* ]] || return 1 ;;
        snapshot_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tsnapshot'*$'original_exit\t77'* ]] || return 1 ;;
        snapshot_copy_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tsnapshot-copy'*$'original_exit\t1'* ]] || return 1 ;;
        cont_failure)
            [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'failure_stage\tnone'*$'restore_exit\t77'*$'running_exit\t1'* && $paused == 1 && $resumes == 1 ]] || return 1
            return 0
            ;;
        running_failure) [[ $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'running_exit\t1'* ]] || return 1 ;;
    esac
    [[ $paused == 0 ]] || return 1
    [[ $mode == running_failure || $(cat "$dir/isolation/cross-network/stop.outcome.tsv") == *$'running_exit\t0'* ]] || return 1
    return 0
)

profile_write "$WORK/profile.tsv"
isolation_produces_and_consumes_five_bound_cases
for failure in negative_failure snapshot_failure snapshot_copy_failure cont_failure running_failure; do
    isolation_stop_failure_restores_or_blocks "$failure"
done
for failure in stop_error stop_output_failure stop_unknown stop_resume_failure; do
    isolation_stop_failure_restores_or_blocks "$failure"
done
