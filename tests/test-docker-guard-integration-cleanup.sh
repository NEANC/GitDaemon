#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
E=$(mktemp -d)
trap 'rm -rf "$E"' EXIT
mkdir "$E/control"
RUN=layer RUNNER=gmtest
printf 'INTEGRATION_PRIMARY_EXIT=0\nINTEGRATION_CLEANUP_EXIT=2\n' > "$E/control/integration-status.txt"
docker() { return 0; }
iptables-save() { return 0; }
guard_remove_rules() { : > "$E/removed"; }
# 资源账本边界以空替身替换，清理不得触碰真实 daemon。
resource_docker() { return 0; }
rc=0
( trap guard_cleanup EXIT; exit 0 ) || rc=$?
printf 'INTEGRATION_FAILURE_GUARD_EXIT=%s\n' "$rc"
[[ $rc == 2 && ! -e $E/removed ]]
grep -qx CLEANUP_EXIT=2 "$E/exit-status.txt"
