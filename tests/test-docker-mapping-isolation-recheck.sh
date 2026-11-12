#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=recheck IT_NETWORK=gm-recheck-net
source "$HERE/test-docker-integration.sh"
source "$HERE/docker-mapping-assertions.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
IT_EVIDENCE_DIR=$TEST_ROOT/evidence
mkdir -p "$IT_EVIDENCE_DIR/control"
IT_CONTROL_DIR=$IT_EVIDENCE_DIR/control

# 为旧快照用例提供与真实产品相同的完整 ID 和账本外部边界。
isolation_snapshot_boundaries() {
    MP_RUN_ID=recheck MPF_SCENARIO=mapping-fallback-isolation MAPPING_ASSERT_TARGET=''
    mapping_fixture_docker() { [[ $1 == inspect && $4 == product ]] || return 80; printf '%064d\n' 3; }
    resource_ledger_dir() { printf '%s\n' "$IT_CONTROL_DIR/resources"; }
    resource_crosscheck() { return 0; }
    resource_verify_object() { [[ $1 == container && $2 == "$(printf '%064d' 3)" && $3 == mapping-fallback-isolation && $4 == product ]]; }
    mapping_receiver_probe() { return 0; }
    mapping_receiver_witness_counts() { printf '0\n0\n0\n0\n'; }
    mapping_witness() { cat "$1"; }
    mapping_receiver_listener_control() { [[ $2 != CONT || $3 == 123 ]] || return 80; printf '123\n'; }
    mapping_receiver_listener_observed_state() { if [[ -s $IT_EVIDENCE_DIR/isolation/$1/listener.restored.pid ]]; then printf 'R\n'; else printf 'T\n'; fi; }
    mapping_receiver_listener_running() { return 0; }
    mapping_receiver_negative_probe() { return 0; }
}

isolation_evidence_calibrates_before_product() (
    local key mode rc count calls=$TEST_ROOT/evidence-calls
    MAPPING_PROFILE=profile
    mapping_scenario_fixture_prepare() { return 0; }
    mapping_proxy_calibrate() { return 0; }
    mapping_profile_load() { return 0; }
    mapping_receiver_witness_counts() {
        local cross=0 input=0 udp=0 tcp=0 name
        while IFS= read -r name; do
            case "$name" in
                cross-network|host-published) cross=$((cross + 1)) ;;
                host-input) input=$((input + 1)) ;;
                dns-udp) udp=$((udp + 1)) ;;
                dns-tcp) tcp=$((tcp + 1)) ;;
            esac
        done < "$calls"
        printf '%s\n%s\n%s\n%s\n' "$cross" "$input" "$udp" "$tcp"
    }
    mapping_receiver_probe() {
        [[ $mode != missing ]] || return 80
        [[ $mode != "$1" ]] || return 1
        printf '%s\n' "$1" >> "$calls"
    }
    mapping_scenario_product_up() { printf 'started\n' > "$TEST_ROOT/product-started"; return 80; }
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        for mode in "$key" missing healthy; do
            : > "$calls"
            rm -f "$TEST_ROOT/product-started"
            MAPPING_ASSERT_CASE=isolation MAPPING_ASSERT_TARGET=$key
            rc=0
            mapping_scenario_evidence fallback mapping-fallback-isolation gen1 "$TEST_ROOT" >/dev/null || rc=$?
            [[ $rc == 80 ]] || return 1
            if [[ $mode == healthy ]]; then
                [[ -e $TEST_ROOT/product-started && $MP_WITNESS_CALIBRATED == 1 && $(wc -l < "$calls") == 5 ]] || return 1
            else
                [[ ! -e $TEST_ROOT/product-started && $MP_WITNESS_CALIBRATED == 0 ]] || return 1
            fi
        done
    done
)

