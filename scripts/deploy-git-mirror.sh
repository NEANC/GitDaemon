#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=${PREFIX:-/usr/local}
CONFIG_DIR=${CONFIG_DIR:-/etc/git-mirror}
DATA_DIR=${DATA_DIR:-/srv/git-mirror}
LOG_DIR=${LOG_DIR:-/var/log/git-mirror}
RUN_DIR=${RUN_DIR:-/run/git-mirror}
OPENRC_DIR=${OPENRC_DIR:-/etc/init.d}

# 输出部署使用说明。
usage() {
    printf '%s\n' "用法: $0 [--prefix 路径] [--config-dir 路径] [--data-dir 路径]"
    printf '%s\n' "REPOS 必须通过环境变量提供，例如 owner/repo;owner/other main,stable"
}

# 校验目录参数为绝对路径，避免把文件写到意外位置。
valid_path() {
    case "$1" in
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX=${2:?缺少 --prefix 参数}; shift 2 ;;
        --config-dir) CONFIG_DIR=${2:?缺少 --config-dir 参数}; shift 2 ;;
        --data-dir) DATA_DIR=${2:?缺少 --data-dir 参数}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "${REPOS:-}" ] || { printf '%s\n' 'REPOS 必须设置' >&2; exit 1; }
for path in "$PREFIX" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$OPENRC_DIR"; do
    valid_path "$path" || { printf '路径必须为绝对路径：%s\n' "$path" >&2; exit 1; }
done
command -v git >/dev/null 2>&1 || { printf '%s\n' '请先安装 git' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf '%s\n' '请先安装 curl' >&2; exit 1; }

mkdir -p "$PREFIX/bin" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$OPENRC_DIR"
cp "$SCRIPT_DIR/git-mirror-sync.sh" "$PREFIX/bin/git-mirror-sync.sh"
cp "$SCRIPT_DIR/update-github-hosts.sh" "$PREFIX/bin/update-github-hosts.sh"
chmod 755 "$PREFIX/bin/git-mirror-sync.sh" "$PREFIX/bin/update-github-hosts.sh"
cp "$SCRIPT_DIR/openrc/git-daemon" "$OPENRC_DIR/git-daemon"
cp "$SCRIPT_DIR/openrc/git-mirror-sync" "$OPENRC_DIR/git-mirror-sync"
cp "$SCRIPT_DIR/openrc/git-mirror-hosts" "$OPENRC_DIR/git-mirror-hosts"
chmod 755 "$OPENRC_DIR/git-daemon" "$OPENRC_DIR/git-mirror-sync" "$OPENRC_DIR/git-mirror-hosts"
cat > "$CONFIG_DIR/mirror.env" <<EOF
REPOS=$(printf '%s' "$REPOS")
SHORT_LINKS=${SHORT_LINKS:-}
MIRROR_ROOT=$DATA_DIR
LOG_DIR=$LOG_DIR
RUN_DIR=$RUN_DIR
EOF
chmod 600 "$CONFIG_DIR/mirror.env"
printf '%s\n' 'Alpine/OpenRC Git 镜像部署完成。'