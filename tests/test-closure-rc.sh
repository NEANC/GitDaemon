#!/usr/bin/env bash
# 确定性验证实例 rc.conf 最终赋值语义与尾部边界。
set -uo pipefail
source "$(dirname "$0")/../scripts/lib/foundation.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
failed=0
# 检查断言并累计失败，保留每个边界的原始输出。
check() { if "$@"; then printf 'PASS %s\n' "$*"; else printf 'FAIL %s\n' "$*"; failed=$((failed + 1)); fi; }
# 有效重复赋值只能由最后一条决定实际白名单。
last_assignment() {
    printf 'rc_env_allow="%s"\nrc_env_allow="REPOS"\n' "$(gm_required_env_allow)" > "$work/rc.conf"
    gm_ensure_instance_rc_conf "$work/rc.conf" || return 1
    local actual
    actual=$(sh -c '. "$1"; printf "%s" "$rc_env_allow"' sh "$work/rc.conf")
    [[ " $actual " == *' GIT_PORT '* ]]
}
# 闭引号尾部命令不能被接受为有效赋值。
reject_trailing() {
    printf 'rc_env_allow="REPOS"; echo unexpected\n' > "$work/rc.conf"
    ! gm_read_rc_env_allow "$work/rc.conf"
}
# 注释是有效尾部，未引号的多词值不是 shell 赋值。
accept_comment() {
    printf 'rc_env_allow="REPOS" # comment\n' > "$work/rc.conf"
    [[ $(gm_read_rc_env_allow "$work/rc.conf") == REPOS ]]
}
# 拒绝未引号的多词值，避免把 shell 命令误认为白名单。
reject_unquoted_words() {
    printf 'rc_env_allow=REPOS GIT_PORT\n' > "$work/rc.conf"
    ! gm_read_rc_env_allow "$work/rc.conf"
}
# boot 运行级中的交付服务必须在引导前被识别。
boot_registration() {
    XDG_CONFIG_HOME=$work/config
    mkdir -p "$XDG_CONFIG_HOME/rc/runlevels/boot"
    ln -s /missing "$XDG_CONFIG_HOME/rc/runlevels/boot/git-daemon"
    gm_instance_default_runlevel_has_delivered_service
}
# 自定义默认运行级按最终字面赋值检查，不执行配置中的命令。
custom_registration() {
    XDG_CONFIG_HOME=$work/custom
    mkdir -p "$XDG_CONFIG_HOME/rc/runlevels/night"
    printf 'rc_default_runlevel=default\nrc_default_runlevel="night" # selected\n' > "$XDG_CONFIG_HOME/rc/rc.conf"
    ln -s /missing "$XDG_CONFIG_HOME/rc/runlevels/night/git-mirror-sync"
    gm_instance_default_runlevel_has_delivered_service
}
# 动态默认运行级无法静态确认，必须拒绝引导。
dynamic_registration() {
    XDG_CONFIG_HOME=$work/dynamic
    mkdir -p "$XDG_CONFIG_HOME/rc"
    printf 'rc_default_runlevel=$(touch "%s/executed")\n' "$work" > "$XDG_CONFIG_HOME/rc/rc.conf"
    gm_instance_default_runlevel_has_delivered_service && [[ ! -e $work/executed ]]
}
check last_assignment
check reject_trailing
check accept_comment
check reject_unquoted_words
check boot_registration
check custom_registration
check dynamic_registration
printf 'checks=7 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
