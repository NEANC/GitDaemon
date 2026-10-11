#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-foundation.XXXXXXXX") || exit 1
FAILURES=0
CHECKS=0
# Git Bash 需要真实符号链接表示，初始化登记链接的行为才与 Alpine 一致。
export MSYS=winsymlinks:sys

# 仅清理本测试通过 mktemp 创建的目录。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

if [[ -f $ROOT/scripts/lib/foundation.sh ]]; then
    source "$ROOT/scripts/lib/foundation.sh"
fi

# 同步入口加载时即声明空配置数组，再由 gm_load_config 填充；
# 直接调用凭据 helper 的夹具须复现该前置状态，避免 nounset 下数组下标按算术求值。
declare -A GM_CONFIG=()

# 运行环境只带 busybox 的 sed 小程序而没有独立 sed 可执行入口；
# 在测试私有目录内提供等价入口，保持断言不变且不扩大生产镜像依赖。
if ! command -v sed >/dev/null 2>&1; then
    TEST_TOOLS=$TEST_ROOT/tools
    mkdir -p -- "$TEST_TOOLS" || exit 1
    printf '#!/bin/sh\nexec busybox sed "$@"\n' > "$TEST_TOOLS/sed" || exit 1
    chmod 755 -- "$TEST_TOOLS/sed" || exit 1
    PATH=$TEST_TOOLS:$PATH
    export PATH
fi

# 每个用例在独立子 Shell 中运行，避免环境优先级互相污染。
check() {
    local label=$1
    shift
    if [[ -n ${TEST_FILTER-} && $label != *"$TEST_FILTER"* ]]; then return 0; fi
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 缺少约定接口时返回明确断言失败，而不是调用不存在的命令。
require_function() {
    if ! declare -F "$1" >/dev/null; then
        printf '缺少共享接口：%s\n' "$1"
        return 1
    fi
}

# 清除测试使用的普通配置环境，确保默认值测试不受宿主环境影响。
clear_config_environment() {
    unset GIT_PORT LISTEN_ADDRESS TZ PROXY_URL ENABLE_CRON CRON_SCHEDULE
    unset ENABLE_HOSTS_UPDATE HOSTS_CRON HOSTS_URL HOSTS_URL_FALLBACK
    unset GITHUB_TOKEN GITHUB_TOKEN_FILE REPOS SHORT_LINKS
}

# 验证合法配置采用纯数据读取，保留第一个等号后的内容。
config_values() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/values.conf
    printf '%s\n' '# 独占行注释' 'GIT_PORT=12345' 'HOSTS_URL=https://example.invalid/api?a=b=c' 'CRON_SCHEDULE=0 */2 * * *' > "$file"
    gm_load_config "$file" || return 1
    [[ ${GM_CONFIG[GIT_PORT]} == 12345 && ${GM_CONFIG[HOSTS_URL]} == 'https://example.invalid/api?a=b=c' && ${GM_CONFIG[CRON_SCHEDULE]} == '0 */2 * * *' ]]
}

# 验证环境优先于文件、未设置时使用文件以及默认值。
config_precedence() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/precedence.conf
    printf '%s\n' 'GIT_PORT=12345' 'ENABLE_CRON=no' 'PROXY_URL=https://proxy.invalid:8443' > "$file"
    export GIT_PORT=23456 PROXY_URL=
    gm_load_config "$file" || return 1
    [[ ${GM_CONFIG[GIT_PORT]} == 23456 && ${GM_CONFIG[ENABLE_CRON]} == no && ${GM_CONFIG[PROXY_URL]} == '' && ${GM_CONFIG[ENABLE_HOSTS_UPDATE]} == yes ]]
}

# 验证非法文件配置不能因显式环境覆盖而被悄悄忽略。
config_rejected() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/rejected.conf expected=$2 output status=0
    printf '%s\n' "$1" > "$file"
    export GIT_PORT=23456
    output=$(gm_load_config "$file" 2>&1) || status=$?
    [[ $status == 1 && $output == "git-mirror: $expected" ]]
}

# 验证显式空值不会回退为合法默认值。
config_empty_required() {
    require_function gm_load_config || return 1
    clear_config_environment
    export GIT_PORT=
    local output status=0
    output=$(gm_load_config "$TEST_ROOT/absent.conf" 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 有效配置值非法：GIT_PORT' ]]
}

# 验证恶意数据既不执行命令替换，也不执行分号后的命令。
config_no_execution() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/injection.conf marker=$TEST_ROOT/executed
    printf 'TZ=$(touch "%s");touch "%s"\n' "$marker" "$marker" > "$file"
    local output status=0
    output=$(gm_load_config "$file" 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 配置值非法：TZ' && ! -e $marker ]]
}

# 验证读取已有配置不会改写其任何字节。
config_unchanged() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/unchanged.conf
    printf '%s\n' '# 保留用户内容' 'GIT_PORT=12345' > "$file"
    cp -- "$file" "$file.before" || return 1
    export GIT_PORT=23456
    gm_load_config "$file" || return 1
    cmp -s -- "$file" "$file.before"
}

# 验证显式 TZ 环境变量覆盖卷内时区，且卷内配置逐字节不变。
config_timezone_environment_override() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/timezone-env.conf
    printf '%s\n' 'TZ=Asia/Shanghai' 'GIT_PORT=12345' > "$file"
    cp -- "$file" "$file.before" || return 1
    export TZ=UTC
    gm_load_config "$file" || return 1
    [[ ${GM_CONFIG[TZ]} == UTC ]] || return 1
    cmp -s -- "$file" "$file.before"
}

# 验证未设置 TZ 时读取卷内值，并在卷内缺失时回退到默认 Asia/Shanghai。
config_timezone_volume_and_default() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/timezone-file.conf
    printf 'TZ=Asia/Shanghai\n' > "$file"
    gm_load_config "$file" || return 1
    [[ ${GM_CONFIG[TZ]} == Asia/Shanghai ]] || return 1
    rm -f -- "$file"
    gm_load_config "$file" || return 1
    [[ ${GM_CONFIG[TZ]} == Asia/Shanghai ]]
}

# 验证非法 TZ 即使由环境显式给出也必须拒绝，且不触碰卷内字节。
config_timezone_invalid_rejected() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/timezone-invalid.conf output status=0
    printf 'TZ=Asia/Shanghai\n' > "$file"
    cp -- "$file" "$file.before" || return 1
    export TZ=Missing/ClosureTimezone
    output=$(gm_load_config "$file" 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 有效配置值非法：TZ' ]] || return 1
    cmp -s -- "$file" "$file.before"
}

# 验证显式凭据来源写入私密状态，配置卷保持原始字节且状态权限收紧。
sync_credentials_state_is_private() {
    require_function gm_save_sync_credentials || return 1
    require_function gm_load_sync_credentials || return 1
    local run=$TEST_ROOT/credential-state before
    mkdir -p -- "$run/runtime" "$run/config" || return 1
    # 生产私密目录校验要求运行目录为 0700；夹具须显式收紧，而非放宽产品校验。
    chmod 700 -- "$run/runtime" || return 1
    printf '%s\n' '# 保留原始配置' 'TZ=UTC' > "$run/config/mirror.env"
    cp -- "$run/config/mirror.env" "$run/config/mirror.env.before" || return 1
    export GITHUB_TOKEN=lifecycle-secret-token
    unset GITHUB_TOKEN_FILE
    gm_save_sync_credentials "$run" || return 1
    [[ $(stat -c %a -- "$run/runtime/sync-credentials") == 600 ]] || return 1
    before=$(<"$run/config/mirror.env")
    unset GITHUB_TOKEN
    gm_load_sync_credentials "$run" || return 1
    [[ ${GITHUB_TOKEN-} == lifecycle-secret-token ]] || return 1
    [[ $before == "$(<"$run/config/mirror.env")" ]] || return 1
    ! grep -q lifecycle-secret-token "$run/config/mirror.env"
}

# 验证互斥凭据来源不会被接受或输出到诊断中。
config_credentials() {
    require_function gm_load_config || return 1
    clear_config_environment
    export GITHUB_TOKEN=foundation-sensitive-fixture GITHUB_TOKEN_FILE=/invalid/token
    local output status
    output=$(gm_load_config "$TEST_ROOT/absent.conf" 2>&1)
    status=$?
    [[ $status == 1 && $output == 'git-mirror: GITHUB_TOKEN 与 GITHUB_TOKEN_FILE 互斥' && $output != *foundation-sensitive-fixture* ]]
}

