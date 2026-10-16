#!/usr/bin/env bash
# 载体契约：调用真实载体函数，只替换 namespace、进程、socket 与 Docker 外部边界。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ! -f $HERE/docker-validation-carrier.sh ]] || source "$HERE/docker-validation-carrier.sh"

TEST_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TEST_IMAGE=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# 创建测试目录并清空副作用计数。
new_scratch() {
    local scratch
    scratch=$(mktemp -d) || return 1
    : > "$scratch/mutations"
    printf '%s\n' "$scratch"
}

# 写入精确 21 键审批。
write_approval() {
    local path=$1 mode=$2 order=$3
    {
        printf 'schema_version\t1\nrun_id\tcontract\nexpires_at_epoch\t2000000000\n'
        printf 'host_machine_id\t0123456789abcdef0123456789abcdef\n'
        printf 'host_boot_id\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
        printf 'runner_user\tgmtest\nrunner_uid\t10001\nrunner_gid\t10001\n'
        printf 'source_dir\t/approved/source\nsource_sha256\t%s\n' "$TEST_SHA"
        printf 'product_image_id\t%s\ntools_image_id\t%s\n' "$TEST_IMAGE" "$TEST_IMAGE"
        printf 'product_archive\t/approved/product.tar\nproduct_archive_sha256\t%s\n' "$TEST_SHA"
        printf 'tools_archive\t/approved/tools.tar\ntools_archive_sha256\t%s\n' "$TEST_SHA"
        printf 'mapping_profile_sha256\t%s\ndockerd_sha256\t%s\n' "$TEST_SHA" "$TEST_SHA"
        printf 'storage_driver\tvfs\nallowed_mode\t%s\nallowed_order\t%s\n' "$mode" "$order"
    } > "$path"
    chmod 600 "$path"
}

# 安装稳定的载体事实边界。
setup_boundaries() {
    local scratch=$1
    carrier_effect() { printf '%s\n' "$*" >> "$scratch/mutations"; }
    carrier_now_epoch() { printf '1700000000\n'; }
    carrier_current_uid() { printf '0\n'; }
    carrier_host_machine_id() { printf '0123456789abcdef0123456789abcdef\n'; }
    carrier_host_boot_id() { printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'; }
    carrier_current_namespace() { printf '4 4001 4 4002\n'; }
    carrier_host_namespace() { printf '4 3001 4 3002\n'; }
    carrier_proc_starttime() { if [[ $1 == 31337 ]]; then printf '888\n'; elif [[ $1 == 31338 ]]; then printf '889\n'; else return 1; fi; }
    carrier_socket_facts() { printf '9999 4242 0 10001 660 %s/run/contract/docker.sock\n' "$scratch"; }
    carrier_daemon_id() { printf 'daemon-contract-0001\n'; }
    carrier_file_facts() { printf '0 %s\n' "$(stat -c '%a' "$1")"; }
    carrier_state_root() { printf '%s/state\n' "$scratch"; }
    carrier_runtime_root() { printf '%s/run\n' "$scratch"; }
    carrier_holder_namespace() { printf '4 4001 4 4002\n'; }
    carrier_start_holder() { printf '31337\n'; }
    carrier_start_dockerd() { printf '31338\n'; }
    carrier_process_alive() { return 0; }
    carrier_sleep() { :; }
    carrier_stop_process() { printf 'stop:%s\n' "$1" >> "$scratch/mutations"; }
    carrier_remove_tree() { printf 'remove:%s\n' "$1" >> "$scratch/mutations"; rm -rf -- "$1"; }
    carrier_configure_socket() { :; }
    carrier_host_readonly_query() {
        case "$*" in
            *' container ls '*|*' network ls '*|*' volume ls '*|*' image ls '*) return 0 ;;
            *) printf 'snapshot:%s\n' "$*" ;;
        esac
    }
    carrier_path_sha256() { printf '%s\n' "$TEST_SHA"; }
    carrier_source_sha256() { printf '%s\n' "$TEST_SHA"; }
    carrier_dockerd_sha256() { printf '%s\n' "$TEST_SHA"; }
}

