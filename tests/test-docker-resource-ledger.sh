#!/usr/bin/env bash
# 资源登记账本契约：调用真实 crosscheck/remove/cleanup/register，只替换 Docker 外部边界。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ! -f $HERE/docker-resource-ledger.sh ]] || source "$HERE/docker-resource-ledger.sh"
[[ ! -f $HERE/docker-network-guard.sh ]] || source "$HERE/docker-network-guard.sh"
[[ ! -f $HERE/docker-integration-startup.sh ]] || source "$HERE/docker-integration-startup.sh"

# 替身状态：对象存活、kind、三标签、卷身份摘要与各类故障注入。
declare -A M_LIVE=() M_KIND=() M_RUN=() M_SCEN=() M_ROLE=() M_DIGEST=()
declare -A M_DELFAIL=() M_INSPECTFAIL=() M_ENUMFAIL=() M_RESIDFAIL=() M_BLOCK=()

# 初始化一次账本用例的临时目录与替身状态。
ledger_setup() {
    S=$(mktemp -d)
    DOCKER_CALLS=$S/docker.calls
    DELETE_CALLS=$S/delete.calls
    REMOVE_RULE_CALLS=$S/remove-rule.calls
    : > "$DOCKER_CALLS"; : > "$DELETE_CALLS"; : > "$REMOVE_RULE_CALLS"
    M_LIVE=(); M_KIND=(); M_RUN=(); M_SCEN=(); M_ROLE=(); M_DIGEST=()
    M_DELFAIL=(); M_INSPECTFAIL=(); M_ENUMFAIL=(); M_RESIDFAIL=(); M_BLOCK=()
    RESOURCE_LEDGER_DIR=$S/control/resources
    RESOURCE_RUN=r1
    mkdir -p "$RESOURCE_LEDGER_DIR"
}

# 声明一个存活对象及其身份属性。
declare_object() {
    local kind=$1 id=$2 run=$3 scenario=$4 role=$5 digest=${6:-}
    M_LIVE[$id]=1; M_KIND[$id]=$kind; M_RUN[$id]=$run; M_SCEN[$id]=$scenario; M_ROLE[$id]=$role
    [[ -z $digest ]] || M_DIGEST[$id]=$digest
}

# 枚举计数：区分交叉验证枚举与最终残留枚举，支持残查询故障注入。
count_enum() {
    local kind=$1 n=0 f=$S/enum.$1.count
    [[ ! -f $f ]] || n=$(cat "$f")
    n=$((n + 1)); printf '%s\n' "$n" > "$f"
    [[ ${M_ENUMFAIL[$kind]:-0} != 1 ]] || return 9
    if [[ ${M_RESIDFAIL[$kind]:-0} == 1 && $n -ge 2 ]]; then return 9; fi
    return 0
}

# Docker 外部边界替身：按命令分派，记录调用与删除，注入故障。
mock_docker() {
    printf '%s\n' "$*" >> "$DOCKER_CALLS"
    local sub=${1:-} id='' fmt='' a k
    case "$sub" in
        inspect)
            shift
            if [[ ${1:-} == -f ]]; then fmt=${2:-}; id=${3:-}; else fmt=''; id=${1:-}; fi
            [[ ${M_INSPECTFAIL[$id]:-0} != 1 ]] || return 9
            [[ ${M_LIVE[$id]:-0} == 1 ]] || return 1
            case "$fmt" in
                '{{.Id}}'|'{{.Name}}') printf '%s\n' "$id" ;;
                *'.CreatedAt'*) printf '%s\n' "${M_DIGEST[$id]}" ;;
                *'.Config.Labels'*|*'.Labels'*)
                    printf '%s\t%s\t%s\n' "${M_RUN[$id]}" "${M_SCEN[$id]}" "${M_ROLE[$id]}"
                    if [[ -n ${M_BLOCK[$id]:-} ]]; then
                        : > "$S/label-entered"
                        local w=0
                        while [[ -f ${M_BLOCK[$id]} && $w -lt 100 ]]; do sleep 0.05; w=$((w + 1)); done
                    fi
                    ;;
                *) printf '{}\n' ;;
            esac
            ;;
        logs) return 0 ;;
        ps)
            count_enum container || return 9
            for k in "${!M_LIVE[@]}"; do
                [[ ${M_LIVE[$k]} == 1 && ${M_KIND[$k]} == container ]] || continue
                printf '%s\n' "$k"
            done
            ;;
        rm)
            shift
            for a in "$@"; do [[ $a == -* ]] || { id=$a; break; }; done
            printf 'rm %s\n' "$id" >> "$DELETE_CALLS"
            [[ ${M_DELFAIL[$id]:-0} != 1 ]] || return 9
            M_LIVE[$id]=0
            ;;
        network|volume)
            case "${2:-}" in
                ls)
                    count_enum "$sub" || return 9
                    for k in "${!M_LIVE[@]}"; do
                        [[ ${M_LIVE[$k]} == 1 && ${M_KIND[$k]} == "$sub" ]] || continue
                        printf '%s\n' "$k"
                    done
                    ;;
                rm)
                    id=${3:-}
                    printf '%s %s\n' "$sub" "$id" >> "$DELETE_CALLS"
                    [[ ${M_DELFAIL[$id]:-0} != 1 ]] || return 9
                    M_LIVE[$id]=0
                    ;;
                inspect) printf 'false\n' ;;
                *) return 0 ;;
            esac
            ;;
        *) return 0 ;;
    esac
    return 0
}

