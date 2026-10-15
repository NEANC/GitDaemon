#!/usr/bin/env bash
# Mapping 独立双断言与反假绿判定。
# 依赖 tests/docker-mapping-fixture.sh：地址档案、映射网络/策略、双 CA 资产与代理原语由该文件提供。
# 本文件交付接口 D 的场景编排、判定器与安全负例；所有 Docker/Git/同步入口只经具名边界函数调用，
# 契约测试以替身替换这些边界。判定器不设替身，直接消费证据文件，因此假绿注入无法绕过。

# 场景与证据契约。
MAPPING_ASSERT_KINDS='fallback direct'
MAPPING_ASSERT_SCENARIO_FALLBACK='mapping-fallback'
MAPPING_ASSERT_SCENARIO_DIRECT='mapping-direct'
MAPPING_ASSERT_FILES='identity.tsv sync.log sync.exit proxy.before proxy.after connect.log upstream.before upstream.after refs.expected refs.actual head.expected head.actual fsck.exit dns.txt'
MAPPING_ASSERT_IDENTITY_KEYS=(run_id scenario generation network_id image_id profile_sha256 input_sha256 manifest_sha256 unique_commit)
MAPPING_ASSERT_NEGATIVES='missing-map invalid-map dns-false-green unreachable-map-system wrong_proxy_ca wrong_proxy_san wrong_upstream_ca wrong_upstream_san isolation'
# 判定器只认这些产品文案；system/proxy 成功文案一旦出现即否定 mapping 成功。
MAPPING_ASSERT_MARK_MAPPING='同步传输路径：直连加动态地址映射'
MAPPING_ASSERT_MARK_SYSTEM='同步传输路径：直连系统 DNS'
MAPPING_ASSERT_MARK_PROXY='同步传输路径：配置的 HTTPS 代理'
MAPPING_ASSERT_MARK_PROXY_FAIL='传输失败：配置的 HTTPS 代理'
MAPPING_ASSERT_FAIL=1
MAPPING_ASSERT_FIXTURE=80
# 产品侧接线：快照与测试 Git 信任配置写在本场景数据卷（RUN_ROOT）内，CA 卷只读挂在 /ca。
MAPPING_ASSERT_RUN_ROOT='/var/lib/git-daemon'
MAPPING_ASSERT_INSTALL_ROOT='/usr/local/lib/git-mirror'
MAPPING_ASSERT_SYNC_ENTRY="$MAPPING_ASSERT_INSTALL_ROOT/git-mirror-sync.sh"
MAPPING_ASSERT_SNAPSHOT_REL='hosts/github-hosts.snapshot'
MAPPING_ASSERT_GITCONFIG_REL='fixture/gitconfig'
MAPPING_ASSERT_DATA_ROLE='data'
MAPPING_ASSERT_PRODUCT_ROLE='product'
# invalid-map 负例使用的保留地址（原校验器必须拒绝，且不生成 resolve）。
MAPPING_ASSERT_RESERVED_ADDR='198.18.0.1'

# 判定器被拒层次：sync 表示底层同步/完整性失败，mapping 表示映射判定失败，policy 表示配置审计失败。
# 负例编排把该层次写入证据，供后续区分「同步层」与「映射判定层」的拒绝。
MAPPING_ASSERT_REJECT_LAYER=''
# 产品可观测就绪标记（入口前台就绪日志）与轮询上限；容器在跑不等于业务可服务。
MAPPING_PRODUCT_READY_MARK='[git-daemon] 容器前台就绪'
MAPPING_PRODUCT_READY_TRIES=120

# 运行期只读字段，由 identity 与边界填充。
MAPPING_ASSERT_GENERATION=''
MAPPING_ASSERT_PRODUCT=''
MAPPING_ASSERT_CASE=''
MAPPING_ASSERT_SNAPSHOT_MODE='valid'
MAPPING_ASSERT_DNS_MODE='none'
MAPPING_ASSERT_GENERATION_SEQ=0
MPA_RUN_ID='' MPA_SCENARIO='' MPA_GENERATION='' MPA_NETWORK_ID='' MPA_IMAGE_ID=''
MPA_PROFILE_SHA256='' MPA_INPUT_SHA256='' MPA_MANIFEST_SHA256='' MPA_UNIQUE_COMMIT=''

# kind 白名单。
mapping_assert_kind_valid() {
    case " $MAPPING_ASSERT_KINDS " in
        *" ${1:-} "*) return 0 ;;
        *) return 1 ;;
    esac
}

# 负例名称白名单。
mapping_assert_negative_valid() {
    case " $MAPPING_ASSERT_NEGATIVES " in
        *" ${1:-} "*) return 0 ;;
        *) return 1 ;;
    esac
}

# kind 到固定 scenario ID 的映射。
mapping_assert_scenario() {
    case "${1:-}" in
        fallback) printf '%s\n' "$MAPPING_ASSERT_SCENARIO_FALLBACK" ;;
        direct) printf '%s\n' "$MAPPING_ASSERT_SCENARIO_DIRECT" ;;
        *) return 1 ;;
    esac
}

# 本次场景运行标识：进程内递增，绑定数据卷、快照、产品与代理计数文件。
mapping_assert_generation() {
    local kind=${1:-} scenario
    scenario=$(mapping_assert_scenario "$kind") || return 1
    MAPPING_ASSERT_GENERATION_SEQ=$((MAPPING_ASSERT_GENERATION_SEQ + 1))
    printf '%s-g%s-%s\n' "$scenario" "$MAPPING_ASSERT_GENERATION_SEQ" "$$"
}

