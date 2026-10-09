#!/usr/bin/env bash
# 显式延期契约：默认执行原断言，仅明确选择时记录 mapping 延期。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=defer IT_NETWORK=gm-defer-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
if ! declare -F check_mapping_sync >/dev/null; then
    printf 'FAIL missing explicit mapping selection\n'
    exit 1
fi
# 记录调用而不启动业务。
check_proxy_sync() { printf '%s\n' "$*" >> "$TEST_ROOT/calls"; }
IT_DEFER_MAPPING=0
DEFERRED=0
check_mapping_sync mapping assertion
[[ $(cat "$TEST_ROOT/calls") == 'mapping assertion' && $DEFERRED == 0 ]]
: > "$TEST_ROOT/calls"
IT_DEFER_MAPPING=1
check_mapping_sync mapping assertion > "$TEST_ROOT/deferred"
[[ ! -s "$TEST_ROOT/calls" && $DEFERRED == 1 ]]
grep -q 'DEFER.*mapping.*NAT' "$TEST_ROOT/deferred"
printf 'PASS explicit mapping selection\n'