# 每例装载替身边界。
install_docker_double() {
    resource_docker() { mock_docker "$@"; }
}

# 差异样本必须：清理返回 2、零删除、零撤规则。
assert_no_delete_no_rule() {
    [[ ! -s $DELETE_CALLS ]] || { printf 'unexpected delete calls:\n'; cat "$DELETE_CALLS"; return 1; }
    [[ ! -s $REMOVE_RULE_CALLS ]] || { printf 'unexpected rule reversal\n'; return 1; }
    return 0
}

# 未登记的同 label 对象不得被删除。
case_unregistered_same_label_is_not_deleted() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    local rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    printf 'cleanup=%s delete_calls=%s\n' "$rc" "$(wc -l < "$DELETE_CALLS")"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# 已登记对象实际 label 不符时不得被删除。
case_registered_wrong_label_is_not_deleted() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    resource_register container c1 fixture product || return 1
    M_SCEN[c1]=other
    local rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    printf 'cleanup=%s delete_calls=%s\n' "$rc" "$(wc -l < "$DELETE_CALLS")"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# 同名卷被重建（CreatedAt/Driver/Mountpoint/labels 摘要变化）时不得被删除。
case_recreated_volume_is_not_deleted() {
    ledger_setup
    install_docker_double
    declare_object volume v1 r1 fixture data 'createdA|local|/var/lib/docker/volumes/v1/_data|gitdaemon.run=r1,'
    resource_register volume v1 fixture data || return 1
    M_DIGEST[v1]='createdB|local|/var/lib/docker/volumes/v1/_data|gitdaemon.run=r1,'
    local rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    printf 'cleanup=%s delete_calls=%s\n' "$rc" "$(wc -l < "$DELETE_CALLS")"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# 登记对象消失但无删除回执必须失败。
case_missing_without_receipt_fails() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    resource_register container c1 fixture product || return 1
    M_LIVE[c1]=0
    local rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    printf 'cleanup=%s delete_calls=%s\n' "$rc" "$(wc -l < "$DELETE_CALLS")"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# inspect 查询失败必须保留隔离，不执行删除。
case_inspect_failure_retains_isolation() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    resource_register container c1 fixture product || return 1
    M_INSPECTFAIL[c1]=1
    local rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    printf 'cleanup=%s delete_calls=%s\n' "$rc" "$(wc -l < "$DELETE_CALLS")"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# 已成功删除的对象凭回执幂等；正常二次清理返回 0 且不再删除。
case_registered_delete_is_idempotent() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    declare_object network n1 r1 fixture net
    declare_object volume v1 r1 fixture data 'createdA|local|/p|a=1,'
    resource_register container c1 fixture product || return 1
    resource_register network n1 fixture net || return 1
    resource_register volume v1 fixture data || return 1
    local rc=0 first second
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    first=$(wc -l < "$DELETE_CALLS")
    [[ $rc == 0 && $first == 3 ]] || { printf 'first cleanup rc=%s deletes=%s\n' "$rc" "$first"; return 1; }
    rc=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
    second=$(wc -l < "$DELETE_CALLS")
    printf 'first=%s second_rc=%s second_deletes=%s\n' "$first" "$rc" "$second"
    [[ $rc == 0 && $second == "$first" ]] || return 1
    rc=0
    resource_remove container c1 2>/dev/null || rc=$?
    [[ $rc == 0 ]] || return 1
    [[ $(wc -l < "$DELETE_CALLS") == "$first" ]] || return 1
    rm -rf "$S"
}

