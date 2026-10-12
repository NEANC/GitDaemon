#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/git-mirror-recover.sh"
if [[ -f $ROOT/scripts/git-mirror-gc.sh ]]; then source "$ROOT/scripts/git-mirror-gc.sh"; fi
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FAILURES=0

fixture() {
    declare -F gm_gc_one_locked >/dev/null || { printf '缺少GC执行接口\n'; return 1; }
    export RUN_ROOT=$TEST_ROOT/$BASHPID INSTALL_ROOT=$ROOT/scripts TZ=UTC
    mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/repos/owner" "$RUN_ROOT/logs" || return 1
    gm_parse_repos 'owner/repo' '' || return 1
    gm_container_lease_acquire && gm_startup_prepare || return 1
    dir=$RUN_ROOT/repos/owner/repo.git
    git init -q --bare "$dir" || return 1
    local -A initial=([schema]=1 [repo]=owner/repo [generation]=1 [desired]=present [observed]=ready [published]=no [message]=unchecked)
    gm_begin_operation sync || return 1
    gm_repo_state_commit_locked owner/repo initial && gm_startup_check_one owner/repo || return 1
    gm_lifecycle_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION" || return 1
    gm_gc_state_read owner/repo calendar || return 1
    now=$(date +%s)
    calendar[anchor_date]=$(TZ=UTC date -d '30 days ago' +%F)
    calendar[next_due_date]=$(TZ=UTC date -d yesterday +%F)
    calendar[not_before]=0
    gm_gc_state_commit_locked owner/repo calendar
}

test_auto_no_work_advances_cycle() (
    local dir now old
    local -A calendar=() outcome=()
    fixture || return 1
    old=${calendar[next_due_date]}
    export GIT_TRACE2_EVENT=$RUN_ROOT/trace.json
    gm_gc_one_locked owner/repo "$now" outcome || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${outcome[result]} == SUCCESS && ${calendar[next_due_date]} > "$old" && ${calendar[last_success_at]} -ge $now ]] || return 1
    [[ ${calendar[last_attempt_at]} == "$now" && ${calendar[status]} == scheduled ]] || return 1
    grep -q 'gc.autoDetach=false' "$GIT_TRACE2_EVENT" || return 1
    ! grep -q '"child_class":"gc"' "$GIT_TRACE2_EVENT"
)

test_busy_keeps_attempt_time() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    bash -c 'source "$1/scripts/git-mirror-gc.sh"; gm_gc_run_one owner/repo result' _ "$ROOT" >/dev/null 2>&1 || rc=$?
    gm_gc_state_read owner/repo calendar || return 1
    [[ $rc == 75 && ${calendar[last_attempt_at]} == 0 ]]
)

test_two_callers_only_one_claim() (
    local dir now first second a=0 b=0
    local -A calendar=() outcome=()
    fixture || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    bash -c 'source "$1/scripts/git-mirror-gc.sh"; gm_parse_repos owner/repo ""; gm_gc_run_one owner/repo result' _ "$ROOT" >"$RUN_ROOT/one" 2>&1 & first=$!
    bash -c 'source "$1/scripts/git-mirror-gc.sh"; gm_parse_repos owner/repo ""; gm_gc_run_one owner/repo result' _ "$ROOT" >"$RUN_ROOT/two" 2>&1 & second=$!
    wait "$first" || a=$?
    wait "$second" || b=$?
    [[ $a == 0 || $a == 75 ]] && [[ $b == 0 || $b == 75 ]] || return 1
    [[ $a == 0 || $b == 0 ]] || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[last_result]} == SUCCESS ]] || return 1
    [[ $(cat "$RUN_ROOT/one" "$RUN_ROOT/two" | grep -c 'result=SUCCESS') == 1 ]]
)

