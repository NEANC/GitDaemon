#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/.repository-state-test.XXXXXXXX") || exit 1
FAILURES=0
CHECKS=0
export MSYS=winsymlinks:sys
unset GM_STATE_TEST_FAULT
trap 'rm -rf -- "$TEST_ROOT"' EXIT

source "$ROOT/scripts/lib/foundation.sh"
source "$ROOT/scripts/lib/repository-state.sh"

sync() {
    local path=${!#}
    if [[ -f $path ]]; then
        return 0
    fi
    command sync "$@"
}

check() {
    local label=$1
    shift
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

roundtrip() {
    local root=$TEST_ROOT/roundtrip repo=owner/repo
    local -A state=() loaded=()
    mkdir -p -- "$root" || return 1
    state[schema]=1
    state[repo]=$repo
    state[generation]=7
    state[desired]=present
    state[observed]=ready
    state[published]=yes
    state[message]=initial-sync
    RUN_ROOT=$root
    gm_repo_state_commit_locked "$repo" state || return 1
    gm_repo_state_read "$repo" loaded || return 1
    [[ ${loaded[repo]} == owner/repo && ${loaded[generation]} == 7 && ${loaded[desired]} == present && ${loaded[observed]} == ready && ${loaded[published]} == yes && ${loaded[message]} == initial-sync ]]
}

reject_symlink_and_duplicate_key() {
    local root=$TEST_ROOT/reject repo=owner/repo status=0
    local -A loaded=()
    mkdir -p -- "$root/state/repos/owner" || return 1
    printf '%s\n' 'schema=1' 'repo=owner/repo' 'repo=owner/repo' 'generation=1' 'desired=present' 'observed=ready' 'published=yes' 'message=x' > "$root/state/repos/owner/repo.state"
    RUN_ROOT=$root
    gm_repo_state_read "$repo" loaded >/dev/null 2>&1 && return 1
    rm -- "$root/state/repos/owner/repo.state" || return 1
    printf '%s\n' 'schema=1' 'repo=owner/repo' 'generation=1' 'desired=present' 'observed=ready' 'published=yes' 'message=x' > "$root/state/repos/owner/repo.state"
    rm -- "$root/state/repos/owner/repo.state" || return 1
    ln -s -- link.state "$root/state/repos/owner/repo.state" || return 1
    printf '%s\n' 'schema=1' 'repo=owner/repo' 'generation=1' 'desired=present' 'observed=ready' 'published=yes' 'message=x' > "$root/state/repos/owner/link.state"
    gm_repo_state_read "$repo" loaded >/dev/null 2>&1 && return 1
    return 0
}

reject_unknown_fields() {
    local root=$TEST_ROOT/unknown repo=owner/repo
    local -A loaded=() state=()
    mkdir -p -- "$root/state/repos/owner" || return 1
    printf '%s\n' 'schema=1' 'repo=owner/repo' 'generation=1' 'desired=present' 'observed=ready' 'published=yes' 'message=x' 'extra=value' > "$root/state/repos/owner/repo.state"
    RUN_ROOT=$root
    gm_repo_state_read "$repo" loaded >/dev/null 2>&1 && return 1
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=x state[extra]=value
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    return 0
}

commit_fault_keeps_old_record() {
    local root=$TEST_ROOT/fault repo=owner/repo before after fault
    local -A state=()
    mkdir -p -- "$root" || return 1
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=old
    RUN_ROOT=$root
    gm_repo_state_commit_locked "$repo" state || return 1
    before=$(<"$root/state/repos/owner/repo.state") || return 1
    for fault in write sync rename; do
        state[generation]=2 state[message]=new
        export GM_STATE_TEST_FAULT=$fault
        gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
        unset GM_STATE_TEST_FAULT
        after=$(<"$root/state/repos/owner/repo.state") || return 1
        [[ $after == "$before" ]] || return 1
    done
    state[generation]=2 state[message]=new
    export GM_STATE_TEST_FAULT=directory-sync
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    unset GM_STATE_TEST_FAULT
    after=$(<"$root/state/repos/owner/repo.state") || return 1
    [[ $after != "$before" && $after == *'generation=2'* && $after == *'message=new'* ]] || return 1
    return 0
}

directory_sync_is_indeterminate() {
    local root=$TEST_ROOT/indeterminate repo=owner/repo status=0
    local -A state=()
    mkdir -p -- "$root" || return 1
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=old
    RUN_ROOT=$root
    gm_repo_state_commit_locked "$repo" state || return 1
    state[generation]=2 state[message]=new
    export GM_STATE_TEST_FAULT=directory-sync
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 || status=$?
    unset GM_STATE_TEST_FAULT
    [[ $status == 2 && $(<"$root/state/repos/owner/repo.state") == *'generation=2'* ]]
}

repository_and_operation_directories_are_independent() {
    local root=$TEST_ROOT/independent repo=owner/repo
    local -A state=()
    mkdir -p -- "$root" || return 1
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=x
    RUN_ROOT=$root
    gm_operation_commit_locked "$repo" state || return 1
    [[ ! -e $root/state/repos && -f $root/state/operations/owner/repo.state ]]
}

value_grammar_is_consistent() {
    local root=$TEST_ROOT/value-grammar repo=owner/repo
    local -A state=() loaded=()
    mkdir -p -- "$root" || return 1
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]='tag#fragment'
    RUN_ROOT=$root
    gm_repo_state_commit_locked "$repo" state || return 1
    gm_repo_state_read "$repo" loaded || return 1
    [[ ${loaded[message]} == 'tag#fragment' ]] || return 1
    state[message]='bad=value'
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    state[message]=x state[schema]=2
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    state[schema]=1 state[desired]=invalid
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    return 0
}

reject_unsafe_parent_and_file() {
    local root=$TEST_ROOT/unsafe repo=owner/repo outside=$TEST_ROOT/outside
    local -A state=() loaded=()
    mkdir -p -- "$root/state" "$outside" || return 1
    ln -s -- "$outside" "$root/state/repos" || return 1
    RUN_ROOT=$root
    state[schema]=1 state[repo]=$repo state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=x
    gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    rm -- "$root/state/repos" || return 1
    mkdir -p -- "$root/state/repos/owner" || return 1
    chmod 555 "$root/state/repos/owner" || return 1
    local mode
    mode=$(stat -c %a -- "$root/state/repos/owner") || return 1
    if [[ $mode == 555 ]]; then
        gm_repo_state_commit_locked "$repo" state >/dev/null 2>&1 && return 1
    fi
    chmod 755 "$root/state/repos/owner" || return 1
    printf sentinel > "$outside/file" || return 1
    ln -- "$outside/file" "$root/state/repos/owner/repo.state" || return 1
    [[ $(stat -c %h -- "$root/state/repos/owner/repo.state") == 2 ]] || return 1
    gm_repo_state_read "$repo" loaded >/dev/null 2>&1 && return 1
    return 0
}

reject_invalid_repo_and_create_directories() {
    local root=$TEST_ROOT/invalid
    local -A state=()
    mkdir -p -- "$root" || return 1
    RUN_ROOT=$root
    state[schema]=1 state[repo]=../escape state[generation]=1 state[desired]=present state[observed]=ready state[published]=yes state[message]=x
    gm_repo_state_commit_locked ../escape state >/dev/null 2>&1 && return 1
    state[repo]=owner/repo
    gm_repo_state_commit_locked owner/repo state || return 1
    [[ -f $root/state/repos/owner/repo.state && ! -e $root/state/operations ]]
}

check roundtrip roundtrip
check reject_symlink_and_duplicate_key reject_symlink_and_duplicate_key
check reject_unknown_fields reject_unknown_fields
check commit_fault_keeps_old_record commit_fault_keeps_old_record
check directory_sync_is_indeterminate directory_sync_is_indeterminate
check repository_and_operation_directories_are_independent repository_and_operation_directories_are_independent
check value_grammar_is_consistent value_grammar_is_consistent
check reject_unsafe_parent_and_file reject_unsafe_parent_and_file
check reject_invalid_repo_and_create_directories reject_invalid_repo_and_create_directories

printf 'checks=%s failures=%s\n' "$CHECKS" "$FAILURES"
(( FAILURES == 0 ))