# 跨创建与登记的 TERM 必须在安全点处理：登记仍落盘，随后按信号退出。
case_signal_between_create_and_register() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    # 标签查询阻塞，确定性地在创建与登记之间收到 TERM；登记落盘后才退出。
    M_BLOCK[c1]=$S/label-block
    : > "$S/label-block"
    ( resource_register container c1 fixture product ) > "$S/out" 2>&1 &
    local pid=$! rc=0 i
    for ((i=0;i<100;i++)); do [[ -f $S/label-entered ]] && break; sleep 0.05; done
    kill -TERM "$pid" 2>/dev/null
    sleep 0.3
    rm -f "$S/label-block"
    wait "$pid" || rc=$?
    printf 'register_exit=%s\n' "$rc"
    [[ $rc == 143 ]] || return 1
    grep -q $'^1\tregister\tcontainer\tc1\t' "$RESOURCE_LEDGER_DIR/ledger.tsv" || { printf 'register record missing\n'; return 1; }
    local clean=0
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || clean=$?
    printf 'cleanup_after_signal=%s\n' "$clean"
    [[ $clean == 0 && $(wc -l < "$DELETE_CALLS") == 1 ]] || return 1
    rm -rf "$S"
}

# 清理前必须重新核验同一 VM/runner/socket/daemon；漂移时保留隔离、零删除、零撤规则。
case_cleanup_revalidates_daemon() {
    ledger_setup
    install_docker_double
    local E=$S/ev
    mkdir -p "$E/control"
    RUN=r1 RUNNER=gmtest GUARD_BOUND=1 GUARD_MANIFEST=/m GUARD_ATTESTATION=/a
    validation_environment_verify() { return 77; }
    iptables-save() { return 0; }
    guard_remove_rules() { printf 'x\n' >> "$REMOVE_RULE_CALLS"; }
    local rc=0
    ( trap guard_cleanup EXIT; exit 7 ) || rc=$?
    printf 'guard_exit=%s\n' "$rc"
    [[ $rc == 7 ]] || return 1
    grep -qx 'CLEANUP_EXIT=2' "$E/exit-status.txt" || return 1
    assert_no_delete_no_rule || return 1
    [[ -s $E/recover.sh ]] || { printf 'missing recovery script\n'; return 1; }
    rm -rf "$S"
}

# 清理差异样本：主退出 7 保持 7，主退出 0 最终为 2；差异时无删除、无撤规则。
case_difference_sample_keeps_primary_and_isolation() {
    ledger_setup
    install_docker_double
    local E=$S/ev
    mkdir -p "$E/control"
    RUN=r1 RUNNER=gmtest GUARD_BOUND=0
    declare_object container stray r1 fixture product
    iptables-save() { return 0; }
    guard_remove_rules() { printf 'x\n' >> "$REMOVE_RULE_CALLS"; }
    docker() { mock_docker "$@"; }
    local rc=0
    ( trap guard_cleanup EXIT; exit 7 ) || rc=$?
    printf 'primary7_exit=%s\n' "$rc"
    [[ $rc == 7 ]] || return 1
    grep -qx 'CLEANUP_EXIT=2' "$E/exit-status.txt" || return 1
    assert_no_delete_no_rule || return 1
    : > "$REMOVE_RULE_CALLS"
    rc=0
    ( trap guard_cleanup EXIT; exit 0 ) || rc=$?
    printf 'primary0_exit=%s\n' "$rc"
    [[ $rc == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    local clean_delete
    clean_delete=$(wc -l < "$DELETE_CALLS")
    [[ $clean_delete == 0 ]] || return 1
    rm -rf "$S"
}

# container/network/volume × enumerate/inspect/delete/residual-query 故障均为隔离保留。
case_cleanup_fault_matrix() {
    local kind phase rc=0 id
    for kind in container network volume; do
        for phase in enumerate inspect delete residual-query; do
            ledger_setup
            install_docker_double
            case "$kind" in
                container) id=c1; declare_object container c1 r1 fixture role ;;
                network) id=n1; declare_object network n1 r1 fixture role ;;
                volume) id=v1; declare_object volume v1 r1 fixture role 'createdA|local|/p|a=1,' ;;
            esac
            resource_register "$kind" "$id" fixture role || return 1
            case "$phase" in
                enumerate) M_ENUMFAIL[$kind]=1 ;;
                inspect) M_INSPECTFAIL[$id]=1 ;;
                delete) M_DELFAIL[$id]=1 ;;
                residual-query) M_RESIDFAIL[$kind]=1 ;;
            esac
            rc=0
            resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || rc=$?
            printf 'fault=%s-%s cleanup=%s\n' "$kind" "$phase" "$rc"
            [[ $rc == 2 ]] || return 1
            rm -rf "$S"
        done
    done
    return 0
}