install_failure() {
    local mode=$1
    mkdir "$RUN_ROOT/bin" || return 1
    export REAL_GIT=$(command -v git) GC_FAILURE=$mode
    cat > "$RUN_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' gc --auto '* ]]; then
    case "$GC_FAILURE" in
        corrupt) rm -- "$GC_MISSING_OBJECT" ;;
        disk) printf 'fatal: No space left on device\n' >&2 ;;
        unknown) printf 'fatal: unexpected maintenance error\n' >&2 ;;
        stopped) kill -TERM "$GC_SUPERVISOR"; sleep 2 ;;
    esac
    exit 1
fi
exec "$REAL_GIT" "$@"
SH
    chmod 700 "$RUN_ROOT/bin/git" || return 1
    export PATH=$RUN_ROOT/bin:$PATH
}

test_gc_failure_fsck_healthy_republishes() (
    local dir now rc=0
    local -A calendar=() outcome=() state=()
    fixture && install_failure unknown || return 1
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar && gm_repo_state_read owner/repo state || return 1
    [[ $rc == 1 && ${state[health]} == healthy && ${state[published]} == yes && -f $dir/git-daemon-export-ok ]] || return 1
    [[ ${calendar[last_success_at]} == 0 && ${calendar[not_before]} -gt $now && ${calendar[write_blocked]} == yes ]] || return 1
    ! gm_gc_write_allowed owner/repo
)

test_gc_corruption_enqueues_rebuild() (
    local dir now oid rc=0
    local -A calendar=() outcome=() state=()
    fixture || return 1
    oid=$(printf 'reachable\n' | git --git-dir="$dir" hash-object -w --stdin) || return 1
    git --git-dir="$dir" update-ref refs/tags/blob "$oid" || return 1
    export GC_MISSING_OBJECT=$dir/objects/${oid:0:2}/${oid:2}
    install_failure corrupt || return 1
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_repo_state_read owner/repo state || return 1
    [[ $rc == 1 && ${state[health]} == corrupt && ${outcome[reason]} == rebuild_pending && ! -e $dir/git-daemon-export-ok && -d $dir ]]
)

test_disk_full_healthy_read_only() (
    local dir now rc=0
    local -A calendar=() outcome=() state=()
    fixture && install_failure disk || return 1
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar && gm_repo_state_read owner/repo state || return 1
    [[ $rc == 1 && ${state[health]} == healthy && ${state[published]} == yes && ${calendar[reason]} == environment && ${calendar[write_blocked]} == yes ]] || return 1
    update_repo() { touch "$RUN_ROOT/forbidden"; }
    gm_sync_one_locked owner/repo '' outcome && return 1
    [[ ! -e $RUN_ROOT/forbidden ]]
)

test_gc_log_not_deleted() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    printf 'retained diagnosis\n' > "$dir/gc.log"
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar || return 1
    [[ $rc == 1 && ${outcome[result]} == BLOCKED && ${outcome[reason]} == manual_intervention && ${calendar[last_attempt_at]} == 0 ]] || return 1
    [[ $(cat "$dir/gc.log") == 'retained diagnosis' ]] || return 1
    gm_gc_one_locked owner/repo "$now" outcome && return 1
    [[ ! -e $RUN_ROOT/runtime/task && ${calendar[last_attempt_at]} == 0 ]]
)

test_success_record_failure_is_unknown() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    local original
    original=$(declare -f gm_gc_state_commit_locked)
    eval "${original/gm_gc_state_commit_locked/gc_original_commit}"
    gm_gc_state_commit_locked() {
        local -n pending=$2
        [[ ${pending[last_result]} != SUCCESS ]] || return 1
        gc_original_commit "$@"
    }
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar || return 1
    [[ $rc == 1 && ${outcome[result]} != SUCCESS && ${calendar[last_success_at]} == 0 && ${calendar[last_result]} == UNKNOWN && ! -e $dir/git-daemon-export-ok ]] || return 1
    [[ -e $RUN_ROOT/runtime/frozen ]]
)

test_native_lock_precheck() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    printf 'retain\n' > "$dir/packed-refs.lock"
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar || return 1
    [[ $rc == 1 && ${calendar[reason]} == manual_intervention && ${calendar[last_attempt_at]} == 0 && -f $dir/packed-refs.lock ]]
)

