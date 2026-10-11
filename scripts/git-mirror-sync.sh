#!/usr/bin/env bash

# 仅从程序所在位置加载可信共享实现，不执行卷内配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 传输相关数组在脚本加载时初始化为空，避免预检前的未绑定展开。
declare -A GM_CONFIG=()
GM_RESOLVE_ARGS=()
GM_CREDENTIAL_ARGS=()
GM_TRANSPORT_SEQUENCE=()
GM_TRANSPORT_ARGS=()

# 记录同步消息并同时输出到终端和日志。
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

# 删除指定 Git 配置键，仅把“键不存在”（退出码 5）视为已达成，其他错误显式返回。
configure_unset() {
    local dir=$1 key=$2 status
    if git --git-dir="$dir" config --unset-all "$key" 2>/dev/null; then
        return 0
    else
        status=$?
    fi
    [ "$status" -eq 5 ] || return "$status"
    return 0
}

# 按完整镜像或限定分支设置 fetch refspec 与标签策略，每一步失败立即返回。
configure_fetch() {
    local dir=$1 branches=$2 branch
    local -a branch_list=()
    configure_unset "$dir" remote.origin.fetch || return $?
    if [ -z "$branches" ]; then
        git --git-dir="$dir" config remote.origin.mirror true || return 1
        configure_unset "$dir" remote.origin.tagOpt || return $?
        git --git-dir="$dir" config --add remote.origin.fetch '+refs/*:refs/*' || return 1
    else
        git --git-dir="$dir" config remote.origin.mirror false || return 1
        git --git-dir="$dir" config remote.origin.tagOpt --no-tags || return 1
        IFS=, read -r -a branch_list <<< "$branches"
        for branch in "${branch_list[@]}"; do
            git --git-dir="$dir" config --add remote.origin.fetch "+refs/heads/$branch:refs/heads/$branch" || return 1
        done
    fi
    return 0
}

