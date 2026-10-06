#!/usr/bin/env bash
# 用当地墙钟验证 DST 缺失、重复分钟和世纪闰年间隔；并在固定时间戳下验证同一 cron 表达式
# 在 UTC 与 Asia/Shanghai 各自的下一次触发分别符合各自墙钟。
set -uo pipefail
source "$(dirname "$0")/../scripts/git-mirror-scheduler.sh"
[[ $UID != 0 && $EUID != 0 ]] || exit 1
failed=0
checks=0
skipped=0
# 固定 epoch 消除运行日和当前偏移对断言的影响。
check() {
    local label=$1 zone=$2 cron=$3 now=$4 expected=$5 actual
    checks=$((checks + 1))
    actual=$(TZ=$zone gm_cron_next_trigger "$cron" "$now")
    if [[ $actual == "$expected" ]]; then printf 'PASS %s\n' "$label";
    else printf 'FAIL %s expected=%s actual=%s\n' "$label" "$expected" "$actual"; failed=$((failed + 1)); fi
}
check spring EST5EDT,M3.2.0/2,M11.1.0/2 '30 2 * * *' 1772928000 1773037800
check autumn_first EST5EDT,M3.2.0/2,M11.1.0/2 '30 1 * * *' 1793509200 1793511000
check autumn_repeat EST5EDT,M3.2.0/2,M11.1.0/2 '30 1 * * *' 1793511000 1793514600
check century UTC '0 0 29 2 *' 3981312000 4233686400
# 固定时间戳 1700000000（2023-11-14T22:13:20Z；同一瞬间 Asia/Shanghai 为 2023-11-15 06:13:20）：
# 同步表达式 0 20 * * * 与 hosts 表达式 15 20 * * * 的下一次触发按最终有效时区各自墙钟独立推出；
# 两个时区的期望值相差 8 小时（28800 秒），断言只使用显式 TZ，不读取宿主机当前时区。
check sync_utc UTC '0 20 * * *' 1700000000 1700078400
check hosts_utc UTC '15 20 * * *' 1700000000 1700079300
# 非 UTC 时区需要实际 zoneinfo；缺失时以独立跳过计数与退出码报告夹具失败，绝不静默按 UTC 处理。
if [[ -e /usr/share/zoneinfo/Asia/Shanghai ]]; then
    check sync_shanghai Asia/Shanghai '0 20 * * *' 1700000000 1700049600
    check hosts_shanghai Asia/Shanghai '15 20 * * *' 1700000000 1700050500
else
    printf 'SKIP fixture_missing zoneinfo/Asia/Shanghai\n'
    skipped=$((skipped + 2))
fi
printf 'checks=%s failed=%s skipped=%s uid=%s\n' "$checks" "$failed" "$skipped" "$UID"
[[ $failed == 0 ]] || exit 1
[[ $skipped == 0 ]] || exit 77
exit 0