isolation_cases_reach_negative_runner() (
    local key rc=0
    mapping_negative_run() {
        printf '%s\t%s\t%s\n' "$1" "${MAPPING_ASSERT_TARGET:-}" "$2" >> "$TEST_ROOT/negative-calls"
        return 80
    }
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        check_mapping_negative "隔离 $key" "isolation/$key" fallback
        [[ ${IT_SLOT_DONE[isolation_negatives]:-0} == 1 ]] || return 1
        IT_SLOT_DONE[isolation_negatives]=0
    done
    [[ $(wc -l < "$TEST_ROOT/negative-calls") == 5 ]] || return 1
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        grep -Fqx "$(printf 'isolation\t%s\tfallback' "$key")" "$TEST_ROOT/negative-calls" || return 1
    done
    : > "$TEST_ROOT/negative-calls"
    check_mapping_negative '未实现 DNS' dns-false-green/fallback fallback
    [[ ! -s $TEST_ROOT/negative-calls && ${IT_SLOT_FAIL[dns_negatives]:-0} == 1 ]]
)

isolation_target_keeps_case_and_scenario_separate() (
    local dir=$TEST_ROOT/negative-target rc=0
    MAPPING_ASSERT_TARGET=host-published
    mapping_assert_prepare_dir() { mkdir -p "$1"; }
    mapping_scenario_evidence() {
        [[ $MAPPING_ASSERT_CASE == isolation && $MAPPING_ASSERT_TARGET == host-published ]] || return 80
        [[ $2 == mapping-fallback-isolation && $3 != *'/'* ]] || return 80
        return 80
    }
    mapping_scenario_release() { return 0; }
    mapping_negative_run isolation fallback "$dir" || rc=$?
    [[ $rc == 80 ]]
)

isolation_calibration_requires_each_shared_port_probe() (
    local key calls=$TEST_ROOT/calibration-calls rc
    MAPPING_PROFILE=profile MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CASE=isolation
    mapping_profile_load() { return 0; }
    mapping_receiver_witness_counts() {
        local cross=0 input=0 udp=0 tcp=0 name
        while IFS= read -r name; do
            case "$name" in
                cross-network|host-published) cross=$((cross + 1)) ;;
                host-input) input=$((input + 1)) ;;
                dns-udp) udp=$((udp + 1)) ;;
                dns-tcp) tcp=$((tcp + 1)) ;;
            esac
        done < "$calls"
        printf '%s\n%s\n%s\n%s\n' "$cross" "$input" "$udp" "$tcp"
    }
    mapping_receiver_probe() {
        [[ $1 != "${paused:-}" ]] || return 1
        printf '%s\n' "$1" >> "$calls"
    }
    for key in cross-network host-published host-input dns-udp dns-tcp; do
        : > "$calls"
        paused=$key rc=0 MP_WITNESS_CALIBRATED=0
        mapping_calibrate_witness profile >/dev/null || rc=$?
        [[ $rc == 1 && $MP_WITNESS_CALIBRATED == 0 ]] || return 1
    done
    : > "$calls"
    paused='' MP_WITNESS_CALIBRATED=0
    mapping_calibrate_witness profile >/dev/null || return 1
    [[ $MP_WITNESS_CALIBRATED == 1 && $(wc -l < "$calls") == 5 ]]
)

