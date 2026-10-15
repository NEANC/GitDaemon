#!/usr/bin/env bash
# 正式入口和过滤契约：只替换外部业务，不创建 Docker 资源。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/docker-network-guard.sh"
failed=0
for mode in o1 c2 probe; do
    command=$(guard_runner_command "$mode" /source run /evidence product tools) || command=''
    case "$mode" in
        o1) expected='IT_FILTER=o1' ;;
        c2) expected='IT_FILTER=c2' ;;
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
# 新 full/mapping 路径必须带齐绑定参数，且命令内只出现唯一本地端点。
for mode in full mapping-fallback mapping-direct mapping-probe; do
    command=$(guard_runner_command "$mode" /source run /evidence product tools /manifest /attestation /profile) || command=''
    if [[ $command != *'-u IT_FILTER'* || $command != *'test-docker-network.sh'* ]]; then
        printf 'FAIL bound mode=%s actual=%s\n' "$mode" "$command"
        failed=1
    fi
    if [[ $(grep -o 'unix:///var/run/docker.sock' <<< "$command" | wc -l) != 1 ]]; then
        printf 'FAIL mode=%s endpoint not unique: %s\n' "$mode" "$command"
        failed=1
    fi
done
# full 必须显式清除过滤变量：继承 IT_FILTER 时子入口实际读到空值。
full_clears_filter() {
    local scratch cmd rc=0 status=0
    scratch=$(mktemp -d)
    mkdir -p "$scratch/source/tests" "$scratch/bin"
    cat > "$scratch/source/tests/test-docker-network.sh" <<'STUB'
#!/usr/bin/env bash
printf 'IT_FILTER=%s\n' "${IT_FILTER-}" >> "$RUNNER_ENTRY_LOG"
exit 0
STUB
    cat > "$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$DOCKER_STUB_ID"
STUB
    chmod +x "$scratch/source/tests/test-docker-network.sh" "$scratch/bin/docker"
    export DOCKER_STUB_ID=0123456789abcdef0123456789abcdef
    export RUNNER_ENTRY_LOG="$scratch/runner-entry.log"
    printf 'daemon_id\t%s\n' "$DOCKER_STUB_ID" > "$scratch/manifest.tsv"
    cmd=$(guard_runner_command full "$scratch/source" run "$scratch/evidence" product tools \
        "$scratch/manifest.tsv" "$scratch/attestation" "$scratch/profile") || cmd=''
    ( PATH="$scratch/bin:$PATH"; export IT_FILTER=o1; eval "$cmd" ) || rc=$?
    [[ $rc == 0 ]] || { printf 'FAIL full clears-filter rc=%s\n' "$rc"; status=1; }
    grep -qx 'IT_FILTER=' "$scratch/runner-entry.log" || { printf 'FAIL full did not clear IT_FILTER\n'; status=1; }
    rm -rf "$scratch"
    return "$status"
}

# full 子入口必须再次复核延期请求：以 IT_DEFER_MAPPING=1 运行生成的命令返回 2，且未到达子入口。
full_rejects_defer() {
    local scratch cmd rc=0 status=0
    scratch=$(mktemp -d)
    mkdir -p "$scratch/source/tests" "$scratch/bin"
    cat > "$scratch/source/tests/test-docker-network.sh" <<'STUB'
#!/usr/bin/env bash
printf 'runner-entry %s\n' "$*" >> "$RUNNER_ENTRY_LOG"
exit 0
STUB
    cat > "$scratch/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$DOCKER_STUB_ID"
STUB
    chmod +x "$scratch/source/tests/test-docker-network.sh" "$scratch/bin/docker"
    export DOCKER_STUB_ID=0123456789abcdef0123456789abcdef
    export RUNNER_ENTRY_LOG="$scratch/runner-entry.log"
    printf 'daemon_id\t%s\n' "$DOCKER_STUB_ID" > "$scratch/manifest.tsv"
    cmd=$(guard_runner_command full "$scratch/source" run "$scratch/evidence" product tools \
        "$scratch/manifest.tsv" "$scratch/attestation" "$scratch/profile") || cmd=''
    ( PATH="$scratch/bin:$PATH"; export IT_DEFER_MAPPING=1; eval "$cmd" ) || rc=$?
    [[ $rc == 2 ]] || { printf 'FAIL full rejects-defer rc=%s\n' "$rc"; status=1; }
    [[ ! -s $scratch/runner-entry.log ]] || { printf 'FAIL deferred run reached child entry\n'; status=1; }
    rm -rf "$scratch"
    return "$status"
}

# full 子入口必须再次复核延期请求：以 IT_DEFER_MAPPING=1 实际运行生成的命令，行为级断言返回 2。
full_rejects_defer || failed=1
full_clears_filter || failed=1

