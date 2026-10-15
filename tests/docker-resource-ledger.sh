#!/usr/bin/env bash
# 统一资源登记账本：创建登记、删除回执、双向交叉验证与精确清理。
# 所有 Docker 访问只经过 resource_docker 边界；测试以替身替换该边界而不改动核验逻辑。
# 账本目录为本轮证据控制区，串行追加依赖 VM 既有 flock，本库不在线安装工具。

RESOURCE_KINDS='container network volume'
RESOURCE_LOCK_FD=''
# 显式全局声明：本库可能被函数内 source，数组属性必须跨作用域保留。
declare -gA RESOURCE_LEDGER_ACTIVE=()
declare -gA RESOURCE_LEDGER_REMOVED=()
declare -ga RESOURCE_LEDGER_ORDER=()

# 账本目录：显式设置优先，否则取集成运行证据控制区。
resource_ledger_dir() {
    if [[ -n ${RESOURCE_LEDGER_DIR:-} ]]; then
        printf '%s\n' "$RESOURCE_LEDGER_DIR"
        return 0
    fi
    if [[ -n ${IT_EVIDENCE_DIR:-} ]]; then
        printf '%s\n' "$IT_EVIDENCE_DIR/control/resources"
        return 0
    fi
    return 1
}

# 本轮运行标识：登记记录与 label 枚举共用同一值。
resource_run() {
    printf '%s\n' "${RESOURCE_RUN:-${IT_RUN_ID:-}}"
}

# Docker 外部边界：默认直连命令行，绕过启动包装器以避免删除递归。
resource_docker() {
    command docker "$@"
}

# kind 白名单：只接受容器、网络与卷。
resource_kind_valid() {
    case "${1:-}" in
        container|network|volume) return 0 ;;
        *) return 1 ;;
    esac
}

# 读取所有权 label 的选择器路径：容器在 Config.Labels，网络与卷在 Labels。
resource_label_selector() {
    case "$1" in
        container) printf '%s' '.Config.Labels' ;;
        network|volume) printf '%s' '.Labels' ;;
        *) return 1 ;;
    esac
}

# 读取对象身份：容器与网络用完整 ID，卷用 Name。
resource_inspect_identity() {
    local kind=$1 identity=$2 template
    case "$kind" in
        container|network) template='{{.Id}}' ;;
        volume) template='{{.Name}}' ;;
        *) return 2 ;;
    esac
    resource_docker inspect -f "$template" "$identity" 2>/dev/null
}

# 读取 "run/场景/角色" 三个 label，制表符分隔。
resource_inspect_labels() {
    local kind=$1 identity=$2 selector format
    selector=$(resource_label_selector "$kind") || return 2
    format=$(printf '{{index %s "gitdaemon.run"}}\t{{index %s "gitdaemon.scenario"}}\t{{index %s "gitdaemon.role"}}' \
        "$selector" "$selector" "$selector")
    resource_docker inspect -f "$format" "$identity" 2>/dev/null
}

# 冻结卷身份摘要：CreatedAt、Driver、Mountpoint 与完整 labels 组成。
resource_volume_digest() {
    local identity=$1 raw
    raw=$(resource_docker inspect -f '{{.CreatedAt}}|{{.Driver}}|{{.Mountpoint}}|{{range $k,$v := .Labels}}{{$k}}={{$v}},{{end}}' \
        "$identity" 2>/dev/null) || return 2
    [[ -n $raw ]] || return 2
    printf '%s' "$raw" | sha256sum | cut -d' ' -f1
}

# 创建时完整 inspect 的 SHA-256，作为登记证据保存；不作为容器删除条件。
resource_inspect_hash() {
    local identity=$1 raw
    raw=$(resource_docker inspect "$identity" 2>/dev/null) || return 2
    [[ -n $raw ]] || return 2
    printf '%s' "$raw" | sha256sum | cut -d' ' -f1
}

# 对象是否仍存在；查询失败按不存在处理，由登记回执另行判定。
resource_exists() {
    local kind=$1 identity=$2
    case "$kind" in
        container|network) resource_docker inspect -f '{{.Id}}' "$identity" >/dev/null 2>&1 ;;
        volume) resource_docker inspect -f '{{.Name}}' "$identity" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# 按本轮 label 枚举对象；任一类查询失败即返回 2，绝不解释为空集合。
