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
    carrier_proc_starttime() { [[ $1 == 31337 ]] && printf '888\n'; }
    carrier_socket_facts() { printf '9999 4242 0 10001 /run/gitdaemon-validation/contract/docker.sock\n'; }
    carrier_daemon_id() { printf 'daemon-contract-0001\n'; }
    carrier_file_facts() { printf '0 %s\n' "$(stat -c '%a' "$1")"; }
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
    carrier_socket_facts() { printf '9999 9999 0 10001 /run/gitdaemon-validation/contract/docker.sock\n'; }
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
    [[ $args != *'/var/run/docker.sock'* ]] || return 1
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

failed=0
for name in approval_requires_exact_21_keys approval_mode_order_pair_is_closed run_requires_exact_approved_mode_order run_binds_approval_through_state_and_manifest reject_host_namespace reject_reused_holder_pid reject_socket_replacement independent_dockerd_paths mount_propagation_private host_inventory_uses_closed_readonly_argv host_inventory_rejects_runner_and_foreign_namespace host_inventory_pins_host_identity host_inventory_uses_approved_identity host_inventory_has_no_business_delete_path; do
    rc=0
    ( "case_$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
