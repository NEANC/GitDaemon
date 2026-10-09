#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=control IT_NETWORK=gm-control-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
IT_EVIDENCE_DIR=$TEST_ROOT/evidence
mkdir -p "$IT_EVIDENCE_DIR/control"
CHECKS=0
FAILURES=0

# 模拟宿主仅为新请求采样，确认真实 check 子进程不能复用旧确认。
respond() {
    local seq action token
    for seq in 1 2 3 4; do
        while [[ ! -f $IT_EVIDENCE_DIR/control/request-$seq ]]; do sleep 0.01; done
        read -r action token < "$IT_EVIDENCE_DIR/control/request-$seq"
        printf '%s\n' "$seq" > "$IT_EVIDENCE_DIR/snapshot-$seq.rules"
        printf '%s\n' "$token" > "$IT_EVIDENCE_DIR/control/ack-$seq"
    done
}

# 每代保存实际返回的快照身份，不用替身替换控制协议。
generation() {
    network_control snapshot || return $?
    cat "$IT_EVIDENCE_DIR/snapshot-$CONTROL_SEQ.rules" >> "$TEST_ROOT/generations"
}
respond &
worker=$!
for scene in empty cache-1 cache-2 cache-3; do check "$scene" generation; done
kill "$worker" 2>/dev/null || true
wait "$worker" 2>/dev/null || true
actual=$(cat "$TEST_ROOT/generations")
printf 'GENERATION_SNAPSHOTS=%s\n' "$actual"
[[ $FAILURES == 0 && $actual == $'1\n2\n3\n4' ]]
printf 'stale\n' > "$IT_EVIDENCE_DIR/control/ack-5"
printf 'old-frame\n' > "$IT_EVIDENCE_DIR/snapshot-5.rules"
sleep() { return 0; }
rc=0
network_control snapshot || rc=$?
printf 'STALE_ACK_EXIT=%s\n' "$rc"
[[ $rc == 75 ]]
