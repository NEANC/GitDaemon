#!/usr/bin/env bash
# 三代必须显式传递代数，避免 check 子 shell 丢失状态后重新预置缓存。
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
file=$ROOT/tests/test-docker-integration.sh
for generation in 1 2 3; do
    grep -Eq "check '.*' compose_sync_failure_retains_cache $generation$" "$file" || {
        printf 'FAIL: missing explicit cache generation %s\n' "$generation"
        exit 1
    }
done
grep -Fq 'local CACHE_GENERATION=$1' "$file"
grep -Fq 'assert_product_egress "$id" "cache-$CACHE_GENERATION"' "$file"
grep -Fq 'host_git ls-remote "git://127.0.0.1:$COMPOSE_PORT/octocat/Nonexistent-$COMPOSE_TAG.git"' "$file"
# 原始同步日志必须逐代留存，且每代验证真实 HTTP 503。
grep -Fq 'cache-sync-$CACHE_GENERATION.log' "$file" || {
    printf 'FAIL: cache sync logs overwrite earlier generations\n'
    exit 1
}
grep -Fq "grep -q '503' \"\$TEST_ROOT/cache-sync-\$CACHE_GENERATION.log\"" "$file"
printf 'PASS: explicit cache generations retain the same host-published cache and independent 503 logs\n'
