#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
MAPPING_PROFILE=profile MP_U=140.82.112.11 MAPPING_PROXY_AUTHORITY=github.com:443 MAPPING_UPSTREAM_PORT=443
mapping_profile_load() { return 0; }
printf 'wrong_upstream_san\n' > "$WORK/case.tsv"
printf 'case\twrong_upstream_san\nlayer\tinner-failure\nconnect_delta\t1\nrequest_exit\t60\n' > "$WORK/tls-layer.tsv"
for spec in baseline.exit:0 recovery.exit:0 request.exit:60 proxy.before:3 proxy.after:4 proxy.recovered:5 upstream.before:3 upstream.after:4 fsck.exit:0; do
    printf '%s\n' "${spec#*:}" > "$WORK/${spec%:*}"
done
printf 'a\n' > "$WORK/leaf.original"
printf 'b\n' > "$WORK/leaf.wrong"
printf 'a\n' > "$WORK/leaf.restored"
printf 'abc\trefs/heads/main\n' > "$WORK/refs.expected"
cp "$WORK/refs.expected" "$WORK/refs.actual"
printf 'abc\n' > "$WORK/head.expected"
cp "$WORK/head.expected" "$WORK/head.actual"
printf 'authority=github.com:443\tmode=accept\tdial_target=140.82.112.11:443\n' > "$WORK/connect.baseline.new"
cp "$WORK/connect.baseline.new" "$WORK/connect.failed.new"
cp "$WORK/connect.baseline.new" "$WORK/connect.recovered.new"
printf '传输失败：配置的 HTTPS 代理；fatal: SSL: no alternative certificate subject name matches target host name\n' > "$WORK/request.failed.log"
mapping_negative_rejected wrong_upstream_san fallback "$WORK"
[[ $MAPPING_ASSERT_REJECT_LAYER == tls-upstream ]]
cp "$WORK/request.failed.log" "$WORK/request.valid.log"
printf 'fatal: certificate verify failed\n' > "$WORK/request.failed.log"
rc=0
mapping_negative_rejected wrong_upstream_san fallback "$WORK" || rc=$?
[[ $rc == 1 ]]
cp "$WORK/request.valid.log" "$WORK/request.failed.log"
printf '3\n' > "$WORK/upstream.after"
rc=0
mapping_negative_rejected wrong_upstream_san fallback "$WORK" || rc=$?
[[ $rc == 1 ]]
printf '4\n' > "$WORK/upstream.after"
rm "$WORK/leaf.restored"
rc=0
mapping_negative_rejected wrong_upstream_san fallback "$WORK" || rc=$?
[[ $rc == 80 ]]
printf 'upstream SAN acceptance PASS\n'
