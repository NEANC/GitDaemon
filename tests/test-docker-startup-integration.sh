#!/usr/bin/env bash
set -euo pipefail
[[ ${IT_NETWORK_GUARD_READY-} == 1 && $(id -u) != 0 ]] || exit 77
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-integration-startup.sh"
IMAGE=${IT_PRODUCT_IMAGE:?}
NAME=gm-$IT_RUN_ID-startup
VOL=gm-$IT_RUN_ID-startup-data
PROJECT=gm-$IT_RUN_ID-startup
COMPOSE=$IT_EVIDENCE_DIR/control/startup-compose.yml

# 保存原件后仅删除本轮命名资源。
startup_cleanup() {
    local primary=$? cleanup=0
    trap - EXIT
    docker rm -f "$NAME" >/dev/null || cleanup=1
    docker volume rm "$VOL" >/dev/null || cleanup=1
    printf 'INTEGRATION_CLEANUP_EXIT=%s\n' "$cleanup" > "$IT_EVIDENCE_DIR/control/integration-status.txt"
    if (( primary != 0 )); then exit "$primary"; fi
    exit "$cleanup"
}

# 等待真实入口就绪，不以 OpenRC 残留状态代替。
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
cat > "$COMPOSE" <<EOF
services:
  git-daemon:
    image: $IMAGE
    container_name: $NAME
    user: "10001:10001"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    restart: unless-stopped
    network_mode: none
    labels:
      gitdaemon.run: $IT_RUN_ID
    environment:
      REPOS: owner/first;owner/second
    volumes:
      - data:/var/lib/git-daemon
volumes:
  data:
    external: true
    name: $VOL
