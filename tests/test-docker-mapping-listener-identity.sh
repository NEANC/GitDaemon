#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
MP_RUN_ID="pidtest-$$"
receiver="gm-$MP_RUN_ID-witness"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
container_id=$(printf '%064d' 0)
mkdir -p "$work/proc/net" "$work/proc/101/fd" "$work/proc/202/fd" "$work/proc/303/fd"

listener_args='dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon'
for pid in 101 202 303; do
    printf 'dnsmasq\n' > "$work/proc/$pid/comm"
    printf '%s\0' "$listener_args" > "$work/proc/$pid/cmdline"
    printf '%s (dnsmasq) R 1 1 1\n' "$pid" > "$work/proc/$pid/stat"
done
ln -s 'socket:[111]' "$work/proc/101/fd/3"
ln -s 'socket:[222]' "$work/proc/101/fd/4"
ln -s 'socket:[333]' "$work/proc/202/fd/3"
ln -s 'socket:[444]' "$work/proc/202/fd/4"
ln -s 'socket:[555]' "$work/proc/303/fd/3"
ln -s 'socket:[666]' "$work/proc/303/fd/4"
printf '0: 0100007F:0035 00000000:0000 07 0 0 0 0 0 111\n' > "$work/proc/net/udp"
printf '0: 0100007F:0035 00000000:0000 0A 0 0 0 0 0 222\n' > "$work/proc/net/tcp"
: > "$work/proc/net/udp6"
: > "$work/proc/net/tcp6"

resource_ledger_dir() { printf '/tmp\n'; }
resource_crosscheck() { [[ $RESOURCE_RUN == "$MP_RUN_ID" ]]; }
resource_verify_object() { [[ $1 == container && $2 == "$container_id" && $3 == mapping && $4 == witness ]]; }

mapping_fixture_docker() {
    if [[ $1 == inspect && $2 == -f && $4 == "$receiver" ]]; then
        printf '%s\n' "$container_id"
    elif [[ $1 == exec && $2 == "$receiver" ]]; then
        shift 2
        if [[ $1 == sh && $2 == -c ]]; then
            local script=$3
            script=${script//\/proc\//$work\/proc\/}
            sh -c "$script" "${@:4}"
        elif [[ $1 == kill ]]; then
            [[ $3 == 101 ]] || return 80
            case $2 in
                -STOP) printf '101 (dnsmasq) T 1 1 1\n' > "$work/proc/101/stat" ;;
                -CONT) printf '101 (dnsmasq) R 1 1 1\n' > "$work/proc/101/stat" ;;
                *) return 80 ;;
            esac
            printf '%s %s\n' "$2" "$3" >> "$work/signals"
        else
            return 80
        fi
    else
        return 80
    fi
}

expect_pid() {
    local key=$1 expected=$2 actual
    actual=$(mapping_receiver_listener_pid "$key") || return 1
    [[ $actual == "$expected" ]]
}

expect_rejected() {
    local rc=0
    mapping_receiver_listener_pid dns-udp >/dev/null || rc=$?
    [[ $rc == 80 ]]
}

expect_pid dns-udp 101
expect_pid dns-tcp 101
rm "$work/proc/101/fd/4"
ln -s 'socket:[222]' "$work/proc/202/fd/5"
expect_rejected
rm "$work/proc/202/fd/5"
ln -s 'socket:[222]' "$work/proc/101/fd/4"
expect_pid dns-udp 101
[[ $(mapping_receiver_listener_control dns-udp STOP) == 101 ]]
mapping_receiver_listener_state 101 T
[[ $(mapping_receiver_listener_control dns-tcp CONT 101) == 101 ]]
mapping_receiver_listener_state 101 R
[[ $(cat "$work/signals") == $'-STOP 101\n-CONT 101' ]]
[[ $(cat "$work/proc/202/stat") == '202 (dnsmasq) R 1 1 1' ]]

printf '0: 0100007F:1535 00000000:0000 07 0 0 0 0 0 111\n' > "$work/proc/net/udp"
expect_rejected
printf '0: 0100007F:0035 00000000:0000 07 0 0 0 0 0 111\n' > "$work/proc/net/udp"
printf '0: 0100007F:1535 00000000:0000 0A 0 0 0 0 0 222\n' > "$work/proc/net/tcp"
expect_rejected
printf '0: 0100007F:0035 00000000:0000 0A 0 0 0 0 0 222\n' > "$work/proc/net/tcp"
ln -s 'socket:[111]' "$work/proc/303/fd/5"
ln -s 'socket:[222]' "$work/proc/303/fd/6"
expect_rejected
rc=0
mapping_receiver_listener_control dns-udp STOP >/dev/null || rc=$?
[[ $rc == 80 && $(cat "$work/signals") == $'-STOP 101\n-CONT 101' ]]
rm "$work/proc/303/fd/5" "$work/proc/303/fd/6"
expect_pid dns-udp 101
printf 'listener PID, port 53 socket ownership and STOP/CONT contract verified\n'