test_unknown_retry_stays_fixed() (
    local dir now floor
    local -A calendar=() outcome=()
    fixture || return 1
    calendar[status]=running calendar[last_result]=UNKNOWN calendar[not_before]=0
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_gc_recover_locked owner/repo outcome || return 1
    gm_gc_state_read owner/repo calendar || return 1
    floor=${calendar[not_before]}
    gm_gc_recover_locked owner/repo outcome || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ $floor -gt $now && ${calendar[not_before]} == "$floor" && ${calendar[last_success_at]} == 0 ]]
)

test_not_due_and_generation_gate() (
    local dir now rc=0
    local -A calendar=() outcome=() state=()
    fixture || return 1
    calendar[not_before]=$((now+86400))
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_gc_one_locked owner/repo "$now" outcome || return 1
    [[ ${outcome[result]} == NOT_DUE ]] || return 1
    calendar[not_before]=0
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_repo_state_read owner/repo state || return 1
    state[generation]=2
    gm_repo_state_commit_locked owner/repo state || return 1
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    [[ $rc == 1 && ${outcome[result]} != SUCCESS ]]
)

test_stopped_skips_recovery() (
    local dir now rc=0
    local -A calendar=() outcome=() state=()
    fixture && install_failure stopped || return 1
    export GC_SUPERVISOR=$BASHPID
    trap 'gm_request_stop instance TERM' TERM
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar && gm_repo_state_read owner/repo state || return 1
    [[ $rc == 143 && ${state[message]} == recovery_required && ! -e $dir/git-daemon-export-ok && ${calendar[last_success_at]} == 0 && -e $RUN_ROOT/runtime/frozen ]]
)

test_real_threshold_foreground() (
    local dir now i oid packs starts exits
    local -A calendar=() outcome=()
    fixture || return 1
    for i in 1 2 3 4; do
        oid=$(printf 'pack-%s\n' "$i" | git --git-dir="$dir" hash-object -w --stdin) || return 1
        git --git-dir="$dir" update-ref "refs/tags/blob$i" "$oid" || return 1
        printf '%s\n' "$oid" | git --git-dir="$dir" pack-objects "$dir/objects/pack/pack" >/dev/null || return 1
    done
    git --git-dir="$dir" config gc.autoPackLimit 2 || return 1
    export GIT_TRACE2_EVENT=$RUN_ROOT/threshold.json
    gm_gc_one_locked owner/repo "$now" outcome || return 1
    packs=$(find "$dir/objects/pack" -name '*.pack' | wc -l)
    [[ ${outcome[result]} == SUCCESS && $packs -lt 4 ]] || return 1
    grep -q 'pack-objects' "$GIT_TRACE2_EVENT" || return 1
    starts=$(grep -c '"event":"child_start"' "$GIT_TRACE2_EVENT")
    exits=$(grep -c '"event":"child_exit"' "$GIT_TRACE2_EVENT")
    [[ $starts -gt 0 && $starts == "$exits" ]] || return 1
    git --git-dir="$dir" fsck --full || return 1
    [[ ! -e $RUN_ROOT/runtime/task ]]
)

test_state_rejects_invalid_data() (
    local dir now file
    local -A calendar=() outcome=()
    fixture || return 1
    file=$RUN_ROOT/state/gc/owner/repo.state
    printf 'unknown=data\n' >> "$file"
    gm_gc_state_read owner/repo calendar && return 1
    return 0
)

test_operation_identity_matches_registration() (
    local dir now original
    local -A calendar=() outcome=()
    fixture || return 1
    original=$(declare -f gm_task_finish_locked)
    eval "${original/gm_task_finish_locked/gc_original_finish}"
    gm_task_finish_locked() {
        local -n active=$1
        local -A on_disk=()
        gm_gc_state_read owner/repo on_disk || return 1
        if [[ ${active[operation]} == gc ]]; then
            [[ ${active[operation_id]} == "${on_disk[operation_id]}" ]] || printf mismatch > "$RUN_ROOT/mismatch"
        fi
        gc_original_finish "$@"
    }
    gm_gc_one_locked owner/repo "$now" outcome || return 1
    [[ ! -e $RUN_ROOT/mismatch ]]
)