# 验证多仓库分支数组及已确认的 owner 同名短名被完整保留。
repos_valid() {
    require_function gm_parse_repos || return 1
    gm_parse_repos 'git/git;octocat/Hello-World main;torvalds/linux master,next,stable' 'git/git git;octocat/Hello-World hello' || return 1
    [[ ${#GM_REPOS[@]} == 3 && ${GM_REPOS[0]} == git/git && ${GM_BRANCHES[0]} == '' && ${GM_BRANCHES[2]} == master,next,stable && ${GM_LINK_TARGETS[0]} == git/git && ${GM_LINK_NAMES[0]} == git ]]
}

# 验证非法项按指定原因拒绝，且不发布上次或本次的半组解析结果。
repos_rejected() {
    require_function gm_parse_repos || return 1
    local expected=$3 status=0 output
    GM_REPOS=(previous/repo)
    GM_BRANCHES=(main)
    GM_LINK_TARGETS=(previous/repo)
    GM_LINK_NAMES=(previous)
    gm_parse_repos "$1" "$2" > "$TEST_ROOT/rejected-repos-output" 2>&1 || status=$?
    output=$(<"$TEST_ROOT/rejected-repos-output")
    [[ $status == 1 && $output == "git-mirror: $expected" ]] || return 1
    [[ ${#GM_REPOS[@]} == 0 && ${#GM_BRANCHES[@]} == 0 && ${#GM_LINK_TARGETS[@]} == 0 && ${#GM_LINK_NAMES[@]} == 0 ]]
}

# 验证预检自身不创建目录、链接或执行输入中的命令。
repos_no_side_effects() {
    require_function gm_parse_repos || return 1
    local work=$TEST_ROOT/preflight marker=$TEST_ROOT/repo-executed
    mkdir -- "$work" || return 1
    cd -- "$work" || return 1
    repos_rejected "git/git;owner/repo \$(touch $marker)" '' '仓库分支字段为空或包含空白' || return 1
    [[ ! -e $marker && ! -e git && ! -e owner ]] || return 1
    gm_parse_repos 'git/git' 'git/git git' || return 1
    [[ ! -e git && ! -L git ]]
}

# 验证加载执行入口只定义函数，不读取用户配置或启动外部操作。
entry_source_safe() {
    local script=$1 entry=$2 work=$TEST_ROOT/source-$2
    mkdir -p -- "$work/config" || return 1
    printf 'TZ=$(touch "%s")\n' "$work/executed" > "$work/config/mirror.env"
    (
        unset REPOS SHORT_LINKS
        export CONFIG_DIR="$work/config" MIRROR_ROOT="$work/repos"
        export LOG_DIR="$work/logs" RUN_DIR="$work/runtime" RUN_ROOT="$work"
        bash -c '
            # 网络边界桩：禁止旧入口在加载期间发起真实下载。
            curl() { return 99; }
            source "$1"
            declare -F "$2" >/dev/null
        ' foundation-source "$ROOT/scripts/$script" "$entry"
    ) > "$work/output" 2>&1 || return 1
    [[ ! -e $work/executed && ! -e $work/repos && ! -e $work/logs && ! -e $work/runtime ]]
}

# 验证路径检查拒绝危险形式，且不通过创建目录来修复输入。
path_rejected() {
    require_function gm_validate_path || return 1
    local expected=${2-} output status=0
    if [[ -z $expected ]]; then
        case "$1" in
            ''|/|/tmp|/etc|/usr|/var|/var/lib) expected='拒绝危险根目录' ;;
            relative/instance) expected='路径必须为明确的绝对实例目录' ;;
            *) expected='路径包含非法分量' ;;
        esac
    fi
    output=$(gm_validate_path "$1" 2>&1) || status=$?
    [[ $status == 1 && $output == "git-mirror: $expected" ]]
}

# 验证调用者拥有的绝对目标可预检，且预检不创建缺失目录。
path_valid_without_creation() {
    require_function gm_validate_path || return 1
    local target=$TEST_ROOT/path-parent/new-instance
    mkdir -- "$TEST_ROOT/path-parent" || return 1
    gm_validate_path "$target" || return 1
    [[ ! -e $target ]]
}

# 验证中间符号链接即使指向同一测试树也不被接受。
path_symlink_rejected() {
    require_function gm_validate_path || return 1
    mkdir -- "$TEST_ROOT/link-target" || return 1
    # Git Bash 使用自身可识别的链接表示；不等同于 Linux 原生链接集成验证。
    case "$(uname -s)" in
        MINGW*|MSYS*) MSYS=winsymlinks:sys ln -s -- "$TEST_ROOT/link-target" "$TEST_ROOT/link-parent" || return 1 ;;
        *) ln -s -- "$TEST_ROOT/link-target" "$TEST_ROOT/link-parent" || return 1 ;;
    esac
    [[ -L $TEST_ROOT/link-parent ]] || {
        printf '测试环境不能创建真实符号链接，不能验证此项\n'
        return 1
    }
    path_rejected "$TEST_ROOT/link-parent/instance" '路径包含符号链接' || return 1
    [[ -L $TEST_ROOT/link-parent && ! -e $TEST_ROOT/link-target/instance ]]
}

# 验证文件不能被当作实例目录或目录父路径。
path_file_rejected() {
    require_function gm_validate_path || return 1
    printf '%s\n' sentinel > "$TEST_ROOT/not-directory"
    path_rejected "$TEST_ROOT/not-directory" '路径组件不是目录' || return 1
    path_rejected "$TEST_ROOT/not-directory/instance" '路径组件不是目录' || return 1
    [[ $(<"$TEST_ROOT/not-directory") == sentinel ]]
}

# 身份边界桩仅模拟 id 返回值，生产代码不得提供跳过身份检查的选项。
identity_root_rejected() {
    require_function gm_check_identity || return 1
    local kind=$1
    id() {
        case "$1:$kind" in
            -u:effective|-ru:real) printf '0\n' ;;
            *) command id "$@" ;;
        esac
    }
    local output status=0
    output=$(gm_check_identity 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 必须以实际和有效 UID 相同的非 root 用户运行' ]]
}

# 验证真实当前身份；测试运行者为非零 UID 时应通过。
identity_current_user() {
    require_function gm_check_identity || return 1
    [[ $UID != 0 && $EUID != 0 ]] || return 1
    gm_check_identity
}

# 以明确的 uname 边界桩验证非 Alpine 拒绝，不依赖测试宿主平台。
platform_non_alpine_rejected() {
    require_function gm_check_platform || return 1
    uname() { printf 'MINGW64_NT\n'; }
    local output status=0
    output=$(gm_check_platform 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 仅支持 Alpine Linux' ]]
}

# 在明确的平台边界桩下验证安装只写独立程序根，不依赖运行配置。
install_without_runtime_config() {
    local work=$TEST_ROOT/install-only
    mkdir -- "$work" || return 1
    (
        unset REPOS SHORT_LINKS
        export GITHUB_TOKEN_FILE="$work/missing-secret"
        export RUN_ROOT="$work/unused-runtime"
        source "$ROOT/scripts/deploy-git-mirror.sh"
        require_function gm_deploy_main || exit 1
        # 平台边界桩：不代表 Alpine/OpenRC 能力验证通过。
        gm_check_platform() { return 0; }
        # 外部服务边界桩：安装阶段一旦调用即失败。
        curl() { return 91; }
        rc-service() { return 92; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        [[ -f $work/program/git-mirror-sync.sh && -f $work/program/lib/foundation.sh ]] || exit 1
        [[ -f $work/program/openrc/git-daemon && ! -e $work/unused-runtime ]]
    )
}

# 在平台边界桩下验证初始化保留已有配置，同时采用新的显式环境参数。
initialize_preserves_config() {
    local work=$TEST_ROOT/initialize
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        source "$ROOT/scripts/deploy-git-mirror.sh"
        require_function gm_deploy_main || exit 1
        # 平台边界桩：只允许测试本地临时文件生命周期。
        gm_check_platform() { return 0; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        # 权限与锁边界桩：Windows 不提供 Alpine 模式位及 flock 集成证据。
        gm_check_private_directory() { return 0; }
        flock() { return 0; }
        # 用户运行级引导边界桩：Windows 无 OpenRC，仅验证实例内登记产物。
        gm_bootstrap_user_runlevel() { return 0; }
        export REPOS=git/git SHORT_LINKS='git/git git' GIT_PORT=12345
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        [[ -f $work/instance/config/mirror.env ]] || { printf '初始化缺少配置：%s\n' "$work/instance/config/mirror.env"; exit 1; }
        [[ -f $work/instance/config/installation.conf ]] || { printf '初始化缺少安装记录：%s\n' "$work/instance/config/installation.conf"; exit 1; }
        printf '%s\n' '# 用户已有配置' 'GIT_PORT=23456' > "$work/instance/config/mirror.env"
        cp -- "$work/instance/config/mirror.env" "$work/before" || exit 1
        export GIT_PORT=34567
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        cmp -s -- "$work/before" "$work/instance/config/mirror.env" || exit 1
        [[ $HOME == "$work/instance/home" && $XDG_RUNTIME_DIR == "$work/instance/runtime" && $TMPDIR == "$work/instance/tmp" ]] || exit 1
        [[ ! -e $work/instance/repos/git && ! -L $work/instance/repos/git ]]
    )
}

# 锁边界桩只验证调用参数和失败传播，不证明操作系统排他锁有效。
lock_boundary_case() {
    require_function gm_lock_acquire || return 1
    local scenario=$1 work=$TEST_ROOT/lock-$1 status=0 before
    mkdir -p -- "$work/runtime" || return 1
    export RUN_ROOT=$work
    printf '%s\n' '不可截断的已有锁内容' > "$work/runtime/sync.lock"
    before=$(<"$work/runtime/sync.lock")
    # 权限边界桩：Windows 模式位不能代表 Alpine 的 0700 权限。
    gm_check_private_directory() { return 0; }
    # 锁系统调用边界桩：区分忙锁、系统错误和成功。
    flock() {
        printf '%s\n' "$*" > "$work/flock-arguments"
        case "$scenario" in
            busy) return 75 ;;
            error) return 69 ;;
            *) return 0 ;;
        esac
    }
    if [[ $scenario == missing ]]; then
        unset -f flock
        # 依赖发现边界桩：不影响其他真实文件系统命令。
        command() {
            if [[ ${1-} == -v && ${2-} == flock ]]; then return 1; fi
            builtin command "$@"
        }
    fi
    gm_lock_acquire sync exclusive > "$work/output" 2>&1 || status=$?
    local output arguments
    output=$(<"$work/output")
    [[ $(<"$work/runtime/sync.lock") == "$before" ]] || return 1
    if [[ $scenario == missing ]]; then
        [[ $status == 1 && $output == 'git-mirror: 缺少必要依赖 flock' && ! -e $work/flock-arguments ]]
        return $?
    fi
    [[ -f $work/flock-arguments ]] || return 1
    arguments=$(<"$work/flock-arguments")
    [[ $arguments =~ ^-n\ -E\ 75\ -x\ [0-9]+$ ]] || return 1
    case "$scenario" in
        busy) [[ $status == 75 && $output == 'git-mirror: 实例锁忙：sync' ]] ;;
        error) [[ $status == 1 && $output == 'git-mirror: 锁工具执行失败，未取得锁' ]] ;;
        success)
            [[ $status == 0 && -z $output ]] || return 1
            gm_lock_release sync
            ;;
    esac
}

