#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=expected IT_NETWORK=gm-expected-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
compose() { return 0; }
compose_container_id() { printf 'exited-product\n'; }
container_networks_internal() { printf 'LIVE_POLICY_CALLED\n' >> "$TEST_ROOT/policy"; return 1; }
assert_container_network_configuration() { printf '%s\n' "$1" >> "$TEST_ROOT/static-policy"; }
docker() { printf 'false\n'; }
rc=0
compose_start_expect_failure || rc=$?
printf 'EXPECTED_EXIT_SCENE=%s\n' "$rc"
[[ $rc == 0 && ! -e $TEST_ROOT/policy && -s $TEST_ROOT/static-policy ]]
