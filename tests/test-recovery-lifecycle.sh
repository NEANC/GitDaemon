#!/usr/bin/env bash
set -uo pipefail
umask 077
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/scripts/lib/repository-recovery.sh"
TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FAILURES=0

# 将真实损坏检查结果交给生命周期准入，核对普通操作与恢复操作的边界。
test_checked_health_gate() (
    local operation=$1 health=$2 oid status=0
    local -A state=([schema]=1 [repo]=owner/repo [generation]=1 [desired]=present [observed]=ready [published]=no [message]=unchecked) result=() checked=()
    export RUN_ROOT=$TEST_ROOT/$operation-$health
    mkdir -p "$RUN_ROOT/runtime" "$RUN_ROOT/repos/owner" || return 1
    gm_container_lease_acquire && gm_container_begin || return 1
    gm_parse_repos 'owner/repo' '' || return 1
    local dir=$RUN_ROOT/repos/owner/repo.git
    git init -q --bare "$dir" || return 1
    oid=$(printf 'missing\n' | git --git-dir="$dir" hash-object -w --stdin) || return 1
    git --git-dir="$dir" update-ref refs/tags/blob "$oid" || return 1
    rm "$dir/objects/${oid:0:2}/${oid:2}" || return 1
    gm_repo_state_commit_locked owner/repo state || return 1
    gm_begin_operation sync || return 1
    gm_repo_check_locked owner/repo "$dir" checked || return 1
    [[ ${checked[health]} == corrupt ]] || return 1
    gm_repo_state_read owner/repo state || return 1
    [[ ${state[schema]} == 2 && ${state[health]} == corrupt && ${state[message]} == corrupt ]] || return 1
    if [[ $health == recovery_required ]]; then
        state[health]=recovery_required
        state[message]=diagnostic
        gm_repo_state_commit_locked owner/repo state || return 1
    fi
    gm_task_run_locked owner/repo "$operation" result touch "$RUN_ROOT/written" || status=$?
    if [[ $operation == sync || $operation == gc ]]; then
        if (( status == 0 )); then gm_task_finish_locked result || true; return 1; fi
        [[ ${result[result]} == RECOVERY_REQUIRED && ! -e $RUN_ROOT/written && ! -e $RUN_ROOT/runtime/task && ! -e $RUN_ROOT/state/operations/owner/repo.state ]] || return 1
        [[ -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} ]]
    else
        (( status == 0 )) || return 1
        gm_task_finish_locked result || return 1
        [[ ${result[result]} == SUCCESS && -f $RUN_ROOT/written ]]
    fi
)

for health in corrupt recovery_required; do
    for operation in sync gc check recovery; do
        if test_checked_health_gate "$operation" "$health"; then
            printf '[PASS] %s %s\n' "$health" "$operation"
        else
            printf '[FAIL] %s %s\n' "$health" "$operation"
            FAILURES=$((FAILURES+1))
        fi
    done
done
printf 'checks=8 failures=%s\n' "$FAILURES"
(( FAILURES == 0 ))
