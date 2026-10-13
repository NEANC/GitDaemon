#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/repository-recovery.sh"
if [[ -f $ROOT/scripts/git-mirror-recover.sh ]]; then source "$ROOT/scripts/git-mirror-recover.sh"; fi
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
CHECKS=0 FAILURES=0

setup_startup() {
    source "$ROOT/scripts/deploy-git-mirror.sh"
    gm_bootstrap_user_runlevel() { return 0; }
    gm_install_program "$TEST_ROOT/$1-program" "$ROOT/scripts" >/dev/null || return 1
    RUN_ROOT=$TEST_ROOT/$1
    export RUN_ROOT REPOS='owner/first;owner/second'
    INSTALL_ROOT=$TEST_ROOT/$1-program
    gm_initialize_instance "$RUN_ROOT" "$INSTALL_ROOT" >/dev/null || return 1
    mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/repos/owner" "$RUN_ROOT/logs" "$RUN_ROOT/tmp"
    unset GM_BOOT_GENERATION GM_STOP_SCOPE GM_LOCAL_FROZEN
    gm_parse_repos 'owner/first;owner/second' '' || return 1
    local repo
    for repo in first second; do
        git init -q --bare "$RUN_ROOT/repos/owner/$repo.git" || return 1
        : > "$RUN_ROOT/repos/owner/$repo.git/git-daemon-export-ok"
    done
    gm_container_lease_acquire || return 1
}

test_legacy_export_cannot_bypass() {
    declare -F gm_startup_prepare >/dev/null || return 1
    setup_startup legacy || return 1
    mkdir -p "$RUN_ROOT/repos/unknown/nested.git"
    printf 'preserve\n' > "$RUN_ROOT/repos/unknown/nested.git/HEAD"
    : > "$RUN_ROOT/repos/unknown/nested.git/git-daemon-export-ok"
    gm_startup_prepare || return 1
    [[ ! -e $RUN_ROOT/repos/unknown/nested.git/git-daemon-export-ok && -f $RUN_ROOT/repos/unknown/nested.git/HEAD ]] || return 1
    [[ ! -e $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok ]] || return 1
    gm_startup_gate_validate
}

test_first_healthy_available_before_second_checked() {
    declare -F gm_startup_checks >/dev/null || return 1
    setup_startup ordered || return 1
    gm_startup_prepare || return 1
    gm_startup_run_repo() {
        if [[ $1 == owner/second ]]; then
            [[ -f $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok && ! -e $RUN_ROOT/repos/owner/second.git/git-daemon-export-ok ]] || return 1
            : > "$RUN_ROOT/ordered"
        fi
        gm_startup_check_one "$1"
    }
    gm_startup_checks || return 1
    [[ -f $RUN_ROOT/ordered && -f $RUN_ROOT/runtime/checks-complete ]]
}

