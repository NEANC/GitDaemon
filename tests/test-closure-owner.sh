#!/usr/bin/env bash
# 拒绝 owner 的 .git 后缀，避免 owner 目录与短链接命名协议冲突。
set -euo pipefail
source "$(dirname "$0")/../scripts/lib/foundation.sh"
[[ $UID != 0 && $EUID != 0 ]]
if gm_validate_repo_name owner.git/repo; then
    printf 'FAIL accepted owner.git/repo uid=%s\n' "$UID"; exit 1
fi
gm_validate_repo_name owner/repo
printf 'PASS rejects .git owner and accepts ordinary owner uid=%s\n' "$UID"