# 验证锁链接在调用锁工具之前拒绝，外部目标不被截断。
lock_symlink_rejected() {
    require_function gm_lock_acquire || return 1
    local work=$TEST_ROOT/lock-link status=0
    mkdir -p -- "$work/runtime" || return 1
    export RUN_ROOT=$work
    printf '%s\n' sentinel > "$work/outside"
    case "$(uname -s)" in
        MINGW*|MSYS*) MSYS=winsymlinks:sys ln -s -- "$work/outside" "$work/runtime/sync.lock" || return 1 ;;
        *) ln -s -- "$work/outside" "$work/runtime/sync.lock" || return 1 ;;
    esac
    [[ -L $work/runtime/sync.lock ]] || return 1
    # 权限与锁调用边界桩，链接检查仍执行真实实现。
    gm_check_private_directory() { return 0; }
    flock() { printf called > "$work/called"; return 0; }
    local output
    output=$(gm_lock_acquire sync exclusive 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 实例文件不能为符号链接' ]] || return 1
    [[ ! -e $work/called && -L $work/runtime/sync.lock && $(<"$work/outside") == sentinel ]]
}

# 验证锁名只能为共享协议中的固定名称，不能变成任意文件路径。
lock_name_rejected() {
    require_function gm_lock_acquire || return 1
    local work=$TEST_ROOT/lock-name
    mkdir -p -- "$work/runtime" || return 1
    export RUN_ROOT=$work
    # 权限与依赖边界桩不替代锁名称校验。
    gm_check_private_directory() { return 0; }
    flock() { printf called > "$work/called"; return 0; }
    local output status=0
    output=$(gm_lock_acquire ../outside exclusive 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 不支持的实例锁名称' ]] || return 1
    [[ ! -e $work/called && ! -e $work/outside && ! -e $work/outside.lock ]]
}

# 以 uname 边界桩验证关键运行入口拒绝非 Alpine，且尚未产生写入。
entry_platform_rejected_before_write() {
    local script=$1 work=$TEST_ROOT/platform-$1 status=0 output
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        export RUN_ROOT=$work/instance REPOS=git/git
        # 外部边界桩防止缺少平台检查的旧实现触发真实网络。
        curl() { return 98; }
        git() {
            if [[ ${1-} == check-ref-format ]]; then command git "$@"; else return 97; fi
        }
        # 平台边界桩仅注入操作系统名称，仍执行真实生产平台检查。
        uname() { printf 'MINGW64_NT\n'; }
        export -f curl git uname
        bash "$ROOT/scripts/$script"
    ) > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    [[ $status == 1 && $output == 'git-mirror: 仅支持 Alpine Linux' && ! -e $work/instance ]]
}

# 验证初始化遇到依赖、权限或忙锁错误时不创建配置及实例记录。
initialize_boundary_failure() {
    local scenario=$1 work=$TEST_ROOT/init-boundary-$1 status=0
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        source "$ROOT/scripts/deploy-git-mirror.sh"
        # 平台边界桩仅允许临时文件测试，不代表 Alpine 集成。
        gm_check_platform() { return 0; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        mkdir -p -- "$work/instance/runtime" || exit 1
        export REPOS=git/git
        # 权限边界桩记录到达位置，使用生产接口的诊断契约。
        gm_check_private_directory() {
            printf 'private %s\n' "$1" >> "$work/permissions"
            if [[ $scenario == permissions ]]; then
                gm_error '实例私有目录权限必须为 0700'
                return 1
            fi
            return 0
        }
        # 锁边界桩记录真实锁接口传来的参数，不证明内核互斥。
        flock() {
            printf '%s\n' "$*" >> "$work/locks"
            if [[ $scenario == busy ]]; then return 75; fi
            return 0
        }
        if [[ $scenario == missing ]]; then
            unset -f flock
            # 依赖发现边界桩只隐藏 flock，不隐藏其他实际文件工具。
            command() {
                if [[ ${1-} == -v && ${2-} == flock ]]; then return 1; fi
                builtin command "$@"
            }
        fi
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" > "$work/output" 2>&1 || status=$?
        local output
        output=$(<"$work/output")
        [[ ! -e $work/instance/config/mirror.env && ! -e $work/instance/config/installation.conf ]] || exit 1
        case "$scenario" in
            missing)
                [[ $status == 1 && $output == 'git-mirror: 缺少必要依赖：flock' ]] || exit 1
                [[ ! -e $work/permissions && ! -e $work/locks ]] || exit 1
                ;;
            permissions)
                [[ $status == 1 && $output == 'git-mirror: 实例私有目录权限必须为 0700' ]] || exit 1
                [[ $(<"$work/permissions") == "private $work/instance/runtime" && ! -e $work/locks ]] || exit 1
                ;;
            busy)
                [[ $status == 75 && $output == 'git-mirror: 实例锁忙：instance' ]] || exit 1
                local -a lock_calls=()
                mapfile -t lock_calls < "$work/locks"
                [[ ${#lock_calls[@]} == 1 && ${lock_calls[0]} =~ ^-n\ -E\ 75\ -x\ [0-9]+$ ]] || exit 1
                [[ -s $work/permissions ]] || exit 1
                ;;
        esac
        return 0
    )
}

# 只解释服务定义并检查变量，不启动 OpenRC 或真实服务。
service_instance_paths() {
    local service=$1
    (
        export INSTALL_ROOT=$TEST_ROOT/service-program RUN_ROOT=$TEST_ROOT/service-instance
        export XDG_RUNTIME_DIR=$RUN_ROOT/runtime
        export GIT_PORT=12345 LISTEN_ADDRESS=127.0.0.1
        export RC_SVCNAME=$service
        unset MIRROR_ROOT
        source "$ROOT/scripts/openrc/$service"
        case "$service" in
            git-mirror-sync) [[ $command == "$INSTALL_ROOT/git-mirror-sync.sh" ]] ;;
            git-mirror-hosts) [[ $command == "$INSTALL_ROOT/update-github-hosts.sh" ]] ;;
            git-mirror-scheduler)
                [[ $command == "$INSTALL_ROOT/git-mirror-scheduler.sh" ]] || exit 1
                [[ $pidfile == "$XDG_RUNTIME_DIR/git-mirror-scheduler.pid" ]] || exit 1
                declare -F start_pre >/dev/null
                ;;
            git-daemon)
                [[ $pidfile == "$XDG_RUNTIME_DIR/git-daemon.pid" ]] || exit 1
                [[ $command == /usr/bin/git ]] || exit 1
                declare -F start_pre >/dev/null
                ;;
        esac
    )
}

# 验证操作入口的锁顺序和错误传播；不模拟真实操作系统排他效果。
operation_lock_order() {
    local scenario=$1 work=$TEST_ROOT/operation-$1 status=0 expected actual
    mkdir -p -- "$work/runtime" || return 1
    export RUN_ROOT=$work
    if [[ $scenario == stopped ]]; then printf stopped > "$work/runtime/stopped"; fi
    # 共享锁接口边界桩记录顺序，并模拟第二把锁忙。
    gm_lock_acquire() {
        printf 'acquire %s %s\n' "$1" "$2" >> "$work/calls"
        if [[ $scenario == busy && $1 == sync ]]; then return 75; fi
        return 0
    }
    # 释放边界桩验证失败时不会泄漏已取得的实例锁。
    gm_lock_release() {
        printf 'release %s\n' "$1" >> "$work/calls"
    }
    gm_begin_operation sync > "$work/output" 2>&1 || status=$?
    actual=$(<"$work/calls")
    case "$scenario" in
        success)
            expected=$'acquire instance shared\nacquire sync exclusive'
            [[ $status == 0 && $actual == "$expected" ]]
            ;;
        busy)
            expected=$'acquire instance shared\nacquire sync exclusive\nrelease instance'
            [[ $status == 75 && $actual == "$expected" ]]
            ;;
        stopped)
            expected=$'acquire instance shared\nrelease instance'
            [[ $status == 1 && $actual == "$expected" && $(<"$work/output") == 'git-mirror: 实例已停止，拒绝启动新操作' ]]
            ;;
    esac
}