resource_enumerate() {
    local kind=$1 run=$2
    case "$kind" in
        container) resource_docker ps -aq --filter "label=gitdaemon.run=$run" ;;
        network) resource_docker network ls -q --filter "label=gitdaemon.run=$run" ;;
        volume) resource_docker volume ls -q --filter "label=gitdaemon.run=$run" ;;
        *) return 2 ;;
    esac
}

# 串行化登记：VM 必须已有 flock，缺少时返回 2，绝不在线安装。
resource_lock() {
    local dir=$1
    command -v flock >/dev/null 2>&1 || return 2
    mkdir -p "$dir" || return 2
    exec {RESOURCE_LOCK_FD}>"$dir/.lock" || return 2
    flock "$RESOURCE_LOCK_FD" || return 2
    return 0
}

# 释放串行锁。
resource_unlock() {
    [[ -n $RESOURCE_LOCK_FD ]] || return 0
    flock -u "$RESOURCE_LOCK_FD" 2>/dev/null
    exec {RESOURCE_LOCK_FD}>&- 2>/dev/null
    RESOURCE_LOCK_FD=''
    return 0
}

# 下一个账本序号：现有行数加一。
resource_next_seq() {
    local dir=$1 n=0
    [[ ! -f $dir/ledger.tsv ]] || n=$(wc -l < "$dir/ledger.tsv")
    printf '%s\n' "$((n + 1))"
}

# 追加一条制表符分隔的账本事件。
resource_ledger_append() {
    local dir=$1
    shift
    ( IFS=$'\t'; printf '%s\n' "$*" ) >> "$dir/ledger.tsv"
}

# 载入账本：按事件顺序保留每个身份的最新状态与创建顺序。
resource_ledger_load() {
    local dir=$1 line seq event kind identity run scenario role hash digest path
    RESOURCE_LEDGER_ACTIVE=()
    RESOURCE_LEDGER_REMOVED=()
    RESOURCE_LEDGER_ORDER=()
    [[ -f $dir/ledger.tsv ]] || return 0
    while IFS=$'\t' read -r seq event kind identity run scenario role hash digest path; do
        [[ -n ${event:-} && -n ${identity:-} ]] || continue
        case "$event" in
            register)
                RESOURCE_LEDGER_ACTIVE["$kind|$identity"]="$seq|$scenario|$role|$hash|$digest|$run"
                RESOURCE_LEDGER_REMOVED["$kind|$identity"]=''
                RESOURCE_LEDGER_ORDER+=("$seq|$kind|$identity")
                ;;
            removed)
                RESOURCE_LEDGER_ACTIVE["$kind|$identity"]=''
                RESOURCE_LEDGER_REMOVED["$kind|$identity"]=1
                ;;
        esac
    done < "$dir/ledger.tsv"
    return 0
}

# 逐对象实时核验身份与全部所有权 label，卷另核身份摘要；任何不符返回 2。
resource_verify_object() {
    local kind=$1 identity=$2 scenario=$3 role=$4 digest=$5
    local current labels run scenario_now role_now
    current=$(resource_inspect_identity "$kind" "$identity") || return 2
    [[ $current == "$identity" ]] || return 2
    labels=$(resource_inspect_labels "$kind" "$identity") || return 2
    IFS=$'\t' read -r run scenario_now role_now <<< "$labels"
    [[ -z $scenario_now || $scenario_now == "$scenario" ]] || return 2
    [[ -z $role_now || $role_now == "$role" ]] || return 2
    if [[ $kind == volume ]]; then
        current=$(resource_volume_digest "$identity") || return 2
        [[ $current == "$digest" ]] || return 2
    fi
    return 0
}

