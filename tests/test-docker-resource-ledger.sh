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

# 创建返回与登记之间的窗口必须由信号延后覆盖：TERM 与 INT 都须在登记落盘后按信号退出。
case_signal_between_create_and_register() {
    local sig expected rc=0 pid i
    set -m
    for sig in TERM INT; do
        ledger_setup
        local scratch=$S
        mkdir -p "$scratch/control"
        IT_RUN_ID=r1 IT_NETWORK=gm-r1-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
        IT_TOOLS_IMAGE=tools IT_PRODUCT_IMAGE=product
        : > "$scratch/create-block"
        # create 替身：对象已创建、身份返回前阻塞；信号在创建与登记之间到达，由资源库延后到登记落盘后。
        command() {
            [[ $1 == docker ]] || { builtin command "$@"; return $?; }
            shift
            local call=$*
            printf '%s\n' "$call" >> "$scratch/docker.calls"
            case "$1" in
                create)
                    : > "$scratch/create-entered"
                    while [[ -f $scratch/create-block ]]; do sleep 0.05; done
                    printf 'cid1\n'
                    ;;
                inspect)
                    case "$call" in
                        *gitdaemon.run*) printf 'r1\tr1\tproduct\n' ;;
                        *'{{.Id}}'*) printf 'cid1\n' ;;
                        *) printf '{}\n' ;;
                    esac
                    ;;
                start) : ;;
            esac
            return 0
        }
        ( docker run --network none product true ) > "$scratch/out" 2>&1 &
        pid=$!
        for ((i=0;i<100;i++)); do [[ -f $scratch/create-entered ]] && break; sleep 0.05; done
        kill -"$sig" "$pid" 2>/dev/null
        sleep 0.3
        rm -f "$scratch/create-block"
        rc=0
        wait "$pid" || rc=$?
        if [[ $sig == TERM ]]; then expected=143; else expected=130; fi
        printf 'signal=%s exit=%s\n' "$sig" "$rc"
        [[ $rc == "$expected" ]] || { printf 'signal %s exit mismatch\n' "$sig"; return 1; }
        grep -q $'^1\tregister\tcontainer\tcid1\tr1\tr1\tproduct\t' "$RESOURCE_LEDGER_DIR/ledger.tsv" \
            || { printf 'register record missing after %s\n' "$sig"; return 1; }
        rm -rf "$S"
    done
    return 0
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

# 三 label 缺失即拒绝登记：对象缺少 scenario/role 时登记返回 2 且不写账本。
case_register_requires_three_labels() {
    ledger_setup
    install_docker_double
    declare_object container c1 r1 fixture product
    local rc=0
    M_SCEN[c1]=''
    resource_register container c1 fixture product 2>/dev/null || rc=$?
    printf 'empty_scenario_register=%s\n' "$rc"
    [[ $rc == 2 ]] || return 1
    rc=0
    M_SCEN[c1]=fixture M_ROLE[c1]=''
    resource_register container c1 fixture product 2>/dev/null || rc=$?
    printf 'empty_role_register=%s\n' "$rc"
    [[ $rc == 2 ]] || return 1
    [[ ! -s $RESOURCE_LEDGER_DIR/ledger.tsv ]] || { printf 'unexpected ledger record\n'; return 1; }
    rm -rf "$S"
}

