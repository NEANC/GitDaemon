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
