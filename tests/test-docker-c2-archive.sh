#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=frames IT_NETWORK=gm-frames-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT
IT_EVIDENCE_DIR=$TEST_ROOT/evidence
mkdir -p "$IT_EVIDENCE_DIR/control/artifacts"
fixture_step() { return 0; }
check_c2() { return 0; }
c2_scene_record_prestate() { printf 'yes\n' > "$TEST_ROOT/c2-lock-busy"; }
c2_scene_mark_signal() { return 0; }
c2_scene_signal() { printf '%s\n' "$scene" > "$C2_STOP_FILE"; }
c2_scene_read_timeline() { printf '%s\n' "$scene" > "$C2_TIMELINE"; }
c2_scene_analyze() { printf '%s\n' "$scene" > "$C2_FACT_FILE"; }
docker() { printf 'container-%s\n' "$scene"; }

# 在真实场景入口调用清理之前，六组原始文件必须已在各自唯一目录落地。
c2_scene_teardown() {
    local dir=$IT_EVIDENCE_DIR/control/artifacts/c2/$mode/$signal/container-$scene file
    for file in c2-timeline.txt c2-facts.txt c2-stop-result; do
        [[ -f $dir/$file && $(cat "$dir/$file") == "$scene" ]] || return 1
    done
    [[ $(cat "$dir/c2-lock-busy") == yes ]]
}
for mode in firstsync timedsync timedhosts; do
    for signal in TERM INT; do
        scene=$mode-$signal
        c2_run_scenario "$mode" 1 "$signal"
    done
done
[[ $(find "$IT_EVIDENCE_DIR/control/artifacts/c2" -name c2-timeline.txt | wc -l) == 6 ]]
