#!/usr/bin/env bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
sed -n '/^for \(window\|scenario\) in /,$p' "$HERE/test-docker-startup-integration.sh" > "$TEST_ROOT/loop.sh"

# 仅替代 Docker 边界，运行交付探针循环及其卷内断言。
run_probe_loop() (
    export RUN_ROOT=$TEST_ROOT/$1
    mkdir -p "$RUN_ROOT/runtime"
    printf 'FROZEN=1\n' > "$RUN_ROOT/runtime/frozen"
    NAME=probe VOL=probe IMAGE=probe
    IT_EVIDENCE_DIR=$RUN_ROOT/evidence
    mkdir -p "$IT_EVIDENCE_DIR/control"
    fault=$1
    # 模拟冻结副作用，保留真实卷内命令的退出码。
    docker() {
        local sub=$1 arg code= value=
        shift
        case "$sub" in
            run)
                if [[ " $* " == *' -d '* ]]; then
                    for arg in "$@"; do
                        if [[ $arg == IT_STOP_WINDOW=* ]]; then value=${arg#*=}; fi
                    done
                    printf '%s\n' "$value" > "$RUN_ROOT/probe-reached"
                    if [[ ${scenario-} == preserve-* && $fault == lose-old ]]; then
                        rm -f "$RUN_ROOT/runtime/frozen"
                    fi
                    return 0
                fi
                while (( $# )); do
                    if [[ $1 == IT_FREEZE_SCENARIO=* ]]; then export "$1"; fi
                    if [[ $1 == -c ]]; then code=$2; break; fi
                    shift
                done
                bash -c "$code"
                ;;
            exec)
                shift
                if [[ $1 == cat ]]; then cat "$RUN_ROOT/probe-reached"
                elif [[ $* == *'git clone'* ]]; then return 0
                else "$@"; fi
                ;;
            kill)
                if [[ $fault != no-freeze ]]; then printf 'FROZEN=1\n' > "$RUN_ROOT/runtime/frozen"; fi
                ;;
            inspect)
                if [[ $* == *Running* ]]; then printf 'false\n'; else printf '0\n'; fi
                ;;
            rm) return 0 ;;
            *) return 64 ;;
        esac
    }
    source "$TEST_ROOT/loop.sh"
)

if [[ $# != 0 ]]; then run_probe_loop "$1"; exit 0; fi
status=0
bash "$0" no-freeze > "$TEST_ROOT/no-freeze.log" 2>&1 || status=$?
if [[ $status == 0 ]]; then
    cat "$TEST_ROOT/no-freeze.log"
    printf '[FAIL] TERM 未写冻结仍被旧 frozen 判为通过\n'
    exit 1
fi
printf '[PASS] TERM 未写冻结时断言失败\n'
status=0
bash "$0" lose-old > "$TEST_ROOT/lose-old.log" 2>&1 || status=$?
[[ $status != 0 ]] || { printf '[FAIL] 旧冻结丢失未被检测\n'; exit 1; }
printf '[PASS] TERM 前旧冻结丢失时断言失败\n'
bash "$0" success > "$TEST_ROOT/success.log"
for scenario in preserve-init preserve-prepare fresh-init fresh-prepare fresh-daemon fresh-checks fresh-hosts fresh-network fresh-scheduler; do
    grep -qx "SCENARIO=$scenario PRE_TERM_VERIFIED=1" "$TEST_ROOT/success.log"
done
printf '[PASS] 两类冻结场景正确时通过\n'
