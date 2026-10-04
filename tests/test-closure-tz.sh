#!/usr/bin/env bash
# 配置时区必须在实际系统上可用，不能把缺失名称静默当 UTC。
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/foundation.sh"
[[ $UID != 0 && $EUID != 0 ]]
if gm_validate_config_value TZ Missing/ClosureTimezone; then
    printf 'FAIL accepts missing timezone uid=%s\n' "$UID"; exit 1
fi
gm_validate_config_value TZ UTC
printf 'PASS missing timezone rejected and UTC accepted uid=%s\n' "$UID"
