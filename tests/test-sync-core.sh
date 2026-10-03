#!/usr/bin/env bash
# 同步核心行为测试：以本地临时 bare 上游构造确定性场景，不访问公网。
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-sync-core.XXXXXXXX") || exit 1
CHECKS=0
FAILURES=0

# 仅清理本测试通过 mktemp 创建的目录。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

if [[ -f $ROOT/scripts/git-mirror-sync.sh ]]; then
    source "$ROOT/scripts/git-mirror-sync.sh"
fi

# 同步函数读取的运行时变量固定为本地值，默认走系统 DNS 传输路径，避免宿主环境影响断言。
export GITHUB_HOST=github.com
GM_TRANSPORT_SEQUENCE=(system)
export LOG_FILE=$TEST_ROOT/sync.log
: > "$LOG_FILE"

# 每个用例在独立子 Shell 中运行，避免全局状态互相污染。
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

# 建立含多分支、标签与 notes 的本地 bare 上游，输出用于播种引用的提交哈希。
build_upstream() {
    local up=$1 work=$2 commit
    git init -q --bare "$up" || return 1
    git init -q "$work" || return 1
    git -C "$work" -c user.email=test@example.invalid -c user.name=test -c commit.gpgsign=false \
        commit -q --allow-empty -m '首次提交' || return 1
    git -C "$work" -c user.email=test@example.invalid -c user.name=test -c commit.gpgsign=false \
        commit -q --allow-empty -m '第二个提交' || return 1
    commit=$(git -C "$work" rev-parse HEAD) || return 1
    git -C "$work" push -q "$up" HEAD:refs/heads/main || return 1
    git -C "$work" push -q "$up" "$commit:refs/heads/dev" || return 1
    git -C "$work" push -q "$up" "$commit:refs/tags/v1" || return 1
    git --git-dir="$up" update-ref refs/notes/commits "$commit" || return 1
    git --git-dir="$up" symbolic-ref HEAD refs/heads/main || return 1
    printf '%s' "$commit"
}

# 建立指向本地上游的镜像裸仓库。
init_mirror() {
    local dir=$1 up=$2
    git init -q --bare "$dir" || return 1
    git --git-dir="$dir" remote add origin "$up" || return 1
}

# 配置在非仓库目录上必须显式失败，不得静默吞掉配置错误。
configure_propagates_failure() {
    require_function configure_fetch || return 1
    if configure_fetch "$TEST_ROOT/missing-repo" "" 2>/dev/null; then
        printf '配置失败被吞掉\n'
        return 1
    fi
    return 0
}

# 仅当配置键不存在（退出码 5）时容错，缺键后仍写入完整 refspec。
configure_tolerates_absent_key() {
    require_function configure_fetch || return 1
    local dir=$TEST_ROOT/absent-key.git
    init_mirror "$dir" "$TEST_ROOT/absent-upstream.git" || return 1
    git --git-dir="$dir" config --unset-all remote.origin.fetch || return 1
    configure_fetch "$dir" "" || return 1
    [[ $(git --git-dir="$dir" config --get-all remote.origin.fetch) == '+refs/*:refs/*' ]]
}

# 配置键不存在（退出码 5）时必须视为已达成，返回 0。
configure_unset_absent_key_returns_zero() {
    require_function configure_unset || return 1
    local dir=$TEST_ROOT/unset-absent.git
    git init -q --bare "$dir" || return 1
    configure_unset "$dir" remote.origin.fetch
}

# 非 Git 目录上删除配置键必须原样返回 Git 原生失败码 128，不得被吞掉。
configure_unset_failure_returns_128() {
    require_function configure_unset || return 1
    local rc=0
    configure_unset "$TEST_ROOT/unset-missing-dir" remote.origin.fetch || rc=$?
    [[ $rc -eq 128 ]] || { printf '失败退出码应为 128，实际：%s\n' "$rc"; return 1; }
}

