#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-foundation.XXXXXXXX") || exit 1
FAILURES=0
CHECKS=0

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
    local file=$TEST_ROOT/rejected.conf
    printf '%s\n' "$1" > "$file"
    export GIT_PORT=23456
    if gm_load_config "$file" >/dev/null 2>&1; then return 1; fi
}

# 验证显式空值不会回退为合法默认值。
config_empty_required() {
    require_function gm_load_config || return 1
    clear_config_environment
    export GIT_PORT=
    if gm_load_config "$TEST_ROOT/absent.conf" >/dev/null 2>&1; then return 1; fi
}

# 验证恶意数据既不执行命令替换，也不执行分号后的命令。
config_no_execution() {
    require_function gm_load_config || return 1
    clear_config_environment
    local file=$TEST_ROOT/injection.conf marker=$TEST_ROOT/executed
    printf 'TZ=$(touch "%s");touch "%s"\n' "$marker" "$marker" > "$file"
    if gm_load_config "$file" >/dev/null 2>&1; then return 1; fi
    [[ ! -e $marker ]]
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

# 验证互斥凭据来源不会被接受或输出到诊断中。
config_credentials() {
    require_function gm_load_config || return 1
    clear_config_environment
    export GITHUB_TOKEN=foundation-sensitive-fixture GITHUB_TOKEN_FILE=/invalid/token
    local output status
    output=$(gm_load_config "$TEST_ROOT/absent.conf" 2>&1)
    status=$?
    [[ $status != 0 && $output != *foundation-sensitive-fixture* ]]
}

# 验证多仓库分支数组及已确认的 owner 同名短名被完整保留。
repos_valid() {
    require_function gm_parse_repos || return 1
    gm_parse_repos 'git/git;octocat/Hello-World main;torvalds/linux master,next,stable' 'git/git git;octocat/Hello-World hello' || return 1
    [[ ${#GM_REPOS[@]} == 3 && ${GM_REPOS[0]} == git/git && ${GM_BRANCHES[0]} == '' && ${GM_BRANCHES[2]} == master,next,stable && ${GM_LINK_TARGETS[0]} == git/git && ${GM_LINK_NAMES[0]} == git ]]
}

# 验证所有非法项均导致整组预检失败。
repos_rejected() {
    require_function gm_parse_repos || return 1
    if gm_parse_repos "$1" "${2:-}" >/dev/null 2>&1; then return 1; fi
}

# 验证预检自身不创建目录、链接或执行输入中的命令。
repos_no_side_effects() {
    require_function gm_parse_repos || return 1
    local work=$TEST_ROOT/preflight marker=$TEST_ROOT/repo-executed
    mkdir -- "$work" || return 1
    cd -- "$work" || return 1
    if gm_parse_repos "git/git;owner/repo \$(touch $marker)" '' >/dev/null 2>&1; then return 1; fi
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
    if gm_validate_path "$1" > /dev/null 2>&1; then return 1; fi
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
    path_rejected "$TEST_ROOT/link-parent/instance"
}

# 验证文件不能被当作实例目录或目录父路径。
path_file_rejected() {
    require_function gm_validate_path || return 1
    printf '%s\n' sentinel > "$TEST_ROOT/not-directory"
    path_rejected "$TEST_ROOT/not-directory" || return 1
    path_rejected "$TEST_ROOT/not-directory/instance"
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
    if gm_check_identity > /dev/null 2>&1; then return 1; fi
}

# 验证真实当前身份；测试运行者为非零 UID 时应通过。
identity_current_user() {
    require_function gm_check_identity || return 1
    [[ $UID != 0 && $EUID != 0 ]] || return 1
    gm_check_identity
}

# 验证 Git Bash 无法冒充 Alpine；此项不是 Alpine 正向集成验证。
platform_non_alpine_rejected() {
    require_function gm_check_platform || return 1
    case "$(uname -s)" in
        MINGW*|MSYS*)
            if gm_check_platform > /dev/null 2>&1; then return 1; fi
            ;;
        *)
            printf '本用例要求已确认的 Git Bash 非 Alpine 环境\n'
            return 1
            ;;
    esac
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
    gm_lock_acquire sync exclusive || status=$?
    [[ $(<"$work/runtime/sync.lock") == "$before" ]] || return 1
    case "$scenario" in
        missing) [[ $status != 0 && $status != 75 && ! -e $work/flock-arguments ]] ;;
        busy) [[ $status == 75 ]] ;;
        error) [[ $status != 0 && $status != 75 ]] ;;
        success)
            [[ $status == 0 && -s $work/flock-arguments ]] || return 1
            local arguments
            arguments=$(<"$work/flock-arguments")
            [[ $arguments == *'-n'* && $arguments == *'-E 75'* && $arguments == *'-x'* ]]
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
    gm_lock_acquire sync exclusive > /dev/null 2>&1 || status=$?
    [[ $status != 0 && ! -e $work/called && $(<"$work/outside") == sentinel ]]
}