isolation_requires_per_target_snapshots() (
    local snapshot_root=$TEST_ROOT/snapshots count=0 rc=0 cross=0 input=0 udp=0 tcp=0 probes=0
    mkdir -p "$snapshot_root/control"
    IT_CONTROL_DIR=$snapshot_root/control IT_EVIDENCE_DIR=$snapshot_root/evidence MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1
    MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=netid-abc MP_PROFILE_SHA256=hash
    isolation_snapshot_boundaries
    mapping_profile_load() { MP_RUN_ID=recheck MP_P=140.82.112.10 MP_BRIDGE=mrecheck; return 0; }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == gen1 && $3 == netid-abc && $5 == "$MAPPING_ASSERT_TARGET" ]] || return 80
        count=$((count + 1))
        CONTROL_SEQ=$count
        printf '%s\n0\n0\n0\n' "$((count % 5 == 2))" > "$snapshot_root/mapping-snapshot-$count.witness"
        printf '%s\n%s\n%s\n%s\n' "$cross" "$input" "$udp" "$tcp" > "$snapshot_root/mapping-snapshot-$count.rules"
        printf 'target\t%s\nseq\t%s\n' "$5" "$count" > "$snapshot_root/mapping-snapshot-$count.receipt"
    }
    mapping_witness() { cat "$1"; }
    mapping_count() {
        case "$3" in
            cross-network|host-published) sed -n '1p' "$1" ;;
            host-input) sed -n '2p' "$1" ;;
            dns-udp) sed -n '3p' "$1" ;;
            dns-tcp) sed -n '4p' "$1" ;;
        esac
    }
    mapping_probe_egress() {
        [[ $1 == "$(printf '%064d' 3)" && $2 == gen1 ]] || return 80
        probes=$((probes + 1))
        case "${3:-}" in
            cross-network) cross=$((cross + 1)) ;;
            host-published) : ;;
            host-input) input=$((input + 1)) ;;
            dns-udp) udp=$((udp + 1)) ;;
            dns-tcp) tcp=$((tcp + 1)) ;;
            *) cross=1 input=1 udp=1 tcp=1 ;;
        esac
    }
    MAPPING_ASSERT_TARGET=cross-network
    mapping_isolation_check product gen1 profile || rc=$?
    [[ $rc == 0 && $count == 5 && $probes == 1 ]]
    cross=0 count=0 probes=0 rc=0
    MAPPING_ASSERT_TARGET=host-published
    mapping_isolation_check product gen1 profile || rc=$?
    [[ $rc == 1 && $count == 5 && $probes == 1 ]]
)

isolation_snapshots_each_of_five_targets() (
    local snapshot_root=$TEST_ROOT/five-snapshots count=0 probe=0 witness_slot n
    local -a keys=(cross-network host-published host-input dns-udp dns-tcp)
    mkdir -p "$snapshot_root/control"
    IT_CONTROL_DIR=$snapshot_root/control IT_EVIDENCE_DIR=$snapshot_root/evidence MAPPING_ASSERT_GENERATION=gen1 MAPPING_ASSERT_CALIBRATED_GENERATION=gen1
    MP_WITNESS_CALIBRATED=1 MP_NETWORK_ID=netid-abc MP_PROFILE_SHA256=hash
    isolation_snapshot_boundaries
    mapping_profile_load() { return 0; }
    mapping_control_request() {
        [[ $1 == mapping-snapshot && $2 == gen1 && $3 == netid-abc && $5 == "${keys[$((count / 5))]}" ]] || return 80
        count=$((count + 1))
        CONTROL_SEQ=$count
        case "$5" in
            cross-network|host-published) witness_slot=1 ;;
            host-input) witness_slot=2 ;;
            dns-udp) witness_slot=3 ;;
            dns-tcp) witness_slot=4 ;;
        esac
        for n in 1 2 3 4; do
            if [[ $n == "$witness_slot" ]]; then printf '%s\n' "$((count % 5 == 2))"; else printf '0\n'; fi
        done > "$snapshot_root/mapping-snapshot-$count.witness"
        printf '%s\n' "$(( count / 5 ))" > "$snapshot_root/mapping-snapshot-$count.rules"
        printf 'target\t%s\nseq\t%s\n' "$5" "$count" > "$snapshot_root/mapping-snapshot-$count.receipt"
    }
    mapping_witness() { cat "$1"; }
    mapping_count() { cat "$1"; }
    mapping_probe_egress() {
        [[ $1 == "$(printf '%064d' 3)" && $2 == gen1 ]] || return 80
        [[ $3 == "${keys[$probe]}" ]] || return 80
        probe=$((probe + 1))
    }
    mapping_isolation_check product gen1 profile || return 1
    [[ $count == 25 && $probe == 5 ]]
)

failed=0
for name in isolation_evidence_calibrates_before_product isolation_cases_reach_negative_runner isolation_target_keeps_case_and_scenario_separate isolation_calibration_requires_each_shared_port_probe isolation_requires_per_target_snapshots isolation_snapshots_each_of_five_targets; do
    rc=0; ( "$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