# 完整镜像模式不得残留 --no-tags，从指定分支切回后必须恢复标签抓取。
configure_full_restores_tags() {
    require_function configure_fetch || return 1
    local dir=$TEST_ROOT/tags-toggle.git
    init_mirror "$dir" "$TEST_ROOT/tags-upstream.git" || return 1
    configure_fetch "$dir" main || return 1
    [[ $(git --git-dir="$dir" config --get remote.origin.tagOpt) == --no-tags ]] || return 1
    configure_fetch "$dir" "" || return 1
    if git --git-dir="$dir" config --get remote.origin.tagOpt >/dev/null 2>&1; then
        printf '完整镜像模式仍残留 tagOpt\n'
        return 1
    fi
    [[ $(git --git-dir="$dir" config --get remote.origin.mirror) == true ]]
}

# 拉取必须经由原子事务执行，并保留 Git 原生进度与错误输出通道。
update_repo_passes_atomic() {
    require_function update_repo || return 1
    local dir=$TEST_ROOT/atomic.git rec=$TEST_ROOT/atomic.args
    mkdir -p "$dir" || return 1
    : > "$rec"
    local LOG_FILE=$TEST_ROOT/atomic.log
    git() { printf '%s\n' "$@" >> "$rec"; return 0; }
    update_repo owner/repo "$dir" "" || return 1
    grep -qx -- '--atomic' "$rec" || return 1
    grep -qx -- 'fetch' "$rec" || return 1
    : > "$dir/git-daemon-export-ok"
}

# 输出过滤仅隐藏常规引用明细，且不得改变 Git 原命令的退出状态。
run_cmd_preserves_status_and_filters() {
    require_function run_cmd || return 1
    local LOG_FILE=$TEST_ROOT/run-cmd.log out
    : > "$LOG_FILE"
    if run_cmd false; then
        printf '失败状态被过滤改变\n'
        return 1
    fi
    out=$(run_cmd bash -c 'printf " * [new branch]      main -> main\n"; printf "error: 需要保留的错误\n"') || return 1
    [[ $out == *'需要保留的错误'* ]] || { printf '错误信息被过滤：%s\n' "$out"; return 1; }
    [[ $out != *'[new branch]'* ]] || { printf '常规引用明细未过滤：%s\n' "$out"; return 1; }
    grep -Fq -- '[new branch]' "$LOG_FILE"
}

# 完整镜像拉取应写入所有分支、标签与 notes，并在成功后发布仓库。
update_repo_mirror_fetch() {
    require_function update_repo || return 1
    local up=$TEST_ROOT/mirror-up.git dir=$TEST_ROOT/mirror.git
    build_upstream "$up" "$TEST_ROOT/mirror-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/main || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/dev || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/tags/v1 || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/notes/commits || return 1
    [[ -f $dir/git-daemon-export-ok ]]
}

# 拉取失败时保留既有引用、不写发布标记并返回非零。
update_repo_failure_retains_cache() {
    require_function update_repo || return 1
    local up=$TEST_ROOT/retain-up.git dir=$TEST_ROOT/retain.git
    build_upstream "$up" "$TEST_ROOT/retain-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    git --git-dir="$dir" fetch -q "$up" '+refs/heads/main:refs/heads/keep' '+refs/heads/main:refs/tags/keep-tag' || return 1
    git --git-dir="$dir" remote set-url origin "$TEST_ROOT/unreachable.git" || return 1
    if update_repo owner/repo "$dir" main 2>/dev/null; then
        printf '上游不可达却报告成功\n'
        return 1
    fi
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/keep || { printf '既有分支被删除\n'; return 1; }
    git --git-dir="$dir" show-ref --verify --quiet refs/tags/keep-tag || { printf '范围外引用被删除\n'; return 1; }
    [[ ! -e $dir/git-daemon-export-ok ]] || { printf '失败时写入发布标记\n'; return 1; }
    return 0
}