# 登记主体：校验身份与三标签，冻结创建 inspect 证据并串行追加账本。
resource_register_body() {
    local kind=$1 identity=$2 scenario=$3 role=$4
    local dir run labels run_label obj_scenario obj_role hash digest seq path
    dir=$(resource_ledger_dir) || return 2
    run=$(resource_run)
    [[ -n $run ]] || return 2
    if ! labels=$(resource_inspect_labels "$kind" "$identity"); then return 2; fi
    IFS=$'\t' read -r run_label obj_scenario obj_role <<< "$labels"
    [[ $run_label == "$run" ]] || return 2
    [[ -z $obj_scenario || $obj_scenario == "$scenario" ]] || return 2
    [[ -z $obj_role || $obj_role == "$role" ]] || return 2
    if ! hash=$(resource_inspect_hash "$identity"); then return 2; fi
    if [[ $kind == volume ]]; then
        if ! digest=$(resource_volume_digest "$identity"); then return 2; fi
    else
        digest=$identity
    fi
    mkdir -p "$dir/objects" || return 2
    resource_lock "$dir" || return 2
    seq=$(resource_next_seq "$dir")
    path=$dir/objects/$seq-$kind.json
    if ! resource_docker inspect "$identity" > "$path" 2>/dev/null; then
        resource_unlock
        return 2
    fi
    resource_ledger_append "$dir" "$seq" register "$kind" "$identity" "$run_label" "$obj_scenario" "$obj_role" "$hash" "$digest" "$path"
    resource_unlock
    return 0
}

# 创建返回后登记：kind 非法、身份为空或创建 inspect 失败返回 2。
# 登记期间延后 TERM/INT，落盘后重放，避免创建与登记之间丢失登记；登记失败由调用方停止。
resource_register() {
    local kind=${1:-} identity=${2:-} scenario=${3:-} role=${4:-}
    local rc=0 sig=0 prev_term prev_int
    resource_kind_valid "$kind" || return 2
    [[ -n $identity ]] || return 2
    prev_term=$(trap -p TERM)
    prev_int=$(trap -p INT)
    trap 'sig=143' TERM
    trap 'sig=130' INT
    resource_register_body "$kind" "$identity" "$scenario" "$role" || rc=$?
    if [[ -n $prev_term ]]; then eval "$prev_term"; else trap - TERM; fi
    if [[ -n $prev_int ]]; then eval "$prev_int"; else trap - INT; fi
    (( rc == 0 )) || return "$rc"
    if (( sig != 0 )); then exit "$sig"; fi
    return 0
}

# 双向交叉验证：label 枚举集与登记集必须一致，仍存在的登记对象身份/标签须实时相符。
# 任何差异返回 2，不执行删除、不撤销规则。
resource_crosscheck() {
    local dir=${1:-} run kind ids item key entry rkey rseq scenario role hash digest entry_run
    [[ -n $dir ]] || return 2
    run=$(resource_run)
    [[ -n $run ]] || return 2
    resource_ledger_load "$dir" || return 2
    for kind in $RESOURCE_KINDS; do
        if ! ids=$(resource_enumerate "$kind" "$run"); then
            printf 'RESOURCE_DIFF enumerate_failed=%s\n' "$kind" >&2
            return 2
        fi
        for item in $ids; do
            [[ -n $item && $item != -* ]] || continue
            key="$kind|$item"
            if [[ -z ${RESOURCE_LEDGER_ACTIVE[$key]:-} && -z ${RESOURCE_LEDGER_REMOVED[$key]:-} ]]; then
                printf 'RESOURCE_DIFF unregistered=%s\n' "$key" >&2
                return 2
            fi
        done
    done
    for entry in "${RESOURCE_LEDGER_ORDER[@]}"; do
        IFS='|' read -r _ kind item <<< "$entry"
        rkey="$kind|$item"
        if [[ -n ${RESOURCE_LEDGER_REMOVED[$rkey]:-} ]]; then
            if resource_exists "$kind" "$item"; then
                printf 'RESOURCE_DIFF reappeared=%s\n' "$rkey" >&2
                return 2
            fi
            continue
        fi
        [[ -n ${RESOURCE_LEDGER_ACTIVE[$rkey]:-} ]] || continue
        IFS='|' read -r rseq scenario role hash digest entry_run <<< "${RESOURCE_LEDGER_ACTIVE[$rkey]}"
        if ! resource_exists "$kind" "$item"; then
            printf 'RESOURCE_DIFF missing_without_receipt=%s\n' "$rkey" >&2
            return 2
        fi
        if ! resource_verify_object "$kind" "$item" "$scenario" "$role" "$digest"; then
            printf 'RESOURCE_DIFF unverified=%s\n' "$rkey" >&2
            return 2
        fi
    done
    return 0
}