# 辅助容器创建必须携带三 label，登记后标签漂移同样被差异检测拒绝且零删除。
case_helper_registers_three_labels() {
    ledger_setup
    local scratch=$S rc=0 clean=0
    mkdir -p "$scratch/control"
    IT_EVIDENCE_DIR=$scratch IT_RUN_ID=helper IT_NETWORK=gm-helper-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
    IT_TOOLS_IMAGE=tools IT_PRODUCT_IMAGE=product
    command() {
        [[ $1 == docker ]] || { builtin command "$@"; return $?; }
        shift
        printf '%s\n' "$*" >> "$scratch/docker.calls"
        case "$1" in
            create) printf 'helper-id\n' ;;
            inspect)
                case "$*" in
                    *gitdaemon.run*) printf 'helper\thelper\thelper\n' ;;
                    *'{{.Id}}'*) printf 'helper-id\n' ;;
                    *'.NetworkMode'*) printf 'gm-helper-net\n' ;;
                    *'.Config.User'*) printf '10001:10001 true false [ALL] [no-new-privileges]\n' ;;
                    *'.NetworkSettings.Networks'*) printf 'gm-helper-net \n' ;;
                    *'.HostConfig.Dns'*) printf '[172.30.243.53]\n' ;;
                    *'.Sysctls'*) printf '1\n' ;;
                    *'.ExtraHosts'*) printf '[] []\n' ;;
                    *'.Mounts'*) printf 'volume gm-helper-ca\n' ;;
                    *) printf '{}\n' ;;
                esac ;;
            network) printf 'false\n' ;;
            logs) printf 'HELPER_UID=10001:10001\n' ;;
            start) return 0 ;;
        esac
        return 0
    }
    integration_helper_run 0 0 git image -- ls-remote https://example.invalid/x || rc=$?
    printf 'helper_run_exit=%s\n' "$rc"
    [[ $rc == 0 ]] || return 1
    grep -q -- '--label gitdaemon.scenario=helper' "$scratch/docker.calls" \
        || { printf 'helper create missing scenario label\n'; return 1; }
    grep -q -- '--label gitdaemon.role=helper' "$scratch/docker.calls" \
        || { printf 'helper create missing role label\n'; return 1; }
    grep -q $'register\tcontainer\thelper-id\thelper\thelper\thelper\t' "$RESOURCE_LEDGER_DIR/ledger.tsv" \
        || { printf 'ledger missing helper three labels\n'; return 1; }
    # 切换为账本替身并让标签漂移：差异检测对辅助容器同样拒绝且零删除。
    install_docker_double
    RESOURCE_RUN=helper
    declare_object container helper-id helper other helper
    resource_cleanup "$RESOURCE_LEDGER_DIR" 2>/dev/null || clean=$?
    printf 'helper_cleanup_after_drift=%s\n' "$clean"
    [[ $clean == 2 ]] || return 1
    assert_no_delete_no_rule || return 1
    rm -rf "$S"
}

# 账本不可解析时必须留下固定可观测标记，绝不静默回退到旧语义。
case_ledger_gate_is_observable() {
    ledger_setup
    unset RESOURCE_LEDGER_DIR IT_EVIDENCE_DIR
    local scratch=$S rc=0
    mkdir -p "$scratch/control"
    IT_RUN_ID=gate IT_NETWORK=gm-gate-net IT_DNS_IP=172.30.243.53 IT_NETWORK_GUARD_READY=1
    IT_TOOLS_IMAGE=tools IT_PRODUCT_IMAGE=product
    command() {
        [[ $1 == docker ]] || { builtin command "$@"; return $?; }
        shift
        printf '%s\n' "$*" >> "$scratch/docker.calls"
        return 0
    }
    docker run --network none product true 2>"$scratch/err-run" || rc=$?
    grep -qx 'RESOURCE_LEDGER_UNAVAILABLE caller=run' "$scratch/err-run" \
        || { printf 'run gate not observable\n'; return 1; }
    rc=0
    docker volume create gm-gate-data 2>"$scratch/err-volume" || rc=$?
    grep -qx 'RESOURCE_LEDGER_UNAVAILABLE caller=volume-create' "$scratch/err-volume" \
        || { printf 'volume gate not observable\n'; return 1; }
    rc=0
    network_run --network none product true 2>"$scratch/err-network" || rc=$?
    grep -qx 'RESOURCE_LEDGER_UNAVAILABLE caller=network_run' "$scratch/err-network" \
        || { printf 'network_run gate not observable\n'; return 1; }
    rc=0
    docker rm -f owned 2>"$scratch/err-remove" || rc=$?
    grep -qx 'RESOURCE_LEDGER_UNAVAILABLE caller=integration-remove' "$scratch/err-remove" \
        || { printf 'remove gate not observable\n'; return 1; }
    printf 'remove_without_ledger_exit=%s\n' "$rc"
    [[ $rc == 2 ]] || return 1
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
    register_failure_blocks_start \
    register_requires_three_labels \
    helper_registers_three_labels \
    ledger_gate_is_observable; do
    rc=0
    ( "case_$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