test_startup_unknown_blocks_sync() (
    local dir now floor
    local -A calendar=() outcome=()
    fixture || return 1
    calendar[status]=running calendar[last_result]=UNKNOWN calendar[not_before]=0 calendar[resumed_boot]=none
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_startup_check_one owner/repo || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[write_blocked]} == yes && ${calendar[not_before]} -gt $now ]] || return 1
    floor=${calendar[not_before]}
    gm_startup_check_one owner/repo || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[not_before]} == "$floor" ]] || return 1
    ! gm_gc_write_allowed owner/repo
)

test_task_cancel_recovers_without_freezing() (
    local dir now rc=0
    local -A calendar=() outcome=() state=()
    fixture && install_failure stopped || return 1
    export GC_SUPERVISOR=$BASHPID
    trap 'gm_request_stop task TERM' TERM
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_repo_state_read owner/repo state || return 1
    [[ $rc == 143 && ${state[health]} == healthy && ${state[published]} == yes && ! -e $RUN_ROOT/runtime/frozen ]]
)

test_gc_copy_identity_mismatch_blocks() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    calendar[identity]=0-0
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    gm_gc_state_read owner/repo calendar || return 1
    [[ $rc == 1 && ${outcome[result]} == BLOCKED && ${calendar[last_attempt_at]} == 0 ]]
)

test_replacement_preserves_calendar_and_rebinds() (
    local dir now old
    local -A calendar=() outcome=() state=() checked=()
    fixture || return 1
    old=${calendar[next_due_date]}
    gm_repo_unpublish_locked owner/repo || return 1
    mv "$dir" "$RUN_ROOT/old.git" || return 1
    git init -q --bare "$dir" || return 1
    gm_repo_state_read owner/repo state || return 1
    state[generation]=2
    gm_repo_state_commit_locked owner/repo state || return 1
    gm_repo_check_locked owner/repo "$dir" checked || return 1
    gm_repo_publish_locked owner/repo 2 || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[generation]} == 2 && ${calendar[identity]} == "$(stat -c '%d-%i' "$dir")" && ${calendar[next_due_date]} == "$old" && ${calendar[last_success_at]} == 0 ]]
)

test_cli_signal_targets_supervisor() (
    local dir now caller rc=0 i
    local -A calendar=() outcome=()
    fixture && install_failure unknown || return 1
    cat > "$RUN_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' gc --auto '* ]]; then
    printf started > "$RUN_ROOT/started"
    sleep 30
    exit 0
fi
exec "$REAL_GIT" "$@"
SH
    gm_lock_release sync && gm_lock_release instance || return 1
    bash -c 'source "$1/scripts/git-mirror-gc.sh"; gm_parse_repos owner/repo ""; gm_gc_run_one owner/repo' _ "$ROOT" > "$RUN_ROOT/cli.log" 2>&1 & caller=$!
    for ((i=0;i<300;i++)); do [[ ! -e $RUN_ROOT/started ]] || break; sleep 0.02; done
    [[ -e $RUN_ROOT/started ]] || { kill -TERM "$caller"; wait "$caller"; return 1; }
    kill -TERM "$caller" || return 1
    wait "$caller" || rc=$?
    for ((i=0;i<500;i++)); do [[ -e $RUN_ROOT/runtime/task ]] || break; sleep 0.02; done
    [[ $rc == 143 && ! -e $RUN_ROOT/runtime/task && ! -e $RUN_ROOT/runtime/frozen ]]
)

test_cli_selection_and_due() (
    local dir now rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    calendar[not_before]=$((now+86400))
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_lock_release sync && gm_lock_release instance || return 1
    gm_prepare_runtime() { return 0; }
    gm_gc_main --repo owner/repo || return 1
    gm_gc_main || return 1
    gm_gc_main --repo other/repo && return 1
    gm_gc_main --force && return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[last_attempt_at]} == 0 ]]
)

