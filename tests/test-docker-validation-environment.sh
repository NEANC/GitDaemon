#!/usr/bin/env bash
# 环境授权与固定入口契约：调用真实核验函数，只替换 VM、runner、socket 与 Docker 外部边界。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ ! -f $HERE/docker-validation-environment.sh ]] || source "$HERE/docker-validation-environment.sh"
[[ ! -f $HERE/docker-network-guard.sh ]] || source "$HERE/docker-network-guard.sh"

VALIDATION_TEST_NOW=1700000000
VALIDATION_TEST_DAEMON=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
VALIDATION_TEST_VM_UUID=4c4c4544-0037-3010-8046-c2c04f4a4d32
VALIDATION_TEST_MACHINE_ID=0123456789abcdef0123456789abcdef
VALIDATION_TEST_BOOT_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
VALIDATION_TEST_PRODUCT_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
VALIDATION_TEST_TOOLS_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
VALIDATION_TEST_PROFILE_ID=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

# 冻结的源码摘要算法，独立计算期望值，不信任被测实现的输出。
frozen_source_digest() {
    local dir=$1
    ( CDPATH= cd -- "$dir" || exit 1
      find . -type f \
          -not -path './.git/*' -not -path './docs/superpowers/*' \
          -not -path './.venv/*' -not -path './venv/*' -not -path './env/*' \
          -not -path '*/__pycache__/*' \
          -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1 )
}

# 覆盖全部宿主身份边界，使核验可在无 VM、无 Docker 的环境下执行。
setup_identity_boundaries() {
    validation_host_vm_uuid() { printf '%s\n' "$VALIDATION_TEST_VM_UUID"; }
    validation_host_machine_id() { printf '%s\n' "$VALIDATION_TEST_MACHINE_ID"; }
    validation_host_boot_id() { printf '%s\n' "$VALIDATION_TEST_BOOT_ID"; }
    validation_now_epoch() { printf '%s\n' "$VALIDATION_TEST_NOW"; }
    validation_socket_facts() { printf '9999 4242 0 999 /run/docker.sock\n'; }
    validation_passwd_lookup() { printf 'gmtest:10001:10001\n'; }
    validation_proc_starttime() { printf '777\n'; }
    validation_proc_owner() { printf '10001\n'; }
}

# 建立 PATH 替身：记录并阻断 Docker、iptables 与 ip 的全部副作用。
install_effect_stubs() {
    local scratch=$1 name
    mkdir -p "$scratch/bin"
    : > "$scratch/docker-calls"
    : > "$scratch/effect-calls"
    cat > "$scratch/bin/docker" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
case "$*" in
    'context show') printf 'default\n' ;;
    *info*) cat "$DOCKER_STUB_ID" ;;
esac
exit 0
CLI
    for name in iptables iptables-save ip; do
        cat > "$scratch/bin/$name" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$EFFECT_STUB_LOG"
exit 0
STUB
    done
    chmod +x "$scratch/bin/docker" "$scratch/bin/iptables" "$scratch/bin/iptables-save" "$scratch/bin/ip"
    printf '%s\n' "$VALIDATION_TEST_DAEMON" > "$scratch/daemon-id"
    export DOCKER_STUB_LOG="$scratch/docker-calls" DOCKER_STUB_ID="$scratch/daemon-id" EFFECT_STUB_LOG="$scratch/effect-calls"
    export PATH="$scratch/bin:$PATH"
}

# 拒绝样本必须零副作用：无资源创建、无规则安装、无业务启动。
assert_no_mutation() {
    local scratch=$1
    if grep -Eq 'create|run|compose|network' "$scratch/docker-calls" 2>/dev/null; then
        printf 'unexpected docker mutation:\n'
        cat "$scratch/docker-calls"
        return 1
    fi
    if [[ -s $scratch/effect-calls ]]; then
        printf 'unexpected iptables/ip mutation:\n'
        cat "$scratch/effect-calls"
        return 1
    fi
    [[ ! -e $scratch/business.started ]]
}