# 验证锁名只能为共享协议中的固定名称，不能变成任意文件路径。
lock_name_rejected() {
    require_function gm_lock_acquire || return 1
    local work=$TEST_ROOT/lock-name
    mkdir -p -- "$work/runtime" || return 1
    export RUN_ROOT=$work
    # 权限与依赖边界桩不替代锁名称校验。
    gm_check_private_directory() { return 0; }
    flock() { return 0; }
    if gm_lock_acquire ../outside exclusive > /dev/null 2>&1; then return 1; fi
    [[ ! -e $work/outside && ! -e $work/outside.lock ]]
}

# 验证关键运行入口在真实非 Alpine 平台拒绝，且尚未产生写入。
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
        export -f curl git
        bash "$ROOT/scripts/$script"
    ) > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    [[ $status != 0 && $output == *Alpine* && ! -e $work/instance ]]
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
        # 权限边界桩分别返回拒绝或通过；生产检查不能绕过。
        gm_check_private_directory() {
            [[ $scenario != permissions ]]
        }
        # 锁边界桩模拟 util-linux flock 的独立忙锁退出码。
        flock() {
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
        [[ $status != 0 && ! -e $work/instance/config/mirror.env && ! -e $work/instance/config/installation.conf ]] || exit 1
        if [[ $scenario == busy ]]; then [[ $status == 75 ]] || exit 1; fi
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
            git-daemon)
                [[ $pidfile == "$XDG_RUNTIME_DIR/git-daemon.pid" ]] || exit 1
                [[ $command_args == *"--base-path=$RUN_ROOT/repos"* && $command_args == *'--port=12345'* ]]
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
            [[ $status != 0 && $actual == "$expected" ]]
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
        gm_deploy_main --install --install-root "$work/program" || exit 1
        export REPOS=git/git ENABLE_CRON=no
        gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" || exit 1
        mkdir -p -- "$work/instance/repos/example" || exit 1
        printf '%s\n' repository > "$work/instance/repos/example/sentinel"
        printf '%s\n' credential-fixture > "$work/instance/secrets/sentinel"
        printf '%s\n' log-fixture > "$work/instance/logs/sentinel"
        printf '%s\n' 'GIT_PORT=12345' > "$work/instance/config/mirror.env"
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
        # 服务控制边界桩只允许本测试程序目录的用户模式停止调用。
        rc-service() {
            [[ ${1-} == --user && ${2-} == "$work/program/openrc/"* && ${3-} == stop && $# == 3 ]] || return 90
            printf '%s\n' "$*" >> "$work/services"
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
            default) options+=(--yes) ;;
            repos|config|credentials|logs) options+=("--delete-$scenario" --yes) ;;
            confirm-no|confirm-yes) options+=(--delete-repos) ;;
            stop-failure|busy|lock-error|missing-flock|missing-openrc|forged-record|missing-record|dangerous-root|linked-repos)
                options+=(--delete-repos --delete-config --delete-credentials --delete-logs --yes)
                ;;
        esac
        case "$scenario" in
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
            default|confirm-no)
                [[ $status == 0 ]] || { printf '%s\n' "$output"; exit 1; }
                [[ -f $run/repos/example/sentinel && -f $run/config/mirror.env && -f $run/secrets/sentinel && -f $run/logs/sentinel ]] || exit 1
                if [[ $scenario == confirm-no ]]; then [[ ! -e $work/services ]] || exit 1; fi
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
                [[ $status != 0 ]] || exit 1
                [[ -f $run/repos/example/sentinel && -f $run/config/mirror.env && -f $run/secrets/sentinel && -f $run/logs/sentinel ]] || exit 1
                if [[ $scenario == busy ]]; then [[ $status == 75 ]] || exit 1; fi
                if [[ $scenario == lock-error ]]; then [[ $status != 75 ]] || exit 1; fi
                ;;
        esac
        printf verified > "$work/verified"
    ) || return 1
    # 旧实现因 --help 退出子 Shell 时不会写此标记，应得到真实 red。
    [[ -f $work/verified ]]
}

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
    case "$scenario" in
        file-*|normal) output=$(gm_validate_file "$work/ancestor/protected/data" read 2>&1) || status=$? ;;
        *) output=$(gm_validate_path "$work/ancestor/protected" read 2>&1) || status=$? ;;
    esac
    [[ $(<"$work/ancestor/protected/data") == sentinel ]] || return 1
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

