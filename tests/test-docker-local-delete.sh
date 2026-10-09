#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-integration-startup.sh"
IT_RUN_ID=delete
IT_EVIDENCE_DIR=$(mktemp -d)
trap 'rm -rf "$IT_EVIDENCE_DIR"' EXIT
mkdir -p "$IT_EVIDENCE_DIR/control"

# 删除命令的错误即便被调用方忽略，也必须留下跨进程失败记录。
command() {
    [[ $1 == docker ]] || { builtin command "$@"; return $?; }
    shift
    case "$*" in
        'ps -aq '*) printf 'owned\n' ;;
        'inspect -f {{.Id}} '*) printf 'owned\n' ;;
        'rm '*) return 9 ;;
    esac
    return 0
}
( docker rm -f owned || true )
[[ -s $IT_EVIDENCE_DIR/control/integration-failures.log ]]