# 新建空白工作目录与源码目录。
new_scratch() {
    local scratch
    scratch=$(mktemp -d) || return 1
    mkdir -p "$scratch/source/tests" || return 1
    printf 'impl\n' > "$scratch/source/scripts-placeholder.txt"
    printf '%s\n' "$scratch"
}

# 写入满足全部固定值约束的基准授权清单，返回清单路径。
prepare_manifest() {
    local scratch=$1 manifest attestation_digest source_digest
    [[ -d $scratch/source ]] || return 1
    printf 'offline attestation\n' > "$scratch/offline.txt"
    attestation_digest=$(sha256sum "$scratch/offline.txt" | cut -d' ' -f1)
    source_digest=$(frozen_source_digest "$scratch/source") || return 1
    manifest=$scratch/environment.tsv
    {
        printf 'schema_version\t1\n'
        printf 'profile\toffline-vm\n'
        printf 'run_id\tcontract\n'
        printf 'expires_at_epoch\t%s\n' "$((VALIDATION_TEST_NOW + 3600))"
        printf 'vm_uuid\t%s\n' "$VALIDATION_TEST_VM_UUID"
        printf 'machine_id\t%s\n' "$VALIDATION_TEST_MACHINE_ID"
        printf 'boot_id\t%s\n' "$VALIDATION_TEST_BOOT_ID"
        printf 'offline_attestation_sha256\t%s\n' "$attestation_digest"
        printf 'runner_user\tgmtest\n'
        printf 'runner_uid\t10001\n'
        printf 'runner_gid\t10001\n'
        printf 'source_dir\t%s\n' "$scratch/source"
        printf 'source_sha256\t%s\n' "$source_digest"
        printf 'runner_entry\ttests/test-docker-network.sh\n'
        printf 'docker_endpoint\tunix:///var/run/docker.sock\n'
        printf 'daemon_id\t%s\n' "$VALIDATION_TEST_DAEMON"
        printf 'socket_realpath\t/run/docker.sock\n'
        printf 'socket_device\t9999\n'
        printf 'socket_inode\t4242\n'
        printf 'socket_uid\t0\n'
        printf 'socket_gid\t999\n'
        printf 'product_image_id\t%s\n' "$VALIDATION_TEST_PRODUCT_ID"
        printf 'tools_image_id\t%s\n' "$VALIDATION_TEST_TOOLS_ID"
        printf 'mapping_profile_sha256\t%s\n' "$VALIDATION_TEST_PROFILE_ID"
    } > "$manifest"
    chown 0:0 "$manifest"
    chmod 644 "$manifest"
    printf '%s\n' "$manifest"
}

# 改写某键的值，用于构造策略拒绝样本。
rewrite_key() {
    local source=$1 target=$2 key=$3 value=$4
    awk -F '\t' -v OFS='\t' -v key="$key" -v value="$value" '$1==key{$2=value} {print}' "$source" > "$target"
    chown 0:0 "$target"
    chmod 644 "$target"
}

# 基准清单必须被加载，且格式错误固定返回 2。
case_load_accepts_frozen_manifest() {
    local scratch manifest rc=0 short
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_load "$manifest" || rc=$?
    [[ $rc == 0 ]] || { printf 'load rc=%s\n' "$rc"; return 1; }
    [[ $VE_RUN_ID == contract && $VE_DAEMON_ID == "$VALIDATION_TEST_DAEMON" ]] || { printf 'fields not filled\n'; return 1; }
    short=$scratch/short.tsv
    printf 'schema_version\t1\n' > "$short"
    chown 0:0 "$short"
    chmod 644 "$short"
    rc=0
    validation_environment_load "$short" || rc=$?
    [[ $rc == 2 ]] || { printf 'malformed rc=%s\n' "$rc"; return 1; }
    rm -rf "$scratch"
}