# 底层删除边界：按 kind 逆启动包装器直接删除，任一类失败返回 2。
resource_delete() {
    local kind=$1 identity=$2
    case "$kind" in
        container) resource_docker rm -f "$identity" >/dev/null ;;
        network) resource_docker network rm "$identity" >/dev/null ;;
        volume) resource_docker volume rm "$identity" >/dev/null ;;
        *) return 2 ;;
    esac
}

# 记录删除回执，供二次清理与恢复脚本判定幂等。
resource_record_removed() {
    local dir=$1 kind=$2 identity=$3 run=$4 scenario=$5 role=$6 hash=$7 digest=$8
    local seq
    resource_lock "$dir" || return 2
    seq=$(resource_next_seq "$dir")
    resource_ledger_append "$dir" "$seq" removed "$kind" "$identity" "$run" "$scenario" "$role" "$hash" "$digest" ''
    resource_unlock
    return 0
}

# 按登记身份精确删除单个对象：未登记或身份/标签不符返回 2；有删除回执且对象消失幂等返回 0。
resource_remove() {
    local kind=${1:-} identity=${2:-}
    local dir run key scenario role hash digest entry
    resource_kind_valid "$kind" || return 2
    [[ -n $identity ]] || return 2
    dir=$(resource_ledger_dir) || return 2
    run=$(resource_run)
    [[ -n $run ]] || return 2
    resource_ledger_load "$dir" || return 2
    key="$kind|$identity"
    if [[ -n ${RESOURCE_LEDGER_REMOVED[$key]:-} ]]; then
        if resource_exists "$kind" "$identity"; then return 2; fi
        return 0
    fi
    [[ -n ${RESOURCE_LEDGER_ACTIVE[$key]:-} ]] || return 2
    IFS='|' read -r entry scenario role hash digest _ <<< "${RESOURCE_LEDGER_ACTIVE[$key]}"
    resource_verify_object "$kind" "$identity" "$scenario" "$role" "$digest" || return 2
    resource_delete "$kind" "$identity" || return 2
    resource_record_removed "$dir" "$kind" "$identity" "$run" "$scenario" "$role" "$hash" "$digest" || return 2
    return 0
}

# 先交叉验证，再容器→网络→卷（各类逆创建序）精确删除，最后核验无残留。
resource_cleanup() {
    local dir=${1:-} run kind entry identity kind_of i ids
    local -a order=()
    [[ -n $dir ]] || return 2
    run=$(resource_run)
    [[ -n $run ]] || return 2
    RESOURCE_LEDGER_DIR=$dir
    resource_crosscheck "$dir" || return 2
    order=("${RESOURCE_LEDGER_ORDER[@]}")
    for kind in $RESOURCE_KINDS; do
        for ((i=${#order[@]}-1;i>=0;i--)); do
            IFS='|' read -r _ kind_of identity <<< "${order[i]}"
            [[ $kind_of == "$kind" ]] || continue
            resource_remove "$kind_of" "$identity" || return 2
        done
    done
    for kind in $RESOURCE_KINDS; do
        if ! ids=$(resource_enumerate "$kind" "$run"); then
            printf 'RESOURCE_RESIDUAL_QUERY_FAILED kind=%s\n' "$kind" >&2
            return 2
        fi
        if [[ -n ${ids//[[:space:]]/} ]]; then
            printf 'RESOURCE_RESIDUAL kind=%s ids=%s\n' "$kind" "$ids" >&2
            return 2
        fi
    done
    return 0
}

# 输出恢复脚本冻结的库正文：变量与交叉验证/删除/清理函数定义，不含创建登记。
resource_recovery_embed() {
    printf 'RESOURCE_KINDS=%q\n' "$RESOURCE_KINDS"
    printf "RESOURCE_LOCK_FD=''\n"
    printf 'declare -A RESOURCE_LEDGER_ACTIVE=()\ndeclare -A RESOURCE_LEDGER_REMOVED=()\nRESOURCE_LEDGER_ORDER=()\n'
    declare -f resource_ledger_dir resource_run resource_docker resource_kind_valid \
        resource_label_selector resource_inspect_identity resource_inspect_labels \
        resource_volume_digest resource_inspect_hash resource_exists resource_enumerate \
        resource_lock resource_unlock resource_next_seq resource_ledger_append \
        resource_ledger_load resource_verify_object resource_crosscheck \
        resource_delete resource_record_removed resource_remove resource_cleanup
}
