#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
MP_RUN_ID=contract
CONTRACT_ID=$(printf '%064d' 0)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
resource_ledger_dir() { printf '/tmp\n'; }
resource_crosscheck() { return 0; }
resource_verify_object() { [[ $1 == container && $2 == "$CONTRACT_ID" && $3 == mapping && $4 == witness ]]; }
mapping_fixture_docker() {
    case "$1 $2" in
        'inspect -f') printf '%s\n' "$CONTRACT_ID" ;;
        'exec gm-contract-witness')
            shift 2
            if [[ $1 == sh ]]; then
                if [[ $* == *'/proc/[0-9]*'* ]]; then
                    printf '123\n'
                else
                    [[ $* != *'/proc/$1/stat'* ]] || [[ $(cat "$work/state") == "${@: -1}" ]]
                fi
            elif [[ $1 == kill ]]; then
                printf '%s\n' "$2" >> "$work/signals"
                [[ $2 != -STOP || ! -e $work/ignore-stop ]] || return 0
                [[ $2 != -STOP ]] || printf 'T\n' > "$work/state"
                [[ $2 != -CONT ]] || printf 'R\n' > "$work/state"
            fi
            ;;
        *) return 1 ;;
    esac
}

printf 'R\n' > "$work/state"
[[ $(mapping_receiver_listener_control dns-udp STOP) == 123 && $(cat "$work/state") == T ]]
[[ $(mapping_receiver_listener_control dns-tcp CONT 123) == 123 && $(cat "$work/state") == R ]]
[[ $(wc -l < "$work/signals") == 2 ]]
: > "$work/ignore-stop"
rc=0
mapping_receiver_listener_control dns-udp STOP >/dev/null || rc=$?
[[ $rc == 80 && $(cat "$work/state") == R ]]