# 写入发布标记失败必须使本次同步失败。
update_repo_marker_failure() {
    require_function update_repo || return 1
    local up=$TEST_ROOT/marker-up.git dir=$TEST_ROOT/marker.git
    build_upstream "$up" "$TEST_ROOT/marker-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    rm -f -- "$dir/git-daemon-export-ok" || return 1
    mkdir -- "$dir/git-daemon-export-ok" || return 1
    if update_repo owner/repo "$dir" "" 2>/dev/null; then
        printf '发布标记写入失败未被发现\n'
        return 1
    fi
    return 0
}

# 指定分支模式成功后删除范围外引用并把 HEAD 指向首个所选分支。
branch_scope_prunes_and_sets_head() {
    require_function update_repo || return 1
    require_function prune_unselected_refs || return 1
    local up=$TEST_ROOT/scope-up.git dir=$TEST_ROOT/scope.git
    build_upstream "$up" "$TEST_ROOT/scope-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    update_repo owner/repo "$dir" dev || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/dev || return 1
    if git --git-dir="$dir" show-ref --verify --quiet refs/heads/main; then
        printf '范围外分支未删除\n'
        return 1
    fi
    if git --git-dir="$dir" show-ref --verify --quiet refs/tags/v1; then
        printf '范围外标签未删除\n'
        return 1
    fi
    if git --git-dir="$dir" show-ref --verify --quiet refs/notes/commits; then
        printf '范围外 notes 未删除\n'
        return 1
    fi
    [[ $(git --git-dir="$dir" symbolic-ref HEAD) == refs/heads/dev ]] || return 1
    [[ -f $dir/git-daemon-export-ok ]]
}

# 从指定分支切回完整镜像必须恢复全部分支、标签与默认 HEAD。
branch_then_full_restores_mirror() {
    require_function update_repo || return 1
    local up=$TEST_ROOT/restore-up.git dir=$TEST_ROOT/restore.git
    build_upstream "$up" "$TEST_ROOT/restore-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    update_repo owner/repo "$dir" dev || return 1
    update_repo owner/repo "$dir" "" || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/main || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/dev || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/tags/v1 || return 1
    git --git-dir="$dir" show-ref --verify --quiet refs/notes/commits || return 1
    [[ $(git --git-dir="$dir" symbolic-ref HEAD) == refs/heads/main ]]
}

# 所选分支缺失时不得删除任何范围外引用。
prune_refuses_when_selected_missing() {
    require_function prune_unselected_refs || return 1
    local up=$TEST_ROOT/prune-up.git dir=$TEST_ROOT/prune.git
    build_upstream "$up" "$TEST_ROOT/prune-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    if prune_unselected_refs "$dir" dev,missing 2>/dev/null; then
        printf '所选分支缺失却报告成功\n'
        return 1
    fi
    git --git-dir="$dir" show-ref --verify --quiet refs/heads/main || { printf '缺失时误删分支\n'; return 1; }
    git --git-dir="$dir" show-ref --verify --quiet refs/tags/v1 || { printf '缺失时误删标签\n'; return 1; }
    return 0
}

# 完整镜像模式跟随上游默认 HEAD 的变化。
head_follows_upstream_default() {
    require_function update_repo || return 1
    local up=$TEST_ROOT/head-up.git dir=$TEST_ROOT/head.git
    build_upstream "$up" "$TEST_ROOT/head-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    [[ $(git --git-dir="$dir" symbolic-ref HEAD) == refs/heads/main ]] || return 1
    git --git-dir="$up" symbolic-ref HEAD refs/heads/dev || return 1
    update_repo owner/repo "$dir" "" || return 1
    [[ $(git --git-dir="$dir" symbolic-ref HEAD) == refs/heads/dev ]]
}

