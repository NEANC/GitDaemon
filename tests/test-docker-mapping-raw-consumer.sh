#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_raw_consumer() (
    local kind=$1 key=$2 rc=0 dir=$WORK/$1-$2
    mkdir -p "$dir/$kind"
    printf 'connection timed out\0\n\n' > "$dir/$kind/raw.log"
    cp "$dir/$kind/raw.log" "$dir/$kind.log"
    mapping_isolation_raw_log_accept "$dir" "$kind" || return 1
    printf 'connection timed out\0\n' > "$dir/$kind.log"
    mapping_isolation_raw_log_accept "$dir" "$kind" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$dir/$kind/raw.log" "$dir/$kind.log"
    printf 'connection timed out\n\n' > "$dir/$kind.log"
    rc=0; mapping_isolation_raw_log_accept "$dir" "$kind" || rc=$?
    [[ $rc == 1 ]] || return 1
    rm "$dir/$kind.log"
    rc=0; mapping_isolation_raw_log_accept "$dir" "$kind" || rc=$?
    [[ $rc == 80 ]]
)

check_tcp_dns_consumer() (
    local dir=$WORK/shared-tcp rc=0 tool product
    tool=$(printf '%064d' 2)
    product=$(printf '%064d' 1)
    mkdir -p "$dir/probe"
    printf 'no servers could be reached\0\n\n' > "$dir/probe/raw.log"
    printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$product" > "$dir/probe.log"
    cat "$dir/probe/raw.log" >> "$dir/probe.log"
    mapping_isolation_tcp_dns_raw_log_accept "$dir" "$tool" "$product" || return 1
    printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$product" > "$dir/probe.log"
    printf 'no servers could be reached\0\n' >> "$dir/probe.log"
    mapping_isolation_tcp_dns_raw_log_accept "$dir" "$tool" "$product" || rc=$?
    [[ $rc == 1 ]] || return 1
    cp "$dir/probe/raw.log" "$dir/probe.log"
    rc=0; mapping_isolation_tcp_dns_raw_log_accept "$dir" "$tool" "$product" || rc=$?
    [[ $rc == 1 ]]
)

failed=0
for key in cross-network host-published host-input dns-udp dns-tcp; do
    for kind in negative probe; do
        rc=0; check_raw_consumer "$kind" "$key" || rc=$?
        printf '%s %s EXIT=%s\n' "$kind" "$key" "$rc"
        [[ $rc == 0 ]] || failed=1
    done
done
rc=0; check_tcp_dns_consumer || rc=$?
printf 'shared tcp-dns EXIT=%s\n' "$rc"
[[ $rc == 0 ]] || failed=1
exit "$failed"
