#!/usr/bin/env bash
# CA 输入契约：网络客户端不得挂载包含上游私钥的夹具卷。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=ca IT_NETWORK=gm-ca-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
failed=0
for fn in fixture_wait_upstream fixture_wait_proxy fixture_start_auth_upstream fixture_auth_requires_token fixture_wait_hosts_endpoints fixture_hosts_oversize_content_valid_without_cap; do
    if declare -f "$fn" | grep -q '\$FIXTURE_FIX_VOL:\$FIXTURE_MOUNT'; then
        printf 'FAIL private fixture volume exposed by %s\n' "$fn"
        failed=1
    fi
done
exit "$failed"