# 未获批 VM：VM UUID 与当前宿主不符必须返回 77。
case_reject_unapproved_vm() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    validation_host_vm_uuid() { printf 'deadbeef-dead-beef-dead-beefdeadbeef\n'; }
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_verify "$manifest" "$scratch/offline.txt" >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 ]] || { printf 'rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# 陈旧启动：boot-id 漂移必须返回 77。
case_reject_stale_boot() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    validation_host_boot_id() { printf 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\n'; }
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_verify "$manifest" "$scratch/offline.txt" >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 ]] || { printf 'rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# runner 身份不符：用户 uid/gid 与清单不一致必须返回 77。
case_reject_runner_identity() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    validation_passwd_lookup() { printf 'gmtest:10002:10001\n'; }
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_verify "$manifest" "$scratch/offline.txt" >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 ]] || { printf 'rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# 远程端点：清单端点非本地，以及继承的远程 Docker 覆盖，都必须返回 77。
case_reject_remote_endpoint() {
    local scratch manifest bad rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    manifest=$(prepare_manifest "$scratch") || return 1
    bad=$scratch/remote.tsv
    rewrite_key "$manifest" "$bad" docker_endpoint 'tcp://192.0.2.10:2375'
    validation_environment_load "$bad" || rc=$?
    [[ $rc == 77 ]] || { printf 'manifest endpoint rc=%s\n' "$rc"; return 1; }
    rc=0
    ( export DOCKER_HOST='tcp://192.0.2.10:2375'; validation_docker info >/dev/null ) || rc=$?
    [[ $rc == 77 ]] || { printf 'inherited DOCKER_HOST rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# socket 被替换：设备号/inode/属主任一不符必须返回 77。
case_reject_socket_replacement() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    validation_socket_facts() { printf '9999 4343 0 999 /run/docker.sock\n'; }
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_verify "$manifest" "$scratch/offline.txt" >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 ]] || { printf 'rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# 可变清单：组/其他可写与符号链接都必须返回 77。
case_reject_mutable_manifest() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    manifest=$(prepare_manifest "$scratch") || return 1
    chmod 664 "$manifest"
    validation_environment_load "$manifest" || rc=$?
    [[ $rc == 77 ]] || { printf 'writable rc=%s\n' "$rc"; return 1; }
    chmod 644 "$manifest"
    ln -s "$manifest" "$scratch/linked.tsv"
    rc=0
    validation_environment_load "$scratch/linked.tsv" || rc=$?
    [[ $rc == 77 ]] || { printf 'symlink rc=%s\n' "$rc"; return 1; }
    rm -rf "$scratch"
}

# 过期清单：有效期早于当前时间必须返回 77。
case_reject_expired_manifest() {
    local scratch manifest rc=0
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    validation_now_epoch() { printf '%s\n' "$((VALIDATION_TEST_NOW + 7200))"; }
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_environment_verify "$manifest" "$scratch/offline.txt" >/dev/null 2>&1 || rc=$?
    [[ $rc == 77 ]] || { printf 'rc=%s\n' "$rc"; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# full 继承延期请求：任何资源操作前拒绝，且入口返回 2。
case_reject_defer_before_mutation() {
    local scratch rc=0
    scratch=$(new_scratch) || return 1
    install_effect_stubs "$scratch"
    (
        IT_DEFER_MAPPING=1
        guard_main --run-id contract --evidence-dir "$scratch/evidence" --source-dir "$scratch/source" \
            --runner-user gmtest --mode full --product-image product --tools-image tools \
            --environment-manifest "$scratch/environment.tsv" --offline-attestation "$scratch/offline.txt" \
            --mapping-profile "$scratch/profile.tsv"
    ) || rc=$?
    [[ $rc == 2 ]] || { printf 'defer rc=%s\n' "$rc"; return 1; }
    [[ ! -e $scratch/evidence ]] || { printf 'evidence created before defer rejection\n'; return 1; }
    assert_no_mutation "$scratch" || return 1
    # 绑定参数必须被接受：无延期请求时不得退化为参数错误。
    rc=0
    (
        guard_main --run-id contract --evidence-dir "$scratch/evidence" --source-dir "$scratch/source" \
            --runner-user gmtest --mode full --product-image product --tools-image tools \
            --environment-manifest "$scratch/environment.tsv" --offline-attestation "$scratch/offline.txt" \
            --mapping-profile "$scratch/profile.tsv"
    ) || rc=$?
    [[ $rc != 2 ]] || { printf 'full binding rejected as argument error\n'; return 1; }
    assert_no_mutation "$scratch" || return 1
    rm -rf "$scratch"
}

# 同 VM 同 daemon：两侧命令都只使用唯一本地端点，握手 start_ticks 不符即拒绝。
case_same_vm_same_daemon() {
    local scratch manifest command rc=0 count endpoints digest handshake
    scratch=$(new_scratch) || return 1
    setup_identity_boundaries
    install_effect_stubs "$scratch"
    cat > "$scratch/source/tests/test-docker-network.sh" <<'STUB'
#!/usr/bin/env bash
printf 'runner-entry %s\n' "$*" >> "$RUNNER_ENTRY_LOG"
exit 0
STUB
    export RUNNER_ENTRY_LOG="$scratch/runner-entry.log"
    manifest=$(prepare_manifest "$scratch") || return 1
    validation_docker info -f '{{.ID}}' >/dev/null || { printf 'root docker rc=%s\n' "$?"; return 1; }
    command=$(guard_runner_command full "$scratch/source" run "$scratch/evidence" product tools \
        "$manifest" "$scratch/offline.txt" "$scratch/profile.tsv") || { printf 'command generation failed\n'; return 1; }
    [[ $(grep -o 'unix:///var/run/docker.sock' <<< "$command" | wc -l) == 1 ]] || { printf 'runner command endpoint not unique: %s\n' "$command"; return 1; }
    eval "$command" || rc=$?
    [[ $rc == 0 ]] || { printf 'runner command rc=%s\n' "$rc"; return 1; }
    [[ -s $scratch/runner-entry.log ]] || { printf 'runner entry not reached\n'; return 1; }
    endpoints=$(grep -o -- '--host [^ ]*' "$scratch/docker-calls" | sort -u)
    [[ $endpoints == '--host unix:///var/run/docker.sock' ]] || { printf 'endpoints=%s\n' "$endpoints"; return 1; }
    count=$(grep -o -- '--host unix:///var/run/docker.sock' "$scratch/docker-calls" | wc -l)
    [[ $count -ge 2 ]] || { printf 'endpoint count=%s\n' "$count"; return 1; }
    digest=$(sha256sum "$manifest" | cut -d' ' -f1)
    handshake=$scratch/handshake.tsv
    printf 'pid\t4242\nstart_ticks\t999\nboot_id\t%s\nmanifest_sha256\t%s\n' "$VALIDATION_TEST_BOOT_ID" "$digest" > "$handshake"
    rc=0
    validation_runner_verify "$manifest" "$handshake" || rc=$?
    [[ $rc == 77 ]] || { printf 'stale start_ticks accepted rc=%s\n' "$rc"; return 1; }
    printf 'pid\t4242\nstart_ticks\t777\nboot_id\t%s\nmanifest_sha256\t%s\n' "$VALIDATION_TEST_BOOT_ID" "$digest" > "$handshake"
    rc=0
    validation_runner_verify "$manifest" "$handshake" || rc=$?
    [[ $rc == 0 ]] || { printf 'valid handshake rc=%s\n' "$rc"; return 1; }
    rm -rf "$scratch"
}

failed=0
for name in load_accepts_frozen_manifest reject_unapproved_vm reject_stale_boot reject_runner_identity reject_remote_endpoint reject_socket_replacement reject_mutable_manifest reject_expired_manifest reject_defer_before_mutation same_vm_same_daemon; do
    rc=0
    ( "case_$name" ) || rc=$?
    printf '%s EXIT=%s\n' "$name" "$rc"
    [[ $rc == 0 ]] || failed=1
done
exit "$failed"
