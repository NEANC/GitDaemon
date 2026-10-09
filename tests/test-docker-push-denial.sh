#!/usr/bin/env bash
# 核验实机 daemon 拒绝诊断，不将连接故障或成功响应当作拒绝。
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/docker-push-denial.sh"
host_push_denied 128 'fatal: remote error: access denied'
host_push_denied 128 'fatal: remote error: service not enabled: /fixtures/pub.git'
if host_push_denied 128 'fatal: unable to connect: Connection refused'; then exit 1; fi
if host_push_denied 0 'remote error: service not enabled:'; then exit 1; fi
printf 'PASS: daemon denial distinguished from transport failure\n'
