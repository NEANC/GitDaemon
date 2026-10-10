#!/usr/bin/env bash

# 仅加载程序目录中的共享代码，加载定义本身没有部署副作用。
source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/foundation.sh"

# 显示安装与运行初始化的独立命令接口。
usage() {
    printf '%s\n' \
        '安装：deploy-git-mirror.sh --install --install-root /调用者拥有的程序目录' \
        '初始化：deploy-git-mirror.sh --init --install-root /程序目录 [--run-root /var/lib/git-daemon]' \
        '恢复：deploy-git-mirror.sh --resume --install-root /程序目录 [--run-root /var/lib/git-daemon]' \
        '恢复仅解除停止标记，不启动服务；普通初始化保留停止意图。' \
        '安装无需 REPOS，不读取运行凭据；初始化和恢复的 REPOS/SHORT_LINKS 仅来自环境。'
}

# 安装固定程序文件；对已有不同内容明确失败，不覆盖用户文件。
gm_install_program() {
    local install=$1 source_root=$2 file directory record
    local -a files=(deploy-git-mirror.sh uninstall-git-mirror.sh git-daemon-config.sh git-mirror-sync.sh git-mirror-scheduler.sh update-github-hosts.sh lib/foundation.sh lib/repository-state.sh openrc/git-daemon openrc/git-mirror-sync openrc/git-mirror-hosts openrc/git-mirror-scheduler)
    [[ $install != "${HOME:-/}" ]] || { gm_error '不能将用户 HOME 作为安装根'; return 1; }
    gm_validate_path "$install" || return 1
    for directory in lib openrc; do gm_validate_path "$install/$directory" || return 1; done
    for file in "${files[@]}"; do
        [[ -f $source_root/$file && ! -L $source_root/$file ]] || { gm_error '程序源文件缺失或类型异常'; return 1; }
        gm_validate_file "$install/$file" || return 1
        if [[ -e $install/$file ]]; then
            cmp -s -- "$source_root/$file" "$install/$file" || { gm_error '已有程序文件不同，拒绝覆盖'; return 1; }
        fi
    done
    record=$(gm_program_record "$install") || return 1
    gm_validate_file "$install/installation.conf" || return 1
    if [[ -e $install/installation.conf ]]; then
        gm_match_record "$install/installation.conf" "$record" || return 1
    fi
    gm_validate_file "$install/service-capabilities.conf" || return 1
    if [[ -e $install/service-capabilities.conf ]]; then
        gm_match_record "$install/service-capabilities.conf" $'FORMAT=1\nSCHEDULER=present' || return 1
    fi
    (umask 077; mkdir -p -- "$install/lib" "$install/openrc") || return 1
    for file in "${files[@]}"; do
        if [[ ! -e $install/$file ]]; then
            (umask 077; set -o noclobber; cat -- "$source_root/$file" > "$install/$file") || return 1
            chmod 755 -- "$install/$file" || return 1
        fi
    done
    gm_create_data_file "$install/installation.conf" "$record" || return 1
    gm_create_data_file "$install/service-capabilities.conf" $'FORMAT=1\nSCHEDULER=present' || return 1
    printf '程序安装位置：%s\n' "$install"
}

# 初始化缺失的实例文件，验证现存记录并保留已有配置和数据。
gm_initialize_instance() {
    local run=$1 install=$2 record directory file repo executable status
    for executable in git flock stat realpath; do
        command -v "$executable" >/dev/null 2>&1 || { gm_error "缺少必要依赖：$executable"; return 1; }
    done
    gm_validate_instance_paths "$run" "$install" || return 1
    if [[ -d $run/runtime ]]; then
        gm_check_private_directory "$run/runtime" || return 1
    fi
    gm_match_record "$install/installation.conf" "$(gm_program_record "$install")" || return 1
    record=$(gm_instance_record "$run" "$install") || return 1
    if [[ -e $run/config/installation.conf ]]; then
        gm_match_record "$run/config/installation.conf" "$record" || return 1
    fi
    gm_load_config "$run/config/mirror.env" || return 1
    gm_parse_repos "${REPOS-}" "${SHORT_LINKS-}" || return 1
    for repo in "${GM_REPOS[@]}"; do
        gm_validate_path "$run/repos/${repo%/*}" || return 1
        gm_validate_path "$run/repos/$repo.git" || return 1
    done
    file=${GM_CONFIG[GITHUB_TOKEN_FILE]}
    if [[ -n $file ]]; then
        [[ $file == "$run/secrets/"* ]] || { gm_error '凭据文件必须位于本实例 secrets 目录'; return 1; }
        gm_validate_file "$file" || return 1
        [[ -f $file && -r $file ]] || { gm_error '凭据文件不存在或不可读'; return 1; }
    fi
    (umask 077; mkdir -p -- "$run/runtime") || return 1
    gm_check_private_directory "$run/runtime" || return 1
    (
        RUN_ROOT=$run
        gm_lock_acquire instance exclusive || exit $?
        gm_validate_instance_paths "$run" "$install" || exit 1
        if [[ -e $run/config/installation.conf ]]; then
            gm_match_record "$run/config/installation.conf" "$record" || exit 1
        fi
        gm_load_config "$run/config/mirror.env" || exit 1
        for directory in repos config secrets home hosts logs runtime cache tmp state state/repos state/operations; do
            (umask 077; mkdir -p -- "$run/$directory") || exit 1
        done
        gm_create_data_file "$run/config/mirror.env" '# 固定允许键的 KEY=VALUE 纯数据配置；环境参数不自动回写。' || exit 1
        gm_create_data_file "$run/config/installation.conf" "$record" || exit 1
        gm_save_sync_credentials "$run" || exit 1
        # 在实例范围内准备用户 OpenRC 环境并登记服务定义，不把服务加入运行级。
        gm_prepare_instance_openrc "$run" "$install" || exit 1
    )
    status=$?
    [[ $status == 0 ]] || return "$status"
    gm_set_instance_environment "$run" "$install"
    printf '实例初始化位置：%s\n' "$run"
}

# 先完成参数、身份和平台预检，再分派安装或运行初始化。
gm_deploy_main() {
    local mode= install= run=${RUN_ROOT-/var/lib/git-daemon} source_root
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) usage; return 0 ;;
            --install|--init|--resume)
                [[ -z $mode ]] || { gm_error '安装、初始化与恢复模式只能选择一个'; return 2; }
                mode=$1; shift ;;
            --install-root|--run-root)
                [[ $# -ge 2 && -n $2 ]] || { gm_error '路径参数缺少值'; return 2; }
                if [[ $1 == --install-root ]]; then install=$2; else run=$2; fi
                shift 2 ;;
            *) gm_error '不支持的部署参数'; return 2 ;;
        esac
    done
    [[ -n $mode && -n $install ]] || { usage >&2; return 2; }
    gm_check_identity || return 1
    gm_check_platform || return 1
    source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    case "$mode" in
        --install) gm_install_program "$install" "$source_root" ;;
        --init) gm_initialize_instance "$run" "$install" ;;
        --resume) gm_resume_instance "$run" "$install" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    gm_deploy_main "$@"
fi