# 报告每个分支的 12 位短哈希、提交摘要与独立成行的提交时间。
report_short_hash_and_time() {
    require_function report_branches || return 1
    local up=$TEST_ROOT/report-up.git dir=$TEST_ROOT/report.git
    local LOG_FILE=$TEST_ROOT/report.log
    build_upstream "$up" "$TEST_ROOT/report-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    : > "$LOG_FILE"
    report_branches owner/repo "$dir" main success || return 1
    grep -Eq 'main: [0-9a-f]{12} 第二个提交' "$LOG_FILE" || { printf '短哈希或摘要不正确\n'; return 1; }
    grep -Eq '提交时间：[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG_FILE" || { printf '缺少独立提交时间行\n'; return 1; }
    return 0
}

# 没有本地分支时明确提示，而不是静默返回。
report_empty_repo_prompts() {
    require_function report_branches || return 1
    local dir=$TEST_ROOT/empty.git
    local LOG_FILE=$TEST_ROOT/empty.log
    git init -q --bare "$dir" || return 1
    : > "$LOG_FILE"
    report_branches owner/repo "$dir" "" success || return 1
    grep -Fq '没有本地分支可报告' "$LOG_FILE"
}

# 分支枚举失败必须可见且返回非零，不得被吞掉。
report_enumeration_error_not_swallowed() {
    require_function report_branches || return 1
    local dir=$TEST_ROOT/not-a-repo
    local LOG_FILE=$TEST_ROOT/enum.log
    mkdir -p "$dir" || return 1
    : > "$LOG_FILE"
    if report_branches owner/repo "$dir" "" success 2>/dev/null; then
        printf '枚举失败被吞掉\n'
        return 1
    fi
    grep -Fq '无法读取本地分支列表' "$LOG_FILE"
}

# 完整镜像成功后报告必须枚举全部本地分支，而非仅单一指定分支。
report_full_mirror_enumerates_branches() {
    require_function report_branches || return 1
    local up=$TEST_ROOT/enum-full-up.git dir=$TEST_ROOT/enum-full.git
    local LOG_FILE=$TEST_ROOT/enum-full.log
    build_upstream "$up" "$TEST_ROOT/enum-full-work" >/dev/null || return 1
    init_mirror "$dir" "$up" || return 1
    update_repo owner/repo "$dir" "" || return 1
    : > "$LOG_FILE"
    report_branches owner/repo "$dir" "" success || return 1
    grep -Eq 'main: [0-9a-f]{12}' "$LOG_FILE" || { printf '未报告 main 分支\n'; return 1; }
    grep -Eq 'dev: [0-9a-f]{12}' "$LOG_FILE" || { printf '未报告 dev 分支\n'; return 1; }
    return 0
}

# 从有效快照在内存构造 http.curloptResolve 参数数组，多个地址全部保留。
resolve_args_builds_mapping() {
    require_function load_resolve_args || return 1
    local snapshot=$TEST_ROOT/resolve.snapshot joined
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GITHUB_HOST=github.com
    printf '# FORMAT=1\n# SOURCE=x\n# FETCHED=x\n# DIGEST=sha256:00\n# COUNT=2\n140.82.121.3 github.com\n140.82.121.4 github.com\n' > "$snapshot"
    load_resolve_args "$snapshot" || return 1
    joined=" ${GM_RESOLVE_ARGS[*]} "
    [[ $joined == *' http.curloptResolve=github.com:443:140.82.121.3 '* ]] || return 1
    [[ $joined == *' http.curloptResolve=github.com:443:140.82.121.4 '* ]]
}

# 混合快照丢弃非法记录，仅含非法地址的快照视为无效而不产生映射。
resolve_args_filter_invalid_records() {
    require_function load_resolve_args || return 1
    local snapshot=$TEST_ROOT/resolve-invalid.snapshot snapshot2=$TEST_ROOT/resolve-all-invalid.snapshot joined
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GITHUB_HOST=github.com
    printf '# FORMAT=1\n# SOURCE=x\n140.82.121.3 github.com\n10.0.0.1 github.com\n' > "$snapshot"
    load_resolve_args "$snapshot" || return 1
    joined=" ${GM_RESOLVE_ARGS[*]} "
    [[ $joined == *'http.curloptResolve=github.com:443:140.82.121.3'* ]] || return 1
    [[ $joined != *10.0.0.1* ]] || return 1
    printf '# FORMAT=1\n# SOURCE=x\n10.0.0.1 github.com\n127.0.0.1 github.com\n' > "$snapshot2"
    load_resolve_args "$snapshot2" || return 1
    [[ ${#GM_RESOLVE_ARGS[@]} -eq 0 ]]
}

# ENABLE_HOSTS_UPDATE=no 时不读取也不应用快照映射。
resolve_args_disabled_ignores_snapshot() {
    require_function load_resolve_args || return 1
    local snapshot=$TEST_ROOT/resolve-disabled.snapshot
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=no
    GITHUB_HOST=github.com
    printf '# FORMAT=1\n140.82.121.3 github.com\n' > "$snapshot"
    load_resolve_args "$snapshot" || return 1
    [[ ${#GM_RESOLVE_ARGS[@]} -eq 0 ]]
}

# 无快照文件时安全回退系统 DNS，不产生映射参数。
resolve_args_missing_snapshot() {
    require_function load_resolve_args || return 1
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GITHUB_HOST=github.com
    load_resolve_args "$TEST_ROOT/absent.snapshot" || return 1
    [[ ${#GM_RESOLVE_ARGS[@]} -eq 0 ]]
}

# 固定回退顺序：代理 → 直连加映射 → 直连系统 DNS，并按有无代理、映射与开关裁剪。
transport_sequence_order() {
    require_function build_transport_sequence || return 1
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CONFIG[PROXY_URL]=https://proxy.invalid:8443
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    build_transport_sequence || return 1
    [[ ${GM_TRANSPORT_SEQUENCE[*]} == 'proxy mapping system' ]] || return 1
    GM_CONFIG[PROXY_URL]=''
    build_transport_sequence || return 1
    [[ ${GM_TRANSPORT_SEQUENCE[*]} == 'mapping system' ]] || return 1
    GM_RESOLVE_ARGS=()
    build_transport_sequence || return 1
    [[ ${GM_TRANSPORT_SEQUENCE[*]} == 'system' ]] || return 1
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=no
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CONFIG[PROXY_URL]=https://proxy.invalid:8443
    build_transport_sequence || return 1
    [[ ${GM_TRANSPORT_SEQUENCE[*]} == 'proxy system' ]]
}

# 代理与映射互斥且所有路径保持 TLS 与受限重定向。
transport_args_paths() {
    require_function transport_args || return 1
    GM_CONFIG[PROXY_URL]=https://proxy.invalid:8443
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CREDENTIAL_ARGS=()
    local joined
    transport_args proxy || return 1
    joined=" ${GM_TRANSPORT_ARGS[*]} "
    [[ $joined == *' http.proxy=https://proxy.invalid:8443 '* ]] || return 1
    [[ $joined != *curloptResolve* ]] || return 1
    [[ $joined == *' http.followRedirects=initial '* ]] || return 1
    transport_args mapping || return 1
    joined=" ${GM_TRANSPORT_ARGS[*]} "
    [[ $joined == *curloptResolve* ]] || return 1
    [[ $joined != *http.proxy* ]] || return 1
    transport_args system || return 1
    joined=" ${GM_TRANSPORT_ARGS[*]} "
    [[ $joined != *curloptResolve* && $joined != *http.proxy* ]] || return 1
    [[ $joined == *' http.followRedirects=initial '* ]]
}

# Token 经受控凭据助手注入，绝不进入 Git argv 与日志。
credentials_never_in_argv_or_log() {
    require_function prepare_credentials || return 1
    require_function transport_args || return 1
    local LOG_FILE=$TEST_ROOT/cred.log cred_joined arg_joined
    : > "$LOG_FILE"
    GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
    GM_CONFIG[GITHUB_TOKEN_FILE]=''
    GM_CREDENTIAL_ARGS=()
    GITHUB_TOKEN=fixture-secret-token
    prepare_credentials || return 1
    cred_joined=" ${GM_CREDENTIAL_ARGS[*]} "
    [[ $cred_joined == *'credential.helper='* ]] || return 1
    [[ $cred_joined == *'GM_SYNC_TOKEN'* ]] || return 1
    [[ $cred_joined != *fixture-secret-token* ]] || return 1
    transport_args system || return 1
    arg_joined=" ${GM_TRANSPORT_ARGS[*]} "
    [[ $arg_joined == *'credential.helper='* ]] || return 1
    [[ $arg_joined != *fixture-secret-token* ]] || return 1
    ! grep -q 'fixture-secret-token' "$LOG_FILE"
}

# 凭据文件路径读取 Token 同样不进入 argv。
credentials_from_file_not_in_argv() {
    require_function prepare_credentials || return 1
    local file=$TEST_ROOT/token.file LOG_FILE=$TEST_ROOT/cred-file.log joined
    printf 'file-secret-token\n' > "$file"
    : > "$LOG_FILE"
    unset GITHUB_TOKEN
    GM_CONFIG[GITHUB_TOKEN_FILE]=$file
    GM_CREDENTIAL_ARGS=()
    prepare_credentials || return 1
    joined=" ${GM_CREDENTIAL_ARGS[*]} "
    [[ $joined != *file-secret-token* ]] || return 1
    [[ $GM_SYNC_TOKEN == file-secret-token ]]
}

# 直接路径显式清除环境代理变量，避免宿主代理影响解析结果。
clear_proxy_environment_clears() {
    require_function clear_proxy_environment || return 1
    export http_proxy=http://p.invalid https_proxy=http://p.invalid all_proxy=socks5://p.invalid
    clear_proxy_environment || return 1
    [[ -z ${http_proxy-} && -z ${https_proxy-} && -z ${all_proxy-} ]]
}

# fetch 实际带上快照映射参数，证明映射被应用到直连传输。
update_repo_applies_mapping() {
    require_function update_repo || return 1
    local dir=$TEST_ROOT/apply-mapping.git rec=$TEST_ROOT/apply-mapping.args
    mkdir -p "$dir" || return 1
    : > "$rec"
    GM_TRANSPORT_SEQUENCE=(mapping)
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CREDENTIAL_ARGS=()
    git() { printf '%s\n' "$@" >> "$rec"; return 0; }
    update_repo owner/repo "$dir" "" || return 1
    grep -qx -- 'http.curloptResolve=github.com:443:140.82.121.3' "$rec"
}

# 系统 DNS 路径不得携带任何映射参数。
update_repo_system_path_has_no_mapping() {
    require_function update_repo || return 1
    local dir=$TEST_ROOT/system-path.git rec=$TEST_ROOT/system-path.args
    mkdir -p "$dir" || return 1
    : > "$rec"
    GM_TRANSPORT_SEQUENCE=(system)
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CREDENTIAL_ARGS=()
    git() { printf '%s\n' "$@" >> "$rec"; return 0; }
    update_repo owner/repo "$dir" "" || return 1
    ! grep -q 'curloptResolve' "$rec"
}

# 首个传输路径失败时按固定顺序回退，成功即停止并记录路径与原因。
update_repo_falls_back_over_paths() {
    require_function update_repo || return 1
    local dir=$TEST_ROOT/fallback-sync.git LOG_FILE=$TEST_ROOT/fallback-sync.log
    mkdir -p "$dir" || return 1
    : > "$LOG_FILE"
    GM_TRANSPORT_SEQUENCE=(mapping system)
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CREDENTIAL_ARGS=()
    git() { return 0; }
    run_cmd() {
        if [[ " $* " == *' http.curloptResolve='* ]]; then return 1; fi
        return 0
    }
    update_repo owner/repo "$dir" "" || return 1
    grep -q '传输失败：直连加动态地址映射' "$LOG_FILE" || return 1
    grep -q '同步传输路径：直连系统 DNS' "$LOG_FILE"
}

# 全部传输路径失败时同步失败且不写发布标记。
update_repo_all_paths_fail() {
    require_function update_repo || return 1
    local dir=$TEST_ROOT/all-fail.git LOG_FILE=$TEST_ROOT/all-fail.log
    mkdir -p "$dir" || return 1
    : > "$LOG_FILE"
    GM_TRANSPORT_SEQUENCE=(mapping system)
    GM_RESOLVE_ARGS=(-c http.curloptResolve=github.com:443:140.82.121.3)
    GM_CREDENTIAL_ARGS=()
    git() { return 0; }
    run_cmd() { return 1; }
    if update_repo owner/repo "$dir" "" 2>/dev/null; then
        printf '全部传输路径失败却报告成功\n'
        return 1
    fi
    [[ ! -e $dir/git-daemon-export-ok ]]
}

check '配置失败必须显式传播（非仓库目录）' configure_propagates_failure
check '缺键容错仅接受退出码 5' configure_tolerates_absent_key
check '缺键时 configure_unset 返回 0' configure_unset_absent_key_returns_zero
check '非 Git 目录 configure_unset 返回 128' configure_unset_failure_returns_128
check '完整镜像切回后恢复标签抓取' configure_full_restores_tags
check '拉取经由 --atomic 原子事务' update_repo_passes_atomic
check '输出过滤保留错误与退出状态' run_cmd_preserves_status_and_filters
check '完整镜像拉取写入全部分支标签与 notes' update_repo_mirror_fetch
check '拉取失败保留缓存引用且不发布' update_repo_failure_retains_cache
check '发布标记写入失败视为同步失败' update_repo_marker_failure
check '指定分支缩范围并指向首个所选 HEAD' branch_scope_prunes_and_sets_head
check '切回完整镜像恢复全部引用与默认 HEAD' branch_then_full_restores_mirror
check '所选分支缺失时不清理范围外引用' prune_refuses_when_selected_missing
check '完整镜像跟随上游默认 HEAD 变化' head_follows_upstream_default
check '报告含 12 位短哈希、摘要与提交时间' report_short_hash_and_time
check '空仓库明确提示无可报告分支' report_empty_repo_prompts
check '分支枚举失败可见且非零' report_enumeration_error_not_swallowed
check '完整镜像成功枚举全部分支' report_full_mirror_enumerates_branches
check '有效快照构造多地址映射参数' resolve_args_builds_mapping
check '快照丢弃非法地址且全非法时不产生映射' resolve_args_filter_invalid_records
check '禁用开关不读取快照映射' resolve_args_disabled_ignores_snapshot
check '无快照时回退系统 DNS' resolve_args_missing_snapshot
check '固定回退顺序按开关与代理裁剪' transport_sequence_order
check '代理与映射互斥且保持 TLS 重定向限制' transport_args_paths
check 'Token 不进入 argv 与日志' credentials_never_in_argv_or_log
check '凭据文件读取的 Token 不进入 argv' credentials_from_file_not_in_argv
check '直连前清除环境代理变量' clear_proxy_environment_clears
check 'fetch 实际应用快照映射参数' update_repo_applies_mapping
check '系统 DNS 路径不带映射参数' update_repo_system_path_has_no_mapping
check '传输失败按固定顺序回退' update_repo_falls_back_over_paths
check '全部传输路径失败即同步失败' update_repo_all_paths_fail

printf '同步核心行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
