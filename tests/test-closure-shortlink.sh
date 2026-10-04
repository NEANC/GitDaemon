#!/usr/bin/env bash
# 对短链接更新注入普通 I/O 失败及进程崩溃，验证回滚与重跑恢复。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-sync.sh"
[[ $UID != 0 && $EUID != 0 ]] || exit 1
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
failed=0
# 准备真实发布目录和有效的旧受管理链接。
setup() {
    RUN_ROOT=$work/$1
    mkdir -p "$RUN_ROOT/repos/old/repo.git" "$RUN_ROOT/repos/new/repo.git" "$RUN_ROOT/runtime" "$RUN_ROOT/logs"
    chmod 700 "$RUN_ROOT" "$RUN_ROOT/runtime"
    : > "$RUN_ROOT/repos/old/repo.git/git-daemon-export-ok"
    : > "$RUN_ROOT/repos/new/repo.git/git-daemon-export-ok"
    LOG_FILE=$RUN_ROOT/logs/sync.log
    gm_create_short_link "$RUN_ROOT" old/repo shortcut || return 1
}
# 记录发布失败必须恢复链接与记录到完整旧状态。
io_failure() {
    setup io || return 1
    mv() {
        if [[ ${*: -1} == "$RUN_ROOT/config/managed-links/shortcut.git" && ! -f $RUN_ROOT/injected ]]; then
            : > "$RUN_ROOT/injected"
            return 1
        fi
        command mv "$@"
    }
    if gm_create_short_link "$RUN_ROOT" new/repo shortcut; then return 1; fi
    [[ $(readlink "$RUN_ROOT/repos/shortcut.git") == old/repo.git ]] || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/shortcut.git" || return 1
    gm_create_short_link "$RUN_ROOT" new/repo shortcut || return 1
    [[ $(readlink "$RUN_ROOT/repos/shortcut.git") == new/repo.git ]] || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/shortcut.git"
}
# 在链接替换后、记录替换前杀死写入者。
crash_writer() {
    (
        mv() {
            if [[ ${*: -1} == "$RUN_ROOT/config/managed-links/shortcut.git" ]]; then kill -KILL "$BASHPID"; fi
            command mv "$@"
        }
        gm_create_short_link "$RUN_ROOT" new/repo shortcut
    ) >/dev/null 2>&1 &
    local writer=$! status=0
    wait "$writer" 2>/dev/null || status=$?
    [[ $status == 137 ]]
}
# 下次发布须自动恢复再完成更新。
crash_recovery() {
    setup crash || return 1
    crash_writer || return 1
    gm_create_short_link "$RUN_ROOT" new/repo shortcut || return 1
    [[ $(readlink "$RUN_ROOT/repos/shortcut.git") == new/repo.git ]] || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/shortcut.git"
}
# 意图写入中断不能污染正式日志，旧对象保持可重跑。
journal_write_failure() {
    setup journal || return 1
    printf() {
        if [[ $1 == 'FORMAT=1\nOLD=%s\nNEW=%s\n' && ! -f $RUN_ROOT/injected ]]; then
            : > "$RUN_ROOT/injected"
            builtin printf 'FORMAT=1\nOLD='
            return 1
        fi
        builtin printf "$@"
    }
    if gm_create_short_link "$RUN_ROOT" new/repo shortcut; then return 1; fi
    [[ $(readlink "$RUN_ROOT/repos/shortcut.git") == old/repo.git ]] || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/shortcut.git" || return 1
    gm_create_short_link "$RUN_ROOT" new/repo shortcut || return 1
    gm_validate_managed_link "$RUN_ROOT" "$RUN_ROOT/repos/shortcut.git"
}
# 崩溃后删除映射也必须先恢复再清理，不能留下不可管理的新链接。
crash_then_prune() {
    setup prune || return 1
    crash_writer || return 1
    GM_LINK_NAMES=()
    gm_prune_short_links "$RUN_ROOT" || return 1
    [[ ! -e $RUN_ROOT/repos/shortcut.git && ! -L $RUN_ROOT/repos/shortcut.git ]] || return 1
    [[ ! -e $RUN_ROOT/runtime/shortlink-shortcut.pending ]] || return 1
    [[ ! -e $RUN_ROOT/config/managed-links/shortcut.git ]]
}
# pending 恢复不得删除后来替换的外来链接或普通对象。
foreign_pending_objects() {
    setup foreign || return 1
    crash_writer || return 1
    rm -- "$RUN_ROOT/repos/shortcut.git" || return 1
    ln -s unrelated/repo.git "$RUN_ROOT/repos/shortcut.git" || return 1
    if gm_recover_short_link "$RUN_ROOT" shortcut; then return 1; fi
    [[ $(readlink "$RUN_ROOT/repos/shortcut.git") == unrelated/repo.git ]] || return 1
    rm -- "$RUN_ROOT/repos/shortcut.git" || return 1
    printf sentinel > "$RUN_ROOT/repos/shortcut.git"
    if gm_recover_short_link "$RUN_ROOT" shortcut; then return 1; fi
    [[ $(<"$RUN_ROOT/repos/shortcut.git") == sentinel ]]
}

# 首次创建记录失败后不得残留链接或错误记录。
initial_record_failure() {
    setup initial || return 1
    mkdir -p "$RUN_ROOT/repos/fresh/repo.git"
    : > "$RUN_ROOT/repos/fresh/repo.git/git-daemon-export-ok"
    mv() {
        if [[ ${*: -1} == "$RUN_ROOT/config/managed-links/fresh.git" ]]; then return 1; fi
        command mv "$@"
    }
    if gm_create_short_link "$RUN_ROOT" new/repo fresh; then return 1; fi
    [[ ! -e $RUN_ROOT/repos/fresh.git && ! -L $RUN_ROOT/repos/fresh.git ]] || return 1
    [[ ! -e $RUN_ROOT/config/managed-links/fresh.git && ! -e $RUN_ROOT/runtime/shortlink-fresh.pending ]]
}

# 各场景隔离函数替身，仅统计真实行为断言。
check() {
    if ( "$1" ); then printf 'PASS %s\n' "$1";
    else printf 'FAIL %s\n' "$1"; failed=$((failed+1)); fi
}
check io_failure
check crash_recovery
check journal_write_failure
check crash_then_prune
check foreign_pending_objects
check initial_record_failure
printf 'checks=6 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
