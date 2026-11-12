#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mapping_fixture_docker() {
    [[ $1 == exec ]] || return 80
    case $* in
        *' dig '*) printf 'no servers could be reached\n\n'; return 9 ;;
        *' nslookup '*) printf 'connection timed out\n\n'; return 124 ;;
        *' curl '*) printf 'Operation timed out\n\n'; return 28 ;;
        *) printf 'connection refused\n\n'; return 7 ;;
    esac
}

check_case() (
    local kind=$1 key=$2 rc=0 status text file=$WORK/$kind-$key
    mkdir -p "$file/probe"
    CONTROL_SEQ=4
    if [[ $kind == negative ]]; then
        mapping_receiver_negative_probe "$key" "$file" > "$file/negative.log" || rc=$?
    else
        mapping_probe_egress product g1 "$key" "$file" > "$file/probe.log" || rc=$?
    fi
    [[ $rc == 0 ]] || return 1
    case $key in
        dns-udp) status=124; text='connection timed out' ;;
        dns-*) status=9; text='no servers could be reached' ;;
        *) if [[ $kind == negative ]]; then status=7; text='connection refused'; else status=28; text='Operation timed out'; fi ;;
    esac
    [[ $kind != negative || $key != dns-udp ]] || { status=9; text='no servers could be reached'; }
    printf '%s\n\n' "$text" > "$WORK/expected"
    cmp -s "$WORK/expected" "$file/$kind/raw.log" || return 1
    cmp -s "$file/$kind/raw.log" "$file/$kind.log" || return 1
    mapping_isolation_raw_log_accept "$file" "$kind" || return 1
    [[ $(cat "$file/$kind/raw.exit") == "$status" ]] || return 1
    [[ $(awk -F '\t' '$1 == "exit" {print $2}' "$file/$kind/command.tsv") == "$status" ]] || return 1
    [[ $(awk -F '\t' '$1 == "raw_sha256" {print $2}' "$file/$kind/command.tsv") == "$(sha256sum "$file/$kind/raw.log" | cut -d' ' -f1)" ]]
)

check_nul() (
    mapping_fixture_docker() { printf 'connection refused\0\n\n'; return 7; }
    local file=$WORK/nul rc=0
    mkdir -p "$file"
    mapping_receiver_negative_probe cross-network "$file" > "$file/negative.log" || rc=$?
    [[ $rc == 0 ]] || return 1
    printf 'connection refused\0\n\n' > "$WORK/expected"
    cmp -s "$WORK/expected" "$file/negative/raw.log" || return 1
    mapping_isolation_raw_log_accept "$file" negative || return 1
    printf 'connection refused\0\n' > "$file/negative.log"
    rc=0; mapping_isolation_raw_log_accept "$file" negative || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'connection refused\0\n\n' > "$file/negative.log"
    [[ $(cat "$file/negative/raw.exit") == 7 ]] || return 1
    [[ $(awk -F '\t' '$1 == "raw_sha256" {print $2}' "$file/negative/command.tsv") == "$(sha256sum "$WORK/expected" | cut -d' ' -f1)" ]]
)

check_probe_nul() (
    mapping_fixture_docker() { printf 'Operation timed out\0\n\n'; return 28; }
    local file=$WORK/probe-nul rc=0
    mkdir -p "$file/probe"
    mapping_probe_egress product g1 cross-network "$file" > "$file/probe.log" || rc=$?
    [[ $rc == 0 ]] || return 1
    printf 'Operation timed out\0\n\n' > "$WORK/expected"
    cmp -s "$WORK/expected" "$file/probe/raw.log" || return 1
    mapping_isolation_raw_log_accept "$file" probe || return 1
    printf 'Operation timed out\0\n' > "$file/probe.log"
    rc=0; mapping_isolation_raw_log_accept "$file" probe || rc=$?
    [[ $rc == 1 ]] || return 1
    printf 'Operation timed out\0\n\n' > "$file/probe.log"
    [[ $(cat "$file/probe/raw.exit") == 28 ]] || return 1
    [[ $(awk -F '\t' '$1 == "raw_sha256" {print $2}' "$file/probe/command.tsv") == "$(sha256sum "$WORK/expected" | cut -d' ' -f1)" ]]
)

check_docker_failure() (
    mapping_fixture_docker() { printf 'Error response from daemon:\0\n\n'; return 23; }
    local file=$WORK/docker-failure rc=0
    mkdir -p "$file/probe"
    mapping_probe_egress product g1 cross-network "$file" > "$file/probe.log" || rc=$?
    [[ $rc == 80 ]] || return 1
    printf 'Error response from daemon:\0\n\n' > "$WORK/expected"
    cmp -s "$WORK/expected" "$file/probe/raw.log" || return 1
    cmp -s "$WORK/expected" "$file/probe.log" || return 1
    [[ $(cat "$file/probe/raw.exit") == 23 ]] || return 1
    [[ $(awk -F '\t' '$1 == "exit" {print $2}' "$file/probe/command.tsv") == 23 ]]
)

MP_RUN_ID=mtest MP_NETWORK_ID=net-one MAPPING_ASSERT_GENERATION=g1
failed=0
for row in 'negative cross-network' 'negative host-published' 'negative host-input' 'negative dns-udp' 'negative dns-tcp' 'probe cross-network' 'probe host-published' 'probe host-input' 'probe dns-udp'; do
    read -r kind key <<< "$row"
    rc=0; check_case "$kind" "$key" || rc=$?
    printf '%s %s EXIT=%s\n' "$kind" "$key" "$rc"
    [[ $rc == 0 ]] || failed=1
done
rc=0; check_nul || rc=$?
printf 'negative NUL EXIT=%s\n' "$rc"
[[ $rc == 0 ]] || failed=1
rc=0; check_probe_nul || rc=$?
printf 'probe NUL EXIT=%s\n' "$rc"
[[ $rc == 0 ]] || failed=1
rc=0; check_docker_failure || rc=$?
printf 'Docker failure EXIT=%s\n' "$rc"
[[ $rc == 0 ]] || failed=1
exit "$failed"
