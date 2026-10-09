#!/usr/bin/env bash
# 共享网络生命周期契约：使用命令替身验证资源归属，不启动实际容器。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_RUN_ID=shared IT_NETWORK=gm-shared-net IT_SOURCE_ONLY=1
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
failed=0
for network in "$FIXTURE_NET" "$AUTH_NET" "$C2_NET"; do
    if [[ $network != "$IT_NETWORK" ]]; then
        printf 'FAIL shared network: %s\n' "$network"
        failed=1
    fi
done
for volume in "$FIXTURE_FIX_VOL" "$FIXTURE_PROD_VOL" "$AUTH_PROD_VOL" "$C2_VOL" "$C2_LOG_VOL"; do
    if [[ $volume != gm-shared-* ]]; then
        printf 'FAIL scoped volume: %s\n' "$volume"
        failed=1
    fi
done
# 只记录容器与网络操作，阻止任何真实 Docker 调用。
docker() { printf '%s\n' "$*" >> "$TEST_ROOT/docker.calls"; }
# 契约不需要采集真实容器日志。
archive_container() { return 0; }
fixture_create_network_and_volumes
c2_scene_teardown
if grep -q 'network \(create\|rm\)' "$TEST_ROOT/docker.calls"; then
    printf 'FAIL scenario changed guard-owned network\n'
    failed=1
fi
if ! declare -F fixture_release_shared_endpoints >/dev/null; then
    printf 'FAIL missing serial endpoint release\n'
    failed=1
else
    : > "$TEST_ROOT/docker.calls"
    fixture_release_shared_endpoints "$FIXTURE_PROD" "$FIXTURE_NAME"
    grep -q "rm -f $FIXTURE_PROD $FIXTURE_NAME" "$TEST_ROOT/docker.calls" || failed=1
    if grep -q 'volume\|network' "$TEST_ROOT/docker.calls"; then
        printf 'FAIL endpoint release removes auth dependencies\n'
        failed=1
    fi
fi
exit "$failed"