# 所有卸载行为只运行于本测试安装、初始化并填充的临时实例。
uninstall_behavior() {
    local scenario=$1 work=$TEST_ROOT/uninstall-$1
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        source "$ROOT/scripts/deploy-git-mirror.sh"
        # 平台、权限及锁边界桩，不代表真实 Alpine/OpenRC/flock 集成。
        gm_check_platform() { return 0; }
        gm_check_private_directory() { return 0; }
        flock() { return 0; }
        gm_bootstrap_user_runlevel() { return 0; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        export REPOS=git/git
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        mkdir -p -- "$work/instance/repos/example" || exit 1
        printf '%s\n' repository > "$work/instance/repos/example/sentinel"
        printf '%s\n' credential-fixture > "$work/instance/secrets/sentinel"
        printf '%s\n' log-fixture > "$work/instance/logs/sentinel"
        if [[ $scenario != default ]]; then
            printf '%s\n' 'GIT_PORT=12345' > "$work/instance/config/mirror.env"
        fi
        printf '%s\n' outside-sentinel > "$work/outside"
        # 旧卸载脚本会在 source 时执行；以 --help 安全终止旧实现，绝不执行旧删除流程。
        set -- --help
        source "$work/program/uninstall-git-mirror.sh"
        require_function gm_uninstall_main || exit 1
        set --
        # 已安装入口重新加载共享实现后，重新设置明确的测试边界桩。
        gm_check_platform() { return 0; }
        gm_check_private_directory() { return 0; }
        local status=0 output category run=$work/instance
        local -a options=(--run-root "$run" --install-root "$work/program")
        # 服务控制边界桩：校验安装目录绝对路径，再按服务名记录停止顺序。
        rc-service() {
            if [[ ${1-} == --user && ${2-} == -e && $# == 3 ]]; then
                [[ $3 == "$work/program/openrc/"* && -x $3 ]] || return 90
                printf 'exists %s\n' "${3-}" >> "$work/checks"
                return 0
            fi
            [[ $# == 3 && ${1-} == --user && ${3-} == stop ]] || return 90
            [[ $2 == "$work/program/openrc/"* && -x $2 ]] || return 90
            printf '%s\n' "--user ${2##*/} stop" >> "$work/services"
            if [[ $scenario == stop-failure ]]; then return 23; fi
            return 0
        }
        # 保留真实锁文件检查，仅替换外部 flock 退出状态。
        flock() {
            printf '%s\n' "$*" >> "$work/locks"
            case "$scenario" in
                busy) return 75 ;;
                lock-error) return 69 ;;
                *) return 0 ;;
            esac
        }
        case "$scenario" in
            default|scheduler-installed|scheduler-missing|capability-missing) options+=(--yes) ;;
            repos|config|credentials|logs) options+=("--delete-$scenario" --yes) ;;
            confirm-no|confirm-yes) options+=(--delete-repos) ;;
            stop-failure|busy|lock-error|missing-flock|missing-openrc|forged-record|missing-record|dangerous-root|linked-repos)
                options+=(--delete-repos --delete-config --delete-credentials --delete-logs --yes)
                ;;
        esac
        case "$scenario" in
            scheduler-installed)
                # 安装已交付调度服务；此处确认登记存在且可执行。
                export ENABLE_CRON=no
                [[ -x $work/program/openrc/git-mirror-scheduler ]] || exit 1
                ;;
            scheduler-missing)
                # 模拟已登记调度能力但服务定义丢失，卸载必须失败关闭。
                printf 'FORMAT=1\nSCHEDULER=present\n' > "$work/program/service-capabilities.conf"
                export ENABLE_CRON=no
                rm -- "$work/program/openrc/git-mirror-scheduler" || exit 1
                ;;
            capability-missing)
                if [[ -f $work/program/service-capabilities.conf ]]; then
                    rm -- "$work/program/service-capabilities.conf" || exit 1
                fi
                ;;
            missing-flock|missing-openrc)
                # 依赖发现边界桩只隐藏指定组件，其他工具仍使用真实实现。
                command() {
                    if [[ ${1-} == -v ]]; then
                        if [[ $scenario == missing-flock && ${2-} == flock ]]; then return 1; fi
                        if [[ $scenario == missing-openrc && ${2-} == rc-service ]]; then return 1; fi
                    fi
                    builtin command "$@"
                }
                ;;
            forged-record)
                printf 'FORMAT=1\nMODE=instance\nUID=%s\nRUN_ROOT=%s\nINSTALL_ROOT=%s\n' "$EUID" "$work" "$work/program" > "$run/config/installation.conf"
                ;;
            missing-record) rm -- "$run/config/installation.conf" || exit 1 ;;
            dangerous-root) options=(--run-root / --install-root "$work/program" --delete-repos --yes) ;;
            linked-repos)
                mv -- "$run/repos" "$work/preserved-repos" || exit 1
                case "$(uname -s)" in
                    MINGW*|MSYS*) MSYS=winsymlinks:sys ln -s -- "$work/preserved-repos" "$run/repos" || exit 1 ;;
                    *) ln -s -- "$work/preserved-repos" "$run/repos" || exit 1 ;;
                esac
                [[ -L $run/repos ]] || exit 1
                ;;
        esac
        case "$scenario" in
            confirm-no) gm_uninstall_main "${options[@]}" <<< n > "$work/output" 2>&1 || status=$? ;;
            confirm-yes) gm_uninstall_main "${options[@]}" <<< y > "$work/output" 2>&1 || status=$? ;;
            *) gm_uninstall_main "${options[@]}" </dev/null > "$work/output" 2>&1 || status=$? ;;
        esac
        output=$(<"$work/output")
        [[ $(<"$work/outside") == outside-sentinel && $output != *credential-fixture* ]] || exit 1
        [[ -f $work/program/git-mirror-sync.sh && -f $work/program/installation.conf ]] || exit 1
        case "$scenario" in
            default|scheduler-installed|confirm-no)
                [[ $status == 0 ]] || { printf '%s\n' "$output"; exit 1; }
                [[ -f $run/repos/example/sentinel && -f $run/config/mirror.env && -f $run/secrets/sentinel && -f $run/logs/sentinel ]] || exit 1
                if [[ $scenario == confirm-no ]]; then
                    [[ ! -e $work/services && ! -e $work/locks ]] || exit 1
                else
                    local expected_services="--user git-mirror-scheduler stop"$'\n' expected_service
                    [[ $(<"$work/program/service-capabilities.conf") == $'FORMAT=1\nSCHEDULER=present' ]] || exit 1
                    for expected_service in git-mirror-sync git-mirror-hosts git-daemon; do
                        expected_services+="--user $expected_service stop"$'\n'
                    done
                    [[ -f $work/services && $(<"$work/services") == "${expected_services%$'\n'}" ]] || exit 1
                    [[ -s $work/locks && $(<"$run/runtime/stopped") == STOPPED=1 ]] || exit 1
                fi
                ;;
            scheduler-missing|capability-missing)
                local expected_diagnostic='缺少安装服务能力记录'
                if [[ $scenario == scheduler-missing ]]; then expected_diagnostic='已登记调度服务定义缺失'; fi
                [[ $status == 1 && $output == *"$expected_diagnostic"* ]] || { printf '%s\n' "$output"; exit 1; }
                [[ ! -e $work/services && ! -e $work/locks && ! -e $run/runtime/stopped ]] || exit 1
                [[ -f $run/repos/example/sentinel && -f $run/config/mirror.env && -f $run/secrets/sentinel && -f $run/logs/sentinel ]] || exit 1
                ;;
            repos|config|credentials|logs|confirm-yes)
                [[ $status == 0 && -s $work/services && -s $work/locks ]] || { printf '%s\n' "$output"; exit 1; }
                [[ $output == *"$run/"* ]] || exit 1
                for category in repos config credentials logs; do
                    local sentinel
                    case "$category" in
                        repos) sentinel=$run/repos/example/sentinel ;;
                        config) sentinel=$run/config/mirror.env ;;
                        credentials) sentinel=$run/secrets/sentinel ;;
                        logs) sentinel=$run/logs/sentinel ;;
                    esac
                    if [[ $category == "$scenario" || ( $scenario == confirm-yes && $category == repos ) ]]; then
                        [[ ! -e $sentinel ]] || exit 1
                    else
                        [[ -f $sentinel ]] || exit 1
                    fi
                done
                # 安装记录与锁保留，避免删除配置后丢失实例身份或更换锁 inode。
                [[ -f $run/config/installation.conf && -d $run/runtime ]] || exit 1
                ;;
            *)
                local expected_diagnostic expected_status=1 expected_services=
                case "$scenario" in
                    stop-failure) expected_diagnostic='实例服务停止失败，未执行删除' ;;
                    busy) expected_diagnostic='实例锁忙：instance'; expected_status=75 ;;
                    lock-error) expected_diagnostic='锁工具执行失败，未取得锁' ;;
                    missing-flock) expected_diagnostic='缺少必要依赖：flock' ;;
                    missing-openrc) expected_diagnostic='缺少必要依赖：rc-service' ;;
                    forged-record) expected_diagnostic='安装记录缺失字段、路径冲突或身份不匹配' ;;
                    missing-record) expected_diagnostic='读取文件不存在或不可读' ;;
                    dangerous-root) expected_diagnostic='拒绝危险根目录' ;;
                    linked-repos) expected_diagnostic='路径包含符号链接' ;;
                    *) printf '未定义的卸载负向场景：%s\n' "$scenario"; exit 1 ;;
                esac
                [[ $status == "$expected_status" && $output == *"git-mirror: $expected_diagnostic"* ]] || {
                    printf '卸载拒绝原因不符：%s，status=%s\n%s\n' "$scenario" "$status" "$output"
                    exit 1
                }
                [[ $(<"$run/repos/example/sentinel") == repository && $(<"$run/config/mirror.env") == GIT_PORT=12345 ]] || exit 1
                [[ $(<"$run/secrets/sentinel") == credential-fixture && $(<"$run/logs/sentinel") == log-fixture ]] || exit 1
                [[ ! -e $run/runtime/stopped ]] || exit 1
                case "$scenario" in
                    stop-failure)
                        [[ $(<"$work/services") == "--user git-mirror-scheduler stop" && ! -e $work/locks ]] || exit 1
                        ;;
                    busy|lock-error)
                        expected_services="--user git-mirror-scheduler stop"$'\n'"--user git-mirror-sync stop"$'\n'"--user git-mirror-hosts stop"
                        [[ $(<"$work/services") == "$expected_services" ]] || exit 1
                        local -a lock_calls=()
                        mapfile -t lock_calls < "$work/locks"
                        [[ ${#lock_calls[@]} == 1 && ${lock_calls[0]} =~ ^-n\ -E\ 75\ -x\ [0-9]+$ ]] || exit 1
                        ;;
                    *) [[ ! -e $work/services && ! -e $work/locks ]] || exit 1 ;;
                esac
                ;;
        esac
        printf verified > "$work/verified"
    ) || return 1
    # 旧实现因 --help 退出子 Shell 时不会写此标记，应得到真实 red。
    [[ -f $work/verified ]]
}