test_gc_state_fault_boundaries() (
    local dir now before rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    before=$(cat "$RUN_ROOT/state/gc/owner/repo.state")
    calendar[reason]=environment
    GM_STATE_TEST_FAULT=sync
    gm_gc_state_commit_locked owner/repo calendar && return 1
    [[ $(cat "$RUN_ROOT/state/gc/owner/repo.state") == "$before" ]] || return 1
    GM_STATE_TEST_FAULT=directory-sync
    gm_gc_state_commit_locked owner/repo calendar || rc=$?
    [[ $rc == 2 && $GM_STATE_COMMIT_RESULT == indeterminate ]] || return 1
    unset GM_STATE_TEST_FAULT
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[reason]} == environment ]]
)

test_block_commit_failure_freezes() (
    local dir now original rc=0
    local -A calendar=() outcome=()
    fixture || return 1
    printf retain > "$dir/gc.log"
    gm_gc_state_commit_locked() { return 1; }
    gm_gc_one_locked owner/repo "$now" outcome || rc=$?
    [[ $rc == 1 && ${outcome[result]} == UNSAFE && -e $RUN_ROOT/runtime/frozen && ! -e $dir/git-daemon-export-ok ]] || return 1
    [[ -n ${GM_LOCK_FDS[sync]-} && -n ${GM_LOCK_FDS[instance]-} ]]
)

test_offline_resume_once_online_due_only() (
    local dir now floor
    local -A calendar=() outcome=()
    fixture || return 1
    calendar[resumed_boot]=none
    gm_gc_state_commit_locked owner/repo calendar || return 1
    gm_startup_check_one owner/repo || return 1
    gm_gc_state_read owner/repo calendar || return 1
    floor=${calendar[not_before]}
    [[ $floor -ge $now ]] || return 1
    gm_gc_startup_resume_locked owner/repo "$((floor+86400))" || return 1
    gm_gc_state_read owner/repo calendar || return 1
    [[ ${calendar[not_before]} == "$floor" ]] || return 1
    gm_gc_one_locked owner/repo "$floor" outcome || return 1
    [[ ${outcome[result]} == SUCCESS ]]
)

test_state_rejects_duplicates_links_and_permissions() (
    local dir now file backup
    local -A calendar=() outcome=()
    fixture || return 1
    file=$RUN_ROOT/state/gc/owner/repo.state
    backup=$(cat "$file")
    printf 'repo=owner/repo\n' >> "$file"
    gm_gc_state_read owner/repo calendar && return 1
    printf '%s\n' "$backup" > "$file"
    chmod 666 "$file"
    gm_gc_state_read owner/repo calendar && return 1
    chmod 600 "$file"
    mv "$file" "$file.saved"
    ln -s "$file.saved" "$file"
    gm_gc_state_read owner/repo calendar && return 1
    return 0
)

for test in test_auto_no_work_advances_cycle test_busy_keeps_attempt_time test_two_callers_only_one_claim test_gc_failure_fsck_healthy_republishes test_gc_corruption_enqueues_rebuild test_disk_full_healthy_read_only test_gc_log_not_deleted test_success_record_failure_is_unknown test_native_lock_precheck test_unknown_retry_stays_fixed test_not_due_and_generation_gate test_stopped_skips_recovery test_real_threshold_foreground test_state_rejects_invalid_data test_operation_identity_matches_registration test_startup_unknown_blocks_sync test_task_cancel_recovers_without_freezing test_gc_copy_identity_mismatch_blocks test_replacement_preserves_calendar_and_rebinds test_cli_signal_targets_supervisor test_cli_selection_and_due test_gc_state_fault_boundaries test_block_commit_failure_freezes test_offline_resume_once_online_due_only test_state_rejects_duplicates_links_and_permissions; do
    if "$test"; then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf 'checks=25 failures=%s\n' "$FAILURES"
(( FAILURES == 0 ))
