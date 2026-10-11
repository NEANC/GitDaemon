#!/usr/bin/env bash
set -euo pipefail
[[ ${IT_NETWORK_GUARD_READY-} == 1 && $(id -u) != 0 ]] || exit 77
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-integration-startup.sh"
IMAGE=${IT_PRODUCT_IMAGE:?}
NAME=gm-$IT_RUN_ID-startup
VOL=gm-$IT_RUN_ID-startup-data

startup_cleanup() {
    local primary=$? cleanup=0
    trap - EXIT
    docker rm -f "$NAME" >/dev/null || cleanup=1
    docker volume rm "$VOL" >/dev/null || cleanup=1
    printf 'INTEGRATION_CLEANUP_EXIT=%s\n' "$cleanup" > "$IT_EVIDENCE_DIR/control/integration-status.txt"
    if (( primary != 0 )); then exit "$primary"; fi
    exit "$cleanup"
}

startup_wait_ready() {
    local i
    for i in $(seq 1 120); do
        if docker logs "$NAME" 2>&1 | grep -q '容器前台就绪'; then return 0; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$NAME") == true ]] || { docker logs "$NAME"; return 1; }
        sleep 1
    done
    docker logs "$NAME"
    return 1
}

docker volume create "$VOL" >/dev/null
trap startup_cleanup EXIT
docker run --rm --network none -v "$VOL:/var/lib/git-daemon" --entrypoint /bin/bash "$IMAGE" -c '
    set -eu
    umask 077
    for repo in first second legacy; do
        dir=/var/lib/git-daemon/repos/owner/$repo.git
        git init -q --bare "$dir"
        tree=$(git --git-dir="$dir" mktree </dev/null)
        commit=$(printf "seed\n" | git -c user.name=test -c user.email=test@example.invalid --git-dir="$dir" commit-tree "$tree")
        git --git-dir="$dir" update-ref refs/heads/main "$commit"
        git --git-dir="$dir" symbolic-ref HEAD refs/heads/main
        git --git-dir="$dir" remote add origin "https://github.com/owner/$repo.git"
        : > "$dir/git-daemon-export-ok"
    done
    mkdir -p /var/lib/git-daemon/config
    printf "ENABLE_HOSTS_UPDATE=no\nCRON_SCHEDULE=0 0 1 1 *\n" > /var/lib/git-daemon/config/mirror.env
'
docker run -d --name "$NAME" --network none -v "$VOL:/var/lib/git-daemon" \
    --entrypoint /usr/local/bin/git-mirror-entrypoint -e REPOS='owner/first;owner/second' "$IMAGE" >/dev/null
startup_wait_ready
docker exec "$NAME" bash -c '
    set -eu
    source "$INSTALL_ROOT/lib/foundation.sh"
    gm_set_instance_environment "$RUN_ROOT" "$INSTALL_ROOT"
    test -f "$RUN_ROOT/runtime/checks-complete"
    test ! -e "$RUN_ROOT/repos/owner/legacy.git/git-daemon-export-ok"
    test -f "$RUN_ROOT/repos/owner/legacy.git/HEAD"
    git ls-remote git://127.0.0.1/owner/first.git | grep refs/heads/main
    git ls-remote git://127.0.0.1/owner/second.git | grep refs/heads/main
    if git ls-remote git://127.0.0.1/owner/legacy.git; then exit 1; fi
    rc-service --user git-daemon restart
    git ls-remote git://127.0.0.1/owner/first.git | grep refs/heads/main
    if "$INSTALL_ROOT/git-mirror-recover.sh" --startup; then exit 1; fi
'
boot=$(docker exec "$NAME" cat /var/lib/git-daemon/runtime/generation)
docker exec "$NAME" bash -c '
    source "$INSTALL_ROOT/lib/foundation.sh"
    gm_set_instance_environment "$RUN_ROOT" "$INSTALL_ROOT"
    rc-service --user git-mirror-scheduler stop
'
for i in $(seq 1 30); do
    [[ $(docker inspect -f '{{.State.Running}}' "$NAME") == true ]] || break
    sleep 1
done
[[ $(docker inspect -f '{{.State.Running}}' "$NAME") == false ]]
docker start "$NAME" >/dev/null
for i in $(seq 1 120); do
    next=$(docker exec "$NAME" cat /var/lib/git-daemon/runtime/checks-complete 2>/dev/null || true)
    if [[ -n $next && $next != "$boot" ]]; then break; fi
    sleep 1
done
[[ -n $next && $next != "$boot" ]]
docker exec "$NAME" git ls-remote git://127.0.0.1/owner/first.git | grep refs/heads/main
printf '[PASS] 离线缓存下载、未知旧导出撤销、daemon重启门控、scheduler停止退出及容器新代次复检\n'