# compose up 必须 create → inspect/登记 → start：登记先于 start，且不转发 -d 与 --rm。
compose_products_registered_before_start() {
    local scratch log rc=0
    scratch=$(mktemp -d)
    log=$scratch/order
    mkdir -p "$scratch/ledger"
    : > "$log"
    RESOURCE_LEDGER_DIR=$scratch/ledger
    IT_RUN_ID=order
    COMPOSE_VOLUME=gm-order-compose-data
    RESOURCE_RUN=order
    docker() {
        local a verb=''
        for a in "$@"; do case "$a" in create|ps|start) verb=$a ;; esac; done
        case "${1:-}" in
            compose)
                case "$*" in *' -d'*|*' --rm'*|*' -v'*) printf 'FORBIDDEN %s\n' "$*" >> "$log" ;; esac
                case "$verb" in
                    create) printf 'create\n' >> "$log" ;;
                    ps) printf 'cid1\n' ;;
                    start) printf 'start\n' >> "$log" ;;
                esac
                ;;
            inspect) printf 'volume\tgm-order-compose-data\n' ;;
            volume) printf 'gm-order-compose-data\n' ;;
        esac
        return 0
    }
    resource_register() { printf 'register\t%s\t%s\n' "$1" "$2" >> "$log"; return 0; }
    compose up -d --force-recreate || rc=$?
    [[ $rc == 0 ]] || { printf 'FAIL compose up rc=%s\n' "$rc"; }
    grep -q '^FORBIDDEN' "$log" && { printf 'FAIL compose forwarded -d/-v/--rm\n'; rc=1; }
    [[ $(head -n 1 "$log") == create ]] || { printf 'FAIL compose did not create first\n'; rc=1; }
    grep -q $'^register\tcontainer\tcid1$' "$log" || { printf 'FAIL compose container not registered\n'; rc=1; }
    grep -q $'^register\tvolume\tgm-order-compose-data$' "$log" || { printf 'FAIL compose volume not registered\n'; rc=1; }
    [[ $(tail -n 1 "$log") == start ]] || { printf 'FAIL compose did not start last\n'; rc=1; }
    rm -rf "$scratch"
    [[ $rc == 0 ]]
}

# 旧非 mapping 模式新增三参可空；新路径缺参返回 2。
for mode in o1 c2 probe full mapping-fallback mapping-direct mapping-probe; do
    rc=0
    guard_runner_command "$mode" /source run /evidence product tools '' '' '' >/dev/null || rc=$?
    case "$mode" in
        o1|c2|probe) expected=0 ;;
        *) expected=2 ;;
    esac
    [[ $rc == "$expected" ]] || { printf 'FAIL mode=%s optionality rc=%s\n' "$mode" "$rc"; failed=1; }
done
for mode in o1 c2 full probe startup mapping-fallback mapping-direct mapping-probe invalid 'c2 --live'; do
    rc=0
    (
        # 在首个宿主权限检查处停止，不触及 Docker 或隔离规则。
        id() { printf '10001\n'; }
        guard_main --run-id contract --evidence-dir /evidence --source-dir /source --runner-user gmtest --mode "$mode" --product-image product --tools-image tools
    ) || rc=$?
    case "$mode" in o1|c2|full|probe|startup|mapping-fallback|mapping-direct|mapping-probe) expected=77 ;; *) expected=2 ;; esac
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
for group in network empty tz compose-publish compose-runtime https c2 mapping; do
    rc=0
    IT_FILTER=o1 integration_group_selected "$group" || rc=$?
    case "$group" in network|empty|tz|compose-publish) expected=0 ;; *) expected=1 ;; esac
    printf 'FILTER=o1 GROUP=%s EXPECT=%s ACTUAL=%s\n' "$group" "$expected" "$rc"
    [[ $rc == "$expected" ]] || failed=1
    rc=0
    IT_FILTER='' integration_group_selected "$group" || rc=$?
    [[ $rc == 0 ]] || { printf 'FAIL group=%s not selected when unfiltered rc=%s\n' "$group" "$rc"; failed=1; }
done
# 单项映射 mode 只选择映射组。
rc=0
IT_FILTER='' IT_MAPPING_SCENARIO=fallback integration_group_selected mapping || rc=$?
[[ $rc == 0 ]] || { printf 'FAIL single-mode mapping not selected rc=%s\n' "$rc"; failed=1; }
rc=0
IT_FILTER='' IT_MAPPING_SCENARIO=fallback integration_group_selected https || rc=$?
[[ $rc == 1 ]] || { printf 'FAIL single-mode selected legacy group rc=%s\n' "$rc"; failed=1; }
rc=0
IT_FILTER=c2 integration_group_selected empty || rc=$?
[[ $rc == 0 ]] || { printf 'FAIL c2 empty not selected rc=%s\n' "$rc"; failed=1; }
# compose 产物登记契约依赖 integration.sh 的 compose 包装器，故置于 source 之后。
( compose_products_registered_before_start ) || { printf 'FAIL compose registration contract\n'; failed=1; }
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