# create 必须复制审批、创建完整状态，并将 dockerd 的独立路径固化到状态。
case_create_builds_bound_state() {
    local scratch approval state_dir state rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/input.tsv; write_approval "$approval" mapping-probe none
    mkdir -p "$scratch/state" "$scratch/run"
    carrier_create "$approval" "$scratch/state/contract" || rc=$?
    state=$scratch/state/contract/state.tsv
    [[ $rc == 0 && -f $scratch/state/contract/approval.tsv && -f $state ]] || return 1
    cmp -s "$approval" "$scratch/state/contract/approval.tsv" || return 1
    grep -Fqx $'data_root\t'"$scratch/state/contract/docker-data" "$state" || return 1
    grep -Fqx $'exec_root\t'"$scratch/run/contract/docker-exec" "$state" || return 1
    awk -F '\t' '$1 == "approval_sha256" && $2 ~ /^[0-9a-f]{64}$/ { found=1 } END { exit !found }' "$state" || return 1
    rm -rf "$scratch"
}

# run 必须从宿主 self namespace 进入 holder，并向真实 guard 传递固定九参数。
case_run_enters_holder_with_real_guard_args() {
    local scratch approval state manifest args
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_effect() { printf '%s\n' "$*" >> "$scratch/mutations"; }
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || return 1
    args=$(cat "$scratch/mutations")
    [[ $args == "nsenter --target 31337 --net --mount -- env -u IT_MAPPING_ORDER bash $HERE/docker-network-guard.sh --mode mapping-probe --source-dir /approved/source --run-id contract --evidence-dir $scratch/evidence --runner-user gmtest --product-image $TEST_IMAGE --tools-image $TEST_IMAGE --environment-manifest $manifest --offline-attestation $scratch/attestation --mapping-profile $scratch/profile" ]] || return 1
    rm -rf "$scratch"
}

# run 只能从宿主 self namespace 发起，不能从任意第三方 namespace 跳入 holder。
case_run_requires_host_self_namespace() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 7001 4 7002\n'; }
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# manifest 只提供 state 摘要，审批副本必须固定从 state 同目录读取。
case_run_uses_fixed_approval_copy() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    [[ $(wc -l < "$manifest") == 30 ]] || return 1
    grep -q '^carrier_state_sha256' "$manifest" || return 1
    ! grep -q '^approval_path' "$manifest" || return 1
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || rc=$?
    [[ $rc == 0 ]] || return 1
    rm -rf "$scratch"
}

# sequence 授权必须把已核验顺序作为环境参数传给同一九参数 guard。
case_sequence_passes_approved_order_to_guard() {
    local scratch approval state manifest args
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-sequence direct,fallback
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-sequence "$scratch/evidence" direct,fallback || return 1
    args=$(cat "$scratch/mutations")
    [[ $args == *'env IT_MAPPING_ORDER=direct,fallback bash '*'/docker-network-guard.sh --mode mapping-sequence '* ]] || return 1
    rm -rf "$scratch"
}

# cleanup 与 recover 只能在身份完整时进入 holder，recover 还要求显式 runner-stopped。
case_cleanup_and_recover_are_identity_bound() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    mkdir -p "$scratch/final" "$scratch/recovery"
    : > "$scratch/recovery/recover.sh"
    carrier_cleanup "$state" "$scratch/final" || return 1
    carrier_recover "$state" "$scratch/recovery" --runner-stopped || return 1
    rc=0; carrier_recover "$state" "$scratch/recovery" --unsafe || rc=$?
    [[ $rc == 64 ]] || return 1
    grep -q '^nsenter --target 31337 --net --mount -- bash .*/docker-validation-carrier.sh internal-cleanup ' "$scratch/mutations" || return 1
    grep -q '^nsenter --target 31337 --net --mount -- bash .*/recover.sh --runner-stopped$' "$scratch/mutations" || return 1
    rm -rf "$scratch"
}

# state 本身被修改时，即使审批未变也必须在任何 guard 副作用前拒绝。
case_run_rejects_state_hash_drift() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    sed -i 's#docker-data#other-data#' "$state"
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# holder namespace 事实与固定 dockerd 路径任一漂移都必须拒绝。
case_verify_binds_holder_namespace_and_dockerd_paths() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_holder_namespace() { printf '4 4001 4 4999\n'; }
    carrier_verify "$state" || rc=$?
    [[ $rc == 77 ]] || return 1
    setup_boundaries "$scratch"; carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    sed -i 's#docker-data#foreign-data#' "$state"
    rc=0; carrier_verify "$state" || rc=$?
    [[ $rc == 77 ]] || return 1
    rm -rf "$scratch"
}