# 验证分类删除消费纯数据链接记录，不跟随链接且不触碰实例外目标。
managed_link_cleanup() {
    local scenario=$1 work=$TEST_ROOT/managed-link-$1 status=0 output target=owner/repo.git
    local expected= record_target=owner/repo.git
    mkdir -- "$work" || return 1
    clear_config_environment
    source "$ROOT/scripts/deploy-git-mirror.sh"
    # 平台、私有权限和服务锁为边界桩；记录、链接及删除执行真实实现。
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    flock() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    gm_deploy_main --install --install-root "$work/program" || return 1
    export REPOS=owner/repo
    gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || return 1
    mkdir -p -- "$work/instance/repos/owner/repo.git" "$work/instance/config/managed-links" "$work/outside" || return 1
    printf '%s\n' repository > "$work/instance/repos/owner/repo.git/sentinel"
    printf '%s\n' published > "$work/instance/repos/owner/repo.git/git-daemon-export-ok"
    printf '%s\n' outside > "$work/outside/sentinel"
    case "$scenario" in
        valid) ;;
        unknown) expected='未登记短链接' ;;
        dangling) target=owner/missing.git; record_target=$target; expected='受管理短链接目标不存在' ;;
        outside) target=../../outside; record_target=$target; expected='短链接管理记录目标非法' ;;
        mismatch) target=owner; expected='短链接实际目标与管理记录不一致' ;;
        *) return 1 ;;
    esac
    if [[ $scenario != unknown ]]; then
        gm_create_data_file "$work/instance/config/managed-links/alias.git" "$(printf 'FORMAT=1\nTARGET=%s' "$record_target")" || return 1
    fi
    # Git Bash 链接表示仅提供本地行为证据，不等同于 Linux 原生链接验收。
    case "$(uname -s)" in
        MINGW*|MSYS*) MSYS=winsymlinks:sys ln -s -- "$target" "$work/instance/repos/alias.git" || return 1 ;;
        *) ln -s -- "$target" "$work/instance/repos/alias.git" || return 1 ;;
    esac
    [[ -L $work/instance/repos/alias.git ]] || return 1
    source "$work/program/uninstall-git-mirror.sh"
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    # 记录跨层停止与锁序，拒绝其他实例及非停止服务操作。
    rc-service() {
        if [[ $# == 3 && $1 == --user && $2 == -e ]]; then return 0; fi
        [[ $# == 3 && $1 == --user && $3 == stop ]] || return 90
        [[ $2 == "$work/program/openrc/"* && -x $2 ]] || return 90
        printf 'stop %s\n' "${2##*/}" >> "$work/calls"
        return 0
    }
    gm_lock_acquire() {
        printf 'lock %s %s\n' "$1" "$2" >> "$work/calls"
        return 0
    }
    # 记录真实删除命令；解除链接时目标仍存在，递归清理前链接已解除。
    rm() {
        printf '%s\n' "$*" >> "$work/removals"
        if [[ ${2-} == "$work/instance/repos/alias.git" ]]; then
            [[ $# == 2 && $1 == -- && -L $2 ]] || return 91
            [[ $(<"$work/instance/repos/owner/repo.git/sentinel") == repository ]] || return 92
        elif [[ ${3-} == "$work/instance/repos" ]]; then
            [[ $# == 3 && $1 == -rf && $2 == -- && ! -L $work/instance/repos/alias.git ]] || return 93
            [[ $(<"$work/instance/repos/owner/repo.git/sentinel") == repository ]] || return 94
        fi
        command rm "$@"
    }
    gm_uninstall_main --run-root "$work/instance" --delete-repos --yes > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    [[ $(<"$work/outside/sentinel") == outside ]] || return 1
    [[ -f $work/instance/config/mirror.env && -f $work/instance/config/installation.conf ]] || return 1
    [[ -f $work/program/installation.conf ]] || return 1
    if [[ $scenario == valid ]]; then
        expected=$'stop git-mirror-scheduler\nstop git-mirror-sync\nstop git-mirror-hosts\nlock instance exclusive\nlock sync exclusive\nlock hosts exclusive\nstop git-daemon'
        [[ $status == 0 && ! -e $work/instance/repos && ! -L $work/instance/repos ]] || {
            printf '合法受管理相对链接必须允许分类删除：status=%s\n%s\n' "$status" "$output"
            return 1
        }
        [[ $(<"$work/calls") == "$expected" && $(<"$work/instance/runtime/stopped") == STOPPED=1 ]] || return 1
        [[ ! -e $work/instance/config/managed-links/alias.git ]] || return 1
        local expected_removals
        expected_removals="-- $work/instance/repos/alias.git"$'\n'"-- $work/instance/config/managed-links/alias.git"$'\n'"-rf -- $work/instance/repos"
        [[ $(<"$work/removals") == "$expected_removals" ]] || return 1
    else
        [[ $status == 1 && $output == *"$expected"* ]] || {
            printf '链接拒绝原因不符：预期=%s，status=%s\n%s\n' "$expected" "$status" "$output"
            return 1
        }
        [[ ! -e $work/calls && ! -e $work/removals && ! -e $work/instance/runtime/stopped ]] || return 1
        [[ -L $work/instance/repos/alias.git && $(readlink -- "$work/instance/repos/alias.git") == "$target" ]] || return 1
        [[ $(<"$work/instance/repos/owner/repo.git/sentinel") == repository ]] || return 1
    fi
    return 0
}

# owner 目录永不被当作受管理短链接，同名短名也不得覆盖 owner 目录内容。
managed_link_owner_preserved() {
    local run=$TEST_ROOT/managed-owner status=0 output
    mkdir -p -- "$run/repos/git/git.git" "$run/config/managed-links" || return 1
    printf '%s\n' repository > "$run/repos/git/git.git/sentinel"
    gm_create_data_file "$run/config/managed-links/git.git" $'FORMAT=1\nTARGET=git/git.git' || return 1
    output=$(gm_validate_managed_link "$run" "$run/repos/git" 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 未登记短链接' ]] || return 1
    [[ -d $run/repos/git && ! -L $run/repos/git ]] || return 1
    [[ $(<"$run/repos/git/git.git/sentinel") == repository ]] || return 1
    [[ -f $run/config/managed-links/git.git ]]
}

for scenario in valid unknown dangling outside mismatch; do
    check "受管理链接分类删除：$scenario（服务和锁边界桩）" managed_link_cleanup "$scenario"
done
check '受管理链接分类删除：owner 目录保持原状' managed_link_owner_preserved

# 验证显式恢复 CLI 与停止意图，服务及锁桩仅记录外部边界。
resume_lifecycle() {
    local scenario=$1 work=$TEST_ROOT/resume-$1 status=0 output expected
    mkdir -- "$work" || return 1
    clear_config_environment
    source "$ROOT/scripts/deploy-git-mirror.sh"
    require_function gm_resume_instance || return 1
    # 平台、私有权限和 flock 边界桩，文件与配置生命周期仍使用真实实现。
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    flock() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    gm_deploy_main --install --install-root "$work/program" || return 1
    export REPOS=git/git
    gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || return 1
    printf '%s\n' repository > "$work/instance/repos/sentinel"
    source "$work/program/uninstall-git-mirror.sh"
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    # 重新加载共享实现后重建运行级引导桩，后续再次初始化才可在本地执行。
    gm_bootstrap_user_runlevel() { return 0; }
    # 初次默认停止成功，不运行真实 OpenRC。
    rc-service() { return 0; }
    gm_uninstall_main --run-root "$work/instance" || return 1
    [[ $(<"$work/instance/runtime/stopped") == STOPPED=1 ]] || return 1
    gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || return 1
    [[ $(<"$work/instance/runtime/stopped") == STOPPED=1 ]] || return 1
    output=$(gm_begin_operation sync 2>&1) || status=$?
    [[ $status == 1 && $output == 'git-mirror: 实例已停止，拒绝启动新操作' ]] || return 1
    # 锁接口桩记录恢复锁序并模拟忙锁，不声称实际互斥已验证。
    gm_lock_acquire() {
        printf 'lock %s %s\n' "$1" "$2" >> "$work/calls"
        if [[ $scenario == busy && $1 == instance ]]; then
            printf 'git-mirror: 实例锁忙：instance\n' >&2
            return 75
        fi
        return 0
    }
    # 服务边界桩记录停止与状态查询；返回码契约不代表真实 OpenRC 验证。
    rc-service() {
        if [[ ${1-} == --user && ${2-} == -e && $# == 3 ]]; then
            printf 'exists %s\n' "${3-}" >> "$work/checks"
            return 0
        fi
        [[ $# == 3 && ${1-} == --user && ( ${3-} == stop || ${3-} == status ) ]] || return 90
        case "$3" in
            stop)
                [[ $2 == "$work/program/openrc/"* && -x $2 ]] || return 90
                printf 'stop %s\n' "${2##*/}" >> "$work/calls"
                if [[ $scenario == stop-failure ]]; then return 23; fi
                return 0
                ;;
            status)
                printf 'status %s\n' "$2" >> "$work/calls"
                case "$scenario" in
                    still-running) return 0 ;;
                    status-error) return 23 ;;
                    *) return 3 ;;
                esac
                ;;
        esac
    }
    if [[ $scenario == forged-record ]]; then
        printf '%s\n' invalid > "$work/instance/config/installation.conf"
    fi
    # 遗留 PID 文件不能代替服务状态，也不应在恢复时被擅自删除。
    printf '%s\n' 424242 > "$work/instance/runtime/git-daemon.pid"
    status=0
    gm_deploy_main --resume --install-root "$work/program" --run-root "$work/instance" > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    [[ $(<"$work/instance/repos/sentinel") == repository ]] || return 1
    [[ $(<"$work/instance/runtime/git-daemon.pid") == 424242 ]] || return 1
    case "$scenario" in
        success)
            expected=$'stop git-mirror-scheduler\nstop git-mirror-sync\nstop git-mirror-hosts\nlock instance exclusive\nlock sync exclusive\nlock hosts exclusive\nstop git-daemon\nstatus git-mirror-scheduler\nstatus git-mirror-sync\nstatus git-mirror-hosts\nstatus git-daemon'
            [[ $status == 0 && ! -e $work/instance/runtime/stopped && $(<"$work/calls") == "$expected" ]] || {
                printf '恢复必须在三把排他锁内确认全部服务已停止\n实际调用：\n%s\n%s\n' "$(<"$work/calls")" "$output"
                return 1
            }
            : > "$work/calls"
            gm_begin_operation sync || return 1
            [[ $(<"$work/calls") == $'lock instance shared\nlock sync exclusive' ]] || return 1
            ;;
        busy)
            [[ $status == 75 && $output == *'实例锁忙：instance'* ]] || return 1
            [[ $(<"$work/calls") == $'stop git-mirror-scheduler\nstop git-mirror-sync\nstop git-mirror-hosts\nlock instance exclusive' ]] || return 1
            ;;
        stop-failure)
            [[ $status == 1 && $output == *'实例服务停止失败'* && $(<"$work/calls") == 'stop git-mirror-scheduler' ]] || return 1
            ;;
        still-running)
            expected=$'stop git-mirror-scheduler\nstop git-mirror-sync\nstop git-mirror-hosts\nlock instance exclusive\nlock sync exclusive\nlock hosts exclusive\nstop git-daemon\nstatus git-mirror-scheduler'
            [[ $status == 1 && $output == *'实例服务仍在运行：git-mirror-scheduler'* && $(<"$work/calls") == "$expected" ]] || {
                printf '报告运行中的服务必须拒绝恢复：status=%s\n%s\n' "$status" "$output"
                return 1
            }
            ;;
        status-error)
            expected=$'stop git-mirror-scheduler\nstop git-mirror-sync\nstop git-mirror-hosts\nlock instance exclusive\nlock sync exclusive\nlock hosts exclusive\nstop git-daemon\nstatus git-mirror-scheduler'
            [[ $status == 1 && $output == *'无法确认实例服务状态：git-mirror-scheduler'* && $(<"$work/calls") == "$expected" ]] || {
                printf '不可靠状态必须失败关闭：status=%s\n%s\n' "$status" "$output"
                return 1
            }
            ;;
        forged-record)
            [[ $status == 1 && $output == *'安装记录缺失字段、路径冲突或身份不匹配'* && ! -e $work/calls ]] || return 1
            ;;
    esac
    if [[ $scenario != success ]]; then
        [[ $(<"$work/instance/runtime/stopped") == STOPPED=1 ]] || return 1
    fi
    return 0
}

for scenario in success busy stop-failure forged-record still-running status-error; do
    check "显式恢复生命周期：$scenario（服务及锁边界桩）" resume_lifecycle "$scenario"
done

# 验证 --init 在实例内准备用户 OpenRC 环境：白名单、服务登记与幂等，且不启动服务。
init_prepares_user_openrc() {
    local scenario=$1 work=$TEST_ROOT/init-openrc-$1
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        source "$ROOT/scripts/deploy-git-mirror.sh"
        require_function gm_deploy_main || exit 1
        # 平台、私有权限与锁边界桩；运行级引导桩不掩盖实例内登记产物。
        gm_check_platform() { return 0; }
        gm_check_private_directory() { return 0; }
        flock() { return 0; }
        gm_bootstrap_user_runlevel() { return 0; }
        # 服务控制边界桩：初始化一旦启动业务服务即失败。
        rc-service() { printf 'called\n' >> "$work/rc-service-calls"; return 99; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        export REPOS=git/git
        if [[ $scenario == preserve ]]; then
            mkdir -p -- "$work/instance/config/rc" || exit 1
            printf '%s\n' '# 用户已有配置' 'rc_env_allow="EXTRA_VAR"' > "$work/instance/config/rc/rc.conf"
        fi
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        [[ ! -e $work/rc-service-calls ]] || { printf '初始化不应启动业务服务\n'; exit 1; }
        local rc_conf=$work/instance/config/rc/rc.conf service link
        [[ -f $rc_conf ]] || { printf '初始化未生成实例 rc.conf\n'; exit 1; }
        grep -q 'rc_env_allow="[^"]*INSTALL_ROOT RUN_ROOT REPOS' "$rc_conf" || { printf 'rc_env_allow 缺少必要变量\n'; exit 1; }
        if grep -q 'GITHUB_TOKEN' "$rc_conf"; then printf 'rc_env_allow 不应包含凭据变量\n'; exit 1; fi
        for service in git-daemon git-mirror-sync git-mirror-hosts git-mirror-scheduler; do
            link=$work/instance/config/rc/init.d/$service
            [[ -L $link ]] || { printf '缺少实例服务登记：%s\n' "$service"; exit 1; }
            [[ $(readlink -- "$link") == "$work/program/openrc/$service" ]] || { printf '登记目标不一致：%s\n' "$service"; exit 1; }
        done
        if [[ $scenario == preserve ]]; then
            [[ $(head -n 1 "$rc_conf") == '# 用户已有配置' ]] || { printf '用户已有配置未被保留\n'; exit 1; }
            grep -q 'EXTRA_VAR' "$rc_conf" || { printf '用户已有白名单未被保留\n'; exit 1; }
        fi
        cp -- "$rc_conf" "$work/before" || exit 1
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        cmp -s -- "$work/before" "$rc_conf" || { printf '重复初始化必须幂等\n'; exit 1; }
    )
}
check '实例 OpenRC 环境初始化：fresh（平台与引导边界桩）' init_prepares_user_openrc fresh
check '实例 OpenRC 环境初始化：preserve 且幂等（平台与引导边界桩）' init_prepares_user_openrc preserve

# 验证追加白名单时既有内容无尾随换行也不被拼接破坏，第二次初始化仍成功且字节不变。
init_append_without_trailing_newline() {
    local work=$TEST_ROOT/init-append-newline
    mkdir -- "$work" || return 1
    (
        require_function gm_ensure_instance_rc_conf || exit 1
        require_function gm_read_rc_env_allow || exit 1
        local file=$work/rc.conf bytes
        printf 'rc_env_allow="EXTRA_VAR"' > "$file" || exit 1
        cp -- "$file" "$work/original" || exit 1
        gm_ensure_instance_rc_conf "$file" || { printf '首次追加应成功\n'; exit 1; }
        # 既有内容必须逐字节保留且自成一整行，新注释不得拼接到旧末行。
        bytes=$(wc -c < "$work/original") || exit 1
        head -c "$bytes" -- "$file" | cmp -s - "$work/original" || { printf '追加破坏了既有内容\n'; exit 1; }
        [[ $(sed -n '2p' -- "$file") == '# 由 deploy-git-mirror.sh --init 追加：放行交付服务所需变量。' ]] || { printf '追加注释未独立成行\n'; exit 1; }
        gm_read_rc_env_allow "$file" >/dev/null || { printf '追加后既有行应仍可解析\n'; exit 1; }
        cp -- "$file" "$work/before" || exit 1
        gm_ensure_instance_rc_conf "$file" || { printf '第二次初始化应成功\n'; exit 1; }
        cmp -s -- "$work/before" "$file" || { printf '重复初始化必须幂等\n'; exit 1; }
    )
}
check '实例 rc.conf 追加：既有内容无尾随换行仍幂等' init_append_without_trailing_newline

# 验证既有 rc_env_allow 采用引号外行内注释时仍安全解析，未闭合引号失败关闭。
init_read_inline_comment() {
    local work=$TEST_ROOT/init-inline-comment
    mkdir -- "$work" || return 1
    (
        require_function gm_read_rc_env_allow || exit 1
        require_function gm_ensure_instance_rc_conf || exit 1
        local file=$work/rc.conf tokens
        printf '%s\n' 'rc_env_allow="A B" # 用户注释' > "$file" || exit 1
        tokens=$(gm_read_rc_env_allow "$file") || { printf '含行内注释的行应可解析\n'; exit 1; }
        [[ $tokens == $'A\nB' ]] || { printf '解析结果应仅取引号内值：%s\n' "$tokens"; exit 1; }
        cp -- "$file" "$work/original" || exit 1
        gm_ensure_instance_rc_conf "$file" || { printf '含行内注释的既有配置应可追加\n'; exit 1; }
        head -n 1 -- "$file" | cmp -s - "$work/original" || { printf '既有行应逐字节保留\n'; exit 1; }
        printf '%s\n' 'rc_env_allow="A B' > "$work/unterminated" || exit 1
        if gm_read_rc_env_allow "$work/unterminated" >/dev/null 2>&1; then
            printf '未闭合引号应失败关闭\n'; exit 1
        fi
    )
}
check '实例 rc.conf 解析：引号外行内注释可用且未闭合失败关闭' init_read_inline_comment

# 验证引导前检测实例 default 运行级是否已登记交付服务，命中则失败关闭，不启动业务服务。
bootstrap_rejects_delivered_service() {
    local work=$TEST_ROOT/init-runlevel status=0 output
    mkdir -p -- "$work/config/rc/runlevels/default" "$work/config/rc/init.d" "$work/runtime" "$work/cache" || return 1
    (
        require_function gm_instance_default_runlevel_has_delivered_service || exit 1
        require_function gm_bootstrap_user_runlevel || exit 1
        export XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/runtime XDG_CACHE_HOME=$work/cache
        gm_instance_default_runlevel_has_delivered_service && { printf '空运行级不应命中交付服务\n'; exit 1; }
        ln -s -- "$work/config/rc/init.d/git-daemon" "$work/config/rc/runlevels/default/git-daemon" || exit 1
        gm_instance_default_runlevel_has_delivered_service || { printf '运行级含交付服务应命中\n'; exit 1; }
        output=$(gm_bootstrap_user_runlevel 2>&1) || status=$?
        # 真正校验失败关闭：拒绝退出码、明确诊断，且未启动引导（无用户运行级状态副作用）。
        [[ $status == 1 && $output == *'存在交付服务或无法确定'* ]] || { printf '命中交付服务必须失败关闭：status=%s，诊断=%s\n' "$status" "$output"; exit 1; }
        [[ ! -e $XDG_RUNTIME_DIR/openrc/softlevel ]] || { printf '拒绝引导时不得创建用户运行级状态\n'; exit 1; }
    )
}
check '实例运行级引导：default 已登记交付服务时失败关闭' bootstrap_rejects_delivered_service

# 验证服务未登记或不可解析时恢复与停止失败关闭，不凭 status 报已停止。
service_unregistered_rejected() {
    local kind=$1 work=$TEST_ROOT/unreg-$1 status=0 output
    mkdir -- "$work" || return 1
    (
        clear_config_environment
        source "$ROOT/scripts/deploy-git-mirror.sh"
        require_function gm_deploy_main || exit 1
        gm_check_platform() { return 0; }
        gm_check_private_directory() { return 0; }
        flock() { return 0; }
        gm_bootstrap_user_runlevel() { return 0; }
        gm_deploy_main --install --install-root "$work/program" || exit 1
        export REPOS=git/git
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        # 服务控制桩：按名字 -e 报未登记，绝对路径 status 仍报 3（旧实现的误导信号）。
        rc-service() {
            if [[ ${1-} == --user && ${2-} == -e ]]; then
                printf 'exists %s\n' "${3-}" >> "$work/calls"
                return 1
            fi
            printf '%s\n' "$*" >> "$work/calls"
            case "${3-}" in
                status) return 3 ;;
                stop) return 0 ;;
                *) return 90 ;;
            esac
        }
        printf stopped > "$work/instance/runtime/stopped"
        status=0
        case "$kind" in
            resume) output=$(gm_resume_instance "$work/instance" "$work/program" 2>&1) || status=$? ;;
            stop) output=$(gm_stop_instance_service git-daemon 2>&1) || status=$? ;;
        esac
        [[ $status == 1 && $output == *'未登记或不可解析'* ]] || {
            printf '未登记服务必须失败关闭：kind=%s，status=%s，诊断=%s\n' "$kind" "$status" "$output"
            exit 1
        }
        [[ $(<"$work/instance/runtime/stopped") == stopped ]] || exit 1
    )
}
check '未登记服务恢复失败关闭（服务边界桩）' service_unregistered_rejected resume
check '未登记服务停止失败关闭（服务边界桩）' service_unregistered_rejected stop