for scenario in default repos config credentials logs confirm-no confirm-yes stop-failure busy lock-error missing-flock missing-openrc forged-record missing-record dangerous-root linked-repos; do
    check "临时实例卸载：$scenario（服务、权限及锁边界桩）" uninstall_behavior "$scenario"
done
check '同步服务使用独立安装路径（仅定义接线）' service_instance_paths git-mirror-sync
check '刷新服务使用独立安装路径（仅定义接线）' service_instance_paths git-mirror-hosts
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
check 'Git Bash 非 Alpine 平台拒绝' platform_non_alpine_rejected
check '安装不要求 REPOS、不读取凭据、不创建运行目录（平台边界桩）' install_without_runtime_config
check '重复初始化保留配置与实例环境（平台边界桩）' initialize_preserves_config
check '同步入口加载无副作用并提供显式主函数' entry_source_safe git-mirror-sync.sh gm_sync_main
check '刷新入口加载无副作用并提供显式主函数' entry_source_safe update-github-hosts.sh gm_hosts_main
check '配置保留等号与 cron 原始字符串' config_values
check '显式环境、文件、默认值优先级及可选空值' config_precedence
check '重复键拒绝' config_rejected $'GIT_PORT=12345\nGIT_PORT=23456'
check '未知键拒绝' config_rejected 'UNSUPPORTED=value'
check '历史卷 REPOS 拒绝' config_rejected 'REPOS=git/git'
check '历史卷 SHORT_LINKS 拒绝' config_rejected 'SHORT_LINKS=git/git git'
check '配置内 Token 拒绝' config_rejected 'GITHUB_TOKEN=fixture'
check '旧 Shell 引号配置拒绝而非执行或转换' config_rejected 'GIT_PORT="12345"'
check '非法端口不被环境覆盖掩盖' config_rejected 'GIT_PORT=80'
check '非法开关拒绝' config_rejected 'ENABLE_CRON=perhaps'
check '非法 cron 拒绝' config_rejected 'CRON_SCHEDULE=99 99 * * *'
check '非 HTTPS 来源拒绝' config_rejected 'HOSTS_URL=http://example.invalid/meta'
check '显式必填空值拒绝' config_empty_required
check '命令替换与分号绝不执行' config_no_execution
check '已有配置字节不变' config_unchanged
check '凭据互斥且诊断不泄漏 Token' config_credentials
check '合法多仓库及 git/git git 映射预检' repos_valid
for input in '' 'owner/' '/repo' 'owner/repo/extra' 'owner/repo.git' '../repo' 'git/git;git/git main' 'git/git;' ';git/git' 'git/git;;owner/repo' 'git/git HEAD' 'git/git --help' 'git/git *' 'git/git main,' 'git/git ,main' 'git/git main,,next' 'git/git main,main' 'git/git main..next' 'git/git main #comment' $'git/git\nowner/repo' $'git/git\r'; do
    check "非法仓库或分支拒绝：$input" repos_rejected "$input"
done
for input in 'other/repo name' 'git/git .' 'git/git ..' 'git/git bad..name' 'git/git ../bad' 'git/git bad/name' 'git/git name.git' 'git/git two names' 'git/git alias;git/git other' 'git/git same;owner/repo same' 'git/git alias;' $'git/git alias\n'; do
    check "非法短名或关联拒绝：$input" repos_rejected 'git/git;owner/repo' "$input"
done
check '预检无命令执行或链接创建副作用' repos_no_side_effects
printf '基础行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
