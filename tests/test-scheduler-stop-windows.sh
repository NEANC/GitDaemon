#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export ROOT WORK
cat > "$WORK/child" <<'CHILD'
#!/usr/bin/env bash
trap '' TERM INT
printf '%s\n' "$BASHPID" > "$WORK/child.pid"
sleep 3
printf 'finished\n' > "$WORK/finished"
CHILD
chmod 700 "$WORK/child"
bash -c '
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    gm_scheduler_freeze() { printf "frozen\n" > "$WORK/frozen"; }
    trap gm_scheduler_on_stop_signal TERM INT
    gm_scheduler_run_entry "$WORK/child" || true
    if [[ ! -f $WORK/finished ]]; then printf "EARLY_RETURN\n" > "$WORK/result"; exit 1; fi
    printf "JOINED\n" > "$WORK/result"
' &
driver=$!
for ((i=0; i<100; i++)); do
    [[ ! -f $WORK/child.pid ]] || break
    sleep 0.02
done
[[ -f $WORK/child.pid ]]
kill -TERM "$driver"
for ((i=0; i<100; i++)); do
    [[ ! -f $WORK/frozen ]] || break
    sleep 0.02
done
[[ -f $WORK/frozen ]]
kill -TERM "$driver" 2>/dev/null || true
status=0
wait "$driver" || status=$?
child=$(cat "$WORK/child.pid")
for ((i=0; i<200; i++)); do
    kill -0 "$child" 2>/dev/null || break
    sleep 0.02
done
cat "$WORK/result"
[[ $status == 0 && $(cat "$WORK/result") == JOINED ]]
printf '[PASS] 重复 TERM 不把中断的 wait 当成监督者退出\n'

failures=0
for freeze_status in 0 1; do
    export freeze_status
    bash -c '
        source "$ROOT/scripts/git-mirror-scheduler.sh"
        gm_scheduler_freeze() { return "$freeze_status"; }
        trap gm_scheduler_on_stop_signal TERM INT
        GM_SCHEDULER_STOP=1
        status=0
        gm_scheduler_run_entry bash -c "exit 0" || status=$?
        [[ $status != 0 && -z $GM_SCHEDULER_CHILD ]] || exit 1
        [[ $(trap -p TERM INT) == *gm_scheduler_on_stop_signal* ]] || exit 1
    ' || { printf '[FAIL] 停止状态收尾 freeze=%s\n' "$freeze_status"; failures=$((failures+1)); }
done

rm "$WORK/finished" "$WORK/child.pid" "$WORK/frozen" "$WORK/result"
bash -c '
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    gm_scheduler_freeze() { printf "frozen\n" > "$WORK/frozen"; return 1; }
    trap gm_scheduler_on_stop_signal TERM INT
    status=0
    gm_scheduler_run_entry "$WORK/child" || status=$?
    [[ -f $WORK/finished && $status != 0 && -z $GM_SCHEDULER_CHILD ]] || exit 1
    [[ $(trap -p TERM INT) == *gm_scheduler_on_stop_signal* ]] || exit 1
' &
driver=$!
for ((i=0; i<100; i++)); do
    [[ ! -f $WORK/child.pid ]] || break
    sleep 0.02
done
[[ -f $WORK/child.pid ]]
kill -TERM "$driver"
status=0
wait "$driver" || status=$?
sleep 3
if [[ $status == 0 ]]; then
    printf '[PASS] 冻结失败仍等待监督者真实退出\n'
else
    printf '[FAIL] 冻结失败未完整收尾\n'
    failures=$((failures+1))
fi
for boundary in handler entry hosts; do
    export boundary
    if bash -c '
        source "$ROOT/scripts/git-mirror-scheduler.sh"
        gm_scheduler_freeze() { return 0; }
        gm_scheduler_log() { :; }
        case $boundary in
            handler)
                kill() { printf "signal\n" >> "$WORK/handler-signal"; }
                GM_SCHEDULER_CHILD=999999 GM_SCHEDULER_CHILD_PGID=999999 GM_SCHEDULER_SLEEP_CHILD=999998
                gm_scheduler_on_stop_signal
                [[ $GM_SCHEDULER_STOP == 1 && ! -e $WORK/handler-signal ]]
                ;;
            entry)
                GM_SCHEDULER_STOP=1
                gm_scheduler_run_entry bash -c '\''printf started > "$WORK/stopped-entry"'\'' || true
                [[ ! -e $WORK/stopped-entry ]]
                ;;
            hosts)
                GM_SCHEDULER_STOP=1
                gm_scheduler_run_task hosts "$WORK/child" || true
                [[ ! -e $WORK/finished ]]
                ;;
        esac
    '; then
        printf '[PASS] 停止门边界 %s\n' "$boundary"
    else
        printf '[FAIL] 停止门边界 %s\n' "$boundary"
        failures=$((failures+1))
    fi
    rm -f "$WORK/finished"