# 用真实配置读取和独立消费者进程验证服务传参，仅替换平台、私有权限与锁边界。
service_effective_config() {
    local scenario=$1 work=$TEST_ROOT/service-config-$1 status=0 output
    local expected_port=12345 expected_address=127.0.0.1 expected_timezone=UTC
    mkdir -- "$work" || return 1
    clear_config_environment
    source "$ROOT/scripts/deploy-git-mirror.sh"
    require_function gm_with_runtime_environment || return 1
    # 平台与锁边界桩不代替实际配置、安装记录或服务定义读取。
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    flock() { return 0; }
    gm_bootstrap_user_runlevel() { return 0; }
    gm_deploy_main --install --install-root "$work/program" || return 1
    export REPOS=git/git
    gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || return 1
    printf '%s\n' 'GIT_PORT=12345' 'LISTEN_ADDRESS=127.0.0.1' 'TZ=UTC' 'CRON_SCHEDULE=15 * * * *' > "$work/instance/config/mirror.env"
    case "$scenario" in
        defaults)
            printf '%s\n' '# 使用真实默认配置' > "$work/instance/config/mirror.env"
            expected_port=9418; expected_address=0.0.0.0; expected_timezone=Asia/Shanghai
            ;;
        environment)
            export GIT_PORT=23456 LISTEN_ADDRESS=::1 TZ=Asia/Hong_Kong
            expected_port=23456; expected_address=::1; expected_timezone=Asia/Hong_Kong
            ;;
        invalid)
            printf '%s\n' 'LISTEN_ADDRESS=::1:' > "$work/instance/config/mirror.env"
            export LISTEN_ADDRESS=127.0.0.1
            ;;
    esac
    cp -- "$work/instance/config/mirror.env" "$work/before" || return 1
    gm_with_runtime_environment "$work/instance" "$work/program" bash -c '
        printf "%s\n" "--port=$GIT_PORT --listen=$LISTEN_ADDRESS --base-path=$RUN_ROOT/repos" "$TZ" "$ENABLE_CRON" "$CRON_SCHEDULE" "$XDG_RUNTIME_DIR/git-daemon.pid" > "$1"
    ' service-consumer "$work/consumer" > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    cmp -s -- "$work/before" "$work/instance/config/mirror.env" || return 1
    if [[ $scenario == invalid ]]; then
        [[ $status == 1 && $output == 'git-mirror: 配置值非法：LISTEN_ADDRESS' && ! -e $work/consumer ]] || return 1
        return 0
    fi
    [[ $status == 0 && -f $work/consumer ]] || { printf '%s\n' "$output"; return 1; }
    local -a received=()
    mapfile -t received < "$work/consumer"
    [[ ${received[0]} == *"--port=$expected_port"* && ${received[0]} == *"--listen=$expected_address"* ]] || return 1
    [[ ${received[0]} == *"--base-path=$work/instance/repos"* ]] || return 1
    [[ ${received[1]} == "$expected_timezone" && ${received[2]} == yes ]] || return 1
    [[ ${received[4]} == "$work/instance/runtime/git-daemon.pid" ]] || return 1
    if [[ $scenario == defaults ]]; then
        [[ ${received[3]} == '0 * * * *' ]] || return 1
    else
        [[ ${received[3]} == '15 * * * *' ]] || return 1
    fi
    if [[ $scenario == environment ]]; then
        [[ $GIT_PORT == 23456 && $LISTEN_ADDRESS == ::1 && $TZ == Asia/Hong_Kong ]] || return 1
    else
        [[ ! -v GIT_PORT && ! -v LISTEN_ADDRESS && ! -v TZ ]] || return 1
    fi
    return 0
}

