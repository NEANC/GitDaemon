#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
MP_RUN_ID="pidtest-$$"
receiver="gm-$MP_RUN_ID-witness"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
IT_CONTROL_DIR=$work
container_id=$(printf '%064d' 0)
rebound_id=$(printf '%064d' 1)
name_target=$container_id
id_alive=1
: > "$work/inspects"
mkdir -p "$work/proc/net" "$work/proc/101/fd" "$work/proc/202/fd" "$work/proc/303/fd"

# 写入包含 starttime 字段的模拟进程状态。
write_stat() {
    local n
    printf '%s (dnsmasq) %s' "$1" "$2" > "$work/proc/$1/stat"
    for n in {1..18}; do printf ' 0' >> "$work/proc/$1/stat"; done
    printf ' %s\n' "$3" >> "$work/proc/$1/stat"
}

listener_args='dnsmasq --keep-in-foreground --no-resolv --no-hosts --address=/#/ --log-queries --log-facility=- --pid-file= --user=git-daemon'
for pid in 101 202 303; do
    printf 'dnsmasq\n' > "$work/proc/$pid/comm"
    printf '%s\0' "$listener_args" > "$work/proc/$pid/cmdline"
    write_stat "$pid" R 1
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
        printf 'inspect\n' >> "$work/inspects"
        if [[ ${rebind_after_inspect:-0} == 1 && $(wc -l < "$work/inspects") -gt 1 ]]; then
            printf '%s\n' "$rebound_id"
        elif [[ -e $work/rebound ]]; then
            printf '%s\n' "$rebound_id"
        else
            printf '%s\n' "$name_target"
        fi
        if [[ -n ${rebind_on_inspect:-} && $(wc -l < "$work/inspects") -eq $rebind_on_inspect ]]; then
            : > "$work/rebound"
        fi
    elif [[ $1 == inspect && $2 == -f && $4 == "$container_id" ]]; then
        [[ $id_alive == 1 ]] || return 1
        printf '%s\n' "$container_id"
    elif [[ $1 == exec && ( $2 == "$receiver" || $2 == "$container_id" ) ]]; then
        if [[ $2 == "$receiver" && ( ( ${rebind_after_inspect:-0} == 1 && -s $work/inspects ) || -e $work/rebound ) ]]; then
            printf 'new-container-access\n' >> "$work/accesses"
        fi
        [[ $id_alive == 1 ]] || return 1
        shift 2
        if [[ $1 == sh && $2 == -c ]]; then
            local script=$3
            script=${script//\/proc\//$work\/proc\/}
            sh -c "$script" "${@:4}"
        elif [[ $1 == kill ]]; then
            printf '%s\n' "$(wc -l < "$work/inspects")" > "$work/pre-signal-inspects"
            [[ $3 == 101 ]] || return 80
            case $2 in
                -STOP) write_stat 101 T 1 ;;
                -CONT) write_stat 101 R 1 ;;
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
rm "$work/proc/202/fd/3" "$work/proc/202/fd/4"
printf '1: 0100007F:0035 00000000:0000 07 0 0 0 0 0 333\n' >> "$work/proc/net/udp"
printf '1: 0100007F:0035 00000000:0000 0A 0 0 0 0 0 444\n' >> "$work/proc/net/tcp"
expect_pid dns-udp 101
expect_pid dns-tcp 101
rm "$work/proc/101/fd/3" "$work/proc/101/fd/4"
ln -s 'socket:[333]' "$work/proc/101/fd/3"
ln -s 'socket:[444]' "$work/proc/101/fd/4"
expect_pid dns-udp 101
expect_pid dns-tcp 101
rm "$work/proc/101/fd/4"
ln -s 'socket:[444]' "$work/proc/202/fd/5"
expect_rejected
rm "$work/proc/202/fd/5"
ln -s 'socket:[444]' "$work/proc/101/fd/4"
printf '0: 0100007F:0035 00000000:0000 07 0 0 0 0 0 333\n' > "$work/proc/net/udp"
printf '0: 0100007F:0035 00000000:0000 0A 0 0 0 0 0 444\n' > "$work/proc/net/tcp"
expect_pid dns-udp 101
[[ $(mapping_receiver_listener_control dns-udp STOP) == 101 ]]
mapping_receiver_listener_state 101 T
[[ $(mapping_receiver_listener_control dns-tcp CONT 101) == 101 ]]
mapping_receiver_listener_state 101 R
[[ $(cat "$work/signals") == $'-STOP 101\n-CONT 101' ]]
[[ $(mapping_receiver_listener_control dns-udp STOP) == 101 ]]
rm "$work/proc/101/fd/3"
ln -s 'socket:[555]' "$work/proc/101/fd/3"
printf '0: 0100007F:0035 00000000:0000 07 0 0 0 0 0 555\n' > "$work/proc/net/udp"
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101' ]]
rm "$work/proc/101/fd/3"
ln -s 'socket:[333]' "$work/proc/101/fd/3"
printf '0: 0100007F:0035 00000000:0000 07 0 0 0 0 0 333\n' > "$work/proc/net/udp"
rm "$work/proc/101/fd/3" "$work/proc/101/fd/4"
ln -s 'socket:[333]' "$work/proc/202/fd/3"
ln -s 'socket:[444]' "$work/proc/202/fd/4"
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101' ]]
rm "$work/proc/202/fd/3" "$work/proc/202/fd/4"
ln -s 'socket:[333]' "$work/proc/101/fd/3"
ln -s 'socket:[444]' "$work/proc/101/fd/4"
write_stat 101 T 2
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101' ]]
write_stat 101 T 1
[[ $(mapping_receiver_listener_control dns-tcp CONT 101) == 101 ]]
[[ $(awk -F ') ' '{split($2, fields, " "); print fields[1]}' "$work/proc/202/stat") == R ]]
rm "$work/proc/101/fd/3" "$work/proc/101/fd/4"
ln -s 'socket:[111]' "$work/proc/101/fd/3"
ln -s 'socket:[222]' "$work/proc/101/fd/4"

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
[[ $rc == 80 && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
rm "$work/proc/303/fd/5" "$work/proc/303/fd/6"
expect_pid dns-udp 101
printf 'listener PID, port 53 socket ownership and STOP/CONT contract verified\n'

rebind_after_inspect=1
: > "$work/inspects"
rc=0
mapping_receiver_listener_pid dns-udp >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses ]]
for operation in identity state running; do
    : > "$work/inspects"
    rc=0
    case $operation in
        identity) mapping_receiver_listener_identity 101 dns-udp >/dev/null || rc=$? ;;
        state) mapping_receiver_listener_state 101 R || rc=$? ;;
        running) mapping_receiver_listener_running dns-udp 101 || rc=$? ;;
    esac
    [[ $rc == 80 && ! -e $work/accesses ]]
