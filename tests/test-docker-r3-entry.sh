#!/usr/bin/env bash
# 正式入口和过滤契约：只替换外部业务，不创建 Docker 资源。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
failed=0
for mode in o1 c2 full probe; do
    command=$(guard_runner_command "$mode" /source run /evidence product tools) || command=''
    case "$mode" in
        o1) expected='IT_FILTER=o1' ;;
        c2) expected='IT_FILTER=c2' ;;
        full) expected='-u IT_FILTER' ;;
        probe) expected='--live' ;;
    esac
    if [[ $command != *"$expected"* ]]; then
        printf 'FAIL mode=%s expected=%s actual=%s\n' "$mode" "$expected" "$command"
        failed=1
    fi
    if [[ $mode != probe && $command != *'test-docker-network.sh --integration'* ]]; then
        printf 'FAIL missing fixed integration runner: %s\n' "$mode"
        failed=1
    fi
done
for mode in o1 c2 full probe startup invalid 'c2 --live'; do
    rc=0
    (
        # 在首个宿主权限检查处停止，不触及 Docker 或隔离规则。
        id() { printf '10001\n'; }
        guard_main --run-id contract --evidence-dir /evidence --source-dir /source --runner-user gmtest --mode "$mode" --product-image product --tools-image tools
    ) || rc=$?
    case "$mode" in o1|c2|full|probe|startup) expected=77 ;; *) expected=2 ;; esac
    printf 'MODE=%s EXPECT=%s ACTUAL=%s\n' "$mode" "$expected" "$rc"
    [[ $rc == "$expected" ]] || failed=1
done
for mode in invalid 'c2 --live'; do
    rc=0
    guard_runner_command "$mode" /source run /evidence product tools >/dev/null || rc=$?
    [[ $rc == 2 ]] || failed=1
done
IT_SOURCE_ONLY=1 source "$HERE/test-docker-integration.sh"
trap - EXIT
for group in network empty tz compose-publish compose-runtime https c2; do
    rc=0
    IT_FILTER=o1 integration_group_selected "$group" || rc=$?
    case "$group" in network|empty|tz|compose-publish) expected=0 ;; *) expected=1 ;; esac
    printf 'FILTER=o1 GROUP=%s EXPECT=%s ACTUAL=%s\n' "$group" "$expected" "$rc"
    [[ $rc == "$expected" ]] || failed=1
    rc=0
    IT_FILTER='' integration_group_selected "$group" || rc=$?
    [[ $rc == 0 ]] || failed=1
done
rc=0
IT_FILTER=c2 integration_group_selected empty || rc=$?
[[ $rc == 0 ]] || failed=1
# 启动参数通过可执行 CLI 替身采集，不执行实际 Docker。
scratch=$(mktemp -d)
cat > "$scratch/docker" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$@"
CLI
chmod +x "$scratch/docker"
PATH="$scratch:$PATH"
export IT_RUN_ID=contract IT_NETWORK=gm-contract-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
# 此契约只检查解析，受控启动的实际检查由辅助容器契约覆盖。
integration_helper_run() {
    local image=$4
    shift 4
    while [[ $1 != -- ]]; do printf '%s\n' "$1"; shift; done
    shift
    printf '%s\n' "$image" "$@"
}
output=$(docker run -d --name product --network "$IT_NETWORK" --user 10001:10001 --read-only --cap-drop ALL --security-opt no-new-privileges -v gm-contract-data:/var/lib/git-daemon product)
for expected in 172.30.243.4 172.30.243.53 net.ipv6.conf.all.disable_ipv6=1 gm-contract-ca:/ca:ro; do
    if [[ $output != *"$expected"* ]]; then printf 'STARTUP missing=%s\n' "$expected"; failed=1; fi
done
output=$(docker run --network "$IT_NETWORK" --entrypoint sh product --user retained --network payload) || output='rejected image command'
if [[ $output != *$'product\n--user\nretained\n--network\npayload' ]]; then
    printf 'STARTUP changed image command arguments\n'
    failed=1
fi
output=$(docker run -d --name tls --network "$IT_NETWORK" --sysctl net.ipv4.ip_unprivileged_port_start=443 --user 10001:10001 --entrypoint sh product)
if [[ $output == *$'--ip\n172.30.243.4'* || $output != *$'--sysctl\nnet.ipv4.ip_unprivileged_port_start=443'* ]]; then
    printf 'STARTUP misparsed sysctl value as image\n'
    failed=1
fi
output=$(docker run -d --name sampler --pid container:product --network container:product --entrypoint sh product)
if [[ $output != *$'--network\ncontainer:product'* ]]; then
    printf 'STARTUP misparsed pid value as image\n'
    failed=1
fi
rc=0
IT_NETWORK_GUARD_READY=0 docker run product >/dev/null || rc=$?
[[ $rc == 77 ]] || failed=1
rm -rf "$scratch" "$TEST_ROOT"
exit "$failed"
