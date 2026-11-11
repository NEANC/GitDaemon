#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/../scripts/git-mirror-sync.sh"
source "$HERE/docker-mapping-fixture.sh"
source "$HERE/docker-mapping-assertions.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
LOG_FILE=$WORK/product.log
GM_CONFIG[PROXY_URL]=https://gm-proxy:8443
GM_TRANSPORT_SEQUENCE=(proxy)
GM_REPOS=(gitdaemon/fixture)
GM_BRANCHES=('')

gm_check_identity() { return 0; }
gm_prepare_runtime() { return 0; }
configure_fetch() { return 0; }
git() {
    if [[ $* == *'remote get-url origin'* ]]; then printf 'https://github.com/gitdaemon/fixture.git\n'; return 0; fi
    return 1
}
run_cmd() {
    printf "fatal: unable to access 'https://github.com/gitdaemon/fixture.git/': SSL: no alternative certificate subject name matches target host name 'github.com'\n" | tee "$GM_SYNC_DIAGNOSTIC"
    return 128
}
source() {
    if [[ $1 == */git-mirror-recover.sh ]]; then
        gm_recover_scheduled() { update_repo "$1" "$WORK/repo.git" ''; }
        return 0
    fi
    builtin source "$@"
}

rc=0
gm_sync_main --repo gitdaemon/fixture > "$WORK/sync.log" || rc=$?
[[ $rc == 1 ]] || { printf '产品聚合退出码：%s\n' "$rc" >&2; exit 1; }
[[ $(cat "$WORK/sync.log") == *'fatal: unable to access '* ]] || exit 1
[[ $(cat "$WORK/sync.log") != *'传输失败：配置的 HTTPS 代理'* ]] || exit 1
if [[ $# == 1 ]]; then
    cp "$WORK/sync.log" "$1/sync.log"
    printf '%s\n' "$rc" > "$1/sync.exit"
fi
printf '%s\n' "$rc" > "$WORK/sync.exit"
cp "$WORK/sync.log" "$WORK/request.failed.log"
rc=$(mapping_assert_uint_file "$WORK/sync.exit")
[[ $rc == 1 ]] || exit 1
mapping_upstream_san_git_failure "$WORK/request.failed.log" || exit 1
printf "fatal: unable to access 'https://github.com/gitdaemon/fixture.git/': Could not resolve host: github.com\n" >> "$WORK/request.failed.log"
if mapping_upstream_san_git_failure "$WORK/request.failed.log"; then exit 1; fi
printf "fatal: unable to access 'https://github.com/gitdaemon/fixture.git/': SSL: no alternative certificate subject name matches target host name 'other-host.invalid'\n" > "$WORK/request.failed.log"
if mapping_upstream_san_git_failure "$WORK/request.failed.log"; then exit 1; fi
printf 'upstream SAN product boundary PASS\n'
