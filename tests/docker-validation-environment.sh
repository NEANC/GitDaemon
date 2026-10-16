#!/usr/bin/env bash
# 离线验证环境授权库：严格解析管理员清单，绑定 VM、runner 与本地 Docker 端点。
# 只定义只读 VE_* 字段与核验函数；按数据解析清单，绝不 source 或 eval 其内容。

VE_CONTRACT_SCHEMA_VERSION='1'
VE_CONTRACT_PROFILE='offline-vm'
VE_CONTRACT_RUNNER_ENTRY='tests/test-docker-network.sh'
VE_CONTRACT_DOCKER_ENDPOINT='unix:///var/run/docker.sock'
VE_REQUIRED_KEYS='schema_version profile run_id expires_at_epoch vm_uuid machine_id boot_id offline_attestation_sha256 runner_user runner_uid runner_gid source_dir source_sha256 runner_entry docker_endpoint daemon_id socket_realpath socket_device socket_inode socket_uid socket_gid product_image_id tools_image_id mapping_profile_sha256'
VE_SCHEMA2_REQUIRED_KEYS='schema_version profile run_id expires_at_epoch machine_id boot_id offline_attestation_sha256 runner_user runner_uid runner_gid source_dir source_sha256 runner_entry docker_endpoint daemon_id socket_realpath socket_device socket_inode socket_uid socket_gid product_image_id tools_image_id mapping_profile_sha256 holder_pid holder_start_ticks netns_device netns_inode mntns_device mntns_inode carrier_state_sha256'
VE_HANDSHAKE_KEYS='pid start_ticks boot_id manifest_sha256'
VE_REQUIRED_KEY_COUNT=24
VE_SCHEMA2_REQUIRED_KEY_COUNT=30

# 只读字段，由 validation_environment_load 填充。
VE_SCHEMA_VERSION=''
VE_PROFILE=''
VE_RUN_ID=''
VE_EXPIRES_AT_EPOCH=''
VE_VM_UUID=''
VE_MACHINE_ID=''
VE_BOOT_ID=''
VE_OFFLINE_ATTESTATION_SHA256=''
VE_RUNNER_USER=''
VE_RUNNER_UID=''
VE_RUNNER_GID=''
VE_SOURCE_DIR=''
VE_SOURCE_SHA256=''
VE_RUNNER_ENTRY=''
VE_DOCKER_ENDPOINT=''
VE_DAEMON_ID=''
VE_SOCKET_REALPATH=''
VE_SOCKET_DEVICE=''
VE_SOCKET_INODE=''
VE_SOCKET_UID=''
VE_SOCKET_GID=''
VE_PRODUCT_IMAGE_ID=''
VE_TOOLS_IMAGE_ID=''
VE_MAPPING_PROFILE_SHA256=''
VE_HOLDER_PID=''
VE_HOLDER_START_TICKS=''
VE_NETNS_DEVICE=''
VE_NETNS_INODE=''
VE_MNTNS_DEVICE=''
VE_MNTNS_INODE=''
VE_CARRIER_STATE_SHA256=''

# 以下函数只读取宿主与进程事实；测试通过替换它们注入边界，不改动核验逻辑。
validation_host_vm_uuid() {
    cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z'
}
validation_host_machine_id() {
    cat /etc/machine-id 2>/dev/null | tr -d '[:space:]'
}
validation_host_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '[:space:]'
}
validation_now_epoch() { date +%s; }
validation_passwd_lookup() { getent passwd "$1" 2>/dev/null | cut -d: -f1,3,4; }
validation_proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
validation_proc_owner() { stat -c '%u' "/proc/$1" 2>/dev/null; }
validation_namespace_facts() {
    local holder=$VE_HOLDER_PID
    printf '%s %s ' "$holder" "$(validation_proc_starttime "$holder")"
    stat -Lc '%d %i ' "/proc/$holder/ns/net" "/proc/$holder/ns/mnt" 2>/dev/null | tr '\n' ' '
    printf '\n'
}
validation_manifest_digest() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
validation_manifest_facts() { stat -c '%u %a' -- "$1" 2>/dev/null; }
validation_manifest_safe_path() { [[ -f $1 && ! -L $1 ]]; }

