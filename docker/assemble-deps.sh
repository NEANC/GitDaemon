#!/bin/sh

# 以非 root 身份把 Alpine 运行依赖组装成可用的替代根文件树，并补齐被 --scripts=no 跳过的必要文件。
# 该脚本是依赖组装的唯一权威实现：容器构建阶段直接调用，也可在真实 Alpine 上独立运行验证。
# 以 POSIX sh 编写，可在只带 busybox 的最小环境中运行；全程不使用需要 root 的命令，保持官方源与签名校验。

set -eu

# 固定参数：Alpine 版本、应用用户与组、默认时区、包集合、必需命令与禁止路径。
ALPINE_VERSION=3.24.2
APP_USER=git-daemon
APP_GROUP=git-daemon
APP_UID=10001
APP_GID=10001
DEFAULT_TIMEZONE=Asia/Shanghai
PACKAGES='bash git git-daemon curl flock coreutils ca-certificates tzdata openssl openrc'
# 运行时需要的 busybox 小程序；这些命令在禁用安装脚本后只有 applet 而没有符号链接。
REQUIRED_APPLETS='cmp grep setsid'
# 组装完成后必须存在且可执行的命令，相对替代根目录。
REQUIRED_COMMANDS='bin/bash bin/sh bin/cmp bin/grep bin/setsid usr/bin/env usr/bin/git usr/bin/curl usr/bin/openssl usr/bin/flock usr/bin/sha256sum bin/stat usr/bin/realpath usr/libexec/git-core/git-daemon sbin/rc-service sbin/openrc-run'
# 替代根中禁止出现的 SSH 组件路径。
FORBIDDEN_PATHS='usr/bin/ssh usr/bin/scp usr/bin/git-remote-ssh usr/libexec/git-core/git-remote-ssh usr/sbin/sshd'

# 输出诊断并立即失败。
die() {
    printf 'assemble-deps: %s\n' "$*" >&2
    exit 1
}

# 显示用法。
usage() {
    printf '%s\n' \
        '用法：assemble-deps.sh --root 目录 --cache-dir 目录 [选项]' \
        '  --root            替代根目标目录（必填，必须是执行用户可写的绝对路径）' \
        '  --cache-dir       apk 下载缓存目录（必填，绝对路径）' \
        '  --repositories-file 仓库清单（默认 /etc/apk/repositories）' \
        '  --keys-dir        信任公钥目录（默认 /etc/apk/keys）' \
        '  --timezone        写入 /etc/localtime 的时区（默认 Asia/Shanghai）' \
        '组装完成后替代根即为可执行依赖树；脚本可重复执行。'
}

