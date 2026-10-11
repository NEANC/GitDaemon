#!/usr/bin/env bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
command=$(guard_runner_command startup /source run /evidence product tools)
[[ $command == *'--startup-integration'* ]]
status=0
env -u IT_NETWORK_GUARD_READY bash "$HERE/test-docker-startup-integration.sh" || status=$?
[[ $status == 77 ]]
printf '[PASS] 启动集成仅允许固定guard入口\n'