# 证据目录：必须为绝对路径、真实目录、非符号链接且为空，保证每次运行独立且不覆盖既有证据。
mapping_assert_prepare_dir() {
    local dir=${1:-}
    [[ -n $dir && $dir == /* && ! -L $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    if [[ -e $dir ]]; then
        [[ -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
        [[ -z $(ls -A "$dir" 2>/dev/null) ]] || return "$MAPPING_ASSERT_FIXTURE"
    else
        mkdir -p "$dir" 2>/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    fi
    return 0
}

# 证据目录必需文件：缺项、非普通文件、符号链接或不可读一律视为不完整。
mapping_assert_require_files() {
    local dir=${1:-} name file
    [[ -n $dir && -d $dir && ! -L $dir ]] || return 1
    for name in $MAPPING_ASSERT_FILES; do
        file=$dir/$name
        [[ -f $file && ! -L $file && -r $file ]] || return 1
    done
    return 0
}

# 严格非负整数：空值、负数、小数、带符号或空白一律拒绝。
mapping_assert_uint() {
    local raw=${1:-}
    [[ $raw =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$raw"
}

# 读取单行整数证据文件。
mapping_assert_uint_file() {
    local file=${1:-} raw
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    raw=$(sed -n '1p' "$file" 2>/dev/null) || return 1
    mapping_assert_uint "$raw"
}

# 严格解析 identity.tsv：每键恰好一次、无未知键、值非空且无内嵌制表符。
mapping_assert_identity_load() {
    local dir=${1:-} file line key value want count i
    local -a keys=() values=()
    MPA_RUN_ID='' MPA_SCENARIO='' MPA_GENERATION='' MPA_NETWORK_ID='' MPA_IMAGE_ID=''
    MPA_PROFILE_SHA256='' MPA_INPUT_SHA256='' MPA_MANIFEST_SHA256='' MPA_UNIQUE_COMMIT=''
    file=$dir/identity.tsv
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 1
        [[ $line != *$'\r'* ]] || return 1
        key=${line%%$'\t'*}
        value=${line#*$'\t'}
        [[ $key != "$line" && -n $key && -n $value ]] || return 1
        [[ $value != *$'\t'* ]] || return 1
        keys+=("$key")
        values+=("$value")
    done < "$file"
    [[ ${#keys[@]} == "${#MAPPING_ASSERT_IDENTITY_KEYS[@]}" ]] || return 1
    for want in "${MAPPING_ASSERT_IDENTITY_KEYS[@]}"; do
        count=0
        for key in "${keys[@]}"; do
            if [[ $key == "$want" ]]; then count=$((count + 1)); fi
        done
        [[ $count == 1 ]] || return 1
    done
    for i in "${!keys[@]}"; do
        case "${keys[i]}" in
            run_id) MPA_RUN_ID=${values[i]} ;;
            scenario) MPA_SCENARIO=${values[i]} ;;
            generation) MPA_GENERATION=${values[i]} ;;
            network_id) MPA_NETWORK_ID=${values[i]} ;;
            image_id) MPA_IMAGE_ID=${values[i]} ;;
            profile_sha256) MPA_PROFILE_SHA256=${values[i]} ;;
            input_sha256) MPA_INPUT_SHA256=${values[i]} ;;
            manifest_sha256) MPA_MANIFEST_SHA256=${values[i]} ;;
            unique_commit) MPA_UNIQUE_COMMIT=${values[i]} ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# refs 期望与实际必须为完全一致的集合，且集合非空。
mapping_assert_refs_match() {
    local dir=${1:-} expected actual
    [[ -f $dir/refs.expected && -f $dir/refs.actual ]] || return 1
    expected=$(LC_ALL=C sort -u "$dir/refs.expected" 2>/dev/null) || return 1
    actual=$(LC_ALL=C sort -u "$dir/refs.actual" 2>/dev/null) || return 1
    [[ -n $expected ]] || return 1
    [[ $expected == "$actual" ]] || return 1
    return 0
}

# 指定 refs 文件中必须存在本轮独有提交，用于排除旧缓存空跑。
mapping_assert_refs_contain() {
    local file=${1:-} commit=${2:-}
    [[ -n $commit && -f $file && ! -L $file ]] || return 1
    awk -v c="$commit" '$1 == c { found = 1 } END { exit found ? 0 : 1 }' "$file"
}

# HEAD 期望与实际精确一致。
mapping_assert_head_match() {
    local dir=${1:-} expected actual
    expected=$(sed -n '1p' "$dir/head.expected" 2>/dev/null) || return 1
    actual=$(sed -n '1p' "$dir/head.actual" 2>/dev/null) || return 1
    [[ -n $expected && $expected == "$actual" ]] || return 1
    return 0
}

# 日志中首次出现标记的行号；缺失时输出为空。
mapping_assert_log_line() {
    local file=${1:-} marker=${2:-}
    [[ -f $file && -n $marker ]] || return 0
    awk -v m="$marker" 'index($0, m) { print NR; exit }' "$file"
}

# CONNECT 证据必须含合法接受记录：authority 精确、拨号目的只能是冻结 U:443。
mapping_assert_connect_legal() {
    local file=${1:-} upstream=${2:-} line auth mode dial field
    local -a encoded=()
    [[ -n $upstream && -f $file && ! -L $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        auth='' mode='' dial=''
        IFS=$'\t' read -r -a encoded <<< "$line"
        for field in "${encoded[@]}"; do
            case "$field" in
                authority=*) auth=${field#authority=} ;;
                mode=*) mode=${field#mode=} ;;
                dial_target=*) dial=${field#dial_target=} ;;
            esac
        done
        [[ $auth == "$MAPPING_PROXY_AUTHORITY" ]] || continue
        [[ $mode == accept ]] || continue
        [[ $dial == "$upstream:$MAPPING_UPSTREAM_PORT" ]] || continue
        return 0
    done < "$file"
    return 1
}

# dns.txt 必须证明受控 DNS 状态：github.com 的 A 与 AAAA 为 NXDOMAIN（成功不依赖系统 DNS），
# gm-proxy 解析到 X。记录数、名称、类型或取值任一不符一律拒绝。
mapping_assert_dns_file() {
    local file=${1:-} line name rrtype value
    local seen_a=0 seen_aaaa=0 seen_proxy=0
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    mapping_profile_load "${MAPPING_PROFILE:-}" || return 1
    while IFS=$'\t' read -r name rrtype value || [[ -n $name ]]; do
        [[ -n $name && -n $rrtype && -n $value && $value != *$'\t'* ]] || return 1
        case "$name $rrtype" in
            "$MAPPING_UPSTREAM_HOST A")
                [[ $value == NXDOMAIN && $seen_a == 0 ]] || return 1
                seen_a=1
                ;;
            "$MAPPING_UPSTREAM_HOST AAAA")
                [[ $value == NXDOMAIN && $seen_aaaa == 0 ]] || return 1
                seen_aaaa=1
                ;;
            "$MAPPING_PROXY_HOST A")
                [[ $value == "$MP_X" && $seen_proxy == 0 ]] || return 1
                seen_proxy=1
                ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ $seen_a == 1 && $seen_aaaa == 1 && $seen_proxy == 1 ]] || return 1
    return 0
}

# 判定器拒绝层次标记：设置层次后由调用点 return 1，确保判定立即中止并记录层次。
mapping_assert_fail() {
    MAPPING_ASSERT_REJECT_LAYER=${1:-mapping}
    return 0
}

# 判定器：0 通过，1 拒绝。任何缺文件、跨场景 identity、读取错误或负计数均返回 1。
mapping_assert_result() {
    local kind=${1:-} dir=${2:-} scenario
    local sync_exit fsck_exit before after delta up_before up_after
    local mapping_line system_line proxy_line proxy_fail_line
    MAPPING_ASSERT_REJECT_LAYER=''
    mapping_assert_kind_valid "$kind" || { mapping_assert_fail mapping; return 1; }
    [[ -n $dir ]] || { mapping_assert_fail mapping; return 1; }
    mapping_assert_require_files "$dir" || { mapping_assert_fail mapping; return 1; }
    mapping_assert_identity_load "$dir" || { mapping_assert_fail mapping; return 1; }
    scenario=$(mapping_assert_scenario "$kind") || { mapping_assert_fail mapping; return 1; }
    [[ $MPA_SCENARIO == "$scenario" ]] || { mapping_assert_fail mapping; return 1; }
    sync_exit=$(mapping_assert_uint_file "$dir/sync.exit") || { mapping_assert_fail mapping; return 1; }
    fsck_exit=$(mapping_assert_uint_file "$dir/fsck.exit") || { mapping_assert_fail mapping; return 1; }
    [[ $sync_exit == 0 ]] || { mapping_assert_fail sync; return 1; }
    [[ $fsck_exit == 0 ]] || { mapping_assert_fail sync; return 1; }
    mapping_assert_dns_file "$dir/dns.txt" || { mapping_assert_fail mapping; return 1; }
    before=$(mapping_proxy_baseline_total "$dir/proxy.before") || { mapping_assert_fail mapping; return 1; }
    after=$(mapping_proxy_baseline_total "$dir/proxy.after") || { mapping_assert_fail mapping; return 1; }
    (( after >= before )) || { mapping_assert_fail mapping; return 1; }
    delta=$(( after - before ))
    up_before=$(mapping_assert_uint_file "$dir/upstream.before") || { mapping_assert_fail mapping; return 1; }
    up_after=$(mapping_assert_uint_file "$dir/upstream.after") || { mapping_assert_fail mapping; return 1; }
    (( up_after > up_before )) || { mapping_assert_fail mapping; return 1; }
    mapping_assert_refs_match "$dir" || { mapping_assert_fail mapping; return 1; }
    mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || { mapping_assert_fail mapping; return 1; }
    mapping_assert_head_match "$dir" || { mapping_assert_fail mapping; return 1; }
    mapping_line=$(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_MAPPING")
    [[ -n $mapping_line ]] || { mapping_assert_fail mapping; return 1; }
    system_line=$(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_SYSTEM")
    [[ -z $system_line ]] || { mapping_assert_fail mapping; return 1; }
    proxy_line=$(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_PROXY")
    [[ -z $proxy_line ]] || { mapping_assert_fail mapping; return 1; }
    case "$kind" in
        fallback)
            proxy_fail_line=$(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_PROXY_FAIL")
            [[ -n $proxy_fail_line ]] || { mapping_assert_fail mapping; return 1; }
            (( proxy_fail_line < mapping_line )) || { mapping_assert_fail mapping; return 1; }
            (( delta > 0 )) || { mapping_assert_fail mapping; return 1; }
            mapping_profile_load "${MAPPING_PROFILE:-}" || { mapping_assert_fail mapping; return 1; }
            mapping_assert_connect_legal "$dir/connect.log" "$MP_U" || { mapping_assert_fail mapping; return 1; }
            ;;
        direct)
            (( delta == 0 )) || { mapping_assert_fail mapping; return 1; }
            ;;
    esac
    return 0
}

# 场景编排的外部边界。以下函数是契约测试唯一允许替换的接缝：默认实现调用真实夹具与真实入口，
# 替身只替换 Docker/Git/同步入口/TLS 注入等外部交互，编排顺序与证据落盘始终由本文件执行。

# 上游 U:443 实际连接计数。
mapping_scenario_upstream_count() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    [[ -n $kind && -n $scenario && -n $dir ]] || return 1
    mapping_upstream_evidence_count "$scenario"
}

# 制造本场景新提交并写回独有提交标记；提交内容含 run/scenario。
mapping_scenario_upstream_commit() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} image=${MAPPING_PRODUCT_IMAGE:-} sha
    [[ -n $kind && -n $scenario && -n $dir && -n $image ]] || return 1
    mapping_profile_load "${MAPPING_PROFILE:-}" || return 1
    mapping_upstream_git_run "$image" init >/dev/null || return 1
    sha=$(mapping_upstream_git_run "$image" commit "$MP_RUN_ID $scenario") || return 1
    [[ -n $sha ]] || return 1
    mkdir -p "$dir/control" || return 1
    printf '%s\n' "$sha" > "$dir/control/unique-commit" || return 1
    printf '%s\n' "$sha"
}

# 上游 refs 期望：由上游真实 Git 读取。
mapping_scenario_upstream_refs() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} image=${MAPPING_PRODUCT_IMAGE:-}
    [[ -n $kind && -n $scenario && -n $dir && -n $image ]] || return 1
    mapping_upstream_git_run "$image" refs
}

# 上游 HEAD 期望。
mapping_scenario_upstream_head() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} image=${MAPPING_PRODUCT_IMAGE:-}
    [[ -n $kind && -n $scenario && -n $dir && -n $image ]] || return 1
    mapping_upstream_git_run "$image" head
}

# 夹具准备：可复用只读资产 + 独立映射网络 + 上游/代理/DNS/探针；负例注入在启动前生效。
# 产品启动前先重建本轮 CONNECT 日志，杜绝上一轮残留的合法行被复用。
mapping_scenario_fixture_prepare() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} ledger
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n ${MAPPING_PROFILE:-} && -n ${MAPPING_PRODUCT_IMAGE:-} && -n ${MAPPING_TOOLS_IMAGE:-} ]] || return "$MAPPING_ASSERT_FIXTURE"
    ledger=$dir/control/resources
    mapping_assets_prepare "$MAPPING_PROFILE" "$scenario" "$MAPPING_PRODUCT_IMAGE" "$ledger" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_proxy_evidence_reset "$scenario" "$MAPPING_PRODUCT_IMAGE" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_network_create "$MAPPING_PROFILE" "$ledger" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    mapping_negative_prepare "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_fixture_start "$MAPPING_PROFILE" "$scenario" "$MAPPING_PRODUCT_IMAGE" "$MAPPING_TOOLS_IMAGE" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 代理校准：先证接受端口可达、拒绝端口 403、计数增长，再写 proxy.before 基线。
mapping_scenario_calibrate() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_proxy_calibrate "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 测试 Git 信任配置内容：显式清空 http.proxy（不继承宿主/全局代理），只单独指定代理 CA。
# 空值的键必须存在，否则 direct 场景会沿用外部 http.proxy 而绕过直连判定。
mapping_scenario_gitconfig_content() {
    printf '[http]\n\tproxy =\n\tproxySSLCAInfo = %s\n' "$MAPPING_CLIENT_PROXY_CA"
}

# 产品可观测就绪：轮询容器日志中的入口前台就绪标记；容器退出即失败。
# 不把「容器在跑」当作业务可服务，也不依赖持久化 PID 或卷内残留状态。
mapping_scenario_product_ready() {
    local name=${1:-} i logs
    [[ -n $name ]] || return 1
    for ((i = 0; i < MAPPING_PRODUCT_READY_TRIES; i++)); do
        logs=$(mapping_fixture_docker logs "$name" 2>&1) || logs=''
        [[ $logs == *"$MAPPING_PRODUCT_READY_MARK"* ]] && return 0
        [[ $(mapping_fixture_docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null) == true ]] || return 1
        sleep 0.5
    done
    return 1
}

# 顺序占位释放：账本登记身份是 `docker create` 返回的容器 ID（见 docker-resource-ledger.sh 的
# resource_inspect_identity），故先经实时 inspect 取 ID 再精确删除；未登记（inspect 失败）视为无需释放。
mapping_scenario_release_probe() {
    local probe id
    probe=$(mapping_probe_container) || return 1
    id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$probe" 2>/dev/null) || return 0
    [[ -n $id ]] || return 0
    resource_remove container "$id" || return 1
    return 0
}

# 产品就绪：独立数据卷 create/登记 → 安全离线 helper 写合法快照与测试 Git 信任配置 →
# 释放顺序占位 probe(P) → READY 握手 → 从正式容器入口启动并等待可观测就绪。
mapping_scenario_product_up() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    local ledger=$dir/control/resources data gitconfig snapshot_content name netid
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    netid=$(mapping_network_id_load) || return "$MAPPING_ASSERT_FIXTURE"
    data=$(mapping_scenario_data_volume "$MAPPING_ASSERT_GENERATION")
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_create_register volume "$scenario" "$MAPPING_ASSERT_DATA_ROLE" -- \
        resource_docker volume create \
        --label "gitdaemon.run=$MP_RUN_ID" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$MAPPING_ASSERT_DATA_ROLE" "$data" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    snapshot_content=$(mapping_scenario_snapshot_content "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    if [[ -n $snapshot_content ]]; then
        mapping_scenario_data_write "$data" "$MAPPING_ASSERT_SNAPSHOT_REL" "$snapshot_content" "$MAPPING_PRODUCT_IMAGE" \
            || return "$MAPPING_ASSERT_FIXTURE"
    fi
    gitconfig=$(mapping_scenario_gitconfig_content) || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_data_write "$data" "$MAPPING_ASSERT_GITCONFIG_REL" "$gitconfig" "$MAPPING_PRODUCT_IMAGE" \
        || return "$MAPPING_ASSERT_FIXTURE"
    # 顺序占位必须先释放：产品启动前按登记身份删除 probe，产品才能取得冻结地址 P。
    mapping_scenario_release_probe || return "$MAPPING_ASSERT_FIXTURE"
    mapping_ready "$MAPPING_PROFILE" "$netid" || return "$MAPPING_ASSERT_FIXTURE"
    name=$(mapping_scenario_product_container "$MAPPING_ASSERT_GENERATION")
    mapping_fixture_create "$scenario" "$MAPPING_ASSERT_PRODUCT_ROLE" -d --name "$name" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_P" --dns "$MP_D" \
        -v "$data:$MAPPING_ASSERT_RUN_ROOT" -v "$(mapping_ca_volume):$MAPPING_CA_MOUNT:ro" \
        -e "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" -e "INSTALL_ROOT=$MAPPING_ASSERT_INSTALL_ROOT" \
        -e "HOME=$MAPPING_ASSERT_RUN_ROOT/home" \
        -e "GIT_CONFIG_GLOBAL=$MAPPING_ASSERT_RUN_ROOT/$MAPPING_ASSERT_GITCONFIG_REL" \
        -e "GIT_SSL_CAINFO=$MAPPING_CLIENT_UPSTREAM_CA" -e GIT_SMART_HTTP=0 \
        -e ENABLE_HOSTS_UPDATE=yes -e ENABLE_CRON=no \
        -e "PROXY_URL=$(mapping_scenario_proxy_url "$kind")" \
        -e "REPOS=$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO" \
        "$MAPPING_PRODUCT_IMAGE" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    mapping_fixture_docker start "$name" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_product_ready "$name" || return "$MAPPING_ASSERT_FIXTURE"
    printf '%s\n' "$name"
}

# 负例后置注入：额外网络附件等只能在产品运行后施加的缺陷。
mapping_scenario_apply_negative() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} product=${4:-}
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_negative_apply "$kind" "$scenario" "$dir" "$product" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 真实同步入口取证：完整执行产品入口（含 fetch 后 HEAD 读取），写 sync.log 与 sync.exit。
mapping_scenario_sync_exec() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} name proxy_url rc=0
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    name=$(mapping_scenario_product_container "$MAPPING_ASSERT_GENERATION")
    proxy_url=$(mapping_scenario_proxy_url "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    mapping_fixture_docker exec -e "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" \
        -e "GIT_SSL_CAINFO=$MAPPING_CLIENT_UPSTREAM_CA" \
        -e "GIT_CONFIG_GLOBAL=$MAPPING_ASSERT_RUN_ROOT/$MAPPING_ASSERT_GITCONFIG_REL" \
        -e GIT_SMART_HTTP=0 -e ENABLE_HOSTS_UPDATE=yes -e ENABLE_CRON=no \
        -e "PROXY_URL=$proxy_url" -e "REPOS=$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO" \
        -e "HOME=$MAPPING_ASSERT_RUN_ROOT/home" \
        -e http_proxy= -e HTTP_PROXY= -e https_proxy= -e HTTPS_PROXY= \
        -e all_proxy= -e ALL_PROXY= -e NO_PROXY= -e no_proxy= \
        "$name" "$MAPPING_ASSERT_SYNC_ENTRY" > "$dir/sync.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$dir/sync.exit" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 代理增量读取：两端口各自独立计数文件求和，输出与基线同格式，缺失或损坏一律非零。
mapping_scenario_proxy_after() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} accept reject
    [[ -n $kind && -n $scenario && -n $dir ]] || return 1
    accept=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 1
    reject=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_REJECT_PORT") || return 1
    printf 'accept\t%s\nreject\t%s\ntotal\t%s\n' "$accept" "$reject" "$((accept + reject))"
}

# CONNECT 证据读取：只取 authority/mode/dial_target，不涉凭据；文件缺失时输出为空。
mapping_scenario_connect_evidence() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} path
    [[ -n $kind && -n $scenario && -n $dir ]] || return 1
    path=$(mapping_proxy_log_path "$scenario") || return 1
    if mapping_fixture_docker exec "$(mapping_proxy_container)" test -e "$path" >/dev/null 2>&1; then
        mapping_fixture_docker exec "$(mapping_proxy_container)" cat "$path" || return 1
    fi
    return 0
}

# 本地仓库 Git 边界：只读产品 netns 内的缓存仓库，不修改远端。
mapping_scenario_local_git() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    shift 3
    local name gitdir
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    name=$(mapping_scenario_product_container "$MAPPING_ASSERT_GENERATION")
    gitdir="$MAPPING_ASSERT_RUN_ROOT/repos/$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO.git"
    mapping_fixture_docker exec "$name" git --git-dir="$gitdir" "$@"
}

# 本地 refs/HEAD/完整性读取。
mapping_scenario_local_refs() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    mapping_scenario_local_git "$kind" "$scenario" "$dir" for-each-ref --format='%(objectname)%09%(refname)'
}

mapping_scenario_local_head() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    mapping_scenario_local_git "$kind" "$scenario" "$dir" rev-parse HEAD
}

mapping_scenario_local_fsck() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} rc=0
    mapping_scenario_local_git "$kind" "$scenario" "$dir" fsck --strict >/dev/null 2>&1 || rc=$?
    printf '%s\n' "$rc"
    return 0
}

# 受控 DNS 状态取证：github.com 必须 NXDOMAIN（证明成功不依赖系统 DNS），gm-proxy 指向 X。
mapping_scenario_dns_state() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} gh4 gh6 proxy
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    gh4=$(mapping_fixture_docker exec "$(mapping_dns_container)" dig +short +time=1 +tries=1 github.com A 2>/dev/null) || gh4=''
    gh6=$(mapping_fixture_docker exec "$(mapping_dns_container)" dig +short +time=1 +tries=1 github.com AAAA 2>/dev/null) || gh6=''
    proxy=$(mapping_fixture_docker exec "$(mapping_dns_container)" dig +short +time=1 +tries=1 "$MAPPING_PROXY_HOST" A 2>/dev/null) || proxy=''
    printf 'github.com\tA\t%s\n' "${gh4:-NXDOMAIN}"
    printf 'github.com\tAAAA\t%s\n' "${gh6:-NXDOMAIN}"
    printf '%s\tA\t%s\n' "$MAPPING_PROXY_HOST" "$proxy"
    return 0
}

# 受控 DNS 恢复：清除假绿开关并核验 github.com 恢复为 NXDOMAIN、gm-proxy 仍指向 X。
# 恢复后判定器读到的 DNS 证据不再是被造假绿样本。
mapping_scenario_dns_restore() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} file rc=0
    MAPPING_DNS_FAKE_HOST=''
    MAPPING_DNS_FAKE_IP=''
    [[ -n $dir && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    file=$dir/dns.restore
    mapping_scenario_dns_state "$kind" "$scenario" "$dir" > "$file" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_dns_file "$file" || rc="$MAPPING_ASSERT_FAIL"
    rm -f "$file"
    return "$rc"
}

# 局部清理：释放本场景创建的全部资源（产品/上游/代理/DNS/探针容器、映射与负例网络、
# 数据/资产/CA 卷），使同一进程内重跑可重建同名资源而不冲突。资源身份由实时 inspect 取得。
mapping_scenario_release() {
    local kind=${1:-} scenario=${2:-} generation=${3:-} dir=${4:-} ledger id name
    [[ -n $kind && -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "${MAPPING_PROFILE:-}" || return "$MAPPING_ASSERT_FIXTURE"
    ledger=$dir/control/resources
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    local -a containers=(
        "$(mapping_scenario_product_container "$generation")"
        "$(mapping_upstream_container)"
        "$(mapping_proxy_container)"
        "$(mapping_dns_container)"
        "$(mapping_probe_container)"
    )
    for name in "${containers[@]}"; do
        id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$name" 2>/dev/null) || continue
        [[ -n $id ]] || continue
        resource_remove container "$id" || return "$MAPPING_ASSERT_FIXTURE"
    done
    for name in "$MP_NETWORK_NAME" "gm-${MP_RUN_ID}-neg-net"; do
        [[ -n $name ]] || continue
        id=$(mapping_fixture_docker network inspect -f '{{.Id}}' "$name" 2>/dev/null) || continue
        [[ -n $id ]] || continue
        resource_remove network "$id" || return "$MAPPING_ASSERT_FIXTURE"
    done
    for name in "$(mapping_scenario_data_volume "$generation")" "$(mapping_assets_volume)" "$(mapping_ca_volume)"; do
        [[ -n $name ]] || continue
        id=$(mapping_fixture_docker volume inspect -f '{{.Name}}' "$name" 2>/dev/null) || continue
        [[ -n $id ]] || continue
        resource_remove volume "$id" || return "$MAPPING_ASSERT_FIXTURE"
    done
    return 0
}

# 产品数据卷与容器名：按 generation 独立，不与他场景共享。
mapping_scenario_data_volume() {
    printf 'gm-%s-%s-data\n' "${MP_RUN_ID:-run}" "$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9-' '-')"
}

mapping_scenario_product_container() {
    printf 'gm-%s-%s-product\n' "${MP_RUN_ID:-run}" "$(printf '%s' "${1:-}" | tr -c 'A-Za-z0-9-' '-')"
}

# 产品数据卷内写文件：内容经标准输入送入，网络 none、UID 10001、只读写本场景数据卷。
mapping_scenario_data_write() {
    local volume=${1:-} relpath=${2:-} content=${3:-} image=${4:-} status=0
    [[ -n $volume && -n $relpath && -n $image ]] || return 1
    printf '%s' "$content" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -v "$volume:$MAPPING_ASSERT_RUN_ROOT" --entrypoint /bin/sh "$image" \
        -c "umask 022; mkdir -p \"\$(dirname -- '$relpath')\"; cat > '$relpath'" || status=$?
    [[ $status == 0 ]] || return 1
    return 0
}

# 快照内容：valid 写合法 U；reserved 写保留地址（原校验器拒绝）；unallocated 写冻结未分配 N；
# none 表示不写快照（映射不可用）。
mapping_scenario_snapshot_content() {
    local kind=${1:-}
    mapping_assert_kind_valid "$kind" || return 1
    case "$MAPPING_ASSERT_SNAPSHOT_MODE" in
        valid)
            mapping_profile_load "$MAPPING_PROFILE" || return 1
            printf '%s github.com\n' "$MP_U"
            ;;
        reserved) printf '%s github.com\n' "$MAPPING_ASSERT_RESERVED_ADDR" ;;
        unallocated)
            mapping_profile_load "$MAPPING_PROFILE" || return 1
            printf '%s github.com\n' "$MP_N"
            ;;
        none) printf '' ;;
        *) return 1 ;;
    esac
    return 0
}

# 传输输入：fallback 指向拒绝端口代理（CONNECT 403 后回退映射）；direct 清空所有代理项。
mapping_scenario_proxy_url() {
    local kind=${1:-}
    case "$kind" in
        fallback) printf 'https://%s:%s\n' "$MAPPING_PROXY_HOST" "$MAPPING_PROXY_REJECT_PORT" ;;
        direct) printf '' ;;
        *) return 1 ;;
    esac
}

# identity.tsv：绑定 run/scenario/generation/network/image/三项哈希与独有提交。
mapping_scenario_identity_write() {
    local kind=${1:-} scenario=${2:-} generation=${3:-} dir=${4:-}
    local network image profile_sha input_sha manifest_sha unique file
    [[ -n $kind && -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    network=$(mapping_network_id_load) || return "$MAPPING_ASSERT_FIXTURE"
    image=${MAPPING_PRODUCT_IMAGE:-}
    profile_sha=${MP_PROFILE_SHA256:-}
    [[ -n $image && -n $profile_sha ]] || return "$MAPPING_ASSERT_FIXTURE"
    unique=$(sed -n '1p' "$dir/control/unique-commit" 2>/dev/null) || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $unique ]] || return "$MAPPING_ASSERT_FIXTURE"
    input_sha=$(mapping_scenario_hash_of "$dir/inputs.sha256") || input_sha=$profile_sha
    manifest_sha=$(mapping_scenario_hash_of "${MAPPING_MANIFEST:-}") || manifest_sha=$profile_sha
    file=$dir/identity.tsv
    {
        printf 'run_id\t%s\n' "$MP_RUN_ID"
        printf 'scenario\t%s\n' "$scenario"
        printf 'generation\t%s\n' "$generation"
        printf 'network_id\t%s\n' "$network"
        printf 'image_id\t%s\n' "$image"
        printf 'profile_sha256\t%s\n' "$profile_sha"
        printf 'input_sha256\t%s\n' "$input_sha"
        printf 'manifest_sha256\t%s\n' "$manifest_sha"
        printf 'unique_commit\t%s\n' "$unique"
    } > "$file.tmp" || return "$MAPPING_ASSERT_FIXTURE"
    mv -- "$file.tmp" "$file" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 输入摘要：给定文件的 SHA-256；文件不存在或不可读时非零（调用方回退到档案摘要）。
mapping_scenario_hash_of() {
    local file=${1:-} digest
    [[ -n $file && -f $file && ! -L $file && -r $file ]] || return 1
    digest=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1) || return 1
    [[ -n $digest ]] || return 1
    printf '%s\n' "$digest"
}

# 场景证据取证：准备 → 校准 → 取基线 → 独有提交 → 同步 → 汇总证据。
mapping_scenario_evidence() {
    local kind=${1:-} scenario=${2:-} generation=${3:-} dir=${4:-}
    local product up_before base_scenario
    mapping_assert_kind_valid "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    base_scenario=$(mapping_assert_scenario "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_GENERATION=$generation
    # 本轮代理计数与 CONNECT 日志按 generation 独立，重跑不复用上一轮证据。
    MAPPING_PROXY_RUN_ID=$generation
    mapping_scenario_fixture_prepare "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_calibrate "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    product=$(mapping_scenario_product_up "$kind" "$scenario" "$dir") || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $product ]] || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_PRODUCT=$product
    up_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_uint "$up_before" > "$dir/upstream.before" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_commit "$kind" "$scenario" "$dir" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    # identity 绑定 kind 的基础场景，使负例变体仍以同一场景判定，拒绝只能来自注入缺陷本身。
    mapping_scenario_identity_write "$kind" "$base_scenario" "$generation" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_refs "$kind" "$scenario" "$dir" > "$dir/refs.expected" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_head "$kind" "$scenario" "$dir" > "$dir/head.expected" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_apply_negative "$kind" "$scenario" "$dir" "$product" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_sync_exec "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_proxy_after "$kind" "$scenario" "$dir" > "$dir/proxy.after" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_count "$kind" "$scenario" "$dir" > "$dir/upstream.after" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_local_refs "$kind" "$scenario" "$dir" > "$dir/refs.actual" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_local_fsck "$kind" "$scenario" "$dir" > "$dir/fsck.exit" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_dns_state "$kind" "$scenario" "$dir" > "$dir/dns.txt" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 接口 D：单场景独立生命周期（准备→校准→基线→同步→判定→局部清理），可单独运行。
mapping_scenario_run() {
    local kind=${1:-} dir=${2:-} scenario generation rc
    [[ $# == 2 && -n $kind && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_kind_valid "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    scenario=$(mapping_assert_scenario "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_CASE='' MAPPING_ASSERT_SNAPSHOT_MODE=valid MAPPING_ASSERT_DNS_MODE=none
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    generation=$(mapping_assert_generation "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_prepare_dir "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    IT_EVIDENCE_DIR=$dir
    if ! mapping_scenario_evidence "$kind" "$scenario" "$generation" "$dir"; then
        mapping_scenario_release "$kind" "$scenario" "$generation" "$dir" || true
        MAPPING_PROXY_RUN_ID=''
        return "$MAPPING_ASSERT_FIXTURE"
    fi
    if mapping_assert_result "$kind" "$dir"; then
        rc=0
    else
        rc="$MAPPING_ASSERT_FAIL"
    fi
    mapping_scenario_release "$kind" "$scenario" "$generation" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_PROXY_RUN_ID=''
    return "$rc"
}

# 负例判定：0 表示负例被正确拒绝（判定非零）；非零表示假绿/漏判。
# 同时把被拒层次写入 MAPPING_ASSERT_REJECT_LAYER：sync 为底层同步层，mapping 为映射判定层，
# policy 为配置审计层。
mapping_negative_rejected() {
    local case_name=${1:-} kind=${2:-} dir=${3:-}
    case "$case_name" in
        isolation)
            MAPPING_ASSERT_REJECT_LAYER=''
            if mapping_policy_check "${MAPPING_ASSERT_PRODUCT:-}" "$MAPPING_ASSERT_PRODUCT_ROLE" "$MAPPING_PROFILE"; then
                return 1
            fi
            MAPPING_ASSERT_REJECT_LAYER=policy
            return 0
            ;;
        *)
            if mapping_assert_result "$kind" "$dir"; then return 1; fi
            return 0
            ;;
    esac
}

# 接口 D：负例编排。三层退出：底层同步可为 0，mapping 判定须非零，负例本身才返回 0；
# 任何夹具失败返回 80。负例证据记录被拒层次，结束后恢复受控 DNS 并复位本轮分段。
mapping_negative_run() {
    local case_name=${1:-} kind=${2:-} dir=${3:-} scenario generation rc
    [[ $# == 3 && -n $case_name && -n $kind && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_kind_valid "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_negative_valid "$case_name" || return "$MAPPING_ASSERT_FIXTURE"
    # 负例场景 ID 采用独立后缀，并把用例名中的下划线规范为场景允许的连字符。
    scenario="mapping-$kind-${case_name//_/-}"
    mapping_scenario_valid "$scenario" || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_CASE=$case_name MAPPING_ASSERT_SNAPSHOT_MODE=valid MAPPING_ASSERT_DNS_MODE=none
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    generation=$(mapping_assert_generation "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_prepare_dir "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    IT_EVIDENCE_DIR=$dir
    if ! mapping_scenario_evidence "$kind" "$scenario" "$generation" "$dir"; then
        mapping_scenario_release "$kind" "$scenario" "$generation" "$dir" || true
        MAPPING_ASSERT_CASE='' MAPPING_PROXY_RUN_ID=''
        return "$MAPPING_ASSERT_FIXTURE"
    fi
    if mapping_negative_rejected "$case_name" "$kind" "$dir"; then
        rc=0
    else
        rc="$MAPPING_ASSERT_FAIL"
    fi
    printf '%s\n' "${MAPPING_ASSERT_REJECT_LAYER:-none}" > "$dir/reject.layer" || rc="$MAPPING_ASSERT_FIXTURE"
    # 结束后恢复受控 DNS：清除假绿开关（配合本场景释放被造假的 DNS 容器，使后续运行回到 NXDOMAIN）。
    MAPPING_DNS_FAKE_HOST=''
    MAPPING_DNS_FAKE_IP=''
    mapping_scenario_release "$kind" "$scenario" "$generation" "$dir" || rc="$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_CASE='' MAPPING_PROXY_RUN_ID=''
    return "$rc"
}

# 负例默认缺陷：在夹具启动前施加证书/CA/DNS 类缺陷，并设定快照模式。
mapping_negative_prepare() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} case_name=${MAPPING_ASSERT_CASE:-}
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    case "$case_name" in
        '') return 0 ;;
        missing-map) MAPPING_ASSERT_SNAPSHOT_MODE=none ;;
        invalid-map) MAPPING_ASSERT_SNAPSHOT_MODE=reserved ;;
        dns-false-green) MAPPING_ASSERT_SNAPSHOT_MODE=none MAPPING_ASSERT_DNS_MODE=upstream ;;
        unreachable-map-system) MAPPING_ASSERT_SNAPSHOT_MODE=unallocated MAPPING_ASSERT_DNS_MODE=upstream ;;
        wrong_proxy_ca) MAPPING_ASSERT_SNAPSHOT_MODE=valid
            mapping_negative_wrong_ca proxy-ca.crt || return "$MAPPING_ASSERT_FIXTURE" ;;
        wrong_proxy_san) MAPPING_ASSERT_SNAPSHOT_MODE=valid
            MAPPING_NEG_HOST='other-host.invalid' mapping_negative_wrong_san proxy || return "$MAPPING_ASSERT_FIXTURE" ;;
        wrong_upstream_ca) MAPPING_ASSERT_SNAPSHOT_MODE=valid
            mapping_negative_wrong_ca upstream-ca.crt || return "$MAPPING_ASSERT_FIXTURE" ;;
        wrong_upstream_san) MAPPING_ASSERT_SNAPSHOT_MODE=valid
            MAPPING_NEG_HOST='other-host.invalid' mapping_negative_wrong_san upstream || return "$MAPPING_ASSERT_FIXTURE" ;;
        isolation) MAPPING_ASSERT_SNAPSHOT_MODE=valid ;;
        *) return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
    if [[ ${MAPPING_ASSERT_DNS_MODE:-none} == upstream ]]; then
        mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
        MAPPING_DNS_FAKE_HOST='github.com'
        MAPPING_DNS_FAKE_IP=$MP_U
    fi
    return 0
}

# 负例默认缺陷：产品运行后施加的缺陷（额外网络附件）。
mapping_negative_apply() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} product=${4:-}
    case "${MAPPING_ASSERT_CASE:-}" in
        isolation) mapping_negative_extra_network "$dir" "$product" || return "$MAPPING_ASSERT_FIXTURE" ;;
        '') return 0 ;;
        missing-map|invalid-map|dns-false-green|unreachable-map-system) return 0 ;;
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san) return 0 ;;
        *) return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
    return 0
}

# 额外网络附件：把产品接到第二个网络，配置审计必须拒绝该隔离破坏。
mapping_negative_extra_network() {
    local dir=${1:-} product=${2:-} ledger=$dir/control/resources name
    [[ -n $dir && -n $product ]] || return 1
    name="gm-${MP_RUN_ID}-neg-net"
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_create_register network "$MAPPING_ASSERT_CASE" extra -- \
        resource_docker network create --ipv6=false \
        --label "gitdaemon.run=$MP_RUN_ID" \
        --label "gitdaemon.scenario=$MAPPING_ASSERT_CASE" \
        --label "gitdaemon.role=extra" "$name" >/dev/null || return 1
    mapping_fixture_docker network connect "$name" "$product" >/dev/null || return 1
    return 0
}

# 客户端 CA 卷替换为不受信任的自签根：相应 TLS 层必须失败，且不因此关闭校验。
mapping_negative_wrong_ca() {
    local caname=${1:-} image=${MAPPING_PRODUCT_IMAGE:-} script
    [[ -n $caname && -n $image ]] || return 1
    script=$(mapping_negative_ca_script) || return 1
    printf '%s' "$script" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -e "MAPPING_NEG_CANAME=$caname" \
        -v "$(mapping_ca_volume):$MAPPING_CA_MOUNT" --entrypoint /bin/sh "$image" -s
}

# 服务端叶证书替换为错 SAN 的叶证书（仍由真实 CA 签发）：主机名校验必须失败。
mapping_negative_wrong_san() {
    local which=${1:-} image=${MAPPING_PRODUCT_IMAGE:-} script
    [[ -n $which && -n $image ]] || return 1
    script=$(mapping_negative_san_script) || return 1
    printf '%s' "$script" | mapping_fixture_docker run --rm -i --user 10001:10001 --network none \
        -e "MAPPING_ASSET_ROOT=$MAPPING_ASSET_ROOT" -e "MAPPING_NEG_WHICH=$which" \
        -e "MAPPING_NEG_HOST=${MAPPING_NEG_HOST:-other-host.invalid}" \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT" --entrypoint /bin/sh "$image" -s
}

mapping_negative_ca_script() {
    cat <<'MAPPING_NEGCA'
set -eu
work=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=GM-Mapping-Untrusted-CA' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$work/ca.key" -out "$work/ca.crt" >/dev/null 2>&1
umask 022
cat "$work/ca.crt" > "/ca/${MAPPING_NEG_CANAME:?}"
rm -rf "$work"
MAPPING_NEGCA
}

mapping_negative_san_script() {
    cat <<'MAPPING_NEGSAN'
set -eu
R=${MAPPING_ASSET_ROOT:?}
d="$R/${MAPPING_NEG_WHICH:?}"
work=$(mktemp -d)
openssl req -newkey rsa:2048 -nodes -subj "/CN=${MAPPING_NEG_HOST:?}" \
    -keyout "$work/srv.key" -out "$work/srv.csr" >/dev/null 2>&1
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' \
    "$MAPPING_NEG_HOST" > "$work/srv.ext"
openssl x509 -req -in "$work/srv.csr" -CA "$d/tls/ca.crt" -CAkey "$d/tls/ca.key" \
    -CAcreateserial -days 2 -extfile "$work/srv.ext" -out "$d/tls/srv.crt" >/dev/null 2>&1
rm -rf "$work"
MAPPING_NEGSAN
}