# 校验目标是明确的绝对目录。
require_absolute_directory() {
    local value=$1
    local name=$2
    case "$value" in
        /*) ;;
        *) die "$name 必须为绝对路径" ;;
    esac
    [ "$value" != / ] || die "$name 不能为根目录"
    case "$value" in
        *//*) die "$name 含重复斜杠" ;;
    esac
}

# 解析命令行参数，只接受明确的绝对路径。
parse_arguments() {
    root=
    cache=
    repositories_file=/etc/apk/repositories
    keys_dir=/etc/apk/keys
    timezone=$DEFAULT_TIMEZONE
    while [ $# -gt 0 ]; do
        case "$1" in
            --root)
                shift
                [ $# -gt 0 ] || die '--root 缺少值'
                root=$1
                shift
                ;;
            --cache-dir)
                shift
                [ $# -gt 0 ] || die '--cache-dir 缺少值'
                cache=$1
                shift
                ;;
            --repositories-file)
                shift
                [ $# -gt 0 ] || die '--repositories-file 缺少值'
                repositories_file=$1
                shift
                ;;
            --keys-dir)
                shift
                [ $# -gt 0 ] || die '--keys-dir 缺少值'
                keys_dir=$1
                shift
                ;;
            --timezone)
                shift
                [ $# -gt 0 ] || die '--timezone 缺少值'
                timezone=$1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "不支持的参数：$1"
                ;;
        esac
    done
    [ -n "$root" ] || { usage >&2; die '必须提供 --root'; }
    [ -n "$cache" ] || { usage >&2; die '必须提供 --cache-dir'; }
    require_absolute_directory "$root" '--root'
    require_absolute_directory "$cache" '--cache-dir'
    [ -r "$repositories_file" ] || die "仓库清单不可读：$repositories_file"
    [ -d "$keys_dir" ] || die "信任公钥目录不存在：$keys_dir"
    return 0
}

# 拒绝实际或有效 UID 0；组装必须由普通用户完成。
require_non_root() {
    local actual effective
    actual=$(id -ru) || die '无法读取真实 UID'
    effective=$(id -u) || die '无法读取有效 UID'
    if [ "$actual" = 0 ] || [ "$effective" = 0 ]; then
        die '必须以非 root 用户运行（拒绝实际或有效 UID 0）'
    fi
    return 0
}

# 确保替代根内目录存在并设置固定权限。
ensure_directory() {
    local path=$1
    local mode=$2
    if [ ! -d "$path" ]; then
        mkdir -p "$path" || die "无法创建目录：$path"
    fi
    chmod "$mode" "$path" || die "无法设置目录权限：$path"
    return 0
}

# 在替代根内创建符号链接，已存在则原样保留。
ensure_symlink() {
    local target=$1
    local link=$2
    if [ -e "$link" ] || [ -L "$link" ]; then
        return 0
    fi
    mkdir -p "${link%/*}" || die "无法创建链接父目录：${link%/*}"
    ln -s "$target" "$link" || die "无法创建符号链接：$link"
    return 0
}

# 以官方源和签名校验组装固定包集合；首次初始化数据库，重复执行保持幂等。
assemble_packages() {
    if [ -e "$root/lib/apk/db/installed" ]; then
        apk --root "$root" --keys-dir "$keys_dir" --repositories-file "$repositories_file" --cache-dir "$cache" \
            add --usermode --scripts=no $PACKAGES || die '依赖组装失败'
    else
        apk --root "$root" --keys-dir "$keys_dir" --repositories-file "$repositories_file" --cache-dir "$cache" \
            add --initdb --usermode --scripts=no $PACKAGES || die '依赖组装失败'
    fi
    return 0
}

# 为缺失的必要命令创建 busybox 小程序符号链接，绝不覆盖已有真实命令。
ensure_busybox_applets() {
    local applet directory exists
    [ -x "$root/bin/busybox" ] || die '替代根缺少 busybox，无法补齐必需命令'
    for applet in $REQUIRED_APPLETS; do
        exists=no
        for directory in bin usr/bin sbin usr/sbin; do
            if [ -e "$root/$directory/$applet" ]; then
                exists=yes
            fi
        done
        if [ "$exists" = yes ]; then
            continue
        fi
        ln -s busybox "$root/bin/$applet" || die "无法创建 busybox 命令：$applet"
    done
    return 0
}

# 在账户数据文件中确保指定用户名的条目存在，缺失时追加，已存在则不改写。
ensure_account_entry() {
    local file=$1
    local name=$2
    local entry=$3
    local line
    local found=no
    if [ ! -e "$file" ]; then
        printf '%s\n' "$entry" > "$file" || die "无法写入账户文件：$file"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%:*}" = "$name" ]; then
            found=yes
        fi
    done < "$file"
    if [ "$found" = yes ]; then
        return 0
    fi
    printf '%s\n' "$entry" >> "$file" || die "无法追加账户条目：$file"
    return 0
}

# 补齐基础布局文件：账户、hosts、Alpine 平台标识；已存在的文件不被覆盖。
ensure_baselayout_files() {
    ensure_directory "$root/etc" 755
    ensure_account_entry "$root/etc/passwd" root 'root:x:0:0:root:/root:/sbin/nologin'
    ensure_account_entry "$root/etc/passwd" "$APP_USER" "$APP_USER:x:$APP_UID:$APP_GID:$APP_USER:/var/lib/git-daemon:/sbin/nologin"
    ensure_account_entry "$root/etc/group" root 'root:x:0:'
    ensure_account_entry "$root/etc/group" "$APP_GROUP" "$APP_GROUP:x:$APP_GID:"
    ensure_account_entry "$root/etc/shadow" root 'root:!::0:::::'
    ensure_account_entry "$root/etc/shadow" "$APP_USER" "$APP_USER:!::0:::::"
    if [ ! -e "$root/etc/hosts" ]; then
        printf '%s\n' '127.0.0.1 localhost' '::1 localhost' > "$root/etc/hosts" || die '无法写入 /etc/hosts'
    fi
    if [ ! -e "$root/etc/alpine-release" ]; then
        printf '%s\n' "$ALPINE_VERSION" > "$root/etc/alpine-release" || die '无法写入 /etc/alpine-release'
    fi
    if [ ! -e "$root/etc/os-release" ]; then
        printf '%s\n' \
            'NAME="Alpine Linux"' \
            'ID=alpine' \
            "VERSION_ID=$ALPINE_VERSION" \
            "PRETTY_NAME=\"Alpine Linux v${ALPINE_VERSION%.*}\"" \
            'HOME_URL="https://alpinelinux.org/"' \
            'BUG_REPORT_URL="https://gitlab.alpinelinux.org/alpine/aports/-/issues"' \
            > "$root/etc/os-release" || die '无法写入 /etc/os-release'
    fi
    return 0
}

# 创建 OpenRC 运行目录与临时目录，并把 /var/run 指向 /run。
ensure_runtime_directories() {
    ensure_directory "$root/run" 755
    ensure_directory "$root/tmp" 1777
    ensure_symlink ../run "$root/var/run"
    return 0
}

# 用默认时区创建 /etc/localtime 符号链接，指向树内 zoneinfo 数据。
ensure_timezone() {
    [ -f "$root/usr/share/zoneinfo/$timezone" ] || die "时区数据缺失：$timezone"
    ensure_symlink "../usr/share/zoneinfo/$timezone" "$root/etc/localtime"
    return 0
}

# 生成 CA 目录哈希符号链接与逐证书文件：用 sh 内置读取拆分捆绑证书，避免依赖 awk/find。
ensure_ca_certificates() {
    local bundle=$root/etc/ssl/certs/ca-certificates.crt
    local openssl_bin=$root/usr/bin/openssl
    local split
    local counter
    local in_cert
    local line
    local pem
    local base
    local hash
    if [ ! -f "$bundle" ]; then
        printf 'assemble-deps: 警告：缺少 CA 捆绑文件，跳过证书哈希补齐\n' >&2
        return 0
    fi
    ensure_symlink certs/ca-certificates.crt "$root/etc/ssl/cert.pem"
    [ -x "$openssl_bin" ] || die '替代根缺少 openssl，无法生成 CA 哈希链接'
    split=$cache/ca-split
    rm -rf "$split" || die "无法清理 CA 临时目录：$split"
    mkdir -p "$split" || die "无法创建 CA 临时目录：$split"
    counter=0
    in_cert=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            -----BEGIN\ CERTIFICATE-----*)
                counter=$((counter + 1))
                in_cert=1
                ;;
        esac
        if [ "$in_cert" = 1 ]; then
            printf '%s\n' "$line" >> "$split/cert-$counter.pem" || die '无法拆分 CA 证书'
        fi
        case "$line" in
            -----END\ CERTIFICATE-----*)
                in_cert=0
                ;;
        esac
    done < "$bundle"
    if [ "$counter" = 0 ]; then
        die 'CA 捆绑文件未包含任何证书'
    fi
    for pem in "$split"/cert-*.pem; do
        base=${pem##*/}
        hash=$("$openssl_bin" x509 -hash -noout -in "$pem" 2>/dev/null) || die "无法计算证书哈希：$base"
        cp "$pem" "$root/etc/ssl/certs/$base" || die "无法写入证书：$base"
        ln -sf "$base" "$root/etc/ssl/certs/$hash.0" || die "无法创建证书哈希链接：$hash.0"
    done
    rm -rf "$split"
    return 0
}

# 组装后核验必需命令存在且未引入 SSH 组件，缺失即带清晰诊断失败。
verify_tree() {
    local path
    for path in $REQUIRED_COMMANDS; do
        [ -x "$root/$path" ] || die "依赖组装缺少必要可执行文件：$path"
    done
    for path in $FORBIDDEN_PATHS; do
        [ ! -e "$root/$path" ] || die "依赖树不应包含 SSH 组件：$path"
    done
    return 0
}

# 主流程：参数与身份预检 → apk 组装 → 声明式补齐 → 核验。
main() {
    parse_arguments "$@"
    require_non_root
    mkdir -p "$root" "$cache" || die '无法创建目标根或缓存目录'
    printf 'assemble-deps: 组装根 %s；缓存 %s；时区 %s\n' "$root" "$cache" "$timezone"
    assemble_packages
    ensure_busybox_applets
    ensure_runtime_directories
    ensure_baselayout_files
    ensure_timezone
    ensure_ca_certificates
    verify_tree
    printf 'assemble-deps: 依赖树组装与缺口补齐完成：%s\n' "$root"
    return 0
}

main "$@"