done
: > "$work/inspects"
rc=0
mapping_receiver_listener_control dns-udp STOP >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
: > "$work/inspects"
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
: > "$work/inspects"
rc=0
mapping_isolation_stop_failure dns-udp "$work" 80 || rc=$?
[[ $rc == 80 && ! -e $work/accesses && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
rebind_after_inspect=0
id_alive=0
rc=0
mapping_receiver_listener_pid dns-udp >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses ]]
rc=0
mapping_receiver_listener_running dns-udp 101 || rc=$?
[[ $rc == 80 && ! -e $work/accesses ]]
rc=0
mapping_receiver_listener_control dns-udp STOP >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
id_alive=1
[[ $(mapping_receiver_listener_control dns-udp STOP) == 101 ]]
name_target=$rebound_id
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 && ! -e $work/accesses && $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101\n-STOP 101' ]]
printf 'listener name rebinding and original exit rejected without new-container access\n'

name_target=$container_id
: > "$work/inspects"
[[ $(mapping_receiver_listener_control dns-tcp CONT 101) == 101 ]]
: > "$work/inspects"
[[ $(mapping_receiver_listener_control dns-udp STOP) == 101 ]]
rebind_on_inspect=$(cat "$work/pre-signal-inspects")
: > "$work/inspects"
rc=0
mapping_receiver_listener_control dns-tcp CONT 101 >/dev/null || rc=$?
[[ $rc == 80 ]]
[[ -e $work/rebound && ! -e $work/accesses ]]
[[ $(cat "$work/pre-signal-inspects") == "$rebind_on_inspect" ]]
[[ $(cat "$work/signals") == $'-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101\n-STOP 101\n-CONT 101' ]]
printf 'listener uses registered full ID after pre-signal name rebinding\n'