test_resume_cannot_clear_freeze() {
    setup_startup resume || return 1
    printf 'FROZEN=1\n' > "$RUN_ROOT/runtime/frozen"
    printf 'STOPPED=1\n' > "$RUN_ROOT/runtime/stopped"
    gm_resume_instance "$RUN_ROOT" "$ROOT/scripts" >/dev/null 2>&1 && return 1
    [[ -f $RUN_ROOT/runtime/frozen && -f $RUN_ROOT/runtime/stopped ]] || return 1
    gm_startup_prepare || return 1
    [[ ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    gm_task_freeze || return 1
    gm_startup_prepare && return 1
    [[ -f $RUN_ROOT/runtime/frozen ]]
}

test_startup_requires_live_owner() {
    declare -F gm_startup_gate_validate >/dev/null || return 1
    setup_startup owner || return 1
    gm_startup_prepare || return 1
    gm_lock_release container || return 1
    gm_startup_gate_validate && return 1
    return 0
}

test_offline_healthy_downloads() {
    declare -F gm_startup_checks >/dev/null || return 1
    setup_startup offline || return 1
    gm_startup_prepare || return 1
    gm_startup_checks || return 1
    local pid status=0
    (gm_lock_release container; exec git daemon --reuseaddr --listen=127.0.0.1 --port=19418 --base-path="$RUN_ROOT/repos") & pid=$!
    sleep 0.2
    git ls-remote git://127.0.0.1:19418/owner/first.git >/dev/null 2>&1 || status=1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return "$status"
}

test_startup_no_network_before_checks() {
    declare -F gm_startup_network >/dev/null || return 1
    setup_startup network || return 1
    gm_startup_prepare || return 1
    gm_startup_run_repo() { printf '%s %s\n' "$1" "$2" >> "$RUN_ROOT/network"; }
    gm_startup_network && return 1
    [[ ! -e $RUN_ROOT/network ]] || return 1
    gm_lifecycle_record "$RUN_ROOT/runtime/checks-complete" "$GM_BOOT_GENERATION" || return 1
    gm_startup_network || return 1
    [[ $(wc -l < "$RUN_ROOT/network") == 2 ]]
}

test_daemon_rejects_stale_gate() {
    setup_startup daemon || return 1
    gm_without_container_lease "$INSTALL_ROOT/git-daemon-config.sh" >/dev/null 2>&1 && return 1
    gm_startup_prepare || return 1
    gm_without_container_lease "$INSTALL_ROOT/git-daemon-config.sh" >/dev/null || return 1
    gm_lock_release container || return 1
    "$INSTALL_ROOT/git-daemon-config.sh" >/dev/null 2>&1 && return 1
    return 0
}

test_resume_without_context_rejected() {
    setup_startup no-context || return 1
    printf 'STOPPED=1\n' > "$RUN_ROOT/runtime/stopped"
    gm_check_platform() { return 0; }
    rc-service() { if [[ ${3-} == status ]]; then return 3; fi; return 0; }
    local output status=0
    output=$(gm_resume_instance "$RUN_ROOT" "$INSTALL_ROOT" 2>&1) || status=$?
    printf 'resume status=%s diagnostic=%s\n' "$status" "$output"
    [[ $status == 1 && $output == *'容器启动上下文'* && -f $RUN_ROOT/runtime/stopped ]]
}

test_bad_repository_keeps_other_available() {
    setup_startup bad || return 1
    printf 'invalid\n' > "$RUN_ROOT/repos/owner/first.git/HEAD"
    gm_startup_prepare || return 1
    gm_startup_checks || return 1
    [[ ! -e $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok && -f $RUN_ROOT/repos/owner/second.git/git-daemon-export-ok ]]
}

test_worker_failure_revokes_publication() {
    setup_startup worker-failure || return 1
    gm_startup_prepare || return 1
    gm_startup_checks || return 1
    gm_task_run_locked() { local -n output=$3; output=([result]=RUNNING); }
    gm_task_finish_locked() { local -n output=$1; output[result]=RECOVERY_REQUIRED; output[raw_status]=1; }
    gm_startup_run_repo owner/first recovery && return 1
    [[ ! -e $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok && -f $RUN_ROOT/repos/owner/second.git/git-daemon-export-ok ]]
}

test_unknown_writer_blocks_startup() {
    setup_startup writer || return 1
    printf 'unknown writer\n' > "$RUN_ROOT/runtime/task"
    gm_startup_prepare && return 1
    [[ ! -e $RUN_ROOT/runtime/publication-gate ]]
}

test_startup_uses_delivered_find() {
    setup_startup find || return 1
    find() { return 127; }
    gm_startup_prepare || return 1
}

test_scheduler_stop_freezes() {
    setup_startup scheduler || return 1
    gm_startup_prepare || return 1
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    declare -F gm_scheduler_freeze >/dev/null || return 1
    gm_scheduler_freeze || return 1
    [[ -e $RUN_ROOT/runtime/frozen ]]
}

# 冻结中断后仍须在监督持有的业务锁内撤销发布。
test_frozen_worker_revokes_before_unlock() {
    setup_startup frozen-worker || return 1
    gm_startup_prepare && gm_startup_checks || return 1
    gm_task_run_locked() { local -n output=$3; output=([result]=RUNNING); }
    gm_task_finish_locked() {
        [[ ${2-} == retain ]] || return 1
        local -n output=$1
        output[result]=INTERRUPTED
        output[raw_status]=143
        gm_task_freeze
    }
    gm_startup_run_repo owner/first recovery && return 1
    [[ ! -e $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok && -e $RUN_ROOT/runtime/frozen ]]
}

# 信号回调只设置停止意图，不直接向未经公共监督确认的进程发信号。
test_entry_signal_only_records_stop() {
    source "$ROOT/docker/docker-entrypoint.sh"
    GM_ENTRYPOINT_TASK=123 GM_ENTRYPOINT_TASK_PGID=123 GM_ENTRYPOINT_SLEEP=124
    kill() { : > "$TEST_ROOT/signal-kill"; }
    on_stop_signal
    [[ $GM_ENTRYPOINT_STOP == 1 && ${GM_STOP_SCOPE-} == instance && ! -e $TEST_ROOT/signal-kill ]]
}

# 单库环境失败不阻止后续健康库检查，但实例安全故障必须中止。
test_check_failure_scope() {
    setup_startup failure-scope || return 1
    gm_startup_prepare || return 1
    gm_startup_run_repo() {
        if [[ $1 == owner/first ]]; then return 1; fi
        : > "$RUN_ROOT/second-checked"
    }
    gm_startup_checks || return 1
    [[ -f $RUN_ROOT/second-checked ]] || return 1
    gm_startup_run_repo() { return 2; }
    gm_startup_checks && return 1
    return 0
}

# 独立 CLI 不继承启动代次，仍应验证活跃发布门后同步已检查的健康缓存。
test_cli_sync_validates_live_generation() {
    setup_startup cli-generation || return 1
    local dir=$RUN_ROOT/repos/owner/first.git
    git init -q --bare "$RUN_ROOT/upstream.git" || return 1
    git --git-dir="$dir" remote add origin "$RUN_ROOT/upstream.git" || return 1
    gm_startup_prepare && gm_startup_checks || return 1
    gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first || return 1
    [[ -f $dir/git-daemon-export-ok ]] || return 1
    gm_lock_release container || return 1
    gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first && return 1
    return 0
}

setup_cli_probe() {
    setup_startup "$1" || return 1
    git --git-dir="$RUN_ROOT/repos/owner/first.git" remote add origin https://github.com/owner/first.git || return 1
    gm_startup_prepare && gm_startup_checks || return 1
    export REAL_GIT=$(command -v git)
    mkdir -p "$RUN_ROOT/bin" || return 1
    cat > "$RUN_ROOT/bin/git" <<'PROBE'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ $arg == fetch ]]; then
        printf '%s\n' "$BASHPID" > "$RUN_ROOT/fetch.pid"
        if [[ -f $RUN_ROOT/runtime/task ]]; then cp "$RUN_ROOT/runtime/task" "$RUN_ROOT/fetch.task"; fi
        cat "$RUN_ROOT/runtime/task" >> "$RUN_ROOT/fetch.tasks"
        if [[ ${PROBE_MODE-} == wait ]]; then sleep 15; fi
        if [[ ${PROBE_MODE-} == multiwait && $* == *owner/first.git* ]]; then sleep 15; fi
        printf 'fatal: unable to access upstream: The requested URL returned error: 503\n' >&2
        exit 128
    fi
done
exec "$REAL_GIT" "$@"
PROBE
    chmod 700 "$RUN_ROOT/bin/git" || return 1
    export PATH="$RUN_ROOT/bin:$PATH"
}

