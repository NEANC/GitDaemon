#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR=${CONFIG_DIR:-/etc/git-mirror}
MIRROR_ROOT=${MIRROR_ROOT:-/srv/git-mirror}
PREFIX=${PREFIX:-/usr/local}
OPENRC_DIR=${OPENRC_DIR:-/etc/init.d}

# 输出卸载使用说明。
usage() { printf '%s\n' "用法: $0 [--keep-data] [--yes]"; }
KEEP_DATA=no
ASSUME_YES=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --keep-data) KEEP_DATA=yes; shift ;;
        --yes) ASSUME_YES=yes; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
    esac
done
if [ "$ASSUME_YES" != yes ]; then
    printf '确认卸载 Alpine/OpenRC Git 镜像？[y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) exit 0;; esac
fi
for service in git-daemon git-mirror-sync git-mirror-hosts; do
    if command -v rc-service >/dev/null 2>&1; then rc-service "$service" stop >/dev/null 2>&1 || true; fi
    rm -f "$OPENRC_DIR/$service"
done
rm -f "$PREFIX/bin/git-mirror-sync.sh" "$PREFIX/bin/update-github-hosts.sh"
rm -rf "$CONFIG_DIR"
[ "$KEEP_DATA" = yes ] || rm -rf "$MIRROR_ROOT"
printf '%s\n' 'Alpine/OpenRC Git 镜像卸载完成。'