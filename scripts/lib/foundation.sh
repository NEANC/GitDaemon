#!/usr/bin/env bash

# 输出不包含配置值和凭据的诊断，并统一返回失败。
gm_error() {
    printf 'git-mirror: %s\n' "$1" >&2
    return 1
}

# 校验十进制数的长度和范围，避免算术展开接受表达式。
gm_number_in_range() {
    local value=$1 minimum=$2 maximum=$3
    [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$value >= minimum && 10#$value <= maximum ))
}

# 校验五字段 cron，仅接受数值、范围、列表和步长。
gm_validate_cron() {
    local value=$1 index field part base step start end
    local -a fields=() parts=() minimums=(0 0 1 1 0) maximums=(59 23 31 12 7)
    [[ $value != *$'\n'* && $value != *$'\r'* ]] || return 1
    read -r -a fields <<< "$value"
    [[ ${#fields[@]} == 5 ]] || return 1
    for index in "${!fields[@]}"; do
        field=${fields[$index]}
        [[ $field != ,* && $field != *, && $field != *,,* ]] || return 1
        IFS=, read -r -a parts <<< "$field"
        for part in "${parts[@]}"; do
            base=$part
            if [[ $part == */* ]]; then
                base=${part%%/*}
                step=${part#*/}
                gm_number_in_range "$step" 1 "$((maximums[index] + 1))" || return 1
            fi
            if [[ $base == '*' ]]; then
                continue
            elif [[ $base == *-* ]]; then
                start=${base%%-*}
                end=${base#*-}
                gm_number_in_range "$start" "${minimums[$index]}" "${maximums[$index]}" || return 1
                gm_number_in_range "$end" "${minimums[$index]}" "${maximums[$index]}" || return 1
                (( 10#$start <= 10#$end )) || return 1
            else
                gm_number_in_range "$base" "${minimums[$index]}" "${maximums[$index]}" || return 1
            fi
        done
    done
    return 0
}

# 校验 HTTPS 地址结构，不执行字符串，也不允许 URL 内嵌凭据。
gm_validate_https_url() {
    local value=$1 authority host port label
    local -a labels=()
    [[ $value == https://* && $value != *[[:space:][:cntrl:]]* ]] || return 1
    authority=${value#https://}
    authority=${authority%%[/?#]*}
    [[ -n $authority && $authority != *@* ]] || return 1
    host=$authority
    if [[ $authority == *:* ]]; then
        host=${authority%%:*}
        port=${authority#*:}
        gm_number_in_range "$port" 1 65535 || return 1
    fi
    [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && $host != *..* && $host != *. ]] || return 1
    IFS=. read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        [[ $label != -* && $label != *- && ${#label} -le 63 ]] || return 1
    done
    return 0
}

# 校验监听地址，仅接受 IPv4 或不带作用域的 IPv6 字面量。
gm_validate_address() {
    local value=$1 part left right count
    local -a parts=() left_parts=() right_parts=()
    if [[ $value == *:* ]]; then
        [[ $value =~ ^[0-9A-Fa-f:]+$ && $value != *:::* ]] || return 1
        if [[ $value == *::* ]]; then
            left=${value%%::*}
            right=${value#*::}
            [[ $right != *::* ]] || return 1
            if [[ -n $left ]]; then IFS=: read -r -a left_parts <<< "$left"; fi
            if [[ -n $right ]]; then IFS=: read -r -a right_parts <<< "$right"; fi
            parts=("${left_parts[@]}" "${right_parts[@]}")
            count=${#parts[@]}
            (( count < 8 )) || return 1
        else
            [[ $value != :* && $value != *: ]] || return 1
            IFS=: read -r -a parts <<< "$value"
            [[ ${#parts[@]} == 8 ]] || return 1
        fi
        for part in "${parts[@]}"; do
            [[ $part =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
    else
        [[ $value != .* && $value != *. && $value != *..* ]] || return 1
        IFS=. read -r -a parts <<< "$value"
        [[ ${#parts[@]} == 4 ]] || return 1
        for part in "${parts[@]}"; do
            [[ $part =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
            gm_number_in_range "$part" 0 255 || return 1
        done
    fi
    return 0
}

# 对固定配置键分别校验，错误诊断只报告键名。
gm_validate_config_value() {
    local key=$1 value=$2
    [[ $value != *[[:cntrl:]]* ]] || return 1
    case "$key" in
        GIT_PORT) gm_number_in_range "$value" 1024 65535 ;;
        LISTEN_ADDRESS) gm_validate_address "$value" ;;
        ENABLE_CRON|ENABLE_HOSTS_UPDATE) [[ $value == yes || $value == no ]] ;;
        CRON_SCHEDULE|HOSTS_CRON) gm_validate_cron "$value" ;;
        TZ)
            [[ $value =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]
            ;;
        HOSTS_URL) gm_validate_https_url "$value" ;;
        HOSTS_URL_FALLBACK|PROXY_URL)
            [[ -z $value ]] || gm_validate_https_url "$value"
            ;;
        GITHUB_TOKEN_FILE)
            [[ -z $value ]] || [[ $value == /* && $value != */../* && $value != */.. && $value != */./* && $value != */. && $value != *//* ]]
            ;;
        *) return 1 ;;
    esac
}

# 按固定键读取纯数据文件，先验证文件，再合并显式环境和默认值。
gm_load_config() {
    local file=$1 line key value line_number=0
    local -A stored=()
    declare -gA GM_CONFIG=()
    GM_CONFIG=(
        [GIT_PORT]=9418
        [LISTEN_ADDRESS]=0.0.0.0
        [TZ]=Asia/Shanghai
        [ENABLE_CRON]=yes
        [CRON_SCHEDULE]='0 * * * *'
        [ENABLE_HOSTS_UPDATE]=yes
        [HOSTS_CRON]='0 3 * * *'
        [HOSTS_URL]=https://api.github.com/meta
        [HOSTS_URL_FALLBACK]=''
        [PROXY_URL]=''
        [GITHUB_TOKEN_FILE]=''
    )
    if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
        gm_error '配置必须为非符号链接的普通文件'
        return 1
    fi
    if [[ -e $file ]]; then
        [[ -r $file ]] || { gm_error '配置文件不可读'; return 1; }
        while IFS= read -r line || [[ -n $line ]]; do
            line_number=$((line_number + 1))
            [[ $line != *[[:cntrl:]]* ]] || { gm_error "配置第 $line_number 行包含控制字符"; return 1; }
            [[ -z $line || $line == \#* ]] && continue
            [[ $line == *=* ]] || { gm_error "配置第 $line_number 行不是 KEY=VALUE"; return 1; }
            key=${line%%=*}
            value=${line#*=}
            case "$key" in
                GIT_PORT|LISTEN_ADDRESS|TZ|ENABLE_CRON|CRON_SCHEDULE|ENABLE_HOSTS_UPDATE|HOSTS_CRON|HOSTS_URL|HOSTS_URL_FALLBACK|PROXY_URL|GITHUB_TOKEN_FILE) ;;
                *) gm_error "配置第 $line_number 行包含不支持的键，旧 Shell 配置不可执行或自动转换"; return 1 ;;
            esac
            [[ ! ${stored[$key]+present} ]] || { gm_error "配置键重复：$key"; return 1; }
            gm_validate_config_value "$key" "$value" || { gm_error "配置值非法：$key"; return 1; }
            stored[$key]=$value
        done < "$file"
    fi
    for key in "${!GM_CONFIG[@]}"; do
        if [[ -v $key ]]; then
            value=${!key}
            if [[ $key == GITHUB_TOKEN_FILE && -z $value && -n ${stored[$key]-} ]]; then
                gm_error '不能以显式空值清除已配置凭据来源'
                return 1
            fi
        elif [[ ${stored[$key]+present} ]]; then
            value=${stored[$key]}
        else
            value=${GM_CONFIG[$key]}
        fi
        gm_validate_config_value "$key" "$value" || { gm_error "有效配置值非法：$key"; return 1; }
        GM_CONFIG[$key]=$value
    done
    if [[ -n ${GITHUB_TOKEN-} && -n ${GM_CONFIG[GITHUB_TOKEN_FILE]} ]]; then
        gm_error 'GITHUB_TOKEN 与 GITHUB_TOKEN_FILE 互斥'
        return 1
    fi
    if [[ ${GITHUB_TOKEN-} == *[[:cntrl:]]* ]]; then
        gm_error '凭据包含非法控制字符'
        return 1
    fi
    return 0
}

# 校验仓库必须包含两个安全非空分量，且不使用 .git 后缀。
gm_validate_repo_name() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ && $value != *.git ]]
}

# 全量解析仓库和短名，成功后一次性发布数组，不创建任何仓库或链接。
gm_parse_repos() {
    local repos=$1 links=${2-} item repo branches branch name
    local -a items=() fields=() parsed_repos=() parsed_branches=() targets=() names=()
    local -A seen_repos=() seen_branches=() seen_targets=() seen_names=()
    declare -ga GM_REPOS=() GM_BRANCHES=() GM_LINK_TARGETS=() GM_LINK_NAMES=()
    [[ -n $repos && $repos != *$'\r'* && $repos != *$'\n'* && $links != *$'\r'* && $links != *$'\n'* ]] || {
        gm_error 'REPOS 必填，REPOS/SHORT_LINKS 必须为单行字符串'
        return 1
    }
    [[ $repos != \;* && $repos != *\; && $repos != *\;\;* ]] || { gm_error 'REPOS 包含空仓库项'; return 1; }
    command -v git >/dev/null 2>&1 || { gm_error '预检需要 git'; return 1; }
    IFS=';' read -r -a items <<< "$repos"
    for item in "${items[@]}"; do
        repo=$item
        branches=
        if [[ $item == *' '* ]]; then
            repo=${item%% *}
            branches=${item#* }
            while [[ $branches == ' '* ]]; do branches=${branches# }; done
            [[ -n $branches && $branches != *[[:space:]]* ]] || { gm_error '仓库分支字段为空或包含空白'; return 1; }
        fi
        gm_validate_repo_name "$repo" || { gm_error '仓库名称必须为 owner/repo 且不带 .git 后缀'; return 1; }
        [[ ! ${seen_repos[$repo]+present} ]] || { gm_error 'REPOS 包含重复仓库'; return 1; }
        seen_repos[$repo]=1
        if [[ -n $branches ]]; then
            [[ $branches != ,* && $branches != *, && $branches != *,,* ]] || { gm_error '分支列表包含空项'; return 1; }
            IFS=, read -r -a fields <<< "$branches"
            seen_branches=()
            for branch in "${fields[@]}"; do
                [[ $branch != HEAD && $branch != -* ]] || { gm_error '不接受 HEAD 或选项形式的分支'; return 1; }
                git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || { gm_error '分支引用格式非法'; return 1; }
                [[ ! ${seen_branches[$branch]+present} ]] || { gm_error '仓库包含重复分支'; return 1; }
                seen_branches[$branch]=1
            done
        fi
        parsed_repos+=("$repo")
        parsed_branches+=("$branches")
    done
    if [[ -n $links ]]; then
        [[ $links != \;* && $links != *\; && $links != *\;\;* ]] || { gm_error 'SHORT_LINKS 包含空映射'; return 1; }
        IFS=';' read -r -a items <<< "$links"
        for item in "${items[@]}"; do
            [[ $item == *' '* ]] || { gm_error '短名映射需要仓库和短名'; return 1; }
            repo=${item%% *}
            name=${item#* }
            while [[ $name == ' '* ]]; do name=${name# }; done
            gm_validate_repo_name "$repo" || { gm_error '短名目标格式非法'; return 1; }
            [[ ${seen_repos[$repo]+present} ]] || { gm_error '短名目标不在 REPOS 中'; return 1; }
            [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != *..* && $name != *.git ]] || { gm_error '短名格式非法'; return 1; }
            [[ ! ${seen_targets[$repo]+present} && ! ${seen_names[$name]+present} ]] || { gm_error '短名或映射目标重复'; return 1; }
            seen_targets[$repo]=1
            seen_names[$name]=1
            targets+=("$repo")
            names+=("$name")
        done
    fi
    GM_REPOS=("${parsed_repos[@]}")
    GM_BRANCHES=("${parsed_branches[@]}")
    GM_LINK_TARGETS=("${targets[@]}")
    GM_LINK_NAMES=("${names[@]}")
    return 0
}

# 同时核对 Shell 身份和操作系统实际、有效身份，拒绝任何零 UID。
gm_check_identity() {
    local actual effective
    actual=$(id -ru) || return 1
    effective=$(id -u) || return 1
    [[ $actual =~ ^[0-9]+$ && $effective =~ ^[0-9]+$ ]] || return 1
    if [[ $UID == 0 || $EUID == 0 || $actual == 0 || $effective == 0 || $actual != "$effective" ]]; then
        gm_error '必须以实际和有效 UID 相同的非 root 用户运行'
        return 1
    fi
    return 0
}

# 检查真实平台与用户模式能力，不接受环境变量伪造平台或跳过检查。
gm_check_platform() {
    local line alpine=no help executable
    [[ $(uname -s) == Linux && -f /etc/alpine-release && -r /etc/os-release ]] || {
        gm_error '仅支持 Alpine Linux'
        return 1
    }
    while IFS= read -r line || [[ -n $line ]]; do
        case "$line" in ID=alpine|'ID="alpine"') alpine=yes ;; esac
    done < /etc/os-release
    [[ $alpine == yes ]] || { gm_error '系统标识不是 Alpine'; return 1; }
    for executable in openrc rc-service; do
        command -v "$executable" >/dev/null 2>&1 || { gm_error '缺少 OpenRC 用户模式组件'; return 1; }
        help=$("$executable" --help 2>&1) || return 1
        [[ $help == *--user* ]] || { gm_error 'OpenRC 组件不提供用户模式'; return 1; }
    done
    return 0
}

# 检查绝对目录及每个已存在的父组件，不创建目录或修复外部所有权。
gm_validate_path() {
    local path=$1 component current= canonical nearest=/ owner
    local -a components=()
    case "$path" in
        ''|/|/tmp|/etc|/usr|/usr/local|/var|/var/lib|/var/log|/home|/root|/run|/srv|/opt|/bin|/sbin|/dev|/proc|/sys)
            gm_error '拒绝危险根目录'; return 1 ;;
    esac
    [[ $path == /* && $path != */ && $path != *//* && $path != *[[:cntrl:]]* ]] || {
        gm_error '路径必须为明确的绝对实例目录'; return 1;
    }
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || { gm_error '路径包含非法分量'; return 1; }
        current=$current/$component
        [[ ! -L $current ]] || { gm_error '路径包含符号链接'; return 1; }
        if [[ -e $current ]]; then
            [[ -d $current ]] || { gm_error '路径组件不是目录'; return 1; }
            owner=$(stat -c %u -- "$current") || return 1
            [[ $owner == "$EUID" || $owner == 0 ]] || { gm_error '父目录所有权异常'; return 1; }
            nearest=$current
        fi
    done
    [[ -O $nearest && -w $nearest ]] || { gm_error '目标或最近父目录不属于调用者或不可写'; return 1; }
    canonical=$(realpath -m -- "$path") || return 1
    [[ $canonical == "$path" ]] || { gm_error '路径不是规范化路径'; return 1; }
    return 0
}

# 校验可写实例文件，拒绝链接、特殊文件、其他所有者和硬链接。
gm_validate_file() {
    local file=$1 links
    gm_validate_path "${file%/*}" || return 1
    [[ ! -L $file ]] || { gm_error '实例文件不能为符号链接'; return 1; }
    if [[ -e $file ]]; then
        [[ -f $file && -O $file ]] || { gm_error '实例文件类型或所有权异常'; return 1; }
        links=$(stat -c %h -- "$file") || return 1
        [[ $links == 1 ]] || { gm_error '实例文件不能为硬链接'; return 1; }
    fi
    return 0
}

# 验证程序与运行根相互独立，并预检所有固定实例目录和元数据文件。
gm_validate_instance_paths() {
    local run=$1 install=$2 directory
    [[ $run != "${HOME:-/}" && $install != "${HOME:-/}" ]] || {
        gm_error '不能将用户 HOME 作为安装根或运行根'; return 1;
    }
    gm_validate_path "$install" || return 1
    gm_validate_path "$run" || return 1
    [[ $run != "$install" && $run != "$install/"* && $install != "$run/"* ]] || {
        gm_error '程序根与运行根必须相互独立'; return 1;
    }
    for directory in repos config secrets home hosts logs runtime cache tmp; do
        gm_validate_path "$run/$directory" || return 1
    done
    gm_validate_file "$run/config/mirror.env" || return 1
    gm_validate_file "$run/config/installation.conf" || return 1
    return 0
}

# 校验安装记录的逐行固定内容，不解释任何记录值为 Shell 代码。
gm_match_record() {
    local file=$1 expected=$2 actual
    gm_validate_file "$file" || return 1
    [[ -f $file && -r $file ]] || { gm_error '缺少安装记录'; return 1; }
    actual=$(<"$file")
    [[ $actual == "$expected" ]] || { gm_error '安装记录缺失字段、路径冲突或身份不匹配'; return 1; }
    return 0
}

# 在防覆盖模式下创建固定纯数据文件，已有文件不改写。
gm_create_data_file() {
    local file=$1 content=$2
    gm_validate_file "$file" || return 1
    if [[ -e $file ]]; then return 0; fi
    (umask 077; set -o noclobber; printf '%s\n' "$content" > "$file") || return 1
    return 0
}

# 生成不含凭据的程序记录，所有字段值来自已验证路径和身份。
gm_program_record() {
    printf 'FORMAT=1\nMODE=program\nUID=%s\nINSTALL_ROOT=%s' "$EUID" "$1"
}

# 生成绑定程序根、运行根和身份的实例记录。
gm_instance_record() {
    printf 'FORMAT=1\nMODE=instance\nUID=%s\nRUN_ROOT=%s\nINSTALL_ROOT=%s' "$EUID" "$1" "$2"
}

# 将所有用户运行环境定向实例目录，不在安装阶段调用。
gm_set_instance_environment() {
    RUN_ROOT=$1
    INSTALL_ROOT=$2
    HOME=$RUN_ROOT/home
    XDG_CONFIG_HOME=$RUN_ROOT/config
    XDG_RUNTIME_DIR=$RUN_ROOT/runtime
    XDG_CACHE_HOME=$RUN_ROOT/cache
    TMPDIR=$RUN_ROOT/tmp
    export RUN_ROOT INSTALL_ROOT HOME XDG_CONFIG_HOME XDG_RUNTIME_DIR XDG_CACHE_HOME TMPDIR
}

# 检查实例私有目录的实际权限，拒绝通过修改现存目录来掩盖错误。
gm_check_private_directory() {
    local directory=$1 mode
    gm_validate_path "$directory" || return 1
    [[ -d $directory && -O $directory ]] || { gm_error '私有目录不存在或身份不匹配'; return 1; }
    mode=$(stat -c %a -- "$directory") || return 1
    [[ $mode == 700 ]] || { gm_error '实例私有目录权限必须为 0700'; return 1; }
    return 0
}

# 取得固定实例锁：只读打开避免截断，75 专用于忙锁，其他错误不吞失。
gm_lock_acquire() {
    local name=$1 mode=$2 path descriptor status fingerprint current flag
    declare -gA GM_LOCK_FDS
    case "$name" in instance|sync|hosts) ;; *) gm_error '不支持的实例锁名称'; return 1 ;; esac
    case "$mode" in shared) flag=-s ;; exclusive) flag=-x ;; *) gm_error '不支持的锁模式'; return 1 ;; esac
    [[ ! ${GM_LOCK_FDS[$name]+present} ]] || { gm_error '当前进程已持有此锁'; return 1; }
    command -v flock >/dev/null 2>&1 || { gm_error '缺少必要依赖 flock'; return 1; }
    gm_check_private_directory "$RUN_ROOT/runtime" || return 1
    path=$RUN_ROOT/runtime/$name.lock
    gm_validate_file "$path" || return 1
    if [[ ! -e $path ]]; then
        if ! (umask 077; set -o noclobber; : > "$path") 2>/dev/null; then
            gm_validate_file "$path" || return 1
            [[ -f $path ]] || { gm_error '不能创建锁文件'; return 1; }
        fi
    fi
    gm_validate_file "$path" || return 1
    fingerprint=$(stat -c '%d:%i' -- "$path") || return 1
    exec {descriptor}< "$path" || return 1
    if ! gm_validate_file "$path"; then
        exec {descriptor}<&-
        return 1
    fi
    current=$(stat -c '%d:%i' -- "$path") || { exec {descriptor}<&-; return 1; }
    if [[ $fingerprint != "$current" ]]; then
        exec {descriptor}<&-
        gm_error '打开期间锁文件发生变化'
        return 1
    fi
    if flock -n -E 75 "$flag" "$descriptor"; then
        GM_LOCK_FDS[$name]=$descriptor
        return 0
    else
        status=$?
        exec {descriptor}<&-
        if [[ $status == 75 ]]; then
            printf 'git-mirror: 实例锁忙：%s\n' "$name" >&2
            return 75
        fi
        gm_error '锁工具执行失败，未取得锁'
        return 1
    fi
}

# 关闭本进程持有的锁描述符，不删除锁文件或改变锁的 inode。
gm_lock_release() {
    local name=$1 descriptor
    case "$name" in instance|sync|hosts) ;; *) return 1 ;; esac
    declare -gA GM_LOCK_FDS
    if [[ ${GM_LOCK_FDS[$name]+present} ]]; then
        descriptor=${GM_LOCK_FDS[$name]}
        exec {descriptor}<&- || return 1
        unset 'GM_LOCK_FDS[$name]'
    fi
    return 0
}

# 在任何运行写入之前核验真实身份、平台、安装记录和整组配置。
gm_prepare_runtime() {
    local run=$1 install=$2 directory repo credential executable
    gm_check_identity || return 1
    gm_check_platform || return 1
    for executable in git curl flock stat realpath; do
        command -v "$executable" >/dev/null 2>&1 || { gm_error "缺少必要依赖：$executable"; return 1; }
    done
    gm_validate_instance_paths "$run" "$install" || return 1
    gm_match_record "$install/installation.conf" "$(gm_program_record "$install")" || return 1
    gm_match_record "$run/config/installation.conf" "$(gm_instance_record "$run" "$install")" || return 1
    for directory in repos config secrets home hosts logs runtime cache tmp; do
        [[ -d $run/$directory ]] || { gm_error '实例尚未完成初始化'; return 1; }
    done
    gm_check_private_directory "$run/runtime" || return 1
    gm_load_config "$run/config/mirror.env" || return 1
    gm_parse_repos "${REPOS-}" "${SHORT_LINKS-}" || return 1
    for repo in "${GM_REPOS[@]}"; do
        gm_validate_path "$run/repos/${repo%/*}" || return 1
        gm_validate_path "$run/repos/$repo.git" || return 1
    done
    credential=${GM_CONFIG[GITHUB_TOKEN_FILE]}
    if [[ -n $credential ]]; then
        [[ $credential == "$run/secrets/"* ]] || { gm_error '凭据文件必须位于本实例 secrets 目录'; return 1; }
        gm_validate_file "$credential" || return 1
        [[ -f $credential && -r $credential ]] || { gm_error '凭据文件不存在或不可读'; return 1; }
    fi
    gm_validate_file "$run/logs/sync.log" || return 1
    gm_validate_file "$run/hosts/github-hosts.snapshot" || return 1
    gm_validate_file "$run/hosts/github-hosts.snapshot.tmp" || return 1
    gm_validate_file "$run/runtime/stopped" || return 1
    gm_set_instance_environment "$run" "$install"
    export TZ="${GM_CONFIG[TZ]}"
    return 0
}

# 运行入口按实例共享锁、操作排他锁顺序进入，停止标记禁止新操作。
gm_begin_operation() {
    local operation=$1 status
    gm_lock_acquire instance shared || return $?
    if [[ -e $RUN_ROOT/runtime/stopped ]]; then
        gm_lock_release instance || return 1
        gm_error '实例已停止，拒绝启动新操作'
        return 1
    fi
    if gm_lock_acquire "$operation" exclusive; then
        return 0
    else
        status=$?
        gm_lock_release instance || return 1
        return "$status"
    fi
}