for scenario in defaults file environment invalid; do
    check "有效配置辅助接口（非生产接线）：$scenario（平台和锁边界桩）" service_effective_config "$scenario"
done

# 同时验证真实地址校验器与文件配置读取，非法文件不能被环境覆盖掩盖。
ipv6_config_boundary() {
    local address=$1 expected_status=$2 direct_status=0 config_status=0 output
    local file=$TEST_ROOT/ipv6.conf before
    clear_config_environment
    printf 'LISTEN_ADDRESS=%s\n' "$address" > "$file"
    before=$(<"$file")
    gm_validate_address "$address" || direct_status=$?
    [[ $direct_status == "$expected_status" ]] || {
        printf 'IPv6 校验返回异常：%s，实际=%s，预期=%s\n' "$address" "$direct_status" "$expected_status"
        return 1
    }
    if [[ $expected_status == 0 ]]; then
        gm_load_config "$file" || return 1
        [[ ${GM_CONFIG[LISTEN_ADDRESS]} == "$address" ]] || return 1
    else
        export LISTEN_ADDRESS=127.0.0.1
        output=$(gm_load_config "$file" 2>&1) || config_status=$?
        [[ $config_status == 1 && $output == 'git-mirror: 配置值非法：LISTEN_ADDRESS' ]] || {
            printf 'IPv6 配置拒绝异常：%s，status=%s，诊断=%s\n' "$address" "$config_status" "$output"
            return 1
        }
    fi
    [[ $(<"$file") == "$before" ]]
}

for address in '::' '::1' '1::' '2001:db8::1'; do
    check "IPv6 合法地址及配置读取：$address" ipv6_config_boundary "$address" 0
done
for address in '::1:' '1::2:' ':1::2' ':1:2:3:4:5:6:7'; do
    check "IPv6 非法地址及配置拒绝：$address" ipv6_config_boundary "$address" 1
done

# 权限元数据桩只替换指定节点的 stat 返回值，不声称验证 Linux ACL 或挂载。
permission_write_boundary() {
    local scenario=$1 work=$TEST_ROOT/permission-$1 checked fixture_permission_mode expected= output status=0
    mkdir -p -- "$work/ancestor/protected" || return 1
    printf '%s\n' sentinel > "$work/ancestor/protected/data"
    case "$scenario" in
        directory-group) checked=$work/ancestor/protected; fixture_permission_mode=770; expected='目录允许组或其他用户写入' ;;
        directory-other) checked=$work/ancestor/protected; fixture_permission_mode=707; expected='目录允许组或其他用户写入' ;;
        protected-sticky) checked=$work/ancestor/protected; fixture_permission_mode=1777; expected='目录允许组或其他用户写入' ;;
        ancestor-writable) checked=$work/ancestor; fixture_permission_mode=777; expected='共享祖先缺少 sticky 保护' ;;
        ancestor-sticky) checked=$work/ancestor; fixture_permission_mode=1777 ;;
        ancestor-system) checked=$work/ancestor; fixture_permission_mode=755 ;;
        file-group) checked=$work/ancestor/protected/data; fixture_permission_mode=660; expected='文件允许组或其他用户写入' ;;
        file-other) checked=$work/ancestor/protected/data; fixture_permission_mode=606; expected='文件允许组或其他用户写入' ;;
        normal) checked=$work/ancestor/protected/data; fixture_permission_mode=600 ;;
        *) return 1 ;;
    esac
    # 只模拟目标权限及两个受信任祖先的所有者，其余元数据来自真实临时树。
    stat() {
        if [[ ${1-} == -c && ${3-} == -- && ${4-} == "$checked" ]]; then
            if [[ $2 == %a ]]; then printf '%s\n' "$fixture_permission_mode"; return 0; fi
            if [[ $2 == %u && ( $scenario == ancestor-system || $scenario == ancestor-sticky ) ]]; then
                printf '0\n'
                return 0
            fi
        fi
        command stat "$@"
    }
    # 记录异常权限检查是否擅自尝试修复，不改变宿主或测试树权限。
    chmod() { printf 'chmod\n' >> "$work/permission-writes"; return 99; }
    chown() { printf 'chown\n' >> "$work/permission-writes"; return 99; }
    case "$scenario" in
        file-*|normal) output=$(gm_validate_file "$work/ancestor/protected/data" read 2>&1) || status=$? ;;
        *) output=$(gm_validate_path "$work/ancestor/protected" read 2>&1) || status=$? ;;
    esac
    [[ $(<"$work/ancestor/protected/data") == sentinel ]] || return 1
    [[ ! -e $work/permission-writes ]] || return 1
    [[ $(stat -c %a -- "$checked") == "$fixture_permission_mode" ]] || return 1
    if [[ -n $expected ]]; then
        [[ $status == 1 && $output == *"$expected"* ]] || {
            printf '权限断言失败：%s，status=%s，诊断=%s\n' "$scenario" "$status" "$output"
            return 1
        }
    else
        [[ $status == 0 && -z $output ]] || {
            printf '正常权限对照失败：%s，status=%s，诊断=%s\n' "$scenario" "$status" "$output"
            return 1
        }
    fi
    return 0
}

for scenario in directory-group directory-other protected-sticky ancestor-writable ancestor-sticky ancestor-system file-group file-other normal; do
    check "非授权写入边界：$scenario（权限元数据桩）" permission_write_boundary "$scenario"
done

for scenario in default scheduler-installed scheduler-missing capability-missing repos config credentials logs confirm-no confirm-yes stop-failure busy lock-error missing-flock missing-openrc forged-record missing-record dangerous-root linked-repos; do
    check "临时实例卸载：$scenario（服务、权限及锁边界桩）" uninstall_behavior "$scenario"
