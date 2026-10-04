#!/usr/bin/env bash
# 用当地墙钟验证 DST 缺失、重复分钟和世纪闰年间隔。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-scheduler.sh"
[[ $UID != 0 && $EUID != 0 ]] || exit 1
failed=0
# 固定 epoch 消除运行日和当前偏移对断言的影响。
check() {
    local label=$1 zone=$2 cron=$3 now=$4 expected=$5 actual
    actual=$(TZ=$zone gm_cron_next_trigger "$cron" "$now")
    if [[ $actual == "$expected" ]]; then printf 'PASS %s\n' "$label";
    else printf 'FAIL %s expected=%s actual=%s\n' "$label" "$expected" "$actual"; failed=$((failed+1)); fi
}
check spring EST5EDT,M3.2.0/2,M11.1.0/2 '30 2 * * *' 1772928000 1773037800
check autumn_first EST5EDT,M3.2.0/2,M11.1.0/2 '30 1 * * *' 1793509200 1793511000
check autumn_repeat EST5EDT,M3.2.0/2,M11.1.0/2 '30 1 * * *' 1793511000 1793514600
check century UTC '0 0 29 2 *' 3981312000 4233686400
printf 'checks=4 failed=%s uid=%s\n' "$failed" "$UID"
exit "$((failed != 0))"