test_cli_checks_gate_before_network() {
    local mode status
    for mode in missing stale; do
        (
            setup_cli_probe "cli-gate-$mode" || exit 1
            gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first || true
            [[ -s $RUN_ROOT/fetch.pid ]] || exit 1
            rm "$RUN_ROOT/fetch.pid"
            if [[ $mode == missing ]]; then rm "$RUN_ROOT/runtime/checks-complete"; else printf 'stale\n' > "$RUN_ROOT/runtime/checks-complete"; fi
            status=0
            gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first || status=$?
            [[ $status != 0 && ! -e $RUN_ROOT/fetch.pid ]]
        ) || return 1
    done
}

test_cli_transport_failure_is_supervised() {
    setup_cli_probe cli-transport || return 1
    local status=0
    local -A state=()
    gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first || status=$?
    [[ $status == 1 && -s $RUN_ROOT/fetch.task && ! -e $RUN_ROOT/runtime/task ]] || return 1
    gm_repo_state_read owner/first state || return 1
    [[ ${state[health]} == healthy && ${state[message]} != recovery_required && -f $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok ]]
}

test_cli_term_joins_writer() {
    setup_cli_probe cli-term || return 1
    local pid writer= status=0 i result=0
    (gm_lock_release container; exec env -u GM_BOOT_GENERATION PROBE_MODE=wait "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/first) &
    pid=$!
    for ((i=0; i<3000; i++)); do
        [[ ! -s $RUN_ROOT/fetch.pid ]] || break
        sleep 0.02
    done
    if [[ -s $RUN_ROOT/fetch.pid ]]; then writer=$(cat "$RUN_ROOT/fetch.pid"); else result=1; fi
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" || status=$?
    [[ $status != 0 && -s $RUN_ROOT/fetch.task && ! -e $RUN_ROOT/runtime/task ]] || result=1
    if [[ -n $writer ]] && kill -0 "$writer" 2>/dev/null; then
        result=1
        sleep 16
    fi
    [[ ! -f $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok ]] || result=1
    printf 'CLI TERM status=%s writer=%s result=%s\n' "$status" "$writer" "$result"
    return "$result"
}

# 在两库独立 CLI 首库拉取时发送真实信号，验证取消只结束本次调用且不触碰后库或清理链接。
test_cli_multirepo_signal_stops_invocation() {
    local signal=$1
    setup_cli_probe "cli-multi-$signal" || return 1
    export LOG_FILE=$RUN_ROOT/logs/sync.log
    git --git-dir="$RUN_ROOT/repos/owner/second.git" remote add origin https://github.com/owner/second.git || return 1
    gm_create_short_link "$RUN_ROOT" owner/second obsolete || return 1
    cp "$RUN_ROOT/state/repos/owner/second.state" "$RUN_ROOT/second.before" || return 1
    local pid writer= status=0 i result=0 repo operation boot leader start pgid session operation_id begin end group_status
    set -m
    (gm_lock_release container; exec env -u GM_BOOT_GENERATION PROBE_MODE=multiwait "$INSTALL_ROOT/git-mirror-sync.sh") &
    pid=$!
    set +m
    for ((i=0; i<3000; i++)); do
        [[ ! -s $RUN_ROOT/fetch.tasks ]] || break
        sleep 0.02
    done
    if [[ -s $RUN_ROOT/fetch.tasks ]]; then
        writer=$(cat "$RUN_ROOT/fetch.pid")
        read -r repo operation boot leader start pgid session operation_id < "$RUN_ROOT/fetch.task"
        [[ $repo == owner/first ]] || result=1
    else result=1
    fi
    gm_monotonic_ms begin
    kill -"$signal" "$pid" 2>/dev/null || result=1
    for ((i=0; i<500; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.02
    done
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid"; result=1; fi
    wait "$pid" || status=$?
    gm_monotonic_ms end
    [[ $status != 0 && $((end-begin)) -lt 10000 && ! -e $RUN_ROOT/runtime/task ]] || result=1
    if [[ -n $writer ]]; then
        kill -0 "$writer" 2>/dev/null && result=1
        group_status=0
        gm_task_group_alive "$pgid" "$session" || group_status=$?
        [[ $group_status == 1 ]] || result=1
    fi
    [[ $(wc -l < "$RUN_ROOT/fetch.tasks") == 1 ]] || result=1
    cmp "$RUN_ROOT/second.before" "$RUN_ROOT/state/repos/owner/second.state" || result=1
    [[ ! -f $RUN_ROOT/repos/owner/first.git/git-daemon-export-ok && -f $RUN_ROOT/repos/owner/second.git/git-daemon-export-ok ]] || result=1
    [[ -L $RUN_ROOT/repos/obsolete.git && -f $RUN_ROOT/config/managed-links/obsolete.git ]] || result=1
    [[ ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || result=1
    printf 'CLI multi %s status=%s elapsed_ms=%s fetches=%s result=%s\n' "$signal" "$status" "$((end-begin))" "$(wc -l < "$RUN_ROOT/fetch.tasks")" "$result"
    status=0
    gm_without_container_lease env -u GM_BOOT_GENERATION "$INSTALL_ROOT/git-mirror-sync.sh" --repo owner/second || status=$?
    [[ $status == 1 && $(tail -n 1 "$RUN_ROOT/fetch.tasks") == owner/second\ * && ! -e $RUN_ROOT/runtime/task ]] || result=1
    return "$result"
}

for signal in TERM INT; do
    CHECKS=$((CHECKS+1))
    if ( test_cli_multirepo_signal_stops_invocation "$signal" ); then printf '[PASS] CLI multi %s\n' "$signal"; else printf '[FAIL] CLI multi %s\n' "$signal"; FAILURES=$((FAILURES+1)); fi
done

for test in test_cli_checks_gate_before_network test_cli_transport_failure_is_supervised test_cli_term_joins_writer test_cli_sync_validates_live_generation test_legacy_export_cannot_bypass test_first_healthy_available_before_second_checked test_resume_cannot_clear_freeze test_startup_requires_live_owner test_offline_healthy_downloads test_startup_no_network_before_checks test_daemon_rejects_stale_gate test_resume_without_context_rejected test_bad_repository_keeps_other_available test_worker_failure_revokes_publication test_unknown_writer_blocks_startup test_startup_uses_delivered_find test_scheduler_stop_freezes test_frozen_worker_revokes_before_unlock test_entry_signal_only_records_stop test_check_failure_scope; do
    CHECKS=$((CHECKS+1))
    if ( "$test" ); then printf '[PASS] %s\n' "$test"; else printf '[FAIL] %s\n' "$test"; FAILURES=$((FAILURES+1)); fi
done
printf '启动恢复检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
