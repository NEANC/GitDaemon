#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=writable IT_NETWORK=gm-writable-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
failed=0
for fn in fixture_push_rejected fixture_auth_requires_token compose_start_tls_fixture; do
    if declare -f "$fn" | grep -Eq 'cd /tmp|git-dir=/tmp'; then
        printf 'FAIL readonly root write: %s\n' "$fn"
        failed=1
    fi
done
if grep -q 'mktemp -u /tmp/' "$HERE/docker-https-fixture.sh"; then
    printf 'FAIL readonly fixture FIFO\n'
    failed=1
fi
exit "$failed"
