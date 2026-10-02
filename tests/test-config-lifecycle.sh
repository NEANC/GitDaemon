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
