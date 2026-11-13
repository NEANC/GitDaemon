#!/usr/bin/env bash
# Mapping 独立双断言与反假绿判定。
# 依赖 tests/docker-mapping-fixture.sh：地址档案、映射网络/策略、双 CA 资产与代理原语由该文件提供。
# 本文件交付接口 D 的场景编排、判定器与安全负例；所有 Docker/Git/同步入口只经具名边界函数调用，
# 契约测试以替身替换这些边界。判定器不设替身，直接消费证据文件，因此假绿注入无法绕过。

source "$(dirname -- "${BASH_SOURCE[0]}")/docker-wrong-proxy-san.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/docker-wrong-upstream-san.sh"

# 场景与证据契约。
MAPPING_ASSERT_KINDS='fallback direct'
MAPPING_ASSERT_SCENARIO_FALLBACK='mapping-fallback'
MAPPING_ASSERT_SCENARIO_DIRECT='mapping-direct'
MAPPING_ASSERT_FILES='identity.tsv sync.log sync.exit proxy.before proxy.after connect.log upstream.before upstream.after refs.expected refs.actual head.expected head.actual fsck.exit dns.txt'
MAPPING_ASSERT_IDENTITY_KEYS=(run_id scenario generation network_id image_id profile_sha256 input_sha256 manifest_sha256 unique_commit)
MAPPING_ASSERT_NEGATIVES='missing-map invalid-map dns-false-green unreachable-map-system wrong_proxy_ca wrong_proxy_san wrong_upstream_ca wrong_upstream_san isolation'
MAPPING_NEGATIVE_CASES='missing-map/fallback missing-map/direct invalid-map/rfc1918/fallback invalid-map/rfc1918/direct invalid-map/test-net/fallback invalid-map/test-net/direct invalid-map/benchmark/fallback invalid-map/benchmark/direct dns-false-green/fallback dns-false-green/direct unreachable-map-system/fallback unreachable-map-system/direct wrong_proxy_ca wrong_proxy_san wrong_upstream_ca wrong_upstream_san isolation/cross-network isolation/host-published isolation/host-input isolation/dns-udp isolation/dns-tcp'
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
    MAPPING_ASSERT_GENERATION="$scenario-g$MAPPING_ASSERT_GENERATION_SEQ-$$"
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
mapping_upstream_ca_git_diagnostic() {
    local file=${1:-} target
    [[ -f $file && ! -L $file && -r $file ]] || return 1
    target="fatal: unable to access 'https://$MAPPING_UPSTREAM_HOST/$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO.git/': "
    awk -v target="$target" '
        /^fatal: / {
            if (index($0, target) != 1) { invalid = 1; next }
            detail = substr($0, length(target) + 1)
            if (detail ~ /^(SSL certificate problem: )?(unable to get (local )?issuer certificate|self-signed certificate in certificate chain|unable to verify the first certificate)$/) found++
            else invalid = 1
        }
        END { exit invalid || found != 1 }
    ' "$file"
}

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