# 仅隐藏格式明确的常规引用更新行，其他输出与回车进度即时透传。
filter_fetch_output() {
    local char buffer="" at_start=yes candidate=no
    local new_ref='^[[:blank:]]\*[[:blank:]]+\[new (branch|tag|ref)\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local fast_forward='^[[:blank:]]+[[:xdigit:]]+\.\.[[:xdigit:]]+[[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local forced='^[[:blank:]]\+[[:blank:]]+[[:xdigit:]]+\.\.\.[[:xdigit:]]+[[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]+\(forced update\)[[:blank:]]*$'
    local deleted='^[[:blank:]]-[[:blank:]]+\[deleted\][[:blank:]]+\(none\)[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local unchanged='^[[:blank:]]=[[:blank:]]+\[up to date\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    local tag_update='^[[:blank:]]t[[:blank:]]+\[tag update\][[:blank:]]+[^[:space:]]+[[:blank:]]+->[[:blank:]]+[^[:space:]]+[[:blank:]]*$'
    while IFS= read -r -N 1 char; do
        if [ "$candidate" = yes ]; then
            if [ "$char" = $'\n' ]; then
                if [[ ! "$buffer" =~ $new_ref && ! "$buffer" =~ $fast_forward && ! "$buffer" =~ $forced && ! "$buffer" =~ $deleted && ! "$buffer" =~ $unchanged && ! "$buffer" =~ $tag_update ]]; then
                    printf '%s\n' "$buffer"
                fi
                buffer=""
                candidate=no
                at_start=yes
            elif [ "$char" = $'\r' ]; then
                # 回车刷新不是引用明细，不等待换行或进程结束。
                printf '%s\r' "$buffer"
                buffer=""
                candidate=no
                at_start=yes
            else
                buffer+="$char"
            fi
        elif [ "$at_start" = yes ] && [[ "$char" == ' ' || "$char" == $'\t' ]]; then
            candidate=yes
            buffer="$char"
        else
            printf '%s' "$char"
            if [[ "$char" == $'\n' || "$char" == $'\r' ]]; then
                at_start=yes
            else
                at_start=no
            fi
        fi
    done
    # 未以换行结束的内容原样保留，不猜测其是否为完整明细。
    printf '%s' "$buffer"
    return 0
}

# 先追加完整日志，再筛选终端展示；保留 Git 原命令的退出状态。
run_cmd() {
    local -a outputs=("$LOG_FILE")
    if [[ -n ${GM_SYNC_DIAGNOSTIC-} ]]; then outputs+=("$GM_SYNC_DIAGNOSTIC"); fi
    LC_ALL=C "$@" 2>&1 | tee -a "${outputs[@]}" | filter_fetch_output
    return "${PIPESTATUS[0]}"
}

# 仅在成功拉取后删除范围外引用，并把 HEAD 指向首个所选分支。
prune_unselected_refs() {
    local dir=$1 branches=$2 ref branch keep refs
    local -a selected=()
    if [ -z "$branches" ]; then
        return 0
    fi
    IFS=, read -r -a selected <<< "$branches"
    for branch in "${selected[@]}"; do
        git --git-dir="$dir" show-ref --verify --quiet "refs/heads/$branch" || return 1
    done
    refs=$(git --git-dir="$dir" for-each-ref --format='%(refname)') || return 1
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        keep=no
        for branch in "${selected[@]}"; do
            if [ "$ref" = "refs/heads/$branch" ]; then
                keep=yes
                break
            fi
        done
        if [ "$keep" = no ]; then
            git --git-dir="$dir" update-ref -d "$ref" || return 1
        fi
    done <<< "$refs"
    GM_SYNC_STAGE=head
    git --git-dir="$dir" symbolic-ref HEAD "refs/heads/${selected[0]}" || return 1
    return 0
}

# 清除环境代理变量，避免宿主代理影响直连传输路径。
clear_proxy_environment() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY ftp_proxy FTP_PROXY
    return 0
}

# 以受控 Git 凭据助手注入同步 Token，凭据只进入子进程环境，不进入 argv 或日志；
# 助手核对 Git 传入的 host，仅在允许的同步主机（默认 github.com）返回 Token，其它主机不返回。
prepare_credentials() {
    local token= allowed=${GITHUB_HOST:-github.com}
    GM_CREDENTIAL_ARGS=()
    export GIT_TERMINAL_PROMPT=0
    if [[ -n ${GITHUB_TOKEN-} ]]; then
        token=$GITHUB_TOKEN
    elif [[ -n ${GM_CONFIG[GITHUB_TOKEN_FILE]} ]]; then
        token=$(<"${GM_CONFIG[GITHUB_TOKEN_FILE]}") || return 1
        token=${token%$'\n'}
    fi
    [[ -n $token ]] || return 0
    export GM_SYNC_TOKEN="$token"
    export GM_SYNC_ALLOWED_HOST="$allowed"
    GM_CREDENTIAL_ARGS=(-c "credential.helper=!f() { if [ \"\$1\" = get ]; then h=; while IFS= read -r l; do case \"\$l\" in host=*) h=\${l#host=} ;; esac; done; if [ \"\$h\" = \"\$GM_SYNC_ALLOWED_HOST\" ]; then printf 'username=%s\\n' x-access-token; printf 'password=%s\\n' \"\$GM_SYNC_TOKEN\"; fi; fi; return 0; }; f")
    return 0
}

# 每轮读取一次完整快照并在内存校验，构造 git http.curloptResolve 参数数组；
# 应用陈旧快照前输出含陈旧标记与快照时间的告警，便于观察回退前的过期状态。
load_resolve_args() {
    local snapshot=$1 filtered record host stale fetched
    GM_RESOLVE_ARGS=()
    [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]:-yes} == yes ]] || { log '地址刷新已禁用，使用系统 DNS'; return 0; }
    [[ -f $snapshot ]] || { log '无地址快照，使用系统 DNS'; return 0; }
    stale=${snapshot%.snapshot}.stale
    if [[ -e $stale ]]; then
        fetched=$(grep -m1 '^# FETCHED=' -- "$snapshot" 2>/dev/null) || fetched=
        fetched=${fetched#\# FETCHED=}
        log "检测到陈旧标记，地址快照可能过期；快照时间：${fetched:-未知}"
    fi
    filtered=$(gm_hosts_read_snapshot "$snapshot") || { log '地址快照无效，忽略动态映射'; return 0; }
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        host=${record#* }
        [[ $host == "$GITHUB_HOST" ]] || continue
        GM_RESOLVE_ARGS+=(-c "http.curloptResolve=$host:443:${record%% *}")
    done <<< "$filtered"
    return 0
}

# 构造固定回退顺序：配置代理（如有）→ 直连加动态映射（如有）→ 直连系统 DNS。
build_transport_sequence() {
    GM_TRANSPORT_SEQUENCE=()
    if [[ -n ${GM_CONFIG[PROXY_URL]:-} ]]; then
        GM_TRANSPORT_SEQUENCE+=(proxy)
    fi
    if [[ ${GM_CONFIG[ENABLE_HOSTS_UPDATE]:-yes} == yes && ${#GM_RESOLVE_ARGS[@]} -gt 0 ]]; then
        GM_TRANSPORT_SEQUENCE+=(mapping)
    fi
    GM_TRANSPORT_SEQUENCE+=(system)
    return 0
}

# 按尝试标识构造 Git 参数：代理与映射互斥，所有路径保持 TLS 与受限重定向。
transport_args() {
    local attempt=$1 remote_url=${2-} proxy=
    GM_TRANSPORT_ARGS=(-c http.followRedirects=initial)
    if [[ $attempt == proxy ]]; then proxy=${GM_CONFIG[PROXY_URL]}; fi
    if [[ -n $remote_url ]]; then
        GM_TRANSPORT_ARGS+=(-c "http.${remote_url}.proxy=$proxy" -c "remote.origin.proxy=$proxy")
    fi
    case "$attempt" in
        proxy) GM_TRANSPORT_ARGS+=(-c "http.proxy=${GM_CONFIG[PROXY_URL]}") ;;
        mapping) GM_TRANSPORT_ARGS+=(-c http.proxy= -c "http.https://${GITHUB_HOST:-github.com}/.proxy=" "${GM_RESOLVE_ARGS[@]}") ;;
        system) GM_TRANSPORT_ARGS+=(-c http.proxy= -c "http.https://${GITHUB_HOST:-github.com}/.proxy=") ;;
        *) return 1 ;;
    esac
    if [[ ${#GM_CREDENTIAL_ARGS[@]} -gt 0 ]]; then
        GM_TRANSPORT_ARGS+=("${GM_CREDENTIAL_ARGS[@]}")
    fi
    return 0
}

# 返回尝试标识的中文说明，用于记录路径与失败原因。
transport_label() {
    case "$1" in
        proxy) printf '配置的 HTTPS 代理' ;;
        mapping) printf '直连加动态地址映射' ;;
        system) printf '直连系统 DNS' ;;
        *) printf '未知路径' ;;
    esac
}