# 将已核验的 Unix URI 转换为本轮 canonical socket 路径。
validation_endpoint_path() {
    local endpoint=${1:-} path
    [[ $# == 1 && -n $endpoint ]] || return 2
    [[ $VE_SCHEMA_VERSION == 2 && $VE_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 77
    [[ $endpoint == unix:///run/gitdaemon-validation/"$VE_RUN_ID"/docker.sock ]] || return 77
    path=${endpoint#unix://}
    [[ $path == /run/gitdaemon-validation/"$VE_RUN_ID"/docker.sock && $path != *'/../'* ]] || return 77
    printf '%s\n' "$path"
}

# socket 事实：设备号、inode、属主 uid/gid 与 canonical path。
validation_socket_facts() {
    local path=$1 real
    real=$(readlink -f -- "$path" 2>/dev/null) || return 1
    [[ -S $real ]] || return 1
    stat -Lc "%d %i %u %g $real" -- "$real" 2>/dev/null
}

# 排序后的仓库输入文件哈希清单摘要；排除 .git、证据目录、虚拟环境与 docs/superpowers/。
validation_source_digest() {
    local dir=$1
    ( CDPATH= cd -- "$dir" 2>/dev/null || exit 1
      find . -type f \
          -not -path './.git/*' -not -path './docs/superpowers/*' \
          -not -path './evidence/*' \
          -not -path './.venv/*' -not -path './venv/*' -not -path './env/*' \
          -not -path '*/__pycache__/*' \
          -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1 )
}

# 清单必须是 root 所有、普通文件、非符号链接，且组/其他不可写。
validation_manifest_file_guard() {
    local path=${1:-} facts owner mode
    [[ -n $path ]] && validation_manifest_safe_path "$path" || return 77
    facts=$(validation_manifest_facts "$path") || return 77
    owner=${facts%% *}
    mode=${facts#* }
    [[ $owner == 0 ]] || return 77
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 77
    (( (8#$mode & 8#022) == 0 )) || return 77
    return 0
}

# 唯一 Docker CLI 包装器：拒绝继承的 Docker 覆盖与远程 context，始终走本地 socket。
validation_docker() {
    local key context endpoint
    endpoint=${VE_DOCKER_ENDPOINT:-}
    [[ -n $endpoint ]] || return 77
    for key in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
        [[ -z ${!key:-} ]] || return 77
    done
    context=$(command docker context show 2>/dev/null) || context=''
    case "$context" in
        ''|'default'|"$endpoint") ;;
        *) return 77 ;;
    esac
    env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH \
        docker --host "$endpoint" "$@"
}

# 严格解析授权清单：返回 0，格式错误 2，策略拒绝 77；成功后填充只读 VE_* 字段。
validation_environment_load() {
    local manifest=${1:-} line key value want count i required_keys required_count
    local -a keys=() values=()
    [[ $# == 1 ]] || return 2
    validation_manifest_file_guard "$manifest" || return 77
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 2
        [[ $line != *$'\r'* ]] || return 2
        key=${line%%$'\t'*}
        value=${line#*$'\t'}
        [[ $key != "$line" && -n $key && -n $value ]] || return 2
        [[ $value != *$'\t'* ]] || return 2
        keys+=("$key")
        values+=("$value")
    done < "$manifest"
    for i in "${!keys[@]}"; do
        if [[ ${keys[i]} == schema_version ]]; then VE_SCHEMA_VERSION=${values[i]}; fi
    done
    case "$VE_SCHEMA_VERSION" in
        1) required_keys=$VE_REQUIRED_KEYS; required_count=$VE_REQUIRED_KEY_COUNT ;;
        2) required_keys=$VE_SCHEMA2_REQUIRED_KEYS; required_count=$VE_SCHEMA2_REQUIRED_KEY_COUNT ;;
        *) return 77 ;;
    esac
    [[ ${#keys[@]} == "$required_count" ]] || return 2
    for want in $required_keys; do
        count=0
        for key in "${keys[@]}"; do
            if [[ $key == "$want" ]]; then count=$((count + 1)); fi
        done
        [[ $count == 1 ]] || return 2
    done
    for i in "${!keys[@]}"; do
        case "${keys[i]}" in
            schema_version) VE_SCHEMA_VERSION=${values[i]} ;;
            profile) VE_PROFILE=${values[i]} ;;
            run_id) VE_RUN_ID=${values[i]} ;;
            expires_at_epoch) VE_EXPIRES_AT_EPOCH=${values[i]} ;;
            vm_uuid) VE_VM_UUID=${values[i]} ;;
            machine_id) VE_MACHINE_ID=${values[i]} ;;
            boot_id) VE_BOOT_ID=${values[i]} ;;
            offline_attestation_sha256) VE_OFFLINE_ATTESTATION_SHA256=${values[i]} ;;
            runner_user) VE_RUNNER_USER=${values[i]} ;;
            runner_uid) VE_RUNNER_UID=${values[i]} ;;
            runner_gid) VE_RUNNER_GID=${values[i]} ;;
            source_dir) VE_SOURCE_DIR=${values[i]} ;;
            source_sha256) VE_SOURCE_SHA256=${values[i]} ;;
            runner_entry) VE_RUNNER_ENTRY=${values[i]} ;;
            docker_endpoint) VE_DOCKER_ENDPOINT=${values[i]} ;;
            daemon_id) VE_DAEMON_ID=${values[i]} ;;
            socket_realpath) VE_SOCKET_REALPATH=${values[i]} ;;
            socket_device) VE_SOCKET_DEVICE=${values[i]} ;;
            socket_inode) VE_SOCKET_INODE=${values[i]} ;;
            socket_uid) VE_SOCKET_UID=${values[i]} ;;
            socket_gid) VE_SOCKET_GID=${values[i]} ;;
            product_image_id) VE_PRODUCT_IMAGE_ID=${values[i]} ;;
            tools_image_id) VE_TOOLS_IMAGE_ID=${values[i]} ;;
            mapping_profile_sha256) VE_MAPPING_PROFILE_SHA256=${values[i]} ;;
            holder_pid) VE_HOLDER_PID=${values[i]} ;;
            holder_start_ticks) VE_HOLDER_START_TICKS=${values[i]} ;;
            netns_device) VE_NETNS_DEVICE=${values[i]} ;;
            netns_inode) VE_NETNS_INODE=${values[i]} ;;
            mntns_device) VE_MNTNS_DEVICE=${values[i]} ;;
            mntns_inode) VE_MNTNS_INODE=${values[i]} ;;
            carrier_state_sha256) VE_CARRIER_STATE_SHA256=${values[i]} ;;
            *) return 2 ;;
        esac
    done
    case "$VE_SCHEMA_VERSION" in
        1)
            [[ $VE_PROFILE == "$VE_CONTRACT_PROFILE" ]] || return 77
            [[ $VE_DOCKER_ENDPOINT == "$VE_CONTRACT_DOCKER_ENDPOINT" ]] || return 77
            [[ $VE_VM_UUID =~ ^[0-9A-Fa-f-]{16,64}$ ]] || return 2
            ;;
        2)
            [[ $VE_PROFILE == isolated-netns ]] || return 77
            validation_endpoint_path "$VE_DOCKER_ENDPOINT" >/dev/null || return $?
            for key in VE_HOLDER_PID VE_HOLDER_START_TICKS VE_NETNS_DEVICE VE_NETNS_INODE VE_MNTNS_DEVICE VE_MNTNS_INODE; do
                [[ ${!key} =~ ^[0-9]{1,20}$ ]] || return 2
            done
            [[ $VE_CARRIER_STATE_SHA256 =~ ^[0-9a-f]{64}$ ]] || return 2
            ;;
    esac
    [[ $VE_RUNNER_ENTRY == "$VE_CONTRACT_RUNNER_ENTRY" ]] || return 77
    [[ $VE_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 2
    [[ $VE_EXPIRES_AT_EPOCH =~ ^[0-9]{1,12}$ ]] || return 2
    [[ $VE_RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 2
    [[ $VE_RUNNER_UID =~ ^[0-9]{1,10}$ ]] || return 2
    [[ $VE_RUNNER_UID != 0 ]] || return 77
    [[ $VE_RUNNER_GID =~ ^[0-9]{1,10}$ ]] || return 2
    [[ $VE_SOURCE_DIR == /* ]] || return 2
    [[ $VE_MACHINE_ID =~ ^[0-9A-Fa-f]{16,64}$ ]] || return 2
    [[ $VE_BOOT_ID =~ ^[0-9A-Fa-f-]{16,64}$ ]] || return 2
    [[ $VE_DAEMON_ID =~ ^[0-9A-Za-z:._-]{16,128}$ ]] || return 2
    [[ $VE_SOCKET_REALPATH == /* ]] || return 2
    for key in VE_SOCKET_DEVICE VE_SOCKET_INODE VE_SOCKET_UID VE_SOCKET_GID; do
        [[ ${!key} =~ ^[0-9]{1,20}$ ]] || return 2
    done
    for key in VE_OFFLINE_ATTESTATION_SHA256 VE_SOURCE_SHA256 VE_MAPPING_PROFILE_SHA256; do
        [[ ${!key} =~ ^[0-9a-f]{64}$ ]] || return 2
    done
    for key in VE_PRODUCT_IMAGE_ID VE_TOOLS_IMAGE_ID; do
        [[ ${!key} =~ ^sha256:[0-9a-f]{64}$ ]] || return 2
    done
    return 0
}

# 复核离线证明、VM 身份、有效期、源码摘要、socket 与本地 daemon；失败返回 77。
validation_environment_verify() {
    local manifest=${1:-} attestation=${2:-} expected namespace
    [[ $# == 2 && -n $manifest && -n $attestation ]] || return 2
    validation_environment_load "$manifest" || return $?
    expected=$(sha256sum "$attestation" 2>/dev/null | cut -d' ' -f1) || return 77
    [[ -n $expected && $expected == "$VE_OFFLINE_ATTESTATION_SHA256" ]] || return 77
    [[ $(validation_host_machine_id) == "$VE_MACHINE_ID" ]] || return 77
    [[ $(validation_host_boot_id) == "$VE_BOOT_ID" ]] || return 77
    if [[ $VE_SCHEMA_VERSION == 1 ]]; then
        [[ $(validation_host_vm_uuid) == "$(printf '%s' "$VE_VM_UUID" | tr 'A-Z' 'a-z')" ]] || return 77
    else
        namespace=$(validation_namespace_facts) || return 77
        [[ $namespace == "$VE_HOLDER_PID $VE_HOLDER_START_TICKS $VE_NETNS_DEVICE $VE_NETNS_INODE $VE_MNTNS_DEVICE $VE_MNTNS_INODE" ]] || return 77
    fi
    (( $(validation_now_epoch) <= VE_EXPIRES_AT_EPOCH )) || return 77
    [[ $(validation_source_digest "$VE_SOURCE_DIR") == "$VE_SOURCE_SHA256" ]] || return 77
    validation_socket_binding_verify || return 77
    validation_runner_binding_verify || return 77
    validation_local_daemon_verify || return 77
    return 0
}

# 比较 socket 的设备号、inode、属主与 canonical path。
validation_socket_binding_verify() {
    local facts device inode uid gid path socket_path
    if [[ $VE_SCHEMA_VERSION == 2 ]]; then
        socket_path=$(validation_endpoint_path "$VE_DOCKER_ENDPOINT") || return 77
    else
        socket_path=${VE_DOCKER_ENDPOINT#unix://}
    fi
    facts=$(validation_socket_facts "$socket_path") || return 77
    read -r device inode uid gid path <<< "$facts"
    [[ $device == "$VE_SOCKET_DEVICE" && $inode == "$VE_SOCKET_INODE" ]] || return 77
    [[ $uid == "$VE_SOCKET_UID" && $gid == "$VE_SOCKET_GID" && $path == "$VE_SOCKET_REALPATH" ]] || return 77
    return 0
}

# 清单里的 runner 用户必须解析为同一 uid/gid，且不是 root。
validation_runner_binding_verify() {
    local entry uid gid
    entry=$(validation_passwd_lookup "$VE_RUNNER_USER") || return 77
    [[ -n $entry ]] || return 77
    IFS=: read -r _ uid gid <<< "$entry"
    [[ $uid == "$VE_RUNNER_UID" && $gid == "$VE_RUNNER_GID" ]] || return 77
    [[ $uid != 0 ]] || return 77
    return 0
}

# 本地 daemon ID 必须与清单一致，拒绝远程或未知端点。
validation_local_daemon_verify() {
    local actual
    actual=$(validation_docker info -f '{{.ID}}' 2>/dev/null) || return 77
    actual=${actual%%$'\n'*}
    [[ -n $actual && $actual == "$VE_DAEMON_ID" ]] || return 77
    return 0
}

# 握手文件为四键 TSV；对 /proc 启动时间与当前 boot-id 复核，不凭 PID 单值认定身份。
validation_runner_verify() {
    local manifest=${1:-} handshake=${2:-} line key value want count i
    local pid='' start_ticks='' handshake_boot='' handshake_hash='' digest actual owner
    local -a keys=() values=()
    [[ $# == 2 && -n $manifest && -n $handshake ]] || return 2
    validation_environment_load "$manifest" || return $?
    [[ -f $handshake && ! -L $handshake ]] || return 77
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || return 2
        key=${line%%$'\t'*}
        value=${line#*$'\t'}
        [[ $key != "$line" && -n $key && -n $value ]] || return 2
        [[ $value != *$'\t'* ]] || return 2
        keys+=("$key")
        values+=("$value")
    done < "$handshake"
    [[ ${#keys[@]} == 4 ]] || return 2
    for want in $VE_HANDSHAKE_KEYS; do
        count=0
        for key in "${keys[@]}"; do
            if [[ $key == "$want" ]]; then count=$((count + 1)); fi
        done
        [[ $count == 1 ]] || return 2
    done
    for i in "${!keys[@]}"; do
        case "${keys[i]}" in
            pid) pid=${values[i]} ;;
            start_ticks) start_ticks=${values[i]} ;;
            boot_id) handshake_boot=${values[i]} ;;
            manifest_sha256) handshake_hash=${values[i]} ;;
        esac
    done
    [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || return 77
    [[ $start_ticks =~ ^[0-9]{1,20}$ ]] || return 77
    digest=$(validation_manifest_digest "$manifest") || return 77
    [[ -n $digest && $handshake_hash == "$digest" ]] || return 77
    [[ $handshake_boot == "$(validation_host_boot_id)" ]] || return 77
    actual=$(validation_proc_starttime "$pid") || return 77
    [[ -n $actual && $actual == "$start_ticks" ]] || return 77
    owner=$(validation_proc_owner "$pid") || return 77
    [[ $owner == "$VE_RUNNER_UID" ]] || return 77
    return 0
}