# 精确键集与 mode/order 闭包必须在任何副作用前执行。
case_approval_requires_exact_21_keys() {
    local scratch approval bad rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_approval_load "$approval" || return 1
    bad=$scratch/bad.tsv; head -n 20 "$approval" > "$bad"; chmod 600 "$bad"
    carrier_approval_load "$bad" || rc=$?
    [[ $rc == 2 && ! -s $scratch/mutations ]] || return 1
    cat "$approval" > "$bad"; printf 'unknown\tx\n' >> "$bad"; chmod 600 "$bad"
    rc=0; carrier_approval_load "$bad" || rc=$?
    [[ $rc == 2 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# mode/order 只接受五种模式及 sequence 的两种顺序。
case_approval_mode_order_pair_is_closed() {
    local scratch approval mode order rc
    scratch=$(new_scratch); setup_boundaries "$scratch"; approval=$scratch/approval.tsv
    for mode in mapping-probe mapping-fallback mapping-direct full; do
        write_approval "$approval" "$mode" none
        carrier_approval_load "$approval" || return 1
    done
    for order in fallback,direct direct,fallback; do
        write_approval "$approval" mapping-sequence "$order"
        carrier_approval_load "$approval" || return 1
    done
    for mode in '*' mapping-probe,mapping-direct invalid; do
        write_approval "$approval" "$mode" none
        rc=0; carrier_approval_load "$approval" || rc=$?
        [[ $rc == 2 ]] || return 1
    done
    write_approval "$approval" full fallback,direct
    rc=0; carrier_approval_load "$approval" || rc=$?
    [[ $rc == 2 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# 21 键不仅要求集合完整，每个身份、路径、摘要和存储驱动值也必须合法。
case_approval_validates_every_field() {
    local scratch approval bad key value rc
    scratch=$(new_scratch); setup_boundaries "$scratch"; approval=$scratch/approval.tsv
    write_approval "$approval" full none
    for key in host_machine_id host_boot_id runner_user runner_uid runner_gid source_dir source_sha256 product_image_id tools_image_id product_archive product_archive_sha256 tools_archive tools_archive_sha256 mapping_profile_sha256 dockerd_sha256 storage_driver; do
        case "$key" in
            runner_uid) value=0 ;;
            runner_gid) value=bad ;;
            source_dir|product_archive|tools_archive) value=relative ;;
            product_image_id|tools_image_id) value=latest ;;
            storage_driver) value=overlay2 ;;
            runner_user) value='Bad User' ;;
            *) value=bad ;;
        esac
        bad=$scratch/$key.tsv
        awk -F '\t' -v key="$key" -v value="$value" 'BEGIN {OFS="\t"} $1 == key {$2=value} {print}' "$approval" > "$bad"
        chmod 600 "$bad"; rc=0; carrier_approval_load "$bad" || rc=$?
        [[ $rc == 2 ]] || { printf 'invalid %s rc=%s\n' "$key" "$rc"; return 1; }
    done
    rm -rf "$scratch"
}

# create 在任何进程副作用前核对源码、离线档案和 dockerd 摘要。
case_create_rejects_frozen_input_hash_drift() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/input.tsv; write_approval "$approval" mapping-probe none
    mkdir -p "$scratch/state" "$scratch/run"
    carrier_path_sha256() { printf '%064d\n' 0; }
    carrier_create "$approval" "$scratch/state/contract" || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# 运行请求必须与固定审批的 mode/order 精确一致。
case_run_requires_exact_approved_mode_order() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" full "$scratch/evidence" '' || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# state→审批与 manifest→state 的摘要链任一漂移都必须拒绝。
case_run_binds_approval_through_state_and_manifest() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    printf 'tamper\n' >> "$approval"
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# 宿主 namespace、PID 重用和 socket 替换都必须拒绝且零副作用。
case_reject_host_namespace() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_verify "$state" || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# holder 启动时间漂移必须拒绝。
case_reject_reused_holder_pid() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_proc_starttime() { printf '999\n'; }
    carrier_verify "$state" || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# socket inode 漂移必须拒绝。
case_reject_socket_replacement() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_socket_facts() { printf '9999 9999 0 10001 660 %s/run/contract/docker.sock\n' "$scratch"; }
    carrier_verify "$state" || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# dockerd 的 data-root、exec-root、pidfile、socket 与配置必须全部私有。