EOF
docker compose -p "$PROJECT" -f "$COMPOSE" up -d --no-build --pull never
integration_helper_policy "$NAME"
[[ $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$NAME") == unless-stopped ]]
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
    for repo in first second; do
        git clone "git://127.0.0.1/owner/$repo.git" "$RUN_ROOT/tmp/clone-$repo"
        expected=$(git --git-dir="$RUN_ROOT/repos/owner/$repo.git" rev-parse refs/heads/main)
        test "$(git -C "$RUN_ROOT/tmp/clone-$repo" rev-parse HEAD)" = "$expected"
        git -C "$RUN_ROOT/tmp/clone-$repo" fsck --full
    done
    if git ls-remote git://127.0.0.1/owner/legacy.git; then exit 1; fi
    rc-service --user git-daemon restart
    git ls-remote git://127.0.0.1/owner/first.git | grep refs/heads/main
    if "$INSTALL_ROOT/git-mirror-recover.sh" --startup; then exit 1; fi
    owners=0
    for fd in /proc/[0-9]*/fd/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        if [[ $target == "$RUN_ROOT/runtime/container.lock" ]]; then
            printf "LEASE_FD=%s\n" "$fd"
            pid=${fd#/proc/}; pid=${pid%%/*}
            cat "/proc/$pid/comm" "/proc/$pid/stat"
            [[ $fd == /proc/1/fd/* ]]
            owners=$((owners+1))
        fi
    done
    test "$owners" = 1
'
peer_status=0
docker run --rm --network none -v "$VOL:/var/lib/git-daemon" --entrypoint bash "$IMAGE" -c '
    source "$INSTALL_ROOT/lib/foundation.sh"
    source "$INSTALL_ROOT/lib/lifecycle.sh"
    gm_set_instance_environment "$RUN_ROOT" "$INSTALL_ROOT"
    gm_container_lease_acquire
' || peer_status=$?
[[ $peer_status == 75 ]]
printf '[PASS] 真实 clone 内容与 fsck、PID1 独占租约 FD、第二容器争锁75\n'
boot=$(docker exec "$NAME" cat /var/lib/git-daemon/runtime/generation)
restarts=$(docker inspect -f '{{.RestartCount}}' "$NAME")
docker exec "$NAME" bash -c '
    source "$INSTALL_ROOT/lib/foundation.sh"
    gm_set_instance_environment "$RUN_ROOT" "$INSTALL_ROOT"
    rc-service --user git-mirror-scheduler stop
'
for i in $(seq 1 120); do
    next=$(docker exec "$NAME" cat /var/lib/git-daemon/runtime/checks-complete 2>/dev/null || true)
    if [[ -n $next && $next != "$boot" ]]; then break; fi
    sleep 1
done
[[ -n $next && $next != "$boot" ]]
[[ $(docker inspect -f '{{.RestartCount}}' "$NAME") -gt $restarts ]]
docker inspect "$NAME" > "$IT_EVIDENCE_DIR/control/compose-restarted.json"
printf 'PREVIOUS_GENERATION=%s\nNEW_GENERATION=%s\n' "$boot" "$next"
docker exec "$NAME" git ls-remote git://127.0.0.1/owner/first.git | grep refs/heads/main
printf '[PASS] 离线缓存下载、未知旧导出撤销、daemon重启门控、Compose自动重启及新代次复检\n'
docker compose -p "$PROJECT" -f "$COMPOSE" stop -t 30
docker rm "$NAME" >/dev/null
docker run --rm -i --network none -v "$VOL:/var/lib/git-daemon" --entrypoint bash "$IMAGE" -c '
    set -eu
    umask 077
    cat > "$RUN_ROOT/probe.sh"
' <<'PROBE'
set -T
# 只暂停真实入口的指定边界，不替换任何生产函数或服务。
startup_probe() {
    [[ $BASHPID == 1 && ${probe_hit:-0} == 0 ]] || return 0
    case "$IT_STOP_WINDOW:$BASH_COMMAND:${repo-}" in
        init:'gm_without_container_lease "$INSTALL_ROOT/deploy-git-mirror.sh" --init'*|\
        prepare:'gm_startup_prepare'*|\
        daemon:'gm_without_container_lease rc-service --user git-daemon start'*|\
        checks:'gm_startup_run_repo "$repo" check':owner/second|\
        hosts:run_task_best_effort*|\
        network:'gm_startup_network'*|\
        scheduler:'gm_without_container_lease rc-service --user git-mirror-scheduler start'*) ;;
        *) return 0 ;;
    esac
    probe_hit=1
    printf '%s\n' "$IT_STOP_WINDOW" > "$RUN_ROOT/probe-reached"
    while [[ ${GM_ENTRYPOINT_STOP:-0} == 0 && ! -e $RUN_ROOT/probe-release ]]; do
        read -r -t 0.1 _ <> "$RUN_ROOT/probe-fifo" || true
    done
}
trap startup_probe DEBUG
PROBE
for window in init prepare daemon checks hosts network scheduler; do
    docker run --rm --network none -v "$VOL:/var/lib/git-daemon" --entrypoint bash "$IMAGE" -c '
        rm -f "$RUN_ROOT/probe-reached" "$RUN_ROOT/probe-release" "$RUN_ROOT/probe-fifo"
        mkfifo "$RUN_ROOT/probe-fifo"
    '
    docker run -d --name "$NAME" --network none -v "$VOL:/var/lib/git-daemon" \
        --entrypoint /usr/local/bin/git-mirror-entrypoint -e REPOS='owner/first;owner/second' \
        -e BASH_ENV=/var/lib/git-daemon/probe.sh -e IT_STOP_WINDOW="$window" "$IMAGE" >/dev/null
    reached=
    for i in $(seq 1 120); do
        reached=$(docker exec "$NAME" cat /var/lib/git-daemon/probe-reached 2>/dev/null || true)
        [[ $reached != "$window" ]] || break
        sleep 1
    done
    [[ $reached == "$window" ]]
    if [[ $window == checks ]]; then
        docker exec "$NAME" bash -c '
            set -eu
            test ! -e "$RUN_ROOT/runtime/checks-complete"
            git clone git://127.0.0.1/owner/first.git "$RUN_ROOT/tmp/early-first"
            git -C "$RUN_ROOT/tmp/early-first" fsck --full
            if git clone git://127.0.0.1/owner/second.git "$RUN_ROOT/tmp/early-second"; then exit 1; fi
        '
        printf '[PASS] 第二库检查前第一库真实 clone 成功，第二库拒绝下载\n'
    fi
    docker kill --signal TERM "$NAME" >/dev/null
    for i in $(seq 1 30); do
        [[ $(docker inspect -f '{{.State.Running}}' "$NAME") == true ]] || break
        sleep 1
    done
    [[ $(docker inspect -f '{{.State.Running}}' "$NAME") == false ]]
    [[ $(docker inspect -f '{{.State.ExitCode}}' "$NAME") != 137 ]]
    docker run --rm --network none -v "$VOL:/var/lib/git-daemon" --entrypoint bash "$IMAGE" -c '
        test -f "$RUN_ROOT/runtime/frozen"
    '
    docker rm "$NAME" >/dev/null
    printf '[PASS] 真实镜像停止边界 %s：冻结、非KILL退出\n' "$window"
done
