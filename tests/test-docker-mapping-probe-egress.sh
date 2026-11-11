#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"

# 逐目标校验拒绝、触达以及工具与 Docker 错误的退出类别。
probe_case() (
    local key=$1 mode=$2 expected=$3 actual=0 output
    MP_RUN_ID=mtest
    # 替代 Docker 执行边界并记录目标探针次数。
    mapping_fixture_docker() {
        printf '%s\n' "$*" >> "$CALLS"
        case "$mode" in
            rejected)
                if [[ $key == dns-udp ]]; then
                    printf 'nslookup: cannot resolve: connection timed out\n' >&2
                    return 1
                fi
                printf 'curl: (28) Connection timed out\n' >&2
                return 28
                ;;
            reached)
                if [[ $key == dns-udp ]]; then
                    printf 'Name: reachable.invalid\nAddress: 172.30.244.53\n'
                else
                    printf 'HTTP/1.1 200 OK\n'
                fi
                return 0
                ;;
            tool-error)
                printf 'timeout: failed to run command\n' >&2
                return 127
                ;;
            docker-error)
                printf 'Error response from daemon: container is not running\n' >&2
                return 1
                ;;
            false-timeout)
                printf 'Error response from daemon: Connection timed out\n' >&2
                if [[ $key == dns-udp ]]; then return 1; fi
                return 28
                ;;
            udp-timeout)
                printf 'nslookup timed out\n' >&2
                return 124
                ;;
        esac
    }
    : > "$CALLS"
    output=$(mapping_probe_egress product gen1 "$key" 2>&1) || actual=$?
    [[ $actual == "$expected" && $(wc -l < "$CALLS") == 1 ]]
)

CALLS=$(mktemp)
trap 'rm -f "$CALLS"' EXIT
failed=0
for key in dns-udp cross-network host-published host-input; do
    for row in 'rejected 0' 'reached 1' 'tool-error 80' 'docker-error 80' 'false-timeout 80'; do
        read -r mode expected <<< "$row"
        probe_case "$key" "$mode" "$expected" || { printf 'FAIL %s %s\n' "$key" "$mode"; failed=1; }
    done
done
probe_case dns-udp udp-timeout 0 || { printf 'FAIL dns-udp udp-timeout\n'; failed=1; }
exit "$failed"