case_independent_dockerd_paths() {
    local args
    args=$(carrier_dockerd_argv contract)
    [[ $args == *'--data-root /var/lib/gitdaemon-validation/contract/docker-data'* ]] || return 1
    [[ $args == *'--exec-root /run/gitdaemon-validation/contract/docker-exec'* ]] || return 1
    [[ $args == *'--pidfile /run/gitdaemon-validation/contract/dockerd.pid'* ]] || return 1
    [[ $args == *'--host unix:///run/gitdaemon-validation/contract/docker.sock'* ]] || return 1
    [[ $args == *'--containerd-namespace gitdaemon-contract'* ]] || return 1
    [[ $args == *'--containerd-plugins-namespace gitdaemon-contract-plugins'* ]] || return 1
    [[ $args != *'/run/containerd/containerd.sock'* ]] || return 1
    [[ $args != *'/var/run/docker.sock'* ]] || return 1
}

case_create_waits_for_dockerd_and_rolls_back_exactly() {
    local scratch approval rc=0 calls=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/input.tsv; write_approval "$approval" mapping-probe none
    mkdir -p "$scratch/state" "$scratch/run"
    carrier_daemon_id() { calls=$((calls + 1)); return 1; }
    carrier_process_alive() { return 0; }
    carrier_create "$approval" "$scratch/state/contract" || rc=$?
    [[ $rc == 80 && ! -e $scratch/state/contract && ! -e $scratch/run/contract ]] || return 1
    grep -q '^stop:31338$' "$scratch/mutations" || return 1
    grep -q '^stop:31337$' "$scratch/mutations" || return 1
    [[ $(grep -c '^remove:' "$scratch/mutations") == 2 ]] || return 1
    rm -rf "$scratch"
}

case_run_validates_manifest_attestation_and_profile() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    printf 'attestation\n' > "$scratch/attestation"
    printf 'profile\n' > "$scratch/profile"
    carrier_path_sha256() { sha256sum "$1" | cut -d' ' -f1; }
    local profile_hash
    profile_hash=$(carrier_path_sha256 "$scratch/profile")
    awk -F '\t' -v hash="$profile_hash" 'BEGIN {OFS="\t"} $1 == "mapping_profile_sha256" {$2=hash} {print}' "$approval" > "$approval.tmp"
    mv "$approval.tmp" "$approval"; chmod 600 "$approval"
    carrier_test_state_write "$approval" "$state" "$manifest" "$scratch/attestation" "$scratch/profile"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || return 1
    : > "$scratch/mutations"
    printf 'tamper\n' >> "$scratch/profile"
    carrier_run "$state" "$manifest" "$scratch/attestation" "$scratch/profile" mapping-probe "$scratch/evidence" '' || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

case_socket_permissions_reject_world_access() {
    local scratch approval state manifest rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" mapping-probe none
    state=$scratch/state.tsv; manifest=$scratch/manifest.tsv
    carrier_test_state_write "$approval" "$state" "$manifest"
    carrier_current_namespace() { printf '4 3001 4 3002\n'; }
    carrier_socket_facts() { printf '9999 4242 0 10001 666 %s/run/contract/docker.sock\n' "$scratch"; }
    carrier_verify "$state" || rc=$?
    [[ $rc == 77 ]] || return 1
    rm -rf "$scratch"
}

# holder 必须显式使用 private mount propagation。
case_mount_propagation_private() {
    [[ $(carrier_holder_argv) == 'unshare --net --mount --propagation private' ]]
}

# 宿主盘点参数必须封闭且不暴露写命令路径。
case_host_inventory_uses_closed_readonly_argv() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_host_inventory "$approval" "$scratch/state" invalid >/dev/null 2>&1 || rc=$?
    [[ $rc == 2 && ! -s $scratch/mutations ]] || return 1
    [[ $(carrier_host_inventory_argv) != *' rm '* && $(carrier_host_inventory_argv) != *'prune'* ]] || return 1
    rm -rf "$scratch"
}

# runner 或非宿主 namespace 不得执行宿主盘点。
case_host_inventory_rejects_runner_and_foreign_namespace() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_current_uid() { printf '10001\n'; }
    carrier_host_inventory "$approval" "$scratch/state" before >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# 宿主身份漂移必须停止后续盘点查询。
