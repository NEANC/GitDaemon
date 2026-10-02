#!/usr/bin/env bash

# 只加载随程序安装的可信代码，不执行实例配置。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 显示默认保留与显式分类清理接口。
gm_uninstall_usage() {
    printf '%s\n' \
        '用法：uninstall-git-mirror.sh [--run-root 路径] [--install-root 路径]' \
        '默认仅停止实例，保留程序、仓库、配置、凭据、日志及安装记录。' \
        '分类删除：--delete-repos --delete-config --delete-credentials --delete-logs' \
        '--delete-config 仅删除 mirror.env；安装记录和 runtime 始终保留。' \
        '--yes 仅代替确认，不绕过身份、路径、停止或锁检查。'
}

# 递归预检选中目录，仅放行已登记相对短链接，拒绝异常身份、特殊文件及跨设备子树。
gm_validate_cleanup_tree() (
    local path=$1 device=$2 run=$3 actual child
    if [[ -L $path ]]; then
        gm_validate_managed_link "$run" "$path" || return 1
        actual=$(stat -c %d -- "$path") || return 1
        [[ $actual == "$device" ]] || { gm_error '清理目标包含跨设备挂载'; return 1; }
        return 0
    fi
    [[ -e $path ]] || return 0
    [[ -O $path ]] || { gm_error '清理目标所有权异常'; return 1; }
    actual=$(stat -c %d -- "$path") || return 1
    [[ $actual == "$device" ]] || { gm_error '清理目标包含跨设备挂载'; return 1; }
    if [[ -d $path ]]; then
        gm_validate_path "$path" || return 1
        shopt -s nullglob dotglob
        for child in "$path"/*; do
            gm_validate_cleanup_tree "$child" "$device" "$run" || return 1
        done
    elif [[ -f $path ]]; then
        gm_validate_file "$path" || return 1
    else
        gm_error '清理目标包含特殊文件'
        return 1
    fi
    return 0
)

# 核验记录与固定目标，确认或停止后再次调用以防路径状态变化。
gm_validate_uninstall_targets() {
    local run=$1 install=$2 target device
    shift 2
    gm_validate_instance_paths "$run" "$install" || return 1
    gm_match_record "$install/installation.conf" "$(gm_program_record "$install")" || return 1
    gm_match_record "$run/config/installation.conf" "$(gm_instance_record "$run" "$install")" || return 1
    gm_check_private_directory "$run/runtime" || return 1
    gm_validate_file "$run/runtime/stopped" || return 1
    device=$(stat -c %d -- "$run") || return 1
    for target in "$@"; do
        case "$target" in
            "$run/repos"|"$run/secrets"|"$run/logs"|"$run/config/mirror.env") ;;
            *) gm_error '目标不属于允许清理的实例类别'; return 1 ;;
        esac
        gm_validate_cleanup_tree "$target" "$device" "$run" || return 1
    done
    return 0
}

# 默认只停止实例；显式分类清理必须通过记录、边界、停止与排他锁校验。
gm_uninstall_main() (
    local run=${RUN_ROOT-/var/lib/git-daemon} install actual_install yes=no
    local delete_repos=no delete_config=no delete_credentials=no delete_logs=no
    local target answer executable service link
    local -a targets=()
    actual_install=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    install=$actual_install
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) gm_uninstall_usage; return 0 ;;
            --run-root|--install-root)
                [[ $# -ge 2 && -n $2 ]] || { gm_error '路径参数缺少值'; return 2; }
                if [[ $1 == --run-root ]]; then run=$2; else install=$2; fi
                shift 2 ;;
            --delete-repos) delete_repos=yes; shift ;;
            --delete-config) delete_config=yes; shift ;;
            --delete-credentials) delete_credentials=yes; shift ;;
            --delete-logs) delete_logs=yes; shift ;;
            --yes) yes=yes; shift ;;
            --keep-data) shift ;;
            *) gm_error '不支持的卸载参数'; return 2 ;;
        esac
    done
    gm_check_identity || return 1
    gm_check_platform || return 1
    [[ $install == "$actual_install" ]] || { gm_error '安装路径与当前可信程序位置不匹配'; return 1; }
    for executable in rc-service flock stat realpath rm; do
        command -v "$executable" >/dev/null 2>&1 || { gm_error "缺少必要依赖：$executable"; return 1; }
    done
    if [[ $delete_repos == yes ]]; then targets+=("$run/repos"); fi
    if [[ $delete_config == yes ]]; then targets+=("$run/config/mirror.env"); fi
    if [[ $delete_credentials == yes ]]; then targets+=("$run/secrets"); fi
    if [[ $delete_logs == yes ]]; then targets+=("$run/logs"); fi
    gm_validate_uninstall_targets "$run" "$install" "${targets[@]}" || return 1
    gm_load_config "$run/config/mirror.env" || return 1
    gm_set_instance_environment "$run" "$install"
    for service in git-mirror-sync git-mirror-hosts git-daemon; do
        gm_validate_file "$install/openrc/$service" read || return 1
        [[ -f $install/openrc/$service && -x $install/openrc/$service ]] || { gm_error '实例服务定义缺失'; return 1; }
    done
    gm_load_service_capabilities "$install" || return 1
    printf '实例：%s\n程序保留：%s\n' "$run" "$install"
    if [[ ${#targets[@]} -gt 0 ]]; then
        printf '将删除：%s\n' "${targets[@]}"
        if [[ $yes != yes ]]; then
            printf '确认删除以上明确类别？[y/N] '
            IFS= read -r answer || return 0
            case "$answer" in y|Y|yes|YES) ;; *) return 0 ;; esac
        fi
    else
        printf '%s\n' '仅停止实例，保留全部数据。'
    fi
    gm_validate_uninstall_targets "$run" "$install" "${targets[@]}" || return 1
    if [[ $GM_SCHEDULER_CAPABILITY == present ]]; then
        gm_stop_instance_service git-mirror-scheduler || return 1
    fi
    gm_stop_instance_service git-mirror-sync || return 1
    gm_stop_instance_service git-mirror-hosts || return 1
    # 全部写入操作持有 instance 共享锁，卸载按固定顺序独占三把锁。
    gm_lock_acquire instance exclusive || return $?
    gm_lock_acquire sync exclusive || return $?
    gm_lock_acquire hosts exclusive || return $?
    gm_stop_instance_service git-daemon || return 1
    gm_validate_uninstall_targets "$run" "$install" "${targets[@]}" || return 1
    gm_create_data_file "$run/runtime/stopped" 'STOPPED=1' || return 1
    for target in "${targets[@]}"; do
        case "$target" in
            "$run/config/mirror.env") rm -f -- "$target" || return 1 ;;
            "$run/repos")
                # 全部类别已预检；先 unlink 已登记链接，不沿链接进入仓库目标。
                shopt -s nullglob dotglob
                for link in "$run/repos"/*; do
                    if [[ -L $link ]]; then
                        gm_validate_managed_link "$run" "$link" || return 1
                        rm -- "$link" || return 1
                        rm -- "$run/config/managed-links/${link##*/}" || return 1
                    fi
                done
                rm -rf -- "$target" || return 1
                ;;
            "$run/secrets"|"$run/logs") rm -rf -- "$target" || return 1 ;;
            *) gm_error '拒绝非允许目标'; return 1 ;;
        esac
    done
    printf '%s\n' '实例已停止；仅清理显式选择的类别，程序、安装记录和锁目录保留。'
    return 0
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_uninstall_main "$@"
fi
