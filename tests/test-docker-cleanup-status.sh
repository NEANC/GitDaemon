#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=clean IT_NETWORK=gm-clean-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
scratch=$TEST_ROOT
IT_EVIDENCE_DIR=$scratch/evidence
mkdir -p "$IT_EVIDENCE_DIR/control"

# 查询不存在和查询出错分别模拟，真实清理入口负责状态传播。
docker() {
    case "$*" in
        'ps -aq '*) [[ $fault != query ]] || return 9; [[ $fault != archive ]] || printf 'owned\n' ;;
        'inspect -f {{.Id}} '*) printf 'owned\n' ;;
        'inspect owned') return 9 ;;
        'volume ls '*) [[ $fault != volume ]] || printf 'owned-volume\n' ;;
        'volume rm '*) [[ $fault != volume ]] || return 9 ;;
        'image ls '*) [[ $fault != image ]] || printf 'owned-image\n' ;;
        'image rm '*) [[ $fault != image ]] || return 9 ;;
    esac
    return 0
}
compose() { [[ $fault != compose ]] || return 9; }
rm() { [[ $fault != directory ]] || return 9; command rm "$@"; }
for fault in none query archive volume image compose directory; do
    for primary in 0 7; do
        TEST_ROOT=$scratch/$fault-$primary
        mkdir -p "$TEST_ROOT"
        COMPOSE_OVERRIDE=$TEST_ROOT/compose.yml
        : > "$COMPOSE_OVERRIDE"
        rc=0
        ( trap cleanup EXIT; exit "$primary" ) || rc=$?
        expected=$primary
        if [[ $primary == 0 && $fault != none ]]; then expected=2; fi
        printf 'CLEANUP_CASE=%s PRIMARY=%s EXIT=%s EXPECTED=%s\n' "$fault" "$primary" "$rc" "$expected"
        [[ $rc == "$expected" ]] || exit 1
        grep -qx "INTEGRATION_PRIMARY_EXIT=$primary" "$IT_EVIDENCE_DIR/control/integration-status.txt"
        clean=0; [[ $fault == none ]] || clean=2
        grep -qx "INTEGRATION_CLEANUP_EXIT=$clean" "$IT_EVIDENCE_DIR/control/integration-status.txt"
    done
done
fault=none
TEST_ROOT=$scratch

# 局部归档在 check 子进程中失败也必须留给最终清理层。
fault=archive
rc=0
( archive_container owned ) || rc=$?
[[ $rc != 0 && -f $IT_EVIDENCE_DIR/control/integration-failures.log ]]