case_host_inventory_pins_host_identity() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_host_machine_id() { printf 'ffffffffffffffffffffffffffffffff\n'; }
    carrier_host_inventory "$approval" "$scratch/state" before >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 && ! -s $scratch/mutations ]] || return 1
    rm -rf "$scratch"
}

# 宿主盘点身份必须来自审批，不得接受实现内置的固定样本。
case_host_inventory_uses_approved_identity() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    sed -i 's/0123456789abcdef0123456789abcdef/11111111111111111111111111111111/' "$approval"
    carrier_host_machine_id() { printf '11111111111111111111111111111111\n'; }
    carrier_host_namespace() { printf '4 4001 4 4002\n'; }
    carrier_host_inventory "$approval" "$scratch/state" before >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'approved identity rc=%s\n' "$rc"; return 1; }
    rm -rf "$scratch"
}

# 宿主盘点接口只产生固定只读 argv，不接受业务删除参数。
case_host_inventory_has_no_business_delete_path() {
    local argv
    argv=$(carrier_host_inventory_argv)
    [[ $argv == *'info --format'* && $argv == *'container ls -aq --no-trunc'* ]] || return 1
    [[ $argv != *'delete'* && $argv != *' rm '* && $argv != *'prune'* ]]
}

# 宿主盘点必须落盘固定只读查询及身份，且拒绝覆盖已有完整快照。
case_host_inventory_writes_immutable_snapshot() {
    local scratch approval snapshot rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_host_namespace() { printf '4 4001 4 4002\n'; }
    mkdir -p "$scratch/state"
    carrier_host_inventory "$approval" "$scratch/state" before || return 1
    snapshot=$scratch/state/host-before
    [[ -f $snapshot/identity.tsv && -f $snapshot/commands.tsv && -f $snapshot/complete ]] || return 1
    grep -q $'^machine_id\t0123456789abcdef0123456789abcdef$' "$snapshot/identity.tsv" || return 1
    [[ $(find "$snapshot" -name '*.argv' | wc -l) -ge 9 ]] || return 1
    [[ $(find "$snapshot" -name '*.exit' | wc -l) -ge 9 ]] || return 1
    grep -Rqx '0' "$snapshot"/*.exit || return 1
    carrier_host_inventory "$approval" "$scratch/state" before || rc=$?
    [[ $rc == 77 ]] || return 1
    rm -rf "$scratch"
}

case_host_inventory_compares_every_command() {
    local scratch approval rc=0
    scratch=$(new_scratch); setup_boundaries "$scratch"
    approval=$scratch/approval.tsv; write_approval "$approval" full none
    carrier_host_namespace() { printf '4 4001 4 4002\n'; }
    mkdir -p "$scratch/state"
    carrier_host_inventory "$approval" "$scratch/state" before || return 1
    carrier_host_inventory "$approval" "$scratch/state" after || return 1
    carrier_host_inventory_compare "$scratch/state" || return 1
    printf 'changed\n' >> "$scratch/state/host-after/route4.stdout"
    carrier_host_inventory_compare "$scratch/state" || rc=$?
    [[ $rc == 1 ]] || return 1
    rm -rf "$scratch"
}

failed=0
for name in create_builds_bound_state create_rejects_frozen_input_hash_drift create_waits_for_dockerd_and_rolls_back_exactly run_enters_holder_with_real_guard_args run_requires_host_self_namespace run_uses_fixed_approval_copy run_validates_manifest_attestation_and_profile sequence_passes_approved_order_to_guard cleanup_and_recover_are_identity_bound run_rejects_state_hash_drift verify_binds_holder_namespace_and_dockerd_paths approval_requires_exact_21_keys approval_mode_order_pair_is_closed approval_validates_every_field run_requires_exact_approved_mode_order run_binds_approval_through_state_and_manifest reject_host_namespace reject_reused_holder_pid reject_socket_replacement socket_permissions_reject_world_access independent_dockerd_paths mount_propagation_private host_inventory_uses_closed_readonly_argv host_inventory_rejects_runner_and_foreign_namespace host_inventory_pins_host_identity host_inventory_uses_approved_identity host_inventory_has_no_business_delete_path host_inventory_writes_immutable_snapshot host_inventory_compares_every_command; do
    rc=0
    ( "case_$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