# SIGKILL 后恢复：恢复脚本冻结库/账本并要求 --runner-stopped；见未登记同 label 对象不得删除。
case_sigkill_recovery_requires_stopped_and_refuses_stray() {
    ledger_setup
    install_docker_double
    local E=$S/ev
    mkdir -p "$E/control"
    RUN=r1 RUNNER=gmtest GUARD_BOUND=0 GUARD_SOURCE="$HERE/.."
    iptables-save() { return 0; }
    guard_remove_rules() { printf 'x\n' >> "$REMOVE_RULE_CALLS"; }
    docker() { mock_docker "$@"; }
    local rc=0
    # SIGKILL 后残留未登记同 label 对象：差异使清理失败并生成恢复脚本。
    declare_object container stray r1 fixture product
    ( trap guard_cleanup EXIT; exit 137 ) || rc=$?
    printf 'sigkill_exit=%s\n' "$rc"
    [[ $rc == 137 ]] || return 1
    [[ -s $E/recover.sh ]] || { printf 'missing recovery script\n'; return 1; }
    bash -n "$E/recover.sh" || { printf 'recovery syntax error\n'; return 1; }
    rc=0
    bash "$E/recover.sh" >/dev/null 2>&1 || rc=$?
    printf 'recovery_no_flag_exit=%s\n' "$rc"
    [[ $rc == 64 ]] || return 1
    # 带停止确认：环境暴露未登记同 label 对象，交叉验证必须拒绝且不删除。
    mkdir -p "$S/bin"
    cat > "$S/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECOVERY_DOCKER_LOG"
case "$*" in
    'ps -aq '*) printf 'stray\n' ;;
esac
exit 0
STUB
    chmod +x "$S/bin/docker"
    export RECOVERY_DOCKER_LOG="$S/recovery-docker.calls"
    : > "$RECOVERY_DOCKER_LOG"
    rc=0
    PATH="$S/bin:$PATH" bash "$E/recover.sh" --runner-stopped >/dev/null 2>&1 || rc=$?
    printf 'recovery_stopped_exit=%s\n' "$rc"
    [[ $rc == 2 ]] || return 1
    ! grep -Eq '(^| )(rm|network rm|volume rm)( |$)' "$RECOVERY_DOCKER_LOG" || { printf 'stray object deleted\n'; return 1; }
    rm -rf "$S"
}

# 创建成功但登记失败必须禁止 start；登记失败向上返回 2。
case_register_failure_blocks_start() {
    ledger_setup
    local scratch=$S
    mkdir -p "$scratch/control"
    RESOURCE_LEDGER_DIR=$scratch/control/resources
    IT_EVIDENCE_DIR=$scratch IT_RUN_ID=blocks IT_NETWORK=gm-blocks-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
    IT_TOOLS_IMAGE=tools IT_PRODUCT_IMAGE=product
    # 记录 create/start；label 查询返回失败使登记失败，start 不得出现。
    command() {
        [[ $1 == docker ]] || { builtin command "$@"; return $?; }
        shift
        printf '%s\n' "$*" >> "$scratch/docker.calls"
        case "$1" in
            create) printf 'blocks-id\n' ;;
            inspect)
                case "$*" in
                    *'-f'*) return 9 ;;
                    *) printf '{}\n' ;;
                esac
                ;;
            start) printf 'STARTED\n' >> "$scratch/start.calls" ;;
        esac
        return 0
    }
    resource_docker() { command docker "$@"; }
    local rc=0
    integration_helper_run 1 0 sleep product --label x=y --network none -- >/dev/null 2>&1 || rc=$?
    printf 'helper_register_fail_exit=%s starts=%s\n' "$rc" "$(wc -l < "$scratch/start.calls" 2>/dev/null || printf '0')"
    [[ $rc == 2 ]] || return 1
    [[ ! -s $scratch/start.calls ]] || { printf 'start ran after register failure\n'; return 1; }
    rm -rf "$S"
}

failed=0
for name in \
    unregistered_same_label_is_not_deleted \
    registered_wrong_label_is_not_deleted \
    recreated_volume_is_not_deleted \
    missing_without_receipt_fails \
    inspect_failure_retains_isolation \
    registered_delete_is_idempotent \
    signal_between_create_and_register \
    cleanup_revalidates_daemon \
    difference_sample_keeps_primary_and_isolation \
    cleanup_fault_matrix \
    sigkill_recovery_requires_stopped_and_refuses_stray \
    register_failure_blocks_start; do
    rc=0
    ( "case_$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