mapping_assert_connect_all_legal() {
    local file=${1:-} upstream=${2:-} line
    [[ -s $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 1
        printf '%s\n' "$line" | awk -F '\t' -v auth="authority=$MAPPING_PROXY_AUTHORITY" \
            -v dial="dial_target=$upstream:$MAPPING_UPSTREAM_PORT" \
            'NF == 3 && $1 == auth && $2 == "mode=accept" && $3 == dial { ok=1 } END { exit !ok }' || return 1
    done < "$file"
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
    local kind=${1:-} scenario=${2:-} dir=${3:-} ledger netid
    [[ ${MAPPING_ASSERT_RELEASE_FAILED:-0} != 1 ]] || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n ${MAPPING_PROFILE:-} && -n ${MAPPING_PRODUCT_IMAGE:-} && -n ${MAPPING_TOOLS_IMAGE:-} ]] || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_CALIBRATED_GENERATION=''
    ledger=${RESOURCE_LEDGER_DIR:-${IT_CONTROL_DIR:-$dir/control}/resources}
    RESOURCE_LEDGER_DIR=$ledger
    if [[ -f $ledger/ledger.tsv ]]; then
        local entry key shared_witness='' shared_network=''
        mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
        RESOURCE_RUN=$MP_RUN_ID
        resource_crosscheck "$ledger" || return "$MAPPING_ASSERT_FIXTURE"
        shared_witness=$(resource_docker inspect -f '{{.Id}}' "gm-$MP_RUN_ID-witness" 2>/dev/null) || shared_witness=''
        shared_network=$(resource_docker network inspect -f '{{.Id}}' "gm-$MP_RUN_ID-w-net" 2>/dev/null) || shared_network=''
        for key in "${!RESOURCE_LEDGER_ACTIVE[@]}"; do
            entry=${RESOURCE_LEDGER_ACTIVE[$key]:-}
            [[ -z $entry || ( -n $shared_witness && $key == "container|$shared_witness" && $entry == *'|mapping|witness|'* && $entry == *"|$MP_RUN_ID" ) || ( -n $shared_network && $key == "network|$shared_network" && $entry == *'|mapping|witness-network|'* && $entry == *"|$MP_RUN_ID" ) ]] || return "$MAPPING_ASSERT_FIXTURE"
        done
    fi
    mapping_prepare "$MAPPING_PROFILE" "$scenario" "$MAPPING_PRODUCT_IMAGE" "$MAPPING_TOOLS_IMAGE" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_proxy_evidence_reset "$scenario" "$MAPPING_PRODUCT_IMAGE" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_negative_prepare "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    netid=$(mapping_network_id_load) || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ACK_GENERATION=''
    mapping_ready "$MAPPING_PROFILE" "$netid" "$MAPPING_ASSERT_GENERATION" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_activate "$MAPPING_ASSERT_GENERATION" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_fixture_start "$MAPPING_PROFILE" "$scenario" "$MAPPING_PRODUCT_IMAGE" "$MAPPING_TOOLS_IMAGE" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 代理校准：先证接受端口可达、拒绝端口 403、计数增长，再写 proxy.before 基线。
mapping_scenario_calibrate() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    MAPPING_ASSERT_CALIBRATED_GENERATION='' MP_WITNESS_CALIBRATED=0
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_proxy_calibrate "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_CASE:-} == isolation || ${MAPPING_ASSERT_CASE:-} == isolation/* ]]; then
        [[ ${MAPPING_ASSERT_CASE:-} != isolation/* ]] || mapping_witness_key_valid "${MAPPING_ASSERT_TARGET:-}" || return "$MAPPING_ASSERT_FIXTURE"
        mapping_calibrate_witness "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    MAPPING_ASSERT_CALIBRATED_GENERATION=$MAPPING_ASSERT_GENERATION
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
    id=$(mapping_fixture_docker inspect -f '{{.Id}}' "$probe" 2>/dev/null) || { MAPPING_ASSERT_CALIBRATED_GENERATION=''; return 1; }
    [[ -n $id ]] || return 1
    resource_remove container "$id" || { MAPPING_ASSERT_CALIBRATED_GENERATION=''; return 1; }
    return 0
}

# 产品就绪：独立数据卷 create/登记 → 安全离线 helper 写合法快照与测试 Git 信任配置 →
# 释放顺序占位 probe(P) → READY 握手 → 从正式容器入口启动并等待可观测就绪。
mapping_scenario_product_up() {
    local kind=${1:-} scenario=${2:-} dir=${3:-}
    local ledger=${RESOURCE_LEDGER_DIR:-${IT_CONTROL_DIR:-$dir/control}/resources} data gitconfig snapshot_content name
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n ${MAPPING_ASSERT_GENERATION:-} && ${MAPPING_ASSERT_CALIBRATED_GENERATION:-} == "$MAPPING_ASSERT_GENERATION" && ${MAPPING_ACK_GENERATION:-} == "$MAPPING_ASSERT_GENERATION" ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_release_probe || return "$MAPPING_ASSERT_FIXTURE"
    data=$(mapping_scenario_data_volume "$MAPPING_ASSERT_GENERATION")
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_create_register volume "$scenario" "$MAPPING_ASSERT_DATA_ROLE" -- \
        resource_docker volume create \
        --label "gitdaemon.run=$MP_RUN_ID" \
        --label "gitdaemon.scenario=$scenario" \
        --label "gitdaemon.role=$MAPPING_ASSERT_DATA_ROLE" "$data" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    snapshot_content=$(mapping_scenario_snapshot_content "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    mkdir -p "$dir/control" || return "$MAPPING_ASSERT_FIXTURE"
    printf '%s' "$snapshot_content" > "$dir/control/snapshot.content" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ -n $snapshot_content ]]; then
        mapping_scenario_data_write "$data" "$MAPPING_ASSERT_SNAPSHOT_REL" "$snapshot_content" "$MAPPING_PRODUCT_IMAGE" \
            || return "$MAPPING_ASSERT_FIXTURE"
    fi
    gitconfig=$(mapping_scenario_gitconfig_content) || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_data_write "$data" "$MAPPING_ASSERT_GITCONFIG_REL" "$gitconfig" "$MAPPING_PRODUCT_IMAGE" \
        || return "$MAPPING_ASSERT_FIXTURE"
    name=$(mapping_scenario_product_container "$MAPPING_ASSERT_GENERATION")
    mapping_fixture_create "$scenario" "$MAPPING_ASSERT_PRODUCT_ROLE" -d --name "$name" \
        $MAPPING_SAFE_OPTIONS --network "$MP_NETWORK_NAME" --ip "$MP_P" --dns "$MP_D" --dns-search=. \
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
    case "${MAPPING_ASSERT_CASE:-}" in
        wrong_proxy_ca) mapping_negative_wrong_ca proxy-ca.crt || return "$MAPPING_ASSERT_FIXTURE" ;;
        wrong_proxy_san) : ;;
        wrong_upstream_ca) mapping_negative_wrong_ca upstream-ca.crt || return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
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
mapping_scenario_missing_map_validator() {
    local product=${1:-} dir=${2:-}
    [[ -n $product && -d $dir ]] || return 80
    mapping_fixture_docker exec -e "RUN_ROOT=$MAPPING_ASSERT_RUN_ROOT" "$product" /bin/bash -c '
        source /usr/local/lib/git-mirror/git-mirror-sync.sh
        GM_CONFIG[ENABLE_HOSTS_UPDATE]=yes
        GITHUB_HOST=github.com
        LOG_FILE=/dev/null
        snapshot=$RUN_ROOT/hosts/github-hosts.snapshot
        if [[ -e $snapshot ]]; then
            printf "snapshot\tpresent\nresolve_count\t0\n"
            exit 0
        fi
        load_resolve_args "$snapshot" >&2 && build_transport_sequence || exit 1
        printf "snapshot\tabsent\nresolve_count\t%s\n" "${#GM_RESOLVE_ARGS[@]}"
    ' > "$dir/validator.tsv" 2> "$dir/validator.log" || return 80
    return 0
}

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

# 解析单次 dig 原始证据：命令失败、缺 SERVER、SERVFAIL、NODATA 都是夹具失败。
mapping_dns_query() {
    local client=${1:-} resolver=${2:-} name=${3:-} rrtype=${4:-} raw=${5:-} dig_rc=${6:-0}
    local status server answer
    [[ -n $client && -n $resolver && -n $name && $rrtype =~ ^(A|AAAA)$ && -f $raw && ! -L $raw ]] \
        || return "$MAPPING_ASSERT_FIXTURE"
    [[ $dig_rc == 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
    status=$(sed -n 's/.*status: \([A-Z][A-Z]*\),.*/\1/p' "$raw" | head -n 1)
    server=$(sed -n 's/^;; SERVER: \([^#[:space:]]*\).*/\1/p' "$raw" | head -n 1)
    answer=$(sed -n 's/.*ANSWER: \([0-9][0-9]*\).*/\1/p' "$raw" | head -n 1)
    [[ -n $status && $server == "$resolver" ]] || return "$MAPPING_ASSERT_FIXTURE"
    case "$status" in
        NXDOMAIN) printf '%s\t%s\tNXDOMAIN\n' "$name" "$rrtype" ;;
        NOERROR)
            [[ ${answer:-0} -gt 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
            awk -v name="$name" -v type="$rrtype" '$4 == type { print name "\t" type "\t" $5; found=1 } END { if (!found) exit 1 }' "$raw" \
                || return "$MAPPING_ASSERT_FIXTURE"
            ;;
        *) return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
    return 0
}

# 受控 DNS 状态取证：github.com 必须 NXDOMAIN（证明成功不依赖系统 DNS），gm-proxy 指向 X。
mapping_scenario_dns_state() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} spec name type raw rc
    [[ -n $kind && -n $scenario && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    for spec in "$MAPPING_UPSTREAM_HOST A" "$MAPPING_UPSTREAM_HOST AAAA" "$MAPPING_PROXY_HOST A"; do
        read -r name type <<< "$spec"
        raw=$dir/dig-$name-$type.txt
        rc=0
        mapping_fixture_docker exec "${MAPPING_ASSERT_PRODUCT:-$(mapping_dns_container)}" \
            dig +time=1 +tries=1 "@$MP_D" "$name" "$type" > "$raw" 2>&1 || rc=$?
        mapping_dns_query "${MAPPING_ASSERT_PRODUCT:-dns}" "$MP_D" "$name" "$type" "$raw" "$rc" \
            || return "$MAPPING_ASSERT_FIXTURE"
    done
    return 0
}

mapping_scenario_dns_client_probe() {
    local client=${1:-} dir=${2:-} state=${3:-} spec name type raw rc=0
    [[ -n $client && -d $dir && -n $state ]] || return "$MAPPING_ASSERT_FIXTURE"
    for spec in "$MAPPING_UPSTREAM_HOST A" "$MAPPING_UPSTREAM_HOST AAAA" "$MAPPING_PROXY_HOST A"; do
        read -r name type <<< "$spec"
        raw=$dir/dig-$client-$name-$type.txt
        rc=0
        mapping_fixture_docker exec "$client" dig +time=1 +tries=1 "@$MP_D" "$name" "$type" > "$raw" 2>&1 || rc=$?
        mapping_dns_query "$client" "$MP_D" "$name" "$type" "$raw" "$rc" >> "$state" \
            || return "$MAPPING_ASSERT_FIXTURE"
    done
    return 0
}

mapping_scenario_dns_system_probe() {
    local client=${1:-} dir=${2:-} raw rc=0
    [[ -n $client && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    raw=$dir/dns-system-upstream.txt
    mapping_fixture_docker exec "$client" curl --verbose --noproxy '*' --connect-timeout 2 --max-time 3 \
        "http://$MAPPING_UPSTREAM_HOST/" > "$raw" 2>&1 || rc=$?
    [[ $rc == 6 ]] || return "$MAPPING_ASSERT_FIXTURE"
    grep -Fq "Could not resolve host: $MAPPING_UPSTREAM_HOST" "$raw" || return "$MAPPING_ASSERT_FIXTURE"
    raw=$dir/dns-system-proxy.txt
    rc=0
    mapping_fixture_docker exec "$client" curl --verbose --noproxy '*' --connect-timeout 2 --max-time 3 \
        "http://$MAPPING_PROXY_HOST/" > "$raw" 2>&1 || rc=$?
    [[ $rc != 6 ]] || return "$MAPPING_ASSERT_FIXTURE"
    grep -Fq "Trying $MP_X:80" "$raw" || return "$MAPPING_ASSERT_FIXTURE"
}

# 受控 DNS 恢复：清除假绿开关并核验 github.com 恢复为 NXDOMAIN、gm-proxy 仍指向 X。
# 恢复后判定器读到的 DNS 证据不再是被造假绿样本。
mapping_scenario_dns_restore() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} file rc=0
    [[ -n $dir && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    local MAPPING_ASSERT_KIND=$kind
    mapping_dns_set nxdomain "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    file=$dir/dns.restore
    mapping_scenario_dns_state "$kind" "$scenario" "$dir" > "$file" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_dns_file "$file" || rc="$MAPPING_ASSERT_FIXTURE"
    if [[ -n ${MAPPING_ASSERT_PRODUCT:-} ]]; then
        mapping_scenario_product_ready "$MAPPING_ASSERT_PRODUCT" || return "$MAPPING_ASSERT_FIXTURE"
        mapping_scenario_dns_system_probe "$MAPPING_ASSERT_PRODUCT" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    return "$rc"
}

# 局部清理：释放本场景创建的全部资源（产品/上游/代理/DNS/探针容器、映射与负例网络、
# 数据/资产/CA 卷），使同一进程内重跑可重建同名资源而不冲突。资源身份由实时 inspect 取得。
mapping_scenario_release() {
    local kind=${1:-} scenario=${2:-} generation=${3:-} dir=${4:-} ledger id name
    [[ -n $kind && -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "${MAPPING_PROFILE:-}" || return "$MAPPING_ASSERT_FIXTURE"
    ledger=${RESOURCE_LEDGER_DIR:-${IT_CONTROL_DIR:-$dir/control}/resources}
    RESOURCE_LEDGER_DIR=$ledger RESOURCE_RUN=$MP_RUN_ID
    resource_cleanup_scenario "$ledger" "$scenario" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_control_request mapping-release "$generation" "$MP_NETWORK_ID" "$MP_PROFILE_SHA256" || { MAPPING_ASSERT_RELEASE_FAILED=1; return "$MAPPING_ASSERT_FIXTURE"; }
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
        tls) printf 'https://%s:%s\n' "$MAPPING_PROXY_HOST" "$MAPPING_PROXY_ACCEPT_PORT" ;;
        fallback) printf 'https://%s:%s\n' "$MAPPING_PROXY_HOST" "$MAPPING_PROXY_REJECT_PORT" ;;
        direct) printf '' ;;
        *) return 1 ;;
    esac
}

mapping_tls_product_request() {
    local dir=${1:-} scenario=${2:-} rc
    mapping_scenario_sync_exec tls "$scenario" "$dir" || return 80
    rc=$(mapping_assert_uint_file "$dir/sync.exit") || return 80
    cp "$dir/sync.log" "$dir/request.log" || return 80
    printf '%s\n' "$rc"
}

mapping_negative_proxy_ca_restore() {
    local image=${MAPPING_PRODUCT_IMAGE:-}
    [[ -n $image ]] || return 1
    mapping_fixture_docker run --rm --user 10001:10001 --network none \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT:ro" \
        -v "$(mapping_ca_volume):$MAPPING_CA_MOUNT" --entrypoint /bin/sh "$image" \
        -c 'cat "$1" > "$2" && cmp -s "$1" "$2"' sh \
        "$MAPPING_ASSET_ROOT/proxy/tls/ca.crt" "$MAPPING_CLIENT_PROXY_CA"
}

mapping_negative_upstream_ca_restore() {
    local image=${MAPPING_PRODUCT_IMAGE:-}
    [[ -n $image ]] || return 1
    mapping_fixture_docker run --rm --user 10001:10001 --network none \
        -v "$(mapping_assets_volume):$MAPPING_FIXTURE_MOUNT:ro" \
        -v "$(mapping_ca_volume):$MAPPING_CA_MOUNT" --entrypoint /bin/sh "$image" \
        -c 'cat "$1" > "$2" && cmp -s "$1" "$2"' sh \
        "$MAPPING_ASSET_ROOT/upstream/tls/ca.crt" "$MAPPING_CLIENT_UPSTREAM_CA"
}

mapping_tls_client_upstream_ca_hash() {
    local image=${MAPPING_PRODUCT_IMAGE:-} name
    [[ -n $image && -n ${MAPPING_ASSERT_GENERATION:-} ]] || return 1
    name=$(mapping_scenario_product_container "$MAPPING_ASSERT_GENERATION") || return 1
    mapping_fixture_docker exec "$name" sha256sum "$MAPPING_CLIENT_UPSTREAM_CA" | awk '{print $1}'
}

mapping_tls_injected_evidence() {
    local dir=${1:-} kind=${2:-} scenario=${3:-} before after request_rc dial_before dial_after
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$before" > "$dir/proxy.before" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.before" || return 80
    dial_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_before" > "$dir/upstream.before" || return 80
    request_rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$request_rc" > "$dir/request.exit" || return 80
    cp "$dir/request.log" "$dir/request.failed.log" || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$after" > "$dir/proxy.after" || return 80
    dial_after=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_after" > "$dir/upstream.after" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || return 80
    printf 'case\twrong_proxy_ca\nlayer\touter-failure\nconnect_delta\t%s\nrequest_exit\t%s\n' \
        "$((after - before))" "$request_rc" > "$dir/tls-layer.tsv" || return 80
    [[ $request_rc != 0 && $after == "$before" && $dial_after == "$dial_before" ]] || return 1
    cmp -s "$dir/connect.before" "$dir/connect.log" || return 1
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || return 1
    [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
    [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
    grep -Eqi 'certificate|issuer|SSL' "$dir/request.failed.log" || return 1
    return 0
}

mapping_tls_negative_run() {
    local case_name=${1:-} dir=${2:-} kind=${3:-} scenario=${4:-} before after recovered recovery_rc evidence_rc=0
    [[ ( $case_name == wrong_proxy_ca || $case_name == wrong_upstream_ca ) && -d $dir && ! -L $dir ]] || return 80
    if [[ $case_name == wrong_upstream_ca ]]; then
        mapping_tls_upstream_ca_run "$dir" "$kind" "$scenario"
        return $?
    fi
    mapping_scenario_valid "$scenario" || return 80
    mapping_profile_load "$MAPPING_PROFILE" || return 80
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$before" > "$dir/baseline.before"
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.initial" || return 80
    recovery_rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$recovery_rc" > "$dir/baseline.exit"
    [[ $recovery_rc == 0 ]] || return 80
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    cp "$dir/request.log" "$dir/request.baseline.log" || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$after" > "$dir/baseline.after"
    (( after > before )) || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.baseline" || return 80
    [[ $(wc -l < "$dir/connect.baseline") -gt $(wc -l < "$dir/connect.initial") ]] || return 80
    tail -n "+$(( $(wc -l < "$dir/connect.initial") + 1 ))" "$dir/connect.baseline" > "$dir/connect.baseline.new" || return 80
    mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 80
    printf '%s\n' "$case_name" > "$dir/case.tsv"
    if ! mapping_negative_wrong_ca proxy-ca.crt; then
        mapping_negative_proxy_ca_restore || return 80
        return 80
    fi
    mapping_tls_injected_evidence "$dir" "$kind" "$scenario" || evidence_rc=$?
    mapping_negative_proxy_ca_restore || return 80
    (( evidence_rc == 0 )) || return "$evidence_rc"
    recovery_rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$recovery_rc" > "$dir/recovery.exit"
    [[ $recovery_rc == 0 ]] || return 80
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    cp "$dir/request.log" "$dir/request.recovery.log" || return 80
    recovered=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$recovered" > "$dir/proxy.recovered"
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.recovered" || return 80
    after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
    (( recovered > after )) || return 1
    [[ $(wc -l < "$dir/connect.recovered") -gt $(wc -l < "$dir/connect.log") ]] || return 1
    tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" > "$dir/connect.recovered.new" || return 80
    mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
    return 0
}

mapping_tls_upstream_ca_run() {
    local dir=${1:-} kind=${2:-} scenario=${3:-} before after recovered rc evidence_rc=0 dial_before dial_after baseline_dial ca_before ca_after ca_recovered
    mapping_scenario_valid "$scenario" || return 80
    mapping_profile_load "$MAPPING_PROFILE" || return 80
    ca_before=$(mapping_tls_client_upstream_ca_hash) || return 80
    [[ $ca_before =~ ^[0-9a-f]{64}$ ]] || return 80
    printf '%s\n' "$ca_before" > "$dir/ca.before.sha256" || return 80
    dial_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_before" > "$dir/upstream.baseline.before" || return 80
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$before" > "$dir/baseline.before" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.before" || return 80
    rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$rc" > "$dir/baseline.exit" || return 80
    [[ $rc == 0 ]] || return 80
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    cp "$dir/request.log" "$dir/request.baseline.log" || return 80
    after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    (( after > before )) || return 80
    printf '%s\n' "$after" > "$dir/baseline.after" || return 80
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.baseline" || return 80
    tail -n "+$(( $(wc -l < "$dir/connect.before") + 1 ))" "$dir/connect.baseline" > "$dir/connect.baseline.new" || return 80
    mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 80
    baseline_dial=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$baseline_dial" >/dev/null || return 80
    printf '%s\n' "$baseline_dial" > "$dir/upstream.baseline" || return 80
    (( baseline_dial > dial_before )) || return 80
    printf 'wrong_upstream_ca\n' > "$dir/case.tsv" || return 80
    if ! mapping_negative_wrong_ca upstream-ca.crt; then
        mapping_negative_upstream_ca_restore || return 80
        return 80
    fi
    ca_after=$(mapping_tls_client_upstream_ca_hash) || evidence_rc=80
    if (( evidence_rc == 0 )); then
        [[ $ca_after =~ ^[0-9a-f]{64}$ ]] || evidence_rc=80
        printf '%s\n' "$ca_after" > "$dir/ca.after.sha256" || evidence_rc=80
        [[ $ca_after != "$ca_before" ]] || evidence_rc=1
    fi
    before=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || evidence_rc=80
    if (( evidence_rc == 0 )); then mapping_assert_uint "$before" >/dev/null || evidence_rc=80; fi
    if (( evidence_rc == 0 )); then
        printf '%s\n' "$before" > "$dir/proxy.before" || evidence_rc=80
        dial_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || evidence_rc=80
        if (( evidence_rc == 0 )); then mapping_assert_uint "$dial_before" >/dev/null || evidence_rc=80; fi
    fi
    if (( evidence_rc == 0 )); then
        printf '%s\n' "$dial_before" > "$dir/upstream.before" || evidence_rc=80
        rc=$(mapping_tls_product_request "$dir" "$scenario") || evidence_rc=80
    fi
    if (( evidence_rc == 0 )); then
        printf '%s\n' "$rc" > "$dir/request.exit" || evidence_rc=80
        cp "$dir/request.log" "$dir/request.failed.log" || evidence_rc=80
        after=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || evidence_rc=80
        if (( evidence_rc == 0 )); then mapping_assert_uint "$after" >/dev/null || evidence_rc=80; fi
    fi
    if (( evidence_rc == 0 )); then
        dial_after=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || evidence_rc=80
        if (( evidence_rc == 0 )); then mapping_assert_uint "$dial_after" >/dev/null || evidence_rc=80; fi
    fi
    if (( evidence_rc == 0 )); then
        printf '%s\n' "$after" > "$dir/proxy.after" || evidence_rc=80
        printf '%s\n' "$dial_after" > "$dir/upstream.after" || evidence_rc=80
        mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || evidence_rc=80
    fi
    if (( evidence_rc == 0 )); then
        printf 'case\twrong_upstream_ca\nlayer\tinner-failure\nconnect_delta\t%s\nrequest_exit\t%s\n' \
            "$((after - before))" "$rc" > "$dir/tls-layer.tsv" || evidence_rc=80
        [[ $rc != 0 && $after -gt $before && $dial_after -gt $dial_before ]] || evidence_rc=1
        tail -n "+$(( $(wc -l < "$dir/connect.baseline") + 1 ))" "$dir/connect.log" > "$dir/connect.failed.new" || evidence_rc=80
        mapping_assert_connect_legal "$dir/connect.failed.new" "$MP_U" || evidence_rc=1
        mapping_upstream_ca_git_diagnostic "$dir/request.failed.log" || evidence_rc=1
    fi
    mapping_negative_upstream_ca_restore || return 80
    ca_recovered=$(mapping_tls_client_upstream_ca_hash) || return 80
    [[ $ca_recovered =~ ^[0-9a-f]{64}$ ]] || return 80
    printf '%s\n' "$ca_recovered" > "$dir/ca.recovered.sha256" || return 80
    [[ $ca_recovered == "$ca_before" ]] || return 1
    (( evidence_rc == 0 )) || return "$evidence_rc"
    rc=$(mapping_tls_product_request "$dir" "$scenario") || return 80
    printf '%s\n' "$rc" > "$dir/recovery.exit" || return 80
    [[ $rc == 0 ]] || return 80
    grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 80
    cp "$dir/request.log" "$dir/request.recovery.log" || return 80
    recovered=$(mapping_proxy_count_read_remote "$MAPPING_PROXY_ACCEPT_PORT") || return 80
    printf '%s\n' "$recovered" > "$dir/proxy.recovered" || return 80
    (( recovered > after )) || return 1
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.recovered" || return 80
    tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" > "$dir/connect.recovered.new" || return 80
    mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
    dial_after=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return 80
    mapping_assert_uint "$dial_after" > "$dir/upstream.recovered" || return 80
    before=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
    (( dial_after > before )) || return 1
    [[ -f $dir/refs.expected && -f $dir/head.expected && -f $dir/control/unique-commit && ! -L $dir/refs.expected && ! -L $dir/head.expected && ! -L $dir/control/unique-commit ]] || return 80
    mapping_assert_identity_load "$dir" || return 80
    [[ $MPA_UNIQUE_COMMIT == "$(sed -n '1p' "$dir/control/unique-commit")" ]] || return 1
    mapping_scenario_local_refs "$kind" "$scenario" "$dir" > "$dir/refs.actual" || return 80
    mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" || return 80
    mapping_scenario_local_fsck "$kind" "$scenario" "$dir" > "$dir/fsck.exit" || return 80
    mapping_assert_refs_match "$dir" || return 1
    mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 1
    mapping_assert_head_match "$dir" || return 1
    rc=$(mapping_assert_uint_file "$dir/fsck.exit") || return 80
    [[ $rc == 0 ]] || return 1
    return 0
}

# identity.tsv：绑定 run/scenario/generation/network/image/三项哈希与独有提交。
mapping_scenario_identity_write() {
    local kind=${1:-} scenario=${2:-} generation=${3:-} dir=${4:-}
    local network image profile_sha input_sha manifest_sha unique file root
    [[ -n $kind && -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
    network=$(mapping_network_id_load) || return "$MAPPING_ASSERT_FIXTURE"
    image=${MAPPING_PRODUCT_IMAGE:-}
    profile_sha=${MP_PROFILE_SHA256:-}
    [[ -n $image && -n $profile_sha ]] || return "$MAPPING_ASSERT_FIXTURE"
    unique=$(sed -n '1p' "$dir/control/unique-commit" 2>/dev/null) || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $unique ]] || return "$MAPPING_ASSERT_FIXTURE"
    root=${MAPPING_INPUT_ROOT:-}
    [[ -n $root && $root == /* && ${IT_CONTROL_DIR:-} == "$root/control" ]] || return "$MAPPING_ASSERT_FIXTURE"
    input_sha=$(mapping_scenario_frozen_input_hash "$root") || return "$MAPPING_ASSERT_FIXTURE"
    manifest_sha=$(mapping_scenario_hash_of "${MAPPING_MANIFEST:-}") || return "$MAPPING_ASSERT_FIXTURE"
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

mapping_scenario_input_facts() { stat -c '%u %a' -- "$1" 2>/dev/null; }

mapping_scenario_frozen_input_hash() {
    local root=${1:-} list=$root/inputs.sha256 anchor=$root/inputs.sha256.digest facts owner mode digest expected file
    [[ -f $list && ! -L $list && -f $anchor && ! -L $anchor ]] || return 1
    for file in "$list" "$anchor"; do
        facts=$(mapping_scenario_input_facts "$file") || return 1
        read -r owner mode <<< "$facts"
        [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#$mode & 8#022) == 0 )) || return 1
    done
    expected=$(cat -- "$anchor") || return 1
    [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
    digest=$(mapping_scenario_hash_of "$list") || return 1
    [[ $digest == "$expected" ]] || return 1
    sha256sum -c -- "$list" >/dev/null 2>&1 || return 1
    printf '%s\n' "$digest"
}

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
    local product up_before base_scenario head_rc
    mapping_assert_kind_valid "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $scenario && -n $generation && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    base_scenario=$(mapping_assert_scenario "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_GENERATION=$generation
    MAPPING_ASSERT_PRODUCT=''
    # 本轮代理计数与 CONNECT 日志按 generation 独立，重跑不复用上一轮证据。
    MAPPING_PROXY_RUN_ID=$generation
    mapping_scenario_fixture_prepare "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_calibrate "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_DNS_MODE:-none} == upstream ]]; then
        local MAPPING_ASSERT_KIND=$kind
        mapping_dns_set upstream "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    product=$(mapping_scenario_product_up "$kind" "$scenario" "$dir") || return "$MAPPING_ASSERT_FIXTURE"
    [[ -n $product ]] || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_PRODUCT=$product
    up_before=$(mapping_scenario_upstream_count "$kind" "$scenario" "$dir") || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_uint "$up_before" > "$dir/upstream.before" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_commit "$kind" "$scenario" "$dir" >/dev/null || return "$MAPPING_ASSERT_FIXTURE"
    # identity 绑定 kind 的基础场景，使负例变体仍以同一场景判定，拒绝只能来自注入缺陷本身。
    if [[ ${MAPPING_ASSERT_CASE:-} == missing-map ]]; then
        mapping_scenario_identity_write "$kind" "$scenario" "$generation" "$dir" || return 80
    else
        mapping_scenario_identity_write "$kind" "$base_scenario" "$generation" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    mapping_scenario_upstream_refs "$kind" "$scenario" "$dir" > "$dir/refs.expected" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_upstream_head "$kind" "$scenario" "$dir" > "$dir/head.expected" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_CASE:-} == wrong_upstream_san ]]; then
        mapping_upstream_san_case "$dir" "$kind" "$scenario" || return $?
        return 0
    fi
    if [[ ${MAPPING_ASSERT_CASE:-} == wrong_proxy_ca || ${MAPPING_ASSERT_CASE:-} == wrong_upstream_ca ]]; then
        mapping_tls_negative_run "$MAPPING_ASSERT_CASE" "$dir" "$kind" "$scenario" || return $?
        return 0
    fi
    if [[ ${MAPPING_ASSERT_CASE:-} == wrong_proxy_san ]]; then
        mapping_proxy_san_case "$dir" "$kind" "$scenario" || return $?
        return 0
    fi
    mapping_scenario_apply_negative "$kind" "$scenario" "$dir" "$product" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_CASE:-} == missing-map ]]; then
        mapping_scenario_missing_map_validator "$product" "$dir" || return 80
    fi
    mapping_scenario_sync_exec "$kind" "$scenario" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_CASE:-} == unreachable-map-system ]]; then
        mapping_scenario_unreachable_probe "$product" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    mapping_scenario_proxy_after "$kind" "$scenario" "$dir" > "$dir/proxy.after" || return "$MAPPING_ASSERT_FIXTURE"
    case "${MAPPING_ASSERT_CASE:-}" in
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san)
            mapping_tls_layer_write "$MAPPING_ASSERT_CASE" "$dir" || return "$MAPPING_ASSERT_FIXTURE"
            ;;
    esac
    mapping_scenario_upstream_count "$kind" "$scenario" "$dir" > "$dir/upstream.after" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_connect_evidence "$kind" "$scenario" "$dir" > "$dir/connect.log" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_local_refs "$kind" "$scenario" "$dir" > "$dir/refs.actual" || return "$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_CASE:-} == missing-map ]]; then
        head_rc=0
        mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" 2> "$dir/head.stderr" || head_rc=$?
        printf '%s\n' "$head_rc" > "$dir/head.exit"
    else
        mapping_scenario_local_head "$kind" "$scenario" "$dir" > "$dir/head.actual" || return "$MAPPING_ASSERT_FIXTURE"
    fi
    mapping_scenario_local_fsck "$kind" "$scenario" "$dir" > "$dir/fsck.exit" || return "$MAPPING_ASSERT_FIXTURE"
    mapping_scenario_dns_state "$kind" "$scenario" "$dir" > "$dir/dns.txt" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

mapping_scenario_unreachable_probe() {
    local product=${1:-} dir=${2:-} rc=0
    [[ -n $product && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_fixture_docker exec "$product" curl --silent --show-error --connect-timeout 2 \
        --max-time 3 --noproxy '*' --resolve "$MAPPING_UPSTREAM_HOST:443:$MP_N" \
        "https://$MAPPING_UPSTREAM_HOST/health.txt" > "$dir/unreachable.log" 2>&1 || rc=$?
    [[ $rc == 7 || $rc == 28 ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_unreachable_log "$dir/unreachable.log" || return "$MAPPING_ASSERT_FIXTURE"
    printf '%s\n' "$MP_N" > "$dir/unreachable.txt" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 核对直拨日志同时包含目标地址、443 端口及连接失败事实。
mapping_assert_unreachable_log() {
    local file=${1:-}
    [[ -f $file && ! -L $file && -s $file ]] || return 1
    awk -v addr="$MP_N" '
        /Failed to connect|Connection (timed out|refused)|connect to .* port 443 failed/ {
            port = "to " addr " port 443"
            position = index($0, port)
            if (!position) {
                port = "to " addr ":443"
                position = index($0, port)
            }
            if (position && substr($0, position + length(port)) ~ /^([^[:alnum:]_]|$)/) found=1
        }
        END { exit !found }
    ' "$file"
}

# 接口 D：单场景独立生命周期（准备→校准→基线→同步→判定→局部清理），可单独运行。
mapping_scenario_run() {
    local kind=${1:-} dir=${2:-} scenario generation rc
    [[ $# == 2 && -n $kind && -n $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    mapping_assert_kind_valid "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    scenario=$(mapping_assert_scenario "$kind") || return "$MAPPING_ASSERT_FIXTURE"
    MAPPING_ASSERT_CASE='' MAPPING_ASSERT_SNAPSHOT_MODE=valid MAPPING_ASSERT_DNS_MODE=none
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
    mapping_assert_generation "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    generation=$MAPPING_ASSERT_GENERATION
    mapping_assert_prepare_dir "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    local MAPPING_INPUT_ROOT=${IT_CONTROL_DIR%/control}
    # 证据目录局部化：只在本次调用可见；返回后外层值必须保持不变，否则映射组之后的其它
    # 分组会把证据写进映射场景的嵌套目录，主成功/清理失败校验被静默跳过。
    local IT_EVIDENCE_DIR=$dir
    local IT_CONTROL_DIR=${IT_CONTROL_DIR:-$dir/control}
    local RESOURCE_LEDGER_DIR=${RESOURCE_LEDGER_DIR:-$IT_CONTROL_DIR/resources}
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
    local case_name=${1:-} kind=${2:-} dir=${3:-} sync_exit system_line snapshot judge
    [[ -n $dir && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    case "$case_name" in
        missing-map)
            mapping_assert_identity_load "$dir" || return 80
            [[ $MPA_GENERATION == "$MAPPING_ASSERT_GENERATION" && $MPA_RUN_ID == "$MP_RUN_ID" ]] || return 80
            mapping_negative_case_evidence_accept "missing-map/$kind" "$MPA_RUN_ID" "$(mapping_assert_scenario "$kind")-missing-map" "$MPA_GENERATION" "$MPA_MANIFEST_SHA256" "$MPA_INPUT_SHA256" "$dir" || return $?
            [[ $(cat "$dir/control/unique-commit" 2>/dev/null) == "$MPA_UNIQUE_COMMIT" ]] || return 80
            MAPPING_ASSERT_JUDGE=1 MAPPING_ASSERT_REJECT_LAYER=sync
            return 0
            ;;
        isolation)
            MAPPING_ASSERT_REJECT_LAYER=''
            [[ -f $dir/isolation.tsv && ! -L $dir/isolation.tsv ]] || return "$MAPPING_ASSERT_FIXTURE"
            grep -Fqx $'isolation\tPASS' "$dir/isolation.tsv" || return "$MAPPING_ASSERT_FIXTURE"
            MAPPING_ASSERT_REJECT_LAYER=policy
            return 0
            ;;
        dns-false-green|unreachable-map-system)
            mapping_assert_require_files "$dir" || return "$MAPPING_ASSERT_FIXTURE"
            mapping_assert_identity_load "$dir" || return "$MAPPING_ASSERT_FIXTURE"
            sync_exit=$(mapping_assert_uint_file "$dir/sync.exit") || return "$MAPPING_ASSERT_FIXTURE"
            [[ $sync_exit == 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
            system_line=$(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_SYSTEM")
            [[ -n $system_line ]] || return "$MAPPING_ASSERT_FIXTURE"
            mapping_assert_refs_match "$dir" && mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" \
                && mapping_assert_head_match "$dir" || return "$MAPPING_ASSERT_FIXTURE"
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
            [[ -f $dir/dns.txt && ! -L $dir/dns.txt ]] || return "$MAPPING_ASSERT_FIXTURE"
            mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
            grep -Fqx "$(printf '%s\tA\t%s' "$MAPPING_UPSTREAM_HOST" "$MP_U")" "$dir/dns.txt" \
                || return "$MAPPING_ASSERT_FIXTURE"
            [[ -n $(mapping_assert_log_line "$dir/sync.log" '传输失败：直连加动态地址映射') ]] || return 1
            if [[ $case_name == unreachable-map-system ]]; then
                snapshot=$(sed -n '1p' "$dir/control/snapshot.content" 2>/dev/null) || return "$MAPPING_ASSERT_FIXTURE"
                [[ $snapshot == "$MP_N $MAPPING_UPSTREAM_HOST" ]] || return "$MAPPING_ASSERT_FIXTURE"
                [[ -f $dir/unreachable.txt && ! -L $dir/unreachable.txt ]] || return "$MAPPING_ASSERT_FIXTURE"
                grep -Fqx "$MP_N" "$dir/unreachable.txt" || return "$MAPPING_ASSERT_FIXTURE"
                mapping_assert_unreachable_log "$dir/unreachable.log" || return "$MAPPING_ASSERT_FIXTURE"
            else
                [[ -f $dir/control/snapshot.content && ! -s $dir/control/snapshot.content ]] || return "$MAPPING_ASSERT_FIXTURE"
            fi
            judge=0
            mapping_assert_result "$kind" "$dir" || judge=$?
            [[ $judge == 1 && $MAPPING_ASSERT_REJECT_LAYER == mapping ]] || return 1
            MAPPING_ASSERT_JUDGE=$judge
            MAPPING_ASSERT_REJECT_LAYER=dns
            return 0
            ;;
        invalid-map)
            mapping_assert_require_files "$dir" || return "$MAPPING_ASSERT_FIXTURE"
            sync_exit=$(mapping_assert_uint_file "$dir/sync.exit") || return "$MAPPING_ASSERT_FIXTURE"
            (( sync_exit != 0 )) || return 1
            [[ -f $dir/control/snapshot.content && ! -L $dir/control/snapshot.content ]] || return "$MAPPING_ASSERT_FIXTURE"
            snapshot=$(sed -n '1p' "$dir/control/snapshot.content") || return "$MAPPING_ASSERT_FIXTURE"
            [[ $snapshot == "$MAPPING_ASSERT_RESERVED_ADDR $MAPPING_UPSTREAM_HOST" ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
            grep -Fq '地址快照无效，忽略动态映射' "$dir/sync.log" || return 1
            judge=0
            mapping_assert_result "$kind" "$dir" || judge=$?
            [[ $judge == 1 && $MAPPING_ASSERT_REJECT_LAYER == sync ]] || return 1
            MAPPING_ASSERT_JUDGE=$judge
            MAPPING_ASSERT_REJECT_LAYER=sync
            return 0
            ;;
        wrong_proxy_ca)
            [[ $(cat "$dir/case.tsv" 2>/dev/null) == wrong_proxy_ca ]] || return "$MAPPING_ASSERT_FIXTURE"
            mapping_tls_layer_accept "$case_name" "$dir/tls-layer.tsv" || return "$MAPPING_ASSERT_FIXTURE"
            [[ $(mapping_assert_uint_file "$dir/baseline.exit") == 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
            [[ $(mapping_assert_uint_file "$dir/recovery.exit") == 0 ]] || return "$MAPPING_ASSERT_FIXTURE"
            [[ $(mapping_assert_uint_file "$dir/request.exit") -gt 0 ]] || return 1
            mapping_profile_load "$MAPPING_PROFILE" || return "$MAPPING_ASSERT_FIXTURE"
            mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 1
            [[ $(mapping_assert_uint_file "$dir/proxy.before") == $(mapping_assert_uint_file "$dir/proxy.after") ]] || return 1
            [[ $(mapping_assert_uint_file "$dir/proxy.recovered") -gt $(mapping_assert_uint_file "$dir/proxy.after") ]] || return 1
            cmp -s "$dir/connect.before" "$dir/connect.log" || return 1
            [[ $(wc -l < "$dir/connect.recovered") -gt $(wc -l < "$dir/connect.log") ]] || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            grep -Eqi 'certificate|issuer|SSL' "$dir/request.failed.log" || return 1
            MAPPING_ASSERT_REJECT_LAYER=tls-proxy
            return 0
            ;;
        wrong_upstream_ca)
            local baseline_exit recovery_exit request_exit proxy_before proxy_after proxy_recovered upstream_before upstream_after
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == wrong_upstream_ca ]] || return 80
            [[ -f $dir/tls-layer.tsv && ! -L $dir/tls-layer.tsv ]] || return 80
            for snapshot in baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after upstream.recovered ca.before.sha256 ca.after.sha256 ca.recovered.sha256 connect.baseline.new connect.failed.new connect.recovered.new request.failed.log refs.expected refs.actual; do
                [[ -f $dir/$snapshot && ! -L $dir/$snapshot ]] || return 80
            done
            mapping_tls_layer_accept "$case_name" "$dir/tls-layer.tsv" || return 1
            baseline_exit=$(mapping_assert_uint_file "$dir/baseline.exit") || return 80
            recovery_exit=$(mapping_assert_uint_file "$dir/recovery.exit") || return 80
            request_exit=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            proxy_before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            proxy_after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            proxy_recovered=$(mapping_assert_uint_file "$dir/proxy.recovered") || return 80
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            local upstream_recovered ca_before ca_after ca_recovered
            upstream_recovered=$(mapping_assert_uint_file "$dir/upstream.recovered") || return 80
            ca_before=$(cat "$dir/ca.before.sha256") || return 80
            ca_after=$(cat "$dir/ca.after.sha256") || return 80
            ca_recovered=$(cat "$dir/ca.recovered.sha256") || return 80
            [[ $ca_before =~ ^[0-9a-f]{64}$ && $ca_after =~ ^[0-9a-f]{64}$ && $ca_recovered =~ ^[0-9a-f]{64}$ ]] || return 80
            [[ $baseline_exit == 0 && $recovery_exit == 0 ]] || return 80
            (( request_exit > 0 )) || return 1
            mapping_profile_load "$MAPPING_PROFILE" || return 80
            mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.failed.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            (( proxy_after > proxy_before && upstream_after > upstream_before && proxy_recovered > proxy_after && upstream_recovered > upstream_after )) || return 1
            [[ $ca_before != "$ca_after" && $ca_before == "$ca_recovered" ]] || return 1
            [[ -f $dir/refs.expected && -f $dir/refs.actual ]] || return 80
            cmp -s "$dir/refs.expected" "$dir/refs.actual" || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            mapping_upstream_ca_git_diagnostic "$dir/request.failed.log" || return 1
            MAPPING_ASSERT_REJECT_LAYER=tls-upstream
            return 0
            ;;
        wrong_proxy_san)
            [[ $(cat "$dir/case.tsv" 2>/dev/null) == wrong_proxy_san ]] || return 80
            mapping_tls_layer_accept "$case_name" "$dir/tls-layer.tsv" || return 1
            [[ $(mapping_assert_uint_file "$dir/request.exit") -gt 0 ]] || return 1
            [[ $(mapping_assert_uint_file "$dir/proxy.before") == $(mapping_assert_uint_file "$dir/proxy.after") ]] || return 1
            cmp -s "$dir/connect.before" "$dir/connect.log" || return 1
            cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 80
            cmp -s "$dir/refs.expected" "$dir/refs.actual" || return 80
            mapping_assert_head_match "$dir" || return 80
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 80
            MAPPING_ASSERT_REJECT_LAYER=tls-proxy
            return 0
            ;;
        wrong_upstream_san)
            local baseline_exit recovery_exit request_exit proxy_before proxy_after upstream_before upstream_after
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == wrong_upstream_san ]] || return 80
            mapping_assert_identity_load "$dir" || return 80
            [[ -f $dir/control/unique-commit && ! -L $dir/control/unique-commit && $MPA_UNIQUE_COMMIT == "$(cat "$dir/control/unique-commit")" ]] || return 80
            for snapshot in tls-layer.tsv baseline.exit recovery.exit request.exit proxy.before proxy.after proxy.recovered upstream.before upstream.after connect.baseline.new connect.failed.new connect.recovered.new request.failed.log leaf.original leaf.wrong leaf.restored refs.expected refs.actual head.expected head.actual fsck.exit; do
                [[ -f $dir/$snapshot && ! -L $dir/$snapshot ]] || return 80
            done
            mapping_tls_layer_accept "$case_name" "$dir/tls-layer.tsv" || return 1
            baseline_exit=$(mapping_assert_uint_file "$dir/baseline.exit") || return 80
            recovery_exit=$(mapping_assert_uint_file "$dir/recovery.exit") || return 80
            request_exit=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            proxy_before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            proxy_after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            [[ $baseline_exit == 0 && $recovery_exit == 0 ]] || return 80
            (( request_exit > 0 && proxy_after > proxy_before && upstream_after > upstream_before )) || return 1
            [[ $(mapping_assert_uint_file "$dir/proxy.recovered") -gt $proxy_after ]] || return 1
            cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 80
            ! cmp -s "$dir/leaf.original" "$dir/leaf.wrong" || return 1
            mapping_profile_load "$MAPPING_PROFILE" || return 80
            mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.failed.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            [[ $request_exit == 1 ]] || return 1
            mapping_upstream_san_git_failure "$dir/request.failed.log" || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            mapping_assert_refs_match "$dir" || return 80
            mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 80
            mapping_assert_refs_contain "$dir/refs.actual" "$MPA_UNIQUE_COMMIT" || return 80
            mapping_assert_head_match "$dir" || return 80
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 80
            MAPPING_ASSERT_REJECT_LAYER=tls-upstream
            return 0
            ;;
        *)
            mapping_assert_require_files "$dir" || return "$MAPPING_ASSERT_FIXTURE"
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
    mapping_assert_generation "$kind" || return "$MAPPING_ASSERT_FIXTURE"
    generation=$MAPPING_ASSERT_GENERATION
    mapping_assert_prepare_dir "$dir" || return "$MAPPING_ASSERT_FIXTURE"
    local MAPPING_INPUT_ROOT=${IT_CONTROL_DIR%/control}
    # 证据目录局部化：只在本次调用可见；返回后外层值必须保持不变，否则映射组之后的其它
    # 分组会把证据写进映射场景的嵌套目录，主成功/清理失败校验被静默跳过。
    local IT_EVIDENCE_DIR=$dir
    local IT_CONTROL_DIR=${IT_CONTROL_DIR:-$dir/control}
    local RESOURCE_LEDGER_DIR=${RESOURCE_LEDGER_DIR:-$IT_CONTROL_DIR/resources}
    if mapping_scenario_evidence "$kind" "$scenario" "$generation" "$dir"; then
        :
    else
        rc=$?
        mapping_scenario_release "$kind" "$scenario" "$generation" "$dir" || true
        MAPPING_ASSERT_CASE='' MAPPING_PROXY_RUN_ID=''
        [[ $rc == "$MAPPING_ASSERT_FAIL" ]] || rc="$MAPPING_ASSERT_FIXTURE"
        return "$rc"
    fi
    if mapping_negative_rejected "$case_name" "$kind" "$dir"; then
        rc=0
    else
        rc=$?
        [[ $rc == "$MAPPING_ASSERT_FIXTURE" ]] || rc="$MAPPING_ASSERT_FAIL"
    fi
    printf '%s\n' "${MAPPING_ASSERT_REJECT_LAYER:-none}" > "$dir/reject.layer" || rc="$MAPPING_ASSERT_FIXTURE"
    if [[ ${MAPPING_ASSERT_DNS_MODE:-none} == upstream ]]; then
        mapping_scenario_dns_restore "$kind" "$scenario" "$dir" || rc="$MAPPING_ASSERT_FIXTURE"
    fi
    MAPPING_DNS_FAKE_HOST='' MAPPING_DNS_FAKE_IP=''
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
        wrong_proxy_ca) MAPPING_ASSERT_SNAPSHOT_MODE=none ;;
        wrong_proxy_san) MAPPING_ASSERT_SNAPSHOT_MODE=none ;;
        wrong_upstream_ca) MAPPING_ASSERT_SNAPSHOT_MODE=valid ;;
        wrong_upstream_san) MAPPING_ASSERT_SNAPSHOT_MODE=none ;;
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

# 写入 TLS 失败层证据：代理证书错误不得产生 CONNECT，上游证书错误必须已有 CONNECT。
mapping_tls_layer_write() {
    local case_name=${1:-} dir=${2:-} before after request_exit layer expected
    [[ -n $case_name && -n $dir && -d $dir ]] || return "$MAPPING_ASSERT_FIXTURE"
    before=$(mapping_proxy_baseline_total "$dir/proxy.before") || return "$MAPPING_ASSERT_FIXTURE"
    after=$(mapping_proxy_baseline_total "$dir/proxy.after") || return "$MAPPING_ASSERT_FIXTURE"
    request_exit=$(mapping_assert_uint_file "$dir/sync.exit") || return "$MAPPING_ASSERT_FIXTURE"
    (( request_exit != 0 )) || return "$MAPPING_ASSERT_FIXTURE"
    layer=$(mapping_proxy_layer_verdict "$before" "$after" "$request_exit") || return "$MAPPING_ASSERT_FIXTURE"
    case "$case_name" in
        wrong_proxy_ca|wrong_proxy_san) expected=outer-failure ;;
        wrong_upstream_ca|wrong_upstream_san) expected=inner-failure ;;
        *) return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
    [[ $layer == "$expected" ]] || return "$MAPPING_ASSERT_FIXTURE"
    {
        printf 'case\t%s\n' "$case_name"
        printf 'layer\t%s\n' "$layer"
        printf 'connect_delta\t%s\n' "$((after - before))"
        printf 'request_exit\t%s\n' "$request_exit"
    } > "$dir/tls-layer.tsv.tmp" || return "$MAPPING_ASSERT_FIXTURE"
    mv -- "$dir/tls-layer.tsv.tmp" "$dir/tls-layer.tsv" || return "$MAPPING_ASSERT_FIXTURE"
    return 0
}

# 严格验收 TLS 分层证据，拒绝缺项、重复项、未知项和错误的 CONNECT 增量。
mapping_tls_layer_accept() {
    local case_name=${1:-} file=${2:-} key value
    local seen_case='' seen_layer='' seen_delta='' seen_exit=''
    [[ -n $case_name && -f $file && ! -L $file && -r $file ]] || return 1
    while IFS=$'\t' read -r key value || [[ -n $key ]]; do
        [[ -n $key && -n $value ]] || return 1
        case "$key" in
            case) [[ -z $seen_case ]] || return 1; seen_case=$value ;;
            layer) [[ -z $seen_layer ]] || return 1; seen_layer=$value ;;
            connect_delta) [[ -z $seen_delta ]] || return 1; seen_delta=$value ;;
            request_exit) [[ -z $seen_exit ]] || return 1; seen_exit=$value ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ $seen_case == "$case_name" && $seen_exit =~ ^[1-9][0-9]*$ && $seen_delta =~ ^[0-9]+$ ]] || return 1
    case "$case_name" in
        wrong_proxy_ca|wrong_proxy_san) [[ $seen_layer == outer-failure && $seen_delta == 0 ]] ;;
        wrong_upstream_ca|wrong_upstream_san) [[ $seen_layer == inner-failure && $seen_delta -gt 0 ]] ;;
        *) return 1 ;;
    esac
}

# 负例默认缺陷：产品运行后施加的缺陷（额外网络附件）。
mapping_negative_apply() {
    local kind=${1:-} scenario=${2:-} dir=${3:-} product=${4:-}
    case "${MAPPING_ASSERT_CASE:-}" in
        isolation)
            mapping_isolation_check "$product" "$MAPPING_ASSERT_GENERATION" "$MAPPING_PROFILE" \
                || return "$MAPPING_ASSERT_FIXTURE"
            printf 'isolation\tPASS\n' > "$dir/isolation.tsv" || return "$MAPPING_ASSERT_FIXTURE"
            ;;
        '') return 0 ;;
        missing-map|invalid-map|dns-false-green|unreachable-map-system) return 0 ;;
        wrong_proxy_ca|wrong_proxy_san|wrong_upstream_ca|wrong_upstream_san) return 0 ;;
        *) return "$MAPPING_ASSERT_FIXTURE" ;;
    esac
    return 0
}

# 额外网络附件：把产品接到第二个网络，配置审计必须拒绝该隔离破坏。
# ledger 必须在 dir 赋值之后展开：同一行声明会让 $dir 在 set -u 下取到未绑定的外层变量。
mapping_negative_extra_network() {
    local dir=${1:-} product=${2:-} name ledger
    [[ -n $dir && -n $product ]] || return 1
    ledger=$dir/control/resources
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

# 全量验收汇总判定：字段 failures/fixture_failures/deferred/primary_exit/cleanup_exit/residual_count
# 必须为 0；mapping_fallback/mapping_direct/system_fallback/system_direct/dns_negatives/tls_negatives/
# isolation_negatives 必须为 PASS；缺项、重复键、未知形状或非约定取值一律返回 1。
# 仅接受同目录中由 mapping_finalize 发布、并与矩阵和本轮输入绑定的最终汇总。
mapping_full_accept() {
    local file=${1:-} line key value dir receipt run='' manifest='' input='' name digest actual
    local -A seen=()
    local -a zero_fields=(failures fixture_failures deferred primary_exit cleanup_exit residual_count)
    local -a pass_fields=(mapping_fallback mapping_direct system_fallback system_direct
        dns_negatives tls_negatives isolation_negatives host_unchanged)
    zero_fields+=(carrier_cleanup_exit carrier_residual_count)
    [[ -n $file && -f $file && ! -L $file && -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* ]] || return 1
        [[ $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*}
        value=${line#*$'\t'}
        [[ -n $key && -n $value && $value != *$'\t'* ]] || return 1
        [[ -z ${seen[$key]:-} ]] || return 1
        seen[$key]=$value
    done < "$file"
    for key in "${zero_fields[@]}"; do
        [[ ${seen[$key]:-} == 0 ]] || return 1
    done
    for key in "${pass_fields[@]}"; do
        [[ ${seen[$key]:-} == PASS ]] || return 1
    done
    [[ ${#seen[@]} == 16 ]] || return 1
    [[ ${file##*/} == mapping-full-summary.tsv ]] || return 1
    dir=${file%/*}
    receipt=$dir/mapping-full-finalized.tsv
    [[ -d $dir && ! -L $dir && -f $receipt && ! -L $receipt && -r $receipt ]] || return 1
    seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* && $line != *$'\r'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ $value =~ ^[[:xdigit:]]{64}$ && -z ${seen[$key]:-} ]] || return 1
        case $key in summary|matrix|input) ;; *) return 1 ;; esac
        seen[$key]=$value
    done < "$receipt"
    [[ ${#seen[@]} == 3 ]] || return 1
    for name in summary matrix input; do
        case $name in
            summary) actual=$file ;;
            matrix) actual=$dir/mapping-negative-matrix.tsv ;;
            input) actual=$dir/mapping-run-input.tsv ;;
        esac
        [[ -f $actual && ! -L $actual && -r $actual ]] || return 1
        digest=$(sha256sum "$actual") || return 1
        [[ ${digest%% *} == "${seen[$name]}" ]] || return 1
    done
    seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* && $line != *$'\r'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -n $value && $value != *$'\t'* && -z ${seen[$key]:-} ]] || return 1
        case $key in
            run_id) run=$value ;;
            manifest_sha256) manifest=$value ;;
            input_sha256) input=$value ;;
            *) return 1 ;;
        esac
        seen[$key]=1
    done < "$dir/mapping-run-input.tsv"
    [[ ${#seen[@]} == 3 ]] || return 1
    mapping_negative_matrix_accept "$dir/mapping-negative-matrix.tsv" "$run" "$manifest" "$input" || return 1
    return 0
}
mapping_isolation_snapshot_receipt_accept() {
    local sub=$1 stage=$2 generation=$3 network_id=$4 profile_sha256=$5 expected_seq=$6 target=$7 receipt=$1/$2.receipt
    local seq rules_sha witness_sha root=${IT_CONTROL_DIR%/control}
    [[ -f $receipt && ! -L $receipt && -r $receipt && -s $receipt ]] || return 80
    [[ $(wc -l < "$receipt") == 7 ]] || return 80
    seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$receipt")
    rules_sha=$(awk -F '\t' '$1 == "rules_sha256" {print $2}' "$receipt")
    witness_sha=$(awk -F '\t' '$1 == "witness_sha256" {print $2}' "$receipt")
    [[ $seq =~ ^[1-9][0-9]*$ && $rules_sha =~ ^[0-9a-f]{64}$ && $witness_sha =~ ^[0-9a-f]{64}$ ]] || return 80
    [[ $(cat "$receipt") == "$(printf 'target\t%s\nseq\t%s\ngeneration\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\nrules_sha256\t%s\nwitness_sha256\t%s' \
        "$target" "$seq" "$generation" "$network_id" "$profile_sha256" "$rules_sha" "$witness_sha")" ]] || return 1
    [[ $seq == "$expected_seq" ]] || return 1
    [[ -n ${IT_CONTROL_DIR:-} && $root != "$IT_CONTROL_DIR" && -f $root/mapping-snapshot-$seq.receipt && ! -L $root/mapping-snapshot-$seq.receipt && -r $root/mapping-snapshot-$seq.receipt ]] || return 80
    cmp -s "$receipt" "$root/mapping-snapshot-$seq.receipt" || return 1
    [[ $(sha256sum "$sub/$stage.rules" | cut -d' ' -f1) == "$rules_sha" && \
        $(sha256sum "$sub/$stage.witness" | cut -d' ' -f1) == "$witness_sha" ]] || return 1
    return 0
}


mapping_isolation_probe_command_accept() {
    local sub=$1 kind=$2 key=$3 generation=$4 network=$5 before=$6 after=$7 product=${8:-} file=$1/$2/command.tsv
    local spec proto port dest token command status raw_sha
    local -a argv
    [[ -f $file && ! -L $file && -s $file ]] || return 80
    status=$(mapping_assert_uint_file "$sub/$kind/raw.exit") || return 80
    raw_sha=$(sha256sum "$sub/$kind/raw.log") || return 80
    raw_sha=${raw_sha%% *}
    spec=$(mapping_witness_spec "$key") || return 80
    IFS=$'\t' read -r proto port dest <<< "$spec"
    token="$MPA_RUN_ID-$generation-$key"
    if [[ $kind == negative ]]; then
        case $key in
            dns-*) [[ $key != dns-udp ]] || proto=+notcp; [[ $key != dns-tcp ]] || proto=+tcp
                argv=(exec "gm-$MPA_RUN_ID-witness" dig +time=1 +tries=1 "$proto" "@$dest" "$token.invalid" A) ;;
            *) [[ $key != host-input ]] || port=49383
                argv=(exec "gm-$MPA_RUN_ID-witness" sh -c "printf '%s' '$token' | busybox nc -w 2 '$dest' '$port'") ;;
        esac
    else
        case $key in
            dns-udp) argv=(exec "$product" timeout 4 busybox nslookup "$MPA_RUN_ID-$generation.invalid" "$dest") ;;
            dns-tcp) argv=(exec "$(sed -n '8s/^arg\t//p' "$file")" dig +time=1 +tries=1 +tcp "@$dest" "$MPA_RUN_ID-$generation.invalid" A)
                [[ ${argv[1]} =~ ^[0-9a-f]{64}$ ]] || return 1
                [[ $(cat "$sub/probe.log") == *"TCP_DNS_SHARED_NETNS_TOOL=${argv[1]} PRODUCT=$product NOT_PRODUCT_DIRECT_TCP=1"* ]] || return 1 ;;
            *) argv=(exec "$product" curl --noproxy '*' --connect-timeout 2 --max-time 3 "http://$dest:$port/") ;;
        esac
    fi
    command=$(printf 'generation\t%s\nnetwork_id\t%s\ntarget\t%s\nseq_before\t%s\nexit\t%s\nraw_sha256\t%s\n' "$generation" "$network" "$key" "$before" "$status" "$raw_sha")
    command+=$'\n'"$(printf 'arg\t%s\n' "${argv[@]}")"
    command+=$'\n'"$(printf 'seq_after\t%s' "$after")"
    [[ $(cat "$file") == "$command" ]] || return 1
    [[ $before == "$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/$([[ $kind == negative ]] && printf calibration.after || printf before).receipt")" ]] || return 1
    [[ $after == "$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/$([[ $kind == negative ]] && printf negative || printf after).receipt")" ]] || return 1
}
mapping_isolation_raw_log_accept() {
    local sub=$1 kind=$2
    [[ -f $sub/$kind/raw.log && ! -L $sub/$kind/raw.log && -f $sub/$kind.log && ! -L $sub/$kind.log ]] || return 80
    cmp -s "$sub/$kind/raw.log" "$sub/$kind.log" || return 1
}

mapping_isolation_tcp_dns_raw_log_accept() {
    local sub=$1 tool=$2 product=$3 header
    [[ -f $sub/probe/raw.log && ! -L $sub/probe/raw.log && -f $sub/probe.log && ! -L $sub/probe.log ]] || return 80
    header=$(printf 'TCP_DNS_SHARED_NETNS_TOOL=%s PRODUCT=%s NOT_PRODUCT_DIRECT_TCP=1\n' "$tool" "$product")
    head -c "$((${#header} + 1))" "$sub/probe.log" | cmp -s - <(printf '%s\n' "$header") || return 1
    tail -n +2 "$sub/probe.log" | cmp -s - "$sub/probe/raw.log" || return 1
}

mapping_isolation_product_registration_accept() {
    local product_id=$1 run=$2 scenario=$3 ledger=$4 generation=$5 file=$4/ledger.tsv
    local seq event kind identity entry_run entry_scenario role hash digest path extra matches=0 removed=0 inspect_id inspect_name actual_hash
    [[ -f $file && ! -L $file && -r $file ]] || return 80
    while IFS=$'\t' read -r seq event kind identity entry_run entry_scenario role hash digest path extra; do
        [[ $kind == container && $identity == "$product_id" ]] || continue
        case $event in
            register)
                matches=$((matches + 1))
                [[ $entry_run == "$run" && $entry_scenario == "$scenario" && $role == product ]] || return 1
                [[ $seq =~ ^[1-9][0-9]*$ && -n $path && -f $path && ! -L $path && -r $path ]] || return 80
                [[ $path == "$ledger/objects/$seq-container.json" ]] || return 1
                jq -e . "$path" >/dev/null 2>&1 || return 80
                inspect_id=$(jq -r 'if type == "array" and length == 1 then .[0].Id // empty else empty end' "$path") || return 80
                inspect_name=$(jq -r '.[0].Name // empty' "$path") || return 80
                [[ $inspect_id == "$product_id" && $inspect_name == "/gm-$run-$generation-product" ]] || return 1
                actual_hash=$(cat "$path") || return 80
                actual_hash=$(printf '%s' "$actual_hash" | sha256sum) || return 80
                [[ $hash =~ ^[0-9a-f]{64}$ && $hash == "${actual_hash%% *}" && $digest == "$product_id" ]] || return 1
                jq -e --arg run "$run" --arg scenario "$scenario" \
                    '.[0].Config.Labels["gitdaemon.run"] == $run and .[0].Config.Labels["gitdaemon.scenario"] == $scenario and .[0].Config.Labels["gitdaemon.role"] == "product"' \
                    "$path" >/dev/null 2>&1 || return 1
                ;;
            removed)
                [[ $matches == 1 && $removed == 0 && $entry_run == "$run" && $entry_scenario == "$scenario" && $role == product && $hash == "${actual_hash%% *}" && $digest == "$product_id" && -z $path ]] || return 1
                removed=1
                ;;
        esac
    done < "$file"
    [[ $matches == 1 && $removed == 1 ]] || return 1
}

mapping_negative_case_evidence_accept() {
    local case_id=${1:-} run=${2:-} scenario=${3:-} generation=${4:-} manifest=${5:-} input=${6:-} dir=${7:-}
    local request baseline recovery baseline_before baseline_after before after recovered upstream_before upstream_after name kind dial_baseline_before dial_baseline dial_recovered ca_before ca_after ca_recovered key sub wb wa cb ca seq_before seq_after spec proto port dest negative_raw probe_raw stopped restored product_id
    [[ -d $dir && ! -L $dir ]] || return 80
    mapping_assert_identity_load "$dir" || return 80
    [[ $MPA_RUN_ID == "$run" && $MPA_SCENARIO == "$scenario" && $MPA_GENERATION == "$generation" \
        && $MPA_MANIFEST_SHA256 == "$manifest" && $MPA_INPUT_SHA256 == "$input" ]] || return 80
    case $case_id in
        missing-map/fallback|missing-map/direct)
            kind=${case_id#missing-map/}
            [[ $scenario == "mapping-$kind-missing-map" ]] || return 80
            for name in validator.tsv validator.log sync.log sync.exit dns.txt proxy.before proxy.after upstream.before upstream.after; do
                [[ -f $dir/$name && ! -L $dir/$name && -r $dir/$name && -s $dir/$name ]] || return 80
            done
            [[ -f $dir/control/snapshot.content && ! -L $dir/control/snapshot.content && -r $dir/control/snapshot.content ]] || return 80
            [[ $(cat "$dir/validator.tsv") =~ ^snapshot$'\t'(absent|present)$'\n'resolve_count$'\t'[0-9]+$ ]] || return 80
            [[ ! -s $dir/control/snapshot.content && $(cat "$dir/validator.tsv") == $'snapshot\tabsent\nresolve_count\t0' ]] || return 1
            grep -Fq '无地址快照，使用系统 DNS' "$dir/validator.log" || return 1
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            request=$(mapping_assert_uint_file "$dir/sync.exit") || return 80
            (( request > 0 )) || return 1
            before=$(mapping_proxy_baseline_total "$dir/proxy.before") || return 80
            after=$(mapping_proxy_baseline_total "$dir/proxy.after") || return 80
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            [[ -f $dir/connect.log && ! -L $dir/connect.log && -r $dir/connect.log ]] || return 80
            (( upstream_after == upstream_before )) && [[ ! -s $dir/connect.log ]] || return 1
            if [[ $kind == direct ]]; then
                (( after == before )) || return 1
                [[ -z $(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_PROXY_FAIL") ]] || return 1
            else
                (( after > before )) || return 1
                [[ -n $(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_PROXY_FAIL") ]] || return 1
            fi
            grep -Fq '无地址快照，使用系统 DNS' "$dir/sync.log" || return 1
            grep -Fq '传输失败：直连系统 DNS' "$dir/sync.log" || return 1
            [[ $(awk -v url="https://$MAPPING_UPSTREAM_HOST/$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO.git/" '
                /^fatal: / {
                    fatal++
                    if ($0 == "fatal: unable to access '\''" url "'\'': Could not resolve host: github.com") matched++
                }
                END {print fatal == 1 && matched == 1 ? 1 : 0}
            ' "$dir/sync.log") == 1 ]] || return 1
            for name in refs.actual head.actual head.exit fsck.exit; do
                [[ -f $dir/$name && ! -L $dir/$name && -r $dir/$name ]] || return 80
            done
            [[ ! -s $dir/refs.actual && $(cat "$dir/head.actual") == HEAD ]] || return 1
            [[ $(mapping_assert_uint_file "$dir/head.exit") == 128 ]] || return 1
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_MAPPING") && -z $(mapping_assert_log_line "$dir/sync.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            mapping_assert_dns_file "$dir/dns.txt" || return 1
            return 0
            ;;
        isolation/*)
            key=${case_id#isolation/}
            mapping_witness_key_valid "$key" || return 80
            sub=$dir/isolation/$key
            [[ -d $sub && ! -L $sub ]] || return 80
            for name in binding.tsv calibration.before.rules calibration.before.witness calibration.before.receipt calibration.after.rules calibration.after.witness calibration.after.receipt negative.tsv negative.exit negative.log negative.rules negative.witness negative.receipt listener.pid listener.restored.pid listener.stopped.state listener.restored.state negative.target.tsv probe.target.tsv negative/raw.exit negative/raw.log negative/command.tsv probe/raw.exit probe/raw.log probe/command.tsv seq.before seq.after before.rules after.rules before.witness after.witness before.receipt after.receipt probe.log reject.layer; do
                [[ -f $sub/$name && ! -L $sub/$name && -r $sub/$name && -s $sub/$name ]] || return 80
            done
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            [[ $MP_RUN_ID == "$run" && $MP_PROFILE_SHA256 == "$MPA_PROFILE_SHA256" ]] || return 1
            product_id=$(awk -F '\t' '$1 == "product_id" {print $2}' "$sub/binding.tsv")
            [[ $product_id =~ ^[0-9a-f]{64}$ ]] || return 80
            [[ $(cat "$sub/binding.tsv") == "$(printf 'target\t%s\ngeneration\t%s\nnetwork_id\t%s\nprofile_sha256\t%s\nproduct_id\t%s' "$key" "$generation" "$MPA_NETWORK_ID" "$MPA_PROFILE_SHA256" "$product_id")" ]] || return 1
            mapping_isolation_product_registration_accept "$product_id" "$run" "$scenario" "${IT_CONTROL_DIR:-}/resources" "$generation" || return $?
            spec=$(mapping_witness_spec "$key") || return 80
            IFS=$'\t' read -r proto port dest <<< "$spec"
            for name in negative probe; do
                [[ $(cat "$sub/$name.target.tsv") == "$(printf 'target\t%s\nprotocol\t%s\nport\t%s\ndestination\t%s' "$key" "$proto" "$port" "$dest")" ]] || return 1
            done
            stopped=$(cat "$sub/listener.stopped.state") || return 80
            restored=$(cat "$sub/listener.restored.state") || return 80
            [[ $stopped == T && $restored =~ ^[RSDI]$ ]] || return 1
            negative_raw=$(mapping_assert_uint_file "$sub/negative/raw.exit") || return 80
            probe_raw=$(mapping_assert_uint_file "$sub/probe/raw.exit") || return 80
            [[ -s $sub/negative/raw.log && -s $sub/probe/raw.log ]] || return 80
            case $key in
                dns-udp) [[ $negative_raw == 9 && ( $probe_raw == 124 || $probe_raw == 1 ) ]] && grep -aFq 'timed out' "$sub/probe/raw.log" || return 1 ;;
                dns-tcp) [[ $negative_raw == 9 && $probe_raw == 9 ]] && grep -aFq 'no servers could be reached' "$sub/probe/raw.log" || return 1 ;;
                *) (( negative_raw > 0 && probe_raw == 28 )) || return 1 ;;
            esac
            if [[ $key == dns-* ]]; then
                grep -aFq 'no servers could be reached' "$sub/negative/raw.log" || return 1
            else
                { grep -aFq 'refused' "$sub/negative/raw.log" || grep -aFq 'timed out' "$sub/negative/raw.log"; } || return 1
                { grep -aFq 'timed out' "$sub/probe/raw.log" || grep -aFq 'Timeout' "$sub/probe/raw.log"; } || return 1
            fi
            mapping_isolation_raw_log_accept "$sub" negative || return $?
            if [[ $key == dns-tcp ]]; then
                mapping_isolation_tcp_dns_raw_log_accept "$sub" "$(sed -n '8s/^arg\t//p' "$sub/probe/command.tsv")" "$product_id" || return $?
            else
                mapping_isolation_raw_log_accept "$sub" probe || return $?
            fi
            ! grep -aFq 'Error response from daemon:' "$sub/negative/raw.log" && ! grep -aFq 'Error response from daemon:' "$sub/probe/raw.log" || return 1
            [[ $(cat "$sub/negative.tsv") == $'probe_exit\t0' && $(cat "$sub/reject.layer") == policy && -s $sub/negative.log && -s $sub/probe.log ]] || return 1
            request=$(mapping_assert_uint_file "$sub/negative.exit") || return 80
            [[ $request == 0 ]] || return 1
            [[ $(cat "$sub/listener.pid") =~ ^[0-9]+$ && $(cat "$sub/listener.pid") == "$(cat "$sub/listener.restored.pid")" ]] || return 1
            seq_before=$(mapping_assert_uint_file "$sub/seq.before") || return 80
            seq_after=$(mapping_assert_uint_file "$sub/seq.after") || return 80
            (( seq_after > seq_before )) || return 1
            for name in calibration.before calibration.after negative before after; do
                case $name in
                    before) request=$seq_before ;;
                    after) request=$seq_after ;;
                    *) request='' ;;
                esac
                if [[ -z $request ]]; then
                    request=$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/$name.receipt")
                fi
                mapping_isolation_snapshot_receipt_accept "$sub" "$name" "$generation" "$MPA_NETWORK_ID" "$MPA_PROFILE_SHA256" "$request" "$key" || return $?
            done
            local calibration_before_seq calibration_after_seq negative_seq
            calibration_before_seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/calibration.before.receipt")
            calibration_after_seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/calibration.after.receipt")
            negative_seq=$(awk -F '\t' '$1 == "seq" {print $2}' "$sub/negative.receipt")
            (( calibration_before_seq < calibration_after_seq && calibration_after_seq < negative_seq && negative_seq < seq_before )) || return 1
            mapping_isolation_probe_command_accept "$sub" negative "$key" "$generation" "$MPA_NETWORK_ID" "$calibration_after_seq" "$negative_seq" || return $?
            mapping_isolation_probe_command_accept "$sub" probe "$key" "$generation" "$MPA_NETWORK_ID" "$seq_before" "$seq_after" "$product_id" || return $?
            wb=$(mapping_witness "$sub/calibration.before.witness") || return 80
            wa=$(mapping_witness "$sub/calibration.after.witness") || return 80
            mapping_witness_growth "$wb" "$wa" "$key" || return 1
            wb=$(mapping_witness "$sub/negative.witness") || return 80
            [[ $wb == "$wa" ]] || return 1
            wb=$(mapping_witness "$sub/before.witness") || return 80
            wa=$(mapping_witness "$sub/after.witness") || return 80
            [[ $wb == "$wa" ]] || return 1
            cb=$(mapping_count "$sub/before.rules" "$MAPPING_PROFILE" "$key") || return 80
            ca=$(mapping_count "$sub/after.rules" "$MAPPING_PROFILE" "$key") || return 80
            (( ca > cb )) || return 1
            return 0
            ;;
        wrong_proxy_ca)
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == "$case_id" ]] || return 80
            for name in tls-layer.tsv baseline.exit recovery.exit request.exit baseline.before baseline.after proxy.before proxy.after proxy.recovered connect.initial connect.before connect.baseline connect.baseline.new connect.log connect.recovered connect.recovered.new request.baseline.log request.recovery.log request.failed.log upstream.before upstream.after; do
                [[ -f $dir/$name && ! -L $dir/$name ]] || return 80
            done
            baseline=$(mapping_assert_uint_file "$dir/baseline.exit") || return 80
            recovery=$(mapping_assert_uint_file "$dir/recovery.exit") || return 80
            request=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            baseline_before=$(mapping_assert_uint_file "$dir/baseline.before") || return 80
            baseline_after=$(mapping_assert_uint_file "$dir/baseline.after") || return 80
            before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            recovered=$(mapping_assert_uint_file "$dir/proxy.recovered") || return 80
            [[ $baseline == 0 && $recovery == 0 ]] || return 80
            (( baseline_after > baseline_before && before == baseline_after && request > 0 && recovered > after )) || return 1
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.baseline.log" || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.recovery.log" || return 1
            mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            [[ $(wc -l < "$dir/connect.baseline") -gt $(wc -l < "$dir/connect.initial") ]] || return 1
            [[ $(wc -l < "$dir/connect.recovered") -gt $(wc -l < "$dir/connect.log") ]] || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.initial") + 1 ))" "$dir/connect.baseline" | cmp -s - "$dir/connect.baseline.new" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" | cmp -s - "$dir/connect.recovered.new" || return 1
            mapping_tls_layer_accept "$case_id" "$dir/tls-layer.tsv" || return 1
            [[ $(awk -F '\t' '$1 == "request_exit" {print $2}' "$dir/tls-layer.tsv") == "$request" ]] || return 1
            (( before == after )) || return 1
            cmp -s "$dir/connect.before" "$dir/connect.log" || return 1
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            [[ $upstream_before == "$upstream_after" ]] || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            grep -Eqi 'certificate|issuer|SSL' "$dir/request.failed.log" || return 1
            return 0
            ;;
        wrong_upstream_ca)
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == "$case_id" ]] || return 80
            [[ -f $dir/control/unique-commit && ! -L $dir/control/unique-commit && -r $dir/control/unique-commit ]] || return 80
            for name in tls-layer.tsv baseline.exit recovery.exit request.exit baseline.before baseline.after proxy.before proxy.after proxy.recovered upstream.baseline.before upstream.baseline upstream.before upstream.after upstream.recovered ca.before.sha256 ca.after.sha256 ca.recovered.sha256 connect.before connect.baseline connect.baseline.new connect.log connect.failed.new connect.recovered connect.recovered.new request.baseline.log request.recovery.log request.failed.log refs.expected refs.actual head.expected head.actual fsck.exit; do
                [[ -f $dir/$name && ! -L $dir/$name && -r $dir/$name ]] || return 80
            done
            baseline=$(mapping_assert_uint_file "$dir/baseline.exit") || return 80
            recovery=$(mapping_assert_uint_file "$dir/recovery.exit") || return 80
            request=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            baseline_before=$(mapping_assert_uint_file "$dir/baseline.before") || return 80
            baseline_after=$(mapping_assert_uint_file "$dir/baseline.after") || return 80
            before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            recovered=$(mapping_assert_uint_file "$dir/proxy.recovered") || return 80
            dial_baseline_before=$(mapping_assert_uint_file "$dir/upstream.baseline.before") || return 80
            dial_baseline=$(mapping_assert_uint_file "$dir/upstream.baseline") || return 80
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            dial_recovered=$(mapping_assert_uint_file "$dir/upstream.recovered") || return 80
            local ca_before ca_after ca_recovered
            ca_before=$(cat "$dir/ca.before.sha256") || return 80
            ca_after=$(cat "$dir/ca.after.sha256") || return 80
            ca_recovered=$(cat "$dir/ca.recovered.sha256") || return 80
            [[ $ca_before =~ ^[0-9a-f]{64}$ && $ca_after =~ ^[0-9a-f]{64}$ && $ca_recovered =~ ^[0-9a-f]{64}$ ]] || return 80
            [[ $baseline == 0 && $recovery == 0 ]] || return 80
            [[ $(cat "$dir/control/unique-commit") == "$MPA_UNIQUE_COMMIT" ]] || return 1
            (( baseline_after > baseline_before && before == baseline_after && dial_baseline > dial_baseline_before && upstream_before >= dial_baseline && request > 0 && after > before && upstream_after > upstream_before && recovered > after && dial_recovered > upstream_after )) || return 1
            [[ $ca_before != "$ca_after" && $ca_before == "$ca_recovered" ]] || return 1
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.baseline.log" || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.recovery.log" || return 1
            mapping_assert_connect_legal "$dir/connect.baseline.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.failed.new" "$MP_U" || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            [[ $(wc -l < "$dir/connect.baseline") -gt $(wc -l < "$dir/connect.before") && $(wc -l < "$dir/connect.log") -gt $(wc -l < "$dir/connect.baseline") && $(wc -l < "$dir/connect.recovered") -gt $(wc -l < "$dir/connect.log") ]] || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.before") + 1 ))" "$dir/connect.baseline" | cmp -s - "$dir/connect.baseline.new" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.baseline") + 1 ))" "$dir/connect.log" | cmp -s - "$dir/connect.failed.new" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" | cmp -s - "$dir/connect.recovered.new" || return 1
            mapping_tls_layer_accept "$case_id" "$dir/tls-layer.tsv" || return 1
            [[ $(awk -F '\t' '$1 == "request_exit" {print $2}' "$dir/tls-layer.tsv") == "$request" && $(awk -F '\t' '$1 == "connect_delta" {print $2}' "$dir/tls-layer.tsv") == "$((after - before))" ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") && -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            mapping_upstream_ca_git_diagnostic "$dir/request.failed.log" || return 1
            mapping_assert_refs_match "$dir" || return 1
            mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_refs_contain "$dir/refs.actual" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_head_match "$dir" || return 1
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 1
            return 0
            ;;
        wrong_proxy_san)
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == "$case_id" ]] || return 80
            [[ -f $dir/control/unique-commit && ! -L $dir/control/unique-commit ]] || return 80
            for name in tls-layer.tsv request.exit baseline.before proxy.before proxy.after proxy.recovered connect.baseline connect.before connect.log connect.recovered connect.recovered.new connect.health.before connect.health.after connect.health.new leaf.original leaf.wrong leaf.restored cert.original cert.wrong cert.restored key.original key.wrong key.restored health.baseline health.recovered hostname.log request.failed.log request.log refs.expected refs.actual head.expected head.actual fsck.exit; do
                [[ -f $dir/$name && ! -L $dir/$name && -r $dir/$name ]] || return 80
            done
            baseline_before=$(mapping_assert_uint_file "$dir/baseline.before") || return 80
            before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            recovered=$(mapping_assert_uint_file "$dir/proxy.recovered") || return 80
            request=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            [[ $(cat "$dir/control/unique-commit") == "$MPA_UNIQUE_COMMIT" ]] || return 1
            (( baseline_before > 0 && before >= baseline_before && request > 0 && after == before && recovered > after )) || return 1
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            mapping_tls_layer_accept "$case_id" "$dir/tls-layer.tsv" || return 1
            [[ $(awk -F '\t' '$1 == "request_exit" {print $2}' "$dir/tls-layer.tsv") == "$request" ]] || return 1
            cmp -s "$dir/connect.before" "$dir/connect.log" || return 1
            [[ -s $dir/connect.baseline ]] || return 1
            mapping_assert_connect_legal "$dir/connect.baseline" "$MP_U" || return 1
            [[ $(wc -c < "$dir/connect.recovered") -gt $(wc -c < "$dir/connect.health.after") ]] || return 1
            head -c "$(wc -c < "$dir/connect.health.after")" "$dir/connect.recovered" | cmp -s - "$dir/connect.health.after" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.health.after") + 1 ))" "$dir/connect.recovered" | cmp -s - "$dir/connect.recovered.new" || return 1
            mapping_assert_connect_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            [[ $(wc -c < "$dir/connect.health.after") -gt $(wc -c < "$dir/connect.health.before") ]] || return 1
            head -c "$(wc -c < "$dir/connect.health.before")" "$dir/connect.health.after" | cmp -s - "$dir/connect.health.before" || return 1
            mapping_assert_connect_all_legal "$dir/connect.recovered.new" "$MP_U" || return 1
            head -n "$(wc -l < "$dir/connect.health.before")" "$dir/connect.recovered" | cmp -s - "$dir/connect.health.before" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.health.before") + 1 ))" "$dir/connect.health.after" | cmp -s - "$dir/connect.health.new" || return 1
            mapping_assert_connect_legal "$dir/connect.health.new" "$MP_U" || return 1
            mapping_assert_connect_all_legal "$dir/connect.health.new" "$MP_U" || return 1
            [[ $(cat "$dir/leaf.original") != "$(cat "$dir/leaf.wrong")" ]] || return 1
            cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 1
            [[ $(cat "$dir/cert.original") != "$(cat "$dir/cert.wrong")" && $(cat "$dir/key.original") != "$(cat "$dir/key.wrong")" ]] || return 1
            cmp -s "$dir/cert.original" "$dir/cert.restored" || return 1
            cmp -s "$dir/key.original" "$dir/key.restored" || return 1
            [[ -s $dir/health.baseline && -s $dir/health.recovered ]] || return 1
            grep -Eqi 'hostname|subject alternative|certificate.*(match|name)' "$dir/hostname.log" || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY_FAIL" "$dir/request.failed.log" || return 1
            [[ $(awk -v url="https://$MAPPING_UPSTREAM_HOST/$MAPPING_UPSTREAM_OWNER/$MAPPING_UPSTREAM_REPO.git/" -v host="$MAPPING_PROXY_HOST" '
                /fatal: / {
                    rest = $0
                    while (index(rest, "fatal: ")) {
                        fatal++
                        rest = substr(rest, index(rest, "fatal: ") + 7)
                    }
                    if (index($0, "fatal: unable to access '\''" url "'\'': SSL: no alternative certificate subject name matches target host name '\''" host "'\''")) valid++
                }
                END { print fatal == 1 && valid == 1 ? 1 : 0 }
            ' "$dir/request.failed.log") == 1 ]] || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") && -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.log" || return 1
            mapping_assert_refs_match "$dir" || return 1
            mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_refs_contain "$dir/refs.actual" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_head_match "$dir" || return 1
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 1
            return 0
            ;;
        wrong_upstream_san)
            [[ -f $dir/case.tsv && ! -L $dir/case.tsv && $(cat "$dir/case.tsv") == "$case_id" ]] || return 80
            [[ -f $dir/control/unique-commit && ! -L $dir/control/unique-commit && -r $dir/control/unique-commit ]] || return 80
            for name in tls-layer.tsv baseline.exit recovery.exit request.exit baseline.before baseline.after proxy.before proxy.after proxy.recovered upstream.baseline.before upstream.baseline upstream.before upstream.after upstream.recovered connect.before connect.baseline connect.baseline.new connect.log connect.failed.new connect.recovered connect.recovered.new request.baseline.log request.recovery.log request.failed.log leaf.original leaf.wrong leaf.restored cert.original cert.wrong cert.restored key.original key.wrong key.restored refs.expected refs.actual head.expected head.actual fsck.exit; do
                [[ -f $dir/$name && ! -L $dir/$name && -r $dir/$name ]] || return 80
            done
            baseline=$(mapping_assert_uint_file "$dir/baseline.exit") || return 80
            recovery=$(mapping_assert_uint_file "$dir/recovery.exit") || return 80
            request=$(mapping_assert_uint_file "$dir/request.exit") || return 80
            baseline_before=$(mapping_assert_uint_file "$dir/baseline.before") || return 80
            baseline_after=$(mapping_assert_uint_file "$dir/baseline.after") || return 80
            before=$(mapping_assert_uint_file "$dir/proxy.before") || return 80
            after=$(mapping_assert_uint_file "$dir/proxy.after") || return 80
            recovered=$(mapping_assert_uint_file "$dir/proxy.recovered") || return 80
            dial_baseline_before=$(mapping_assert_uint_file "$dir/upstream.baseline.before") || return 80
            dial_baseline=$(mapping_assert_uint_file "$dir/upstream.baseline") || return 80
            upstream_before=$(mapping_assert_uint_file "$dir/upstream.before") || return 80
            upstream_after=$(mapping_assert_uint_file "$dir/upstream.after") || return 80
            dial_recovered=$(mapping_assert_uint_file "$dir/upstream.recovered") || return 80
            [[ $baseline == 0 && $recovery == 0 ]] || return 80
            [[ $(cat "$dir/control/unique-commit") == "$MPA_UNIQUE_COMMIT" ]] || return 1
            (( baseline_after > baseline_before && before == baseline_after && dial_baseline > dial_baseline_before && upstream_before >= dial_baseline && request == 1 && after > before && upstream_after > upstream_before && recovered > after && dial_recovered > upstream_after )) || return 1
            mapping_profile_load "${MAPPING_PROFILE:-}" || return 80
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.baseline.log" || return 1
            grep -Fq "$MAPPING_ASSERT_MARK_PROXY" "$dir/request.recovery.log" || return 1
            mapping_tls_layer_accept "$case_id" "$dir/tls-layer.tsv" || return 1
            [[ $(awk -F '\t' '$1 == "request_exit" {print $2}' "$dir/tls-layer.tsv") == "$request" && $(awk -F '\t' '$1 == "connect_delta" {print $2}' "$dir/tls-layer.tsv") == "$((after - before))" ]] || return 1
            for name in connect.baseline.new connect.failed.new connect.recovered.new; do
                mapping_assert_connect_legal "$dir/$name" "$MP_U" || return 1
                mapping_assert_connect_all_legal "$dir/$name" "$MP_U" || return 1
            done
            [[ $(wc -l < "$dir/connect.baseline") -gt $(wc -l < "$dir/connect.before") && $(wc -l < "$dir/connect.log") -gt $(wc -l < "$dir/connect.baseline") && $(wc -l < "$dir/connect.recovered") -gt $(wc -l < "$dir/connect.log") ]] || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.before") + 1 ))" "$dir/connect.baseline" | cmp -s - "$dir/connect.baseline.new" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.baseline") + 1 ))" "$dir/connect.log" | cmp -s - "$dir/connect.failed.new" || return 1
            tail -n "+$(( $(wc -l < "$dir/connect.log") + 1 ))" "$dir/connect.recovered" | cmp -s - "$dir/connect.recovered.new" || return 1
            [[ $(cat "$dir/leaf.original") != "$(cat "$dir/leaf.wrong")" ]] || return 1
            cmp -s "$dir/leaf.original" "$dir/leaf.restored" || return 1
            for name in cert key; do
                [[ $(cat "$dir/$name.original") =~ ^[0-9a-f]{64}$ && $(cat "$dir/$name.wrong") =~ ^[0-9a-f]{64}$ && $(cat "$dir/$name.restored") =~ ^[0-9a-f]{64}$ ]] || return 1
                [[ $(cat "$dir/$name.original") != "$(cat "$dir/$name.wrong")" ]] || return 1
                cmp -s "$dir/$name.original" "$dir/$name.restored" || return 1
            done
            mapping_upstream_san_git_failure "$dir/request.failed.log" || return 1
            [[ -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_MAPPING") && -z $(mapping_assert_log_line "$dir/request.failed.log" "$MAPPING_ASSERT_MARK_SYSTEM") ]] || return 1
            mapping_assert_refs_match "$dir" || return 1
            mapping_assert_refs_contain "$dir/refs.expected" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_refs_contain "$dir/refs.actual" "$MPA_UNIQUE_COMMIT" || return 1
            mapping_assert_head_match "$dir" || return 1
            [[ $(mapping_assert_uint_file "$dir/fsck.exit") == 0 ]] || return 1
            return 0
            ;;
        *) return 80 ;;
    esac
}

# 严格验收 full 的 21 例负例矩阵及其原始证据目录。
mapping_negative_matrix_accept() {
    local file=${1:-} expected_run=${2:-} expected_manifest=${3:-} expected_input=${4:-}
    local line case_id run scenario generation manifest input evidence assertion result want tabs rc
    local -a columns=()
    local -A seen=() isolation_generations=()
    [[ -n $expected_run && -n $expected_manifest && -n $expected_input && -f $file && ! -L $file && -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* ]] || return 1
        tabs=${line//$'\t'/}
        [[ $((${#line} - ${#tabs})) == 8 ]] || return 1
        IFS=$'\t' read -r -a columns <<< "$line"
        [[ ${#columns[@]} == 9 ]] || return 1
        case_id=${columns[0]} run=${columns[1]} scenario=${columns[2]} generation=${columns[3]}
        manifest=${columns[4]} input=${columns[5]} evidence=${columns[6]}
        assertion=${columns[7]} result=${columns[8]}
        [[ -n $case_id && -n $run && -n $scenario && -n $generation && -n $manifest && -n $input && -n $evidence ]] || return 1
        [[ $assertion == 0 && $result == PASS ]] || return 1
        [[ -z ${seen[$case_id]:-} ]] || return 1
        case " $MAPPING_NEGATIVE_CASES " in *" $case_id "*) ;; *) return 1 ;; esac
        [[ $evidence == "${file%/*}/"* && $evidence != *'/../'* && -d $evidence && ! -L $evidence ]] || return 1
        [[ $run == "$expected_run" && $manifest == "$expected_manifest" && $input == "$expected_input" ]] || return 1
        mapping_negative_case_evidence_accept "$case_id" "$run" "$scenario" "$generation" "$manifest" "$input" "$evidence" || { rc=$?; return "$rc"; }
        if [[ $case_id == isolation/* ]]; then
            [[ -z ${isolation_generations[$generation]:-} ]] || return 1
            isolation_generations[$generation]=1
        fi
        seen[$case_id]=1
    done < "$file"
    for want in $MAPPING_NEGATIVE_CASES; do [[ ${seen[$want]:-} == 1 ]] || return 1; done
    [[ ${#seen[@]} == 21 ]]
}

# 合并业务主状态与外层清理状态：主失败优先，主成功时任一清理失败返回 2。
mapping_final_exit() {
    local primary=${1:-} cleanup=${2:-} carrier_cleanup=${3:-}
    [[ $primary =~ ^[0-9]+$ && $cleanup =~ ^[0-9]+$ && $carrier_cleanup =~ ^[0-9]+$ ]] || return 1
    if (( primary != 0 )); then printf '%s\n' "$primary"; return 0; fi
    if (( cleanup != 0 || carrier_cleanup != 0 )); then printf '2\n'; return 0; fi
    printf '0\n'
}

# 载体外层最终汇总：三份状态和完整负例矩阵齐全后才原子发布 16 键结论。
mapping_finalize() {
    local dir=${1:-} guard=${2:-} carrier=${3:-} business matrix output input_file receipt
    local line key value run='' manifest='' input='' status name digest
    local -A seen=()
    business=$dir/mapping-business-summary.tsv
    matrix=$dir/mapping-negative-matrix.tsv
    output=$dir/mapping-full-summary.tsv
    input_file=$dir/mapping-run-input.tsv
    receipt=$dir/mapping-full-finalized.tsv
    [[ -d $dir && ! -L $dir ]] || return 1
    rm -f -- "$output" "$output.tmp" "$receipt" "$receipt.tmp" || return 1
    for status in "$business" "$guard" "$carrier" "$input_file"; do
        [[ -f $status && ! -L $status && -r $status ]] || return 1
    done
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* && $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -n $value && $value != *$'\t'* && -z ${seen[$key]:-} ]] || return 1
        case "$key" in
            run_id) run=$value ;;
            manifest_sha256) manifest=$value ;;
            input_sha256) input=$value ;;
            *) return 1 ;;
        esac
        seen[$key]=1
    done < "$input_file"
    [[ ${#seen[@]} == 3 && -n $run && -n $manifest && -n $input ]] || return 1
    seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* && $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -n $value && $value != *$'\t'* && -z ${seen[$key]:-} ]] || return 1
        case "$key" in
            failures|fixture_failures|deferred|primary_exit|cleanup_exit|residual_count) [[ $value == 0 ]] || return 1 ;;
            mapping_fallback|mapping_direct|system_fallback|system_direct|dns_negatives|tls_negatives|isolation_negatives) [[ $value == PASS ]] || return 1 ;;
            *) return 1 ;;
        esac
        seen[$key]=1
    done < "$business"
    [[ ${#seen[@]} == 13 ]] || return 1
    seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* && $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -z ${seen[$key]:-} && $value == 0 ]] || return 1
        case "$key" in primary_exit|cleanup_exit|residual_count) ;; *) return 1 ;; esac
        seen[$key]=1
    done < "$guard"
    [[ ${#seen[@]} == 3 ]] || return 1
    seen=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line && $line != *$'\r'* && $line == *$'\t'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -z ${seen[$key]:-} ]] || return 1
        case "$key" in
            carrier_cleanup_exit|carrier_residual_count) [[ $value == 0 ]] || return 1 ;;
            host_unchanged) [[ $value == PASS ]] || return 1 ;;
            *) return 1 ;;
        esac
        seen[$key]=1
    done < "$carrier"
    [[ ${#seen[@]} == 3 ]] || return 1
    mapping_negative_matrix_accept "$matrix" "$run" "$manifest" "$input" || return 1
    cat -- "$business" > "$output.tmp" || return 1
    cat -- "$carrier" >> "$output.tmp" || return 1
    mv -- "$output.tmp" "$output" || return 1
    for name in summary matrix input; do
        case $name in
            summary) status=$output ;;
            matrix) status=$matrix ;;
            input) status=$input_file ;;
        esac
        digest=$(sha256sum "$status") || return 1
        printf '%s\t%s\n' "$name" "${digest%% *}" >> "$receipt.tmp" || return 1
    done
    mv -- "$receipt.tmp" "$receipt" || return 1
    if ! mapping_full_accept "$output"; then
        rm -f -- "$output" "$receipt"
        return 1
    fi
    return 0
}

integration_business_accept() {
    local file=${1:-}
    local line key value
    local -A seen=()
    [[ ${file##*/} == mapping-business-summary.tsv && -f $file && ! -L $file && -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* && $line != *$'\r'* ]] || return 1
        key=${line%%$'\t'*} value=${line#*$'\t'}
        [[ -n $key && -n $value && $value != *$'\t'* && -z ${seen[$key]:-} ]] || return 1
        case $key in
            failures|fixture_failures|deferred|primary_exit|cleanup_exit|residual_count) [[ $value == 0 ]] || return 1 ;;
            mapping_fallback|mapping_direct|system_fallback|system_direct|dns_negatives|tls_negatives|isolation_negatives) [[ $value == PASS ]] || return 1 ;;
            *) return 1 ;;
        esac
        seen[$key]=1
    done < "$file"
    [[ ${#seen[@]} == 13 ]]
}
