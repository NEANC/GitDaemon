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
