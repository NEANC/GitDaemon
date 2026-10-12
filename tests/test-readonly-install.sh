#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-readonly.XXXXXXXX") || exit 1
FAILURES=0
CHECKS=0
source "$ROOT/scripts/lib/foundation.sh"
source "$ROOT/scripts/uninstall-git-mirror.sh"

# 仅清理本测试创建的临时目录，并恢复测试目录自身的写权限。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        if [[ -d $TEST_ROOT/program ]]; then chmod u+w -- "$TEST_ROOT/program"; fi
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

# 用子 Shell 隔离接口边界桩，避免影响后续用例。
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

# 读取模式必须要求目录已存在，不能以可写父目录代替安装目录。
read_missing_directory_rejected() {
    local output status=0
    output=$(gm_validate_path "$TEST_ROOT/missing-program" read 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 读取目录不存在、身份不匹配或不可访问' ]] || return 1
    [[ ! -e $TEST_ROOT/missing-program ]]
}

# 读取模式必须要求普通文件已存在，不应接受尚未安装的记录。
read_missing_file_rejected() {
    local output status=0
    output=$(gm_validate_file "$TEST_ROOT/missing-record" read 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 读取文件不存在或不可读' ]] || return 1
    [[ ! -e $TEST_ROOT/missing-record ]]
}

# 模式必须来自固定枚举，拼写错误不能变成隐式放宽校验。
invalid_mode_rejected() {
    local output status=0
    output=$(gm_validate_path "$TEST_ROOT" unknown 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 不支持的路径访问模式' ]] || return 1
    status=0
    output=$(gm_validate_file "$TEST_ROOT/missing-record" unknown 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 不支持的文件访问模式' ]] || return 1
    [[ ! -e $TEST_ROOT/missing-record ]]
}

# 只读目录中的记录可以读取；Windows 的通过不证明 Linux 挂载权限语义。
read_existing_program() {
    mkdir -- "$TEST_ROOT/program" || return 1
    printf '%s\n' 'FORMAT=1' > "$TEST_ROOT/program/installation.conf"
    chmod 555 -- "$TEST_ROOT/program" || return 1
    gm_validate_path "$TEST_ROOT/program" read || return 1
    gm_validate_file "$TEST_ROOT/program/installation.conf" read || return 1
    [[ $(<"$TEST_ROOT/program/installation.conf") == FORMAT=1 ]]
}

# 安装记录读取只请求读取边界，不要求程序父目录可写。
record_uses_read_boundary() {
    local record=$TEST_ROOT/record.conf
    printf '%s\n' 'FORMAT=1' > "$record"
    # 文件访问模式边界桩；仍由真实读取逻辑比较文件内容。
    gm_validate_file() { [[ $1 == "$record" && ${2-} == read ]]; }
    gm_match_record "$record" 'FORMAT=1'
}

# 实例路径预检对程序根使用读取模式，对运行根保留写入要求。
instance_uses_separate_modes() {
    local install=$TEST_ROOT/immutable run=$TEST_ROOT/instance
    # 路径接口边界桩，不冒充真实只读挂载验证。
    gm_validate_path() {
        if [[ $1 == "$install" ]]; then [[ ${2-} == read ]]; else [[ ${2-write} == write ]]; fi
    }
    # 文件接口边界桩仅接受固定的运行期配置和记录位置。
    gm_validate_file() {
        [[ $1 == "$run/config/mirror.env" || $1 == "$run/config/installation.conf" ]]
    }
    gm_validate_instance_paths "$run" "$install"
}

# 服务停止读取独立程序层的服务定义，不应要求修改服务定义目录。
service_uses_read_boundary() {
    local INSTALL_ROOT=$TEST_ROOT/service-program
    mkdir -p -- "$INSTALL_ROOT/openrc" || return 1
    printf '%s\n' '#!/sbin/openrc-run' > "$INSTALL_ROOT/openrc/git-daemon"
    chmod 755 -- "$INSTALL_ROOT/openrc/git-daemon" || return 1
    # 文件访问模式边界桩，验证停止操作仅请求读取服务文件。
    gm_validate_file() { [[ $1 == "$INSTALL_ROOT/openrc/git-daemon" && ${2-} == read ]]; }
    # 服务边界桩只允许本临时安装的用户模式停止命令。
    rc-service() { [[ $# == 3 && $1 == --user && $2 == -e && $3 == "$INSTALL_ROOT/openrc/git-daemon" ]] || [[ $# == 3 && $1 == --user && $2 == "$INSTALL_ROOT/openrc/git-daemon" && $3 == stop ]]; }
    gm_stop_instance_service git-daemon
}

# 初始化只增加缺失目录，程序层及已有数据均不可覆盖。
test_upgrade_preserves_volume_state() {
    source "$ROOT/scripts/deploy-git-mirror.sh"
    local work=$TEST_ROOT/upgrade name
    gm_check_platform() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    mkdir -p "$work" || return 1
    gm_deploy_main --install --install-root "$work/install" || return 1
    for name in git-mirror-gc.sh lib/gc-state.sh lib/gc-schedule.sh openrc/git-mirror-gc; do
        [[ -x $work/install/$name ]] || return 1
    done
    export REPOS=a/one SHORT_LINKS=
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" || return 1
    printf 'TZ=UTC\n' > "$work/run/config/mirror.env"
    for name in state staging quarantine; do
        [[ -d $work/run/$name ]] || return 1
        printf '%s\n' "$name" > "$work/run/$name/sentinel"
    done
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" || return 1
    [[ $(<"$work/run/config/mirror.env") == TZ=UTC ]] || return 1
    for name in state staging quarantine; do [[ $(<"$work/run/$name/sentinel") == "$name" ]] || return 1; done
    gm_load_service_capabilities "$work/install" || return 1
    [[ $GM_GC_CAPABILITY == present ]]
}

# 显式删除仓库不得连带删除恢复数据，并向操作者说明保留项。
test_uninstall_does_not_expand_deletion() {
    source "$ROOT/scripts/deploy-git-mirror.sh"
    local work=$TEST_ROOT/uninstall name output
    gm_check_platform() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    mkdir -p "$work" || return 1
    gm_deploy_main --install --install-root "$work/install" || return 1
    export REPOS=a/one SHORT_LINKS=
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" || return 1
    for name in state staging quarantine; do
        mkdir -p "$work/run/$name"
        printf '%s\n' "$name" > "$work/run/$name/sentinel"
    done
    source "$work/install/uninstall-git-mirror.sh"
    gm_check_platform() { return 0; }
    rc-service() { return 0; }
    output=$(gm_uninstall_main --run-root "$work/run" --delete-repos --yes) || return 1
    [[ ! -e $work/run/repos ]] || return 1
    for name in state staging quarantine; do
        [[ $(<"$work/run/$name/sentinel") == "$name" && $output == *"$name"* ]] || return 1
    done
    [[ $output == *另行确认* ]]
}

# 未知状态格式不得通过初始化，明确旧版迁移必须保持周期字段。
test_upgrade_schema_contract() {
    source "$ROOT/scripts/deploy-git-mirror.sh"
    source "$ROOT/scripts/lib/repository-recovery.sh"
    local work=$TEST_ROOT/schema status=0
    local -A calendar=()
    gm_check_platform() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    mkdir -p "$work" || return 1
    gm_deploy_main --install --install-root "$work/install" || return 1
    export REPOS=a/one SHORT_LINKS=
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" || return 1
    mkdir -p "$work/run/state/gc/a"
    printf 'schema=999\nrepo=a/one\n' > "$work/run/state/gc/a/one.state"
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" >/dev/null 2>&1 || status=$?
    [[ $status != 0 && $(<"$work/run/state/gc/a/one.state") == $'schema=999\nrepo=a/one' ]] || return 1
    gm_gc_init 2026-01-01 UTC calendar || return 1
    calendar[schema]=1 calendar[repo]=a/one calendar[generation]=1 calendar[identity]=1-2
    calendar[operation_id]=none calendar[reason]=none calendar[write_blocked]=no calendar[resumed_boot]=none calendar[log]=none
    : > "$work/run/state/gc/a/one.state"
    local key
    for key in "${!calendar[@]}"; do printf '%s=%s\n' "$key" "${calendar[$key]}" >> "$work/run/state/gc/a/one.state"; done
    gm_deploy_main --init --install-root "$work/install" --run-root "$work/run" || return 1
    grep -qx schema=2 "$work/run/state/gc/a/one.state" || return 1
    gm_gc_state_read a/one calendar || return 1
    [[ ${calendar[anchor_date]} == 2026-01-01 && ${calendar[next_due_date]} == 2026-01-15 && ${calendar[failed_identity]} == none ]]
}

check 'test_upgrade_schema_contract' test_upgrade_schema_contract
check 'test_upgrade_preserves_volume_state' test_upgrade_preserves_volume_state
check 'test_uninstall_does_not_expand_deletion' test_uninstall_does_not_expand_deletion
check '读取模式拒绝缺失的安装目录' read_missing_directory_rejected
check '读取模式拒绝缺失的安装记录' read_missing_file_rejected
check '路径与文件检查拒绝未知访问模式' invalid_mode_rejected
check '读取现存只读程序目录及记录（非只读挂载集成）' read_existing_program
check '安装记录使用读取边界（接口桩）' record_uses_read_boundary
check '程序根和运行根分别使用读写边界（接口桩）' instance_uses_separate_modes
check '服务停止仅请求读取安装文件（接口桩）' service_uses_read_boundary
printf '只读安装检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