# 拉取单个仓库，成功后缩减范围并跟随默认 HEAD，不改变发布入口。
update_repo() {
    local repo=$1 dir=$2 branches=$3 remote_head line attempt label remote_url
    local GM_SYNC_DIAGNOSTIC
    local -A classification=()
    local -a chosen=()
    GM_SYNC_STAGE=config GM_SYNC_TRANSPORT_ONLY=no GM_SYNC_CONVERGED=no
    GM_SYNC_DIAGNOSTIC=$(mktemp "${LOG_FILE%/*}/sync-diagnostic.XXXXXXXX") || return 1
    GM_SYNC_LAST_LOG=$GM_SYNC_DIAGNOSTIC
    LC_ALL=C configure_fetch "$dir" "$branches" 2>>"$GM_SYNC_DIAGNOSTIC" || return 1
    remote_url=$(LC_ALL=C git --git-dir="$dir" remote get-url origin 2>>"$GM_SYNC_DIAGNOSTIC") || return 1
    GM_SYNC_STAGE=fetch
    log "同步 $repo；分支：${branches:-全部 refs}"
    for attempt in "${GM_TRANSPORT_SEQUENCE[@]}"; do
        transport_args "$attempt" "$remote_url" || return 1
        label=$(transport_label "$attempt")
        GM_SYNC_DIAGNOSTIC=$(mktemp "${LOG_FILE%/*}/sync-fetch.XXXXXXXX") || return 1
        GM_SYNC_LAST_LOG=$GM_SYNC_DIAGNOSTIC
        if run_cmd git "${GM_TRANSPORT_ARGS[@]}" -c gc.autoDetach=false -c maintenance.autoDetach=false --git-dir="$dir" fetch --progress --atomic --prune origin; then
            chosen=("${GM_TRANSPORT_ARGS[@]}")
            log "同步传输路径：$label"
            break
        fi
        gm_sync_classify_failure fetch "$(<"$GM_SYNC_DIAGNOSTIC")" classification
        GM_SYNC_TRANSPORT_ONLY=${classification[transport_only]}
        if [[ $GM_SYNC_TRANSPORT_ONLY != yes ]]; then return 1; fi
        log "传输失败：$label；尝试下一路径"
    done
    if [[ ${#chosen[@]} -eq 0 ]]; then
        log "同步失败：全部传输路径均不可用：$repo"
        return 1
    fi
    GM_SYNC_TRANSPORT_ONLY=no
    if grep -Eiq 'error:|fatal:|failed|warning:.*(gc|maintenance)' "$GM_SYNC_DIAGNOSTIC"; then
        GM_SYNC_STAGE=maintenance
        return 1
    fi
    GM_SYNC_STAGE=refs
    LC_ALL=C prune_unselected_refs "$dir" "$branches" 2>>"$GM_SYNC_DIAGNOSTIC" || return 1
    GM_SYNC_STAGE=head
    if [ -z "$branches" ]; then
        if remote_head=$(LC_ALL=C git "${chosen[@]}" --git-dir="$dir" ls-remote --symref origin HEAD 2>>"$GM_SYNC_DIAGNOSTIC"); then
            while IFS= read -r line; do
                if [[ $line == 'ref: refs/heads/'* ]]; then
                    remote_head=${line#ref: }
                    remote_head=${remote_head%%[[:space:]]*}
                    LC_ALL=C git --git-dir="$dir" symbolic-ref HEAD "$remote_head" 2>>"$GM_SYNC_DIAGNOSTIC" || return 1
                    break
                fi
            done <<< "$remote_head"
        else
            log "无法查询上游默认分支，保留当前 HEAD：$repo"
            return 1
        fi
    fi
    GM_SYNC_CONVERGED=yes
    return 0
}

gm_sync_classify_failure() {
    local stage=$1 diagnostics=$2 line seen=no unknown=no
    local -n failure=$3
    failure=([stage]="$stage" [transport_only]=no [configuration_converged]=no)
    [[ $stage == fetch ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        case "$line" in
            '') ;;
            "fatal: unable to access "*': Could not resolve host: '*|"fatal: unable to access "*': Could not resolve proxy: '*|"fatal: unable to access "*': Failed to connect to '*|"fatal: unable to access "*': Connection timed out'*) seen=yes ;;
            *) unknown=yes ;;
        esac
    done <<< "$diagnostics"
    if [[ $seen == yes && $unknown == no ]]; then failure[transport_only]=yes; fi
    return 0
}

gm_sync_one_locked() {
    local repo=$1 branches=$2 output=$3 dir=$RUN_ROOT/repos/$1.git index found=no status=0 publish_status=0 boot identity
    local -n sync_result=$output
    local -A sync_state=() checked=() convergence=()
    sync_result=([transport_only]=no [configuration_converged]=no [stage]=config)
    gm_validate_repo_name "$repo" || return 1
    for index in "${!GM_REPOS[@]}"; do
        if [[ ${GM_REPOS[$index]} == "$repo" && ${GM_BRANCHES[$index]} == "$branches" ]]; then found=yes; break; fi
    done
    [[ $found == yes && -n ${GM_LOCK_FDS[instance]-} && -n ${GM_LOCK_FDS[sync]-} ]] || return 1
    [[ ${GM_LOCAL_FROZEN-} != yes && -z ${GM_STOP_SCOPE-} && ! -e $RUN_ROOT/runtime/frozen && ! -e $RUN_ROOT/runtime/stopped ]] || return 1
    gm_repo_state_read "$repo" sync_state || return 1
    [[ ${sync_state[health]-} == healthy && ${sync_state[message]} != recovery_required && ${sync_state[desired]} == present ]] || return 1
    gm_validate_path "$dir" || return 1
    gm_validate_file "$RUN_ROOT/runtime/generation" read || return 1
    IFS= read -r boot < "$RUN_ROOT/runtime/generation" || return 1
    identity=$(stat -c '%d-%i' -- "$dir") || return 1
    [[ ${sync_state[checked_boot]-} == "$boot" && $boot == "${GM_BOOT_GENERATION-}" ]] || return 1
    [[ ${sync_state[checked_generation]-} == "${sync_state[generation]}" && ${sync_state[checked_identity]-} == "$identity" ]] || return 1
    update_repo "$repo" "$dir" "$branches" || status=$?
    sync_result[stage]=$GM_SYNC_STAGE
    sync_result[transport_only]=$GM_SYNC_TRANSPORT_ONLY
    sync_result[configuration_converged]=$GM_SYNC_CONVERGED
    convergence=([schema]=1 [repo]="$repo" [generation]="${sync_state[generation]}" [desired]=present [observed]=error [published]=no [message]=configuration_pending)
    if (( status == 0 )); then convergence[observed]=ready; convergence[message]=configuration_converged; fi
    if ! gm_state_directory_prepare "$RUN_ROOT/state/sync/${repo%/*}" ||
        ! gm_state_write_array_locked "$RUN_ROOT/state/sync/$repo.state" convergence; then
        gm_repo_export_remove_locked "$repo" || return 2
        gm_task_freeze || true
        return 2
    fi
    if (( status != 0 )) && [[ $GM_SYNC_TRANSPORT_ONLY != yes ]]; then
        gm_repo_unpublish_locked "$repo" || return 2
        sync_state[published]=no sync_state[health]=recovery_required sync_state[message]=recovery_required sync_state[observed]=error
        gm_repo_state_commit_locked "$repo" sync_state || { gm_task_freeze; return 2; }
        return 1
    fi
    if ! gm_repo_check_locked "$repo" "$dir" checked "$GM_SYNC_TRANSPORT_ONLY"; then
        gm_repo_unpublish_locked "$repo" || return 2
        sync_result[transport_only]=no
        return 1
    fi
    [[ ${checked[health]} == healthy ]] || { sync_result[transport_only]=no; return 1; }
    sync_result[stage]=publish
    gm_repo_publish_locked "$repo" "${sync_state[generation]}" || publish_status=$?
    if (( publish_status == 0 )); then gm_publish_short_links "$RUN_ROOT" "$repo" || publish_status=$?; fi
    if (( publish_status != 0 )); then
        gm_repo_unpublish_locked "$repo" || return 2
        gm_repo_state_read "$repo" sync_state || return 1
        sync_state[health]=recovery_required sync_state[message]=recovery_required
        gm_repo_state_commit_locked "$repo" sync_state || return 2
        return "$publish_status"
    fi
    return "$status"
}

# 报告每个同步分支的提交头；无本地分支或枚举失败时明确提示。
report_branches() {
    local repo=$1 dir=$2 branches=$3 status=$4 branch branch_list details short_hash commit_time subject
    local -a selected=()
    if [ "$status" = success ]; then
        log "$repo 分支提交（本次同步成功）"
    else
        log "$repo 分支提交（本次同步失败；仅本地缓存，未确认上游最新）"
    fi
    if [ -n "$branches" ]; then
        IFS=, read -r -a selected <<< "$branches"
    else
        if ! branch_list=$(git --git-dir="$dir" for-each-ref --sort=refname --format='%(refname:strip=2)' refs/heads/ 2>>"$LOG_FILE"); then
            log "  无法读取本地分支列表"
            return 1
        fi
        if [ -z "$branch_list" ]; then
            log "  没有本地分支可报告"
            return 0
        fi
        while IFS= read -r branch; do
            selected+=("$branch")
        done <<< "$branch_list"
    fi
    for branch in "${selected[@]}"; do
        if details=$(git --git-dir="$dir" log -1 --abbrev=12 --format='%h%n%cI%n%s' "refs/heads/$branch" -- 2>>"$LOG_FILE") && [ -n "$details" ]; then
            short_hash=${details%%$'\n'*}
            details=${details#*$'\n'}
            commit_time=${details%%$'\n'*}
            subject=${details#*$'\n'}
            log "  ↳ $branch: $short_hash $subject"
            log "    提交时间：$commit_time"
        else
            log "  ↳ $branch: 本地不存在或无法读取提交"
        fi
    done
    return 0
}

# 同步单个仓库，失败时保留已有缓存且不发布新仓库。
sync_repo() {
    local repo=$1 branches=$2 dir url status
    local -A sync_output=()
    if [[ -n ${RUN_ROOT-} ]]; then
        gm_sync_one_locked "$repo" "$branches" sync_output
        return $?
    fi
    dir="$MIRROR_ROOT/$repo.git"
    url="https://github.com/$repo.git"
    mkdir -p "$(dirname "$dir")" || return 1
    if [ ! -d "$dir" ]; then
        git init --bare --quiet "$dir" || return 1
        git --git-dir="$dir" remote add origin "$url" || return 1
    fi
    if update_repo "$repo" "$dir" "$branches"; then
        report_branches "$repo" "$dir" "$branches" success || log "分支报告失败，不改变同步结果：$repo"
        return 0
    else
        status=$?
    fi
    if (( status == 2 )); then
        log "同步结果不确定，需重新读取持久状态：$repo"
        return 2
    fi
    log "同步失败，保留已有缓存：$repo"
    report_branches "$repo" "$dir" "$branches" failed
    return 1
}

# 以固定纯数据格式刷新受管理链接记录：先写同目录临时文件，再原子改名到位。
gm_repo_build_candidate_locked() {
    local repo=$1 branches=$2 dir=$3
    local -A build_record=()
    gm_repo_replacement_read "$repo" build_record || return 1
    [[ $dir == "$RUN_ROOT/staging/${build_record[operation]}/repo.git" && ${build_record[phase]} == candidate_building ]] || return 1
    gm_repo_copy_validate "$dir" "${build_record[new_identity]}" || return 1
    git init --bare --quiet "$dir" || return 1
    git --git-dir="$dir" config remote.origin.url "https://github.com/$repo.git" || return 1
    update_repo "$repo" "$dir" "$branches"
}

gm_write_link_record() {
    local record=$1 target=$2 tmp=$1.tmp
    gm_validate_file "$record" || return 1
    gm_validate_file "$tmp" || return 1
    (umask 077; printf 'FORMAT=1\nTARGET=%s\n' "$target" > "$tmp") || return 1
    mv -f -- "$tmp" "$record" || return 1
    return 0
}

# 仅为已发布仓库创建受管理短链接：链接为 repos/<短名>.git 指向同级 owner/repo.git；
# 同名旧链接按受管理协议更新，非受管理对象或指向他处的链接失败关闭，绝不覆盖。
# 从私密意图记录恢复未完成发布；仅接受记录声明的旧/新目标，拒绝接管未知对象。
gm_recover_short_link() {
    local run=$1 name=$2 link=$1/repos/$2.git record=$1/config/managed-links/$2.git
    local journal=$1/runtime/shortlink-$2.pending content old new actual=
    [[ $name =~ ^[A-Za-z0-9._-]+$ && $name != . && $name != *..* ]] || return 1
    gm_validate_path "$run/repos" read || return 1
    [[ -e $journal || -L $journal ]] || return 0
    gm_validate_file "$journal" || return 1
    content=$(<"$journal")
    [[ $content == $'FORMAT=1\nOLD='*$'\nNEW='* ]] || return 1
    old=${content#*$'\nOLD='}; old=${old%%$'\nNEW='*}
    new=${content##*$'\nNEW='}
    [[ $new == *.git ]] && gm_validate_repo_name "${new%.git}" || return 1
    gm_validate_path "$run/repos/$new" || return 1
    if [[ -n $old ]]; then
        [[ $old == *.git ]] && gm_validate_repo_name "${old%.git}" || return 1
        gm_validate_path "$run/repos/$old" || return 1
        if [[ ! -d $run/repos/$old ]]; then
            [[ $run == "$RUN_ROOT" ]] || return 1
            gm_repo_validate_alias_target_locked "${old%.git}" || return 1
        fi
    fi
    if [[ -L $link ]]; then
        [[ $(stat -c %u -- "$link") == "$EUID" ]] || return 1
        actual=$(readlink -- "$link") || return 1
        [[ $actual == "$old" || $actual == "$new" ]] || return 1
        rm -- "$link" || return 1
    elif [[ -e $link ]]; then
        return 1
    fi
    if [[ -n $old ]]; then
        ln -s -- "$old" "$link" || return 1
        gm_write_link_record "$record" "$old" || return 1
    elif [[ -e $record ]]; then
        gm_validate_file "$record" || return 1
        rm -- "$record" || return 1
    fi
    rm -- "$journal" || return 1
    return 0
}

# 在修改链接前发布私密意图记录，普通失败回滚；崩溃后下轮按记录恢复，非双 rename 事务。
gm_create_short_link() {
    local run=$1 target=$2 name=$3
    local link=$run/repos/$name.git rel=$target.git actual old_target=
    local record=$run/config/managed-links/$name.git journal=$run/runtime/shortlink-$name.pending tmp
    [[ -d $run/repos/$rel ]] || { log "短链接目标仓库缺失：$target"; return 1; }
    [[ -f $run/repos/$rel/git-daemon-export-ok ]] || { log "短链接目标仓库未发布：$target"; return 1; }
    (umask 077; mkdir -p -- "$run/config/managed-links" "$run/runtime") || return 1
    gm_check_private_directory "$run/runtime" || return 1
    gm_recover_short_link "$run" "$name" || return 1
    if [[ -L $link ]]; then
        gm_validate_managed_link "$run" "$link" || return 1
        actual=$(readlink -- "$link") || return 1
        [[ $actual == "$rel" ]] && return 0
        old_target=$actual
    elif [[ -e $link ]]; then
        gm_error "短链接位置已存在非链接对象，拒绝覆盖：$name"
        return 1
    fi
    gm_validate_file "$journal" || return 1
    tmp=$(mktemp "$run/runtime/shortlink-$name.XXXXXXXX") || return 1
    if ! (umask 077; printf 'FORMAT=1\nOLD=%s\nNEW=%s\n' "$old_target" "$rel" > "$tmp" && mv -f -- "$tmp" "$journal"); then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ -n $old_target ]]; then
        rm -- "$link" || { gm_recover_short_link "$run" "$name"; return 1; }
    fi
    if ! ln -s -- "$rel" "$link" || ! gm_write_link_record "$record" "$rel"; then
        gm_recover_short_link "$run" "$name" || return 1
        return 1
    fi
    rm -- "$journal" || { gm_recover_short_link "$run" "$name"; return 1; }
    log "创建短链接：$name -> $target"
    return 0
}

# 按当前映射为单个已发布仓库创建全部短链接，任一失败即视为该仓库同步失败。
gm_publish_short_links() {
    local run=$1 target=$2 index
    for index in "${!GM_LINK_TARGETS[@]}"; do
        [[ ${GM_LINK_TARGETS[$index]} == "$target" ]] || continue
        gm_create_short_link "$run" "$target" "${GM_LINK_NAMES[$index]}" || return 1
    done
    return 0
}

# 删除不再出现在 SHORT_LINKS 中的受管理短链接与记录，绝不触碰目标仓库或其它数据。
gm_prune_short_links() {
    local run=$1
    local dir=$run/config/managed-links
    local record name link index journal
    local -A retained=()
    [[ -d $dir ]] || return 0
    shopt -s nullglob dotglob
    for journal in "$run/runtime"/shortlink-*.pending; do
        [[ -f $journal ]] || return 1
        name=${journal##*/shortlink-}
        name=${name%.pending}
        gm_recover_short_link "$run" "$name" || return 1
    done
    for index in "${!GM_LINK_NAMES[@]}"; do
        retained["${GM_LINK_NAMES[$index]}.git"]=1
    done
    shopt -s nullglob dotglob
    for record in "$dir"/*; do
        name=${record##*/}
        [[ -n ${retained[$name]+present} ]] && continue
        link=$run/repos/$name
        if [[ -L $link ]]; then
            gm_validate_managed_link "$run" "$link" || return 1
            rm -- "$link" || return 1
            log "移除已取消的短链接：$name"
        elif [[ -e $link ]]; then
            gm_error "短链接清理位置存在非链接对象，拒绝删除：$name"
            return 1
        fi
        rm -- "$record" || return 1
    done
    return 0
}

# 显式执行同步前读取纯数据并完成整组预检，不创建短链接。
gm_sync_main() (
    local index failed=0 install snapshot status selected= found=no
    if [[ ${1-} == --help || ${1-} == -h ]]; then
        printf '%s\n' '用法：git-mirror-sync.sh [--repo owner/repo]'
        return 0
    fi
    if [[ $# == 2 && $1 == --repo ]]; then
        gm_validate_repo_name "$2" || return 2
        selected=$2
    elif [[ $# != 0 ]]; then gm_error '同步入口不接受此参数'; return 2; fi
    install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    gm_check_identity || return 1
    gm_prepare_runtime "${RUN_ROOT-/var/lib/git-daemon}" "$install" || return 1
    if [[ -n $selected ]]; then
        for index in "${!GM_REPOS[@]}"; do
            if [[ ${GM_REPOS[$index]} == "$selected" ]]; then found=yes; break; fi
        done
        [[ $found == yes ]] || { gm_error '仓库未配置'; return 2; }
    fi
    source "$install/lib/repository-recovery.sh" || return 1
    gm_load_sync_credentials "${RUN_ROOT-/var/lib/git-daemon}" || return 1
    gm_begin_operation sync || return $?
    CONFIG_DIR=$RUN_ROOT/config
    MIRROR_ROOT=$RUN_ROOT/repos
    LOG_DIR=$RUN_ROOT/logs
    RUN_DIR=$RUN_ROOT/runtime
    LOG_FILE=$LOG_DIR/sync.log
    LOCK_FILE=$RUN_DIR/sync.lock
    GITHUB_HOST=${GITHUB_HOST:-github.com}
    snapshot=$RUN_ROOT/hosts/github-hosts.snapshot
    clear_proxy_environment || return 1
    prepare_credentials || return 1
    load_resolve_args "$snapshot" || return 1
    build_transport_sequence || return 1
    for index in "${!GM_REPOS[@]}"; do
        if [[ -n $selected && ${GM_REPOS[$index]} != "$selected" ]]; then continue; fi
        if sync_repo "${GM_REPOS[$index]}" "${GM_BRANCHES[$index]}"; then
            if gm_publish_short_links "$RUN_ROOT" "${GM_REPOS[$index]}"; then
                :
            else
                failed=1
            fi
        else
            status=$?
            if (( status == 2 )); then return 2; fi
            failed=1
        fi
    done
    if [[ -z $selected ]]; then gm_prune_short_links "$RUN_ROOT" || failed=1; fi
    return "$failed"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_sync_main "$@"
fi