done
check '同步服务使用独立安装路径（仅定义接线）' service_instance_paths git-mirror-sync
check '刷新服务使用独立安装路径（仅定义接线）' service_instance_paths git-mirror-hosts
check '调度服务使用独立安装路径（仅定义接线）' service_instance_paths git-mirror-scheduler
check 'daemon 使用实例仓库和运行路径（仅定义接线）' service_instance_paths git-daemon
check '操作按实例共享锁再同步排他锁进入（接口边界桩）' operation_lock_order success
check '操作锁忙返回 75 并释放实例锁（接口边界桩）' operation_lock_order busy
check '停止标记拒绝新操作并释放实例锁（接口边界桩）' operation_lock_order stopped
check '初始化缺少 flock 时不写配置或记录（依赖边界桩）' initialize_boundary_failure missing
check '初始化运行目录权限异常时不写配置或记录（权限边界桩）' initialize_boundary_failure permissions
check '初始化实例锁忙时不写配置或记录（锁边界桩）' initialize_boundary_failure busy
check '锁依赖缺失非零退出且不截断（依赖边界桩）' lock_boundary_case missing
check '忙锁返回 75 且不截断（锁边界桩）' lock_boundary_case busy
check '锁系统错误不能当作忙锁（锁边界桩）' lock_boundary_case error
check '排他锁采用非阻塞和独立忙锁码（锁边界桩）' lock_boundary_case success
check '锁文件链接拒绝且不触碰外部目标（Git Bash 链接）' lock_symlink_rejected
check '锁名称不能穿越实例目录' lock_name_rejected
check '同步入口在非 Alpine 平台写入前拒绝' entry_platform_rejected_before_write git-mirror-sync.sh
check '刷新入口在非 Alpine 平台写入前拒绝' entry_platform_rejected_before_write update-github-hosts.sh
check '部署入口加载无副作用并提供显式主函数' entry_source_safe deploy-git-mirror.sh gm_deploy_main
check '路径预检不创建缺失目标' path_valid_without_creation
for input in '' '/' '/tmp' '/etc' '/usr' '/var' '/var/lib' 'relative/instance' "$TEST_ROOT/../escape" "$TEST_ROOT/./instance"; do
    check "危险路径拒绝：$input" path_rejected "$input"
done
check '中间符号链接拒绝' path_symlink_rejected
check '普通文件不能充当实例路径' path_file_rejected
check '实际 UID 为零拒绝（身份边界桩）' identity_root_rejected real
check '有效 UID 为零拒绝（身份边界桩）' identity_root_rejected effective
check '当前真实非零身份通过' identity_current_user
check '非 Alpine 平台拒绝（uname 边界桩）' platform_non_alpine_rejected
check '安装不要求 REPOS、不读取凭据、不创建运行目录（平台边界桩）' install_without_runtime_config
check '重复初始化保留配置与实例环境（平台边界桩）' initialize_preserves_config
check '同步入口加载无副作用并提供显式主函数' entry_source_safe git-mirror-sync.sh gm_sync_main
check '刷新入口加载无副作用并提供显式主函数' entry_source_safe update-github-hosts.sh gm_hosts_main
check '同步凭据写入私密状态且保持配置字节不变' sync_credentials_state_is_private
# 向负向断言注入不相关错误，验证断言不会把任意非零误当成预期失败。
negative_assertion_reason_guard() {
    local scenario=$1
    case "$scenario" in
        config)
            # 故障注入只替换此子 Shell 中的解析器，不改变生产代码。
            gm_load_config() { gm_error '故障注入：不相关的提前失败'; }
            if config_rejected 'GIT_PORT=80' '配置值非法：GIT_PORT'; then
                printf '配置负向断言错误接受了不相关诊断\n'
                return 1
            fi
            ;;
        repos)
            # 不相关诊断和未清理数组都不能被当成正确的预检拒绝。
            gm_parse_repos() { gm_error '故障注入：不相关的提前失败'; }
            if repos_rejected 'owner/' '' '仓库名称必须为 owner/repo 且不带 .git 后缀'; then
                printf '仓库负向断言错误接受了不相关诊断\n'
                return 1
            fi
            ;;
        lock)
            # 故障注入不调用 flock，原有宽松断言不能据此宣布锁错误覆盖通过。
            gm_lock_acquire() { gm_error '故障注入：未到达锁工具'; }
            if lock_boundary_case error; then
                printf '锁负向断言错误接受了未到达锁工具的失败\n'
                return 1
            fi
            ;;
        tz)
            # 故障注入让配置加载器固定返回卷内值，验证 TZ 优先级断言不会据此误判通过。
            gm_load_config() { declare -gA GM_CONFIG=([TZ]=Asia/Shanghai); return 0; }
            if config_timezone_environment_override; then
                printf 'TZ 优先级断言错误接受了固定卷内值\n'
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
    return 0
}

check '负向断言拒绝错误原因：config（故障注入）' negative_assertion_reason_guard config
check '负向断言拒绝错误原因：repos（故障注入）' negative_assertion_reason_guard repos
check '负向断言拒绝错误原因：lock（故障注入）' negative_assertion_reason_guard lock
check '负向断言拒绝错误原因：TZ 优先级（故障注入）' negative_assertion_reason_guard tz
check '配置保留等号与 cron 原始字符串' config_values
check '显式环境、文件、默认值优先级及可选空值' config_precedence
check '重复键拒绝' config_rejected $'GIT_PORT=12345\nGIT_PORT=23456' '配置键重复：GIT_PORT'
check '未知键拒绝' config_rejected 'UNSUPPORTED=value' '配置第 1 行包含不支持的键，旧 Shell 配置不可执行或自动转换'
check '历史卷 REPOS 拒绝' config_rejected 'REPOS=git/git' '配置第 1 行包含不支持的键，旧 Shell 配置不可执行或自动转换'
check '历史卷 SHORT_LINKS 拒绝' config_rejected 'SHORT_LINKS=git/git git' '配置第 1 行包含不支持的键，旧 Shell 配置不可执行或自动转换'
check '配置内 Token 拒绝' config_rejected 'GITHUB_TOKEN=fixture' '配置第 1 行包含不支持的键，旧 Shell 配置不可执行或自动转换'
check '旧 Shell 引号配置拒绝而非执行或转换' config_rejected 'GIT_PORT="12345"' '配置值非法：GIT_PORT'
check '非法端口不被环境覆盖掩盖' config_rejected 'GIT_PORT=80' '配置值非法：GIT_PORT'
check '非法开关拒绝' config_rejected 'ENABLE_CRON=perhaps' '配置值非法：ENABLE_CRON'
check '非法 cron 拒绝' config_rejected 'CRON_SCHEDULE=99 99 * * *' '配置值非法：CRON_SCHEDULE'
check '非 HTTPS 来源拒绝' config_rejected 'HOSTS_URL=http://example.invalid/meta' '配置值非法：HOSTS_URL'
check '显式必填空值拒绝' config_empty_required
check '命令替换与分号绝不执行' config_no_execution
check '已有配置字节不变' config_unchanged
check 'TZ 显式环境变量覆盖卷内配置且字节不变' config_timezone_environment_override
check 'TZ 未设置时读取卷内值、缺失时默认 Asia/Shanghai' config_timezone_volume_and_default
check 'TZ 非法值拒绝且不触碰卷内字节' config_timezone_invalid_rejected
check '凭据互斥且诊断不泄漏 Token' config_credentials
check '合法多仓库及 git/git git 映射预检' repos_valid
for input in '' 'owner/' '/repo' 'owner/repo/extra' 'owner/repo.git' '../repo' 'git/git;git/git main' 'git/git;' ';git/git' 'git/git;;owner/repo' 'git/git HEAD' 'git/git --help' 'git/git *' 'git/git main,' 'git/git ,main' 'git/git main,,next' 'git/git main,main' 'git/git main..next' 'git/git main #comment' $'git/git\nowner/repo' $'git/git\r'; do
    case "$input" in
        ''|$'git/git\nowner/repo'|$'git/git\r') expected='REPOS 必填，REPOS/SHORT_LINKS 必须为单行字符串' ;;
        'owner/'|'/repo'|'owner/repo/extra'|'owner/repo.git'|'../repo') expected='仓库名称必须为 owner/repo 且不带 .git 后缀' ;;
        'git/git;git/git main') expected='REPOS 包含重复仓库' ;;
        'git/git;'|';git/git'|'git/git;;owner/repo') expected='REPOS 包含空仓库项' ;;
        'git/git HEAD'|'git/git --help') expected='不接受 HEAD 或选项形式的分支' ;;
        'git/git *'|'git/git main..next') expected='分支引用格式非法' ;;
        'git/git main,'|'git/git ,main'|'git/git main,,next') expected='分支列表包含空项' ;;
        'git/git main,main') expected='仓库包含重复分支' ;;
        'git/git main #comment') expected='仓库分支字段为空或包含空白' ;;
    esac
    check "非法仓库或分支拒绝：$input" repos_rejected "$input" '' "$expected"
done
for input in 'other/repo name' 'git/git .' 'git/git ..' 'git/git bad..name' 'git/git ../bad' 'git/git bad/name' 'git/git name.git' 'git/git two names' 'git/git alias;git/git other' 'git/git same;owner/repo same' 'git/git alias;' $'git/git alias\n'; do
    case "$input" in
        'other/repo name') expected='短名目标不在 REPOS 中' ;;
        'git/git alias;git/git other'|'git/git same;owner/repo same') expected='短名或映射目标重复' ;;
        'git/git alias;') expected='SHORT_LINKS 包含空映射' ;;
        $'git/git alias\n') expected='REPOS 必填，REPOS/SHORT_LINKS 必须为单行字符串' ;;
        *) expected='短名格式非法' ;;
    esac
    check "非法短名或关联拒绝：$input" repos_rejected 'git/git;owner/repo' "$input" "$expected"
done
check '预检无命令执行或链接创建副作用' repos_no_side_effects
printf '基础行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
