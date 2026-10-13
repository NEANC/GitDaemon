#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT
export ROOT WORK

# 在真实启动指令前注入信号，业务必须仍被放行握手阻挡。
test_launch_boundary() (
    local signal=$1 boundary=${2:-launch} injected=no owner=$BASHPID status=0
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    RUN_ROOT=$WORK/$boundary-$signal
    mkdir -p "$RUN_ROOT/runtime"
    export RUN_ROOT
    gm_scheduler_log() { :; }
    gm_scheduler_freeze() { : > "$RUN_ROOT/frozen"; }
    trap gm_scheduler_on_stop_signal TERM INT
    inject() {
        if [[ $BASHPID == "$owner" && $injected == no ]] &&
            { [[ $boundary == launch && $BASH_COMMAND == setsid* ]] ||
              [[ $boundary == gate && $BASH_COMMAND == printf* && $BASH_COMMAND == *'>&"$gate"'* ]]; }; then
            injected=yes
            kill -"$signal" "$BASHPID"
        fi
        return 0
    }
    printf '#!/usr/bin/env bash\nprintf written > "$RUN_ROOT/written"\n' > "$RUN_ROOT/child"
    chmod 700 "$RUN_ROOT/child"
    set -T
    trap inject DEBUG
    gm_scheduler_run_task hosts "$RUN_ROOT/child" || status=$?
    trap - DEBUG
    printf '%s signal=%s injected=%s status=%s written=%s\n' "$boundary" "$signal" "$injected" "$status" "$([[ -e $RUN_ROOT/written ]] && printf yes || printf no)"
    [[ $injected == yes && $status != 0 && ! -e $RUN_ROOT/written ]]
)

# 组长退出后仍检查真实子孙，不能提前成功或启动下一轮。
test_orphan() (
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    source "$ROOT/scripts/lib/lifecycle.sh"
    RUN_ROOT=$WORK/orphan
    mkdir -p "$RUN_ROOT/runtime"
    export RUN_ROOT
    gm_scheduler_log() { :; }
    gm_scheduler_freeze() { : > "$RUN_ROOT/frozen"; }
    cat > "$RUN_ROOT/child" <<'CHILD'
#!/usr/bin/env bash
printf '%s\n' "$BASHPID" > "$RUN_ROOT/group"
(trap '' TERM INT; sleep 12) &
sleep 0.2
CHILD
    chmod 700 "$RUN_ROOT/child"
    local status=0 alive=0 group
    gm_scheduler_run_task hosts "$RUN_ROOT/child" || status=$?
    group=$(cat "$RUN_ROOT/group")
    gm_task_group_alive "$group" "$group" || alive=$?
    if (( alive == 0 )); then kill -KILL -- "-$group" 2>/dev/null || true; fi
    printf 'orphan status=%s alive=%s stop=%s\n' "$status" "$alive" "$GM_SCHEDULER_STOP"
    [[ $status != 0 && $alive == 1 && $GM_SCHEDULER_STOP == 1 && -e $RUN_ROOT/frozen ]]
)

# 身份未知或回收失败必须保留记录并阻止再次派发。
test_unsafe() (
    local mode=$1 status=0 pid group
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    source "$ROOT/scripts/lib/lifecycle.sh"
    RUN_ROOT=$WORK/$mode
    mkdir -p "$RUN_ROOT/runtime"
    export RUN_ROOT
    gm_scheduler_log() { :; }
    gm_scheduler_freeze() { : > "$RUN_ROOT/frozen"; }
    if [[ $mode == unknown ]]; then
        gm_scheduler_task_group() { sleep 0.1; return 1; }
    else
        gm_scheduler_wait_group_gone() { return 1; }
    fi
    cat > "$RUN_ROOT/child" <<'CHILD'
#!/usr/bin/env bash
trap '' TERM INT
printf '%s\n' "$BASHPID" > "$RUN_ROOT/group"
sleep 3
CHILD
    chmod 700 "$RUN_ROOT/child"
    trap gm_scheduler_on_stop_signal TERM INT
    local owner=$BASHPID injected=no
    inject() {
        if [[ $BASHPID == "$owner" && $injected == no && -n $GM_SCHEDULER_CHILD && $BASH_COMMAND == '(( GM_SCHEDULER_STOP == 0 ))' ]]; then
            injected=yes
            kill -TERM "$BASHPID"
        fi
        return 0
    }
    set -T
    trap inject DEBUG
    gm_scheduler_run_task hosts "$RUN_ROOT/child" || status=$?
    trap - DEBUG
    pid=$GM_SCHEDULER_CHILD group=$GM_SCHEDULER_CHILD_PGID
    local result=0
    [[ $status != 0 && ${GM_SCHEDULER_UNSAFE-} == 1 && -n $pid && -n ${GM_SCHEDULER_CHILD_IDENTITY[start]-} ]] || result=1
    if [[ $mode == unknown ]]; then [[ ! -e $RUN_ROOT/group ]] || result=1; fi
    if [[ $mode == timeout ]]; then
        local -A live=()
        local field
        gm_process_identity "$pid" live || result=1
        for field in pid start ppid pgid session; do
            [[ ${GM_SCHEDULER_CHILD_IDENTITY[$field]-} == "${live[$field]-}" ]] || result=1
        done
    fi
    gm_scheduler_run_task hosts "$RUN_ROOT/child" || true
    [[ $GM_SCHEDULER_CHILD == "$pid" ]] || result=1
    printf 'unsafe mode=%s status=%s unsafe=%s retained=%s result=%s\n' "$mode" "$status" "${GM_SCHEDULER_UNSAFE-}" "$pid" "$result"
    if [[ -s $RUN_ROOT/group ]]; then group=$(cat "$RUN_ROOT/group"); kill -KILL -- "-$group" 2>/dev/null || true; fi
    if [[ -n $pid ]]; then wait "$pid" 2>/dev/null || true; fi
    return "$result"
)

failures=0
for signal in TERM INT; do
    test_launch_boundary "$signal" || failures=$((failures+1))
    test_launch_boundary "$signal" gate || failures=$((failures+1))
done
test_orphan || failures=$((failures+1))
for mode in unknown timeout; do
    test_unsafe "$mode" || failures=$((failures+1))
done
printf 'scheduler hosts gate failures=%s\n' "$failures"
[[ $failures == 0 ]]