done
cat > "$WORK/stubborn" <<'CHILD'
#!/usr/bin/env bash
trap '' TERM INT
printf '%s\n' "$BASHPID" > "$WORK/stubborn.pid"
sleep 12
CHILD
chmod 700 "$WORK/stubborn"
bash -c '
    source "$ROOT/scripts/git-mirror-scheduler.sh"
    INSTALL_ROOT=$ROOT/scripts
    gm_scheduler_freeze() { :; }
    trap gm_scheduler_on_stop_signal TERM INT
    status=0
    gm_scheduler_run_entry "$WORK/stubborn" || status=$?
    [[ $status != 0 && ${GM_SCHEDULER_UNSAFE-} == 1 && -n $GM_SCHEDULER_CHILD ]] || exit 1
    declare -A live=()
    gm_process_identity "$GM_SCHEDULER_CHILD" live || exit 1
    for field in pid start ppid pgid session; do
        [[ ${GM_SCHEDULER_CHILD_IDENTITY[$field]-} == "${live[$field]}" ]] || exit 1
    done
    [[ ${live[state]} != Z && ${live[state]} != X ]] || exit 1
' &
driver=$!
for ((i=0; i<100; i++)); do
    [[ ! -f $WORK/stubborn.pid ]] || break
    sleep 0.02
done
[[ -f $WORK/stubborn.pid ]]
SECONDS=0
kill -TERM "$driver"
status=0
wait "$driver" || status=$?
elapsed=$SECONDS
if [[ $status == 0 && $elapsed -lt 10 ]]; then
    printf '[PASS] 监督者超时保留身份并报告不安全 elapsed=%s\n' "$elapsed"
else
    printf '[FAIL] 监督者收尾没有预算或丢失身份 elapsed=%s status=%s\n' "$elapsed" "$status"
    failures=$((failures+1))
fi
sleep 12
cat > "$WORK/boundary-child" <<'CHILD'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
printf ready > "$WORK/boundary-ready"
for ((i=0; i<100; i++)); do sleep 0.05; done
printf expired > "$WORK/boundary-expired"
CHILD
chmod 700 "$WORK/boundary-child"
for boundary in entry hosts; do
    export boundary
    rm -f "$WORK/boundary-ready" "$WORK/boundary-expired"
    if bash -c '
        source "$ROOT/scripts/git-mirror-scheduler.sh"
        source "$ROOT/scripts/lib/lifecycle.sh"
        gm_scheduler_log() { :; }
        gm_scheduler_freeze() { gm_monotonic_ms frozen; }
        trap gm_scheduler_on_stop_signal TERM INT
        armed=no injected=no frozen=0 signaled=0
        inject_boundary() {
            if [[ $armed == yes && $injected == no ]]; then
                injected=yes
                while [[ ! -e $WORK/boundary-ready ]]; do sleep 0.01; done
                gm_monotonic_ms signaled
                kill -TERM "$BASHPID"
            elif [[ -n $GM_SCHEDULER_CHILD && $BASH_COMMAND == "(( GM_SCHEDULER_STOP == 0 ))" ]]; then
                armed=yes
            fi
            return 0
        }
        set -T
        trap inject_boundary DEBUG
        status=0
        if [[ $boundary == entry ]]; then
            gm_scheduler_run_entry "$WORK/boundary-child" || status=$?
        else
            gm_scheduler_run_task hosts "$WORK/boundary-child" || status=$?
        fi
        trap - DEBUG
        printf "boundary=%s injected=%s freeze_ms=%s status=%s\n" "$boundary" "$injected" "$((frozen-signaled))" "$status"
        [[ $injected == yes && $status != 0 && $frozen -ge $signaled && $((frozen-signaled)) -lt 1000 && ! -e $WORK/boundary-expired && -z $GM_SCHEDULER_CHILD ]]
    '; then
        printf '[PASS] STOP判断后等待前TERM %s\n' "$boundary"
    else
        printf '[FAIL] STOP判断后等待前TERM %s\n' "$boundary"
        failures=$((failures+1))
    fi
done
for boundary in entry hosts; do
    for expected in 0 23; do
        export boundary expected
        if bash -c '
            source "$ROOT/scripts/git-mirror-scheduler.sh"
            gm_scheduler_log() { :; }
            printf "#!/usr/bin/env bash\nsleep 0.1\nexit %s\n" "$expected" > "$WORK/normal-child"
            chmod 700 "$WORK/normal-child"
            status=0
            if [[ $boundary == entry ]]; then
                gm_scheduler_run_entry "$WORK/normal-child" || status=$?
            else
                gm_scheduler_run_task hosts "$WORK/normal-child" || status=$?
            fi
            [[ $status == "$expected" && -z $GM_SCHEDULER_CHILD ]]
        '; then
            printf '[PASS] 正常等待退出码 %s=%s\n' "$boundary" "$expected"
        else
            printf '[FAIL] 正常等待退出码 %s=%s\n' "$boundary" "$expected"
            failures=$((failures+1))
        fi
    done
done
printf '停止窗口失败数：%s\n' "$failures"
[[ $failures == 0 ]]
