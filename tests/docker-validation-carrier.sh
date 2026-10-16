#!/usr/bin/env bash
# 独立 namespace 验证载体：严格绑定审批、holder、socket 与私有 dockerd 路径。

CARRIER_APPROVAL_KEYS='schema_version run_id expires_at_epoch host_machine_id host_boot_id runner_user runner_uid runner_gid source_dir source_sha256 product_image_id tools_image_id product_archive product_archive_sha256 tools_archive tools_archive_sha256 mapping_profile_sha256 dockerd_sha256 storage_driver allowed_mode allowed_order'
CARRIER_STATE_KEYS='schema_version run_id host_machine_id host_boot_id holder_pid holder_start_ticks netns_device netns_inode mntns_device mntns_inode dockerd_pid dockerd_start_ticks daemon_id docker_endpoint socket_realpath socket_device socket_inode socket_uid socket_gid data_root exec_root approval_sha256'
CARRIER_ALLOWED_MODE=''
CARRIER_ALLOWED_ORDER=''
CARRIER_RUN_ID=''
CARRIER_APPROVAL_SHA256=''
CARRIER_HOST_MACHINE_ID=''
CARRIER_HOST_BOOT_ID=''

# 外部事实边界。
carrier_now_epoch() { date +%s; }
carrier_current_uid() { id -u; }
carrier_host_machine_id() { tr -d '[:space:]' < /etc/machine-id; }
carrier_host_boot_id() { tr -d '[:space:]' < /proc/sys/kernel/random/boot_id; }
carrier_current_namespace() { stat -Lc '%d %i' /proc/self/ns/net; stat -Lc '%d %i' /proc/self/ns/mnt; }
carrier_host_namespace() { stat -Lc '%d %i' /proc/1/ns/net; stat -Lc '%d %i' /proc/1/ns/mnt; }
carrier_proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
carrier_socket_facts() { local real; real=$(readlink -f -- "$1") || return 1; stat -Lc "%d %i %u %g $real" "$real"; }
carrier_daemon_id() { command docker --host "$1" info --format '{{.ID}}'; }
carrier_effect() { "$@"; }
carrier_file_facts() { stat -c '%u %a' "$1" 2>/dev/null; }

# root 所有且不可由组或其他用户写入。
carrier_file_guard() {
    local path=$1 owner mode
    [[ -f $path && ! -L $path ]] || return 77
    read -r owner mode < <(carrier_file_facts "$path") || return 77
    [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 77
    (( (8#$mode & 8#022) == 0 )) || return 77
}

# 解析固定键集合的 TSV。
carrier_parse_exact() {
    local path=$1 expected=$2 expected_count=$3 line key value want count
    local -a keys=() values=()
    carrier_file_guard "$path" || return 77
    while IFS= read -r line || [[ -n $line ]]; do
        key=${line%%$'\t'*}; value=${line#*$'\t'}
        [[ $key != "$line" && -n $key && -n $value && $value != *$'\t'* ]] || return 2
        keys+=("$key"); values+=("$value")
    done < "$path"
    [[ ${#keys[@]} == "$expected_count" ]] || return 2
    for want in $expected; do
        count=0
        for key in "${keys[@]}"; do [[ $key != "$want" ]] || count=$((count + 1)); done
        [[ $count == 1 ]] || return 2
    done
    CARRIER_PARSED_KEYS=("${keys[@]}")
    CARRIER_PARSED_VALUES=("${values[@]}")
}

# 严格加载 21 键审批并验证 mode/order 闭包。
carrier_approval_load() {
    local path=${1:-} i key value
    [[ $# == 1 ]] || return 2
    carrier_parse_exact "$path" "$CARRIER_APPROVAL_KEYS" 21 || return $?
    for i in "${!CARRIER_PARSED_KEYS[@]}"; do
        key=${CARRIER_PARSED_KEYS[i]}; value=${CARRIER_PARSED_VALUES[i]}
        case "$key" in
            schema_version) [[ $value == 1 ]] || return 2 ;;
            run_id) CARRIER_RUN_ID=$value ;;
            host_machine_id) CARRIER_HOST_MACHINE_ID=$value ;;
            host_boot_id) CARRIER_HOST_BOOT_ID=$value ;;
            allowed_mode) CARRIER_ALLOWED_MODE=$value ;;
            allowed_order) CARRIER_ALLOWED_ORDER=$value ;;
        esac
    done
    [[ $CARRIER_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 2
    case "$CARRIER_ALLOWED_MODE" in
        mapping-probe|mapping-fallback|mapping-direct|full) [[ $CARRIER_ALLOWED_ORDER == none ]] || return 2 ;;
        mapping-sequence) [[ $CARRIER_ALLOWED_ORDER == fallback,direct || $CARRIER_ALLOWED_ORDER == direct,fallback ]] || return 2 ;;
        *) return 2 ;;
    esac
    CARRIER_APPROVAL_SHA256=$(sha256sum "$path" | cut -d' ' -f1)
}

# 返回封闭的 holder 命令。
carrier_holder_argv() { printf 'unshare --net --mount --propagation private\n'; }

# 返回本轮独立 dockerd 参数。
carrier_dockerd_argv() {
    local run=${1:-}
    [[ $run =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 2
    printf 'dockerd --config-file /var/lib/gitdaemon-validation/%s/daemon.json --data-root /var/lib/gitdaemon-validation/%s/docker-data --exec-root /run/gitdaemon-validation/%s/docker-exec --pidfile /run/gitdaemon-validation/%s/dockerd.pid --host unix:///run/gitdaemon-validation/%s/docker.sock\n' "$run" "$run" "$run" "$run" "$run"
}

# 测试夹具生成与生产格式相同的 state 和 manifest 摘要链。
carrier_test_state_write() {
    local approval=$1 state=$2 manifest=$3 approval_hash state_hash
    carrier_approval_load "$approval" || return $?
    approval_hash=$CARRIER_APPROVAL_SHA256
    {
        printf 'schema_version\t1\nrun_id\t%s\n' "$CARRIER_RUN_ID"
        printf 'host_machine_id\t0123456789abcdef0123456789abcdef\nhost_boot_id\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
        printf 'holder_pid\t31337\nholder_start_ticks\t888\nnetns_device\t4\nnetns_inode\t4001\nmntns_device\t4\nmntns_inode\t4002\n'
        printf 'dockerd_pid\t31338\ndockerd_start_ticks\t889\ndaemon_id\tdaemon-contract-0001\n'
        printf 'docker_endpoint\tunix:///run/gitdaemon-validation/%s/docker.sock\n' "$CARRIER_RUN_ID"
        printf 'socket_realpath\t/run/gitdaemon-validation/%s/docker.sock\nsocket_device\t9999\nsocket_inode\t4242\nsocket_uid\t0\nsocket_gid\t10001\n' "$CARRIER_RUN_ID"
        printf 'data_root\t/var/lib/gitdaemon-validation/%s/docker-data\nexec_root\t/run/gitdaemon-validation/%s/docker-exec\n' "$CARRIER_RUN_ID" "$CARRIER_RUN_ID"
        printf 'approval_sha256\t%s\n' "$approval_hash"
    } > "$state"
    chmod 600 "$state"
    state_hash=$(sha256sum "$state" | cut -d' ' -f1)
    printf 'carrier_state_sha256\t%s\napproval_path\t%s\n' "$state_hash" "$approval" > "$manifest"
    chmod 600 "$manifest"
}

# 加载状态字段。
carrier_state_load() {
    local state=$1 i key value
    carrier_parse_exact "$state" "$CARRIER_STATE_KEYS" 22 || return $?
    for i in "${!CARRIER_PARSED_KEYS[@]}"; do
        key=${CARRIER_PARSED_KEYS[i]}; value=${CARRIER_PARSED_VALUES[i]}
        case "$key" in
            run_id) CS_RUN_ID=$value ;; host_machine_id) CS_MACHINE_ID=$value ;; host_boot_id) CS_BOOT_ID=$value ;;
            holder_pid) CS_HOLDER_PID=$value ;; holder_start_ticks) CS_HOLDER_START=$value ;;
            netns_device) CS_NET_DEVICE=$value ;; netns_inode) CS_NET_INODE=$value ;;
            mntns_device) CS_MNT_DEVICE=$value ;; mntns_inode) CS_MNT_INODE=$value ;;
            daemon_id) CS_DAEMON_ID=$value ;; docker_endpoint) CS_ENDPOINT=$value ;;
            socket_realpath) CS_SOCKET_REALPATH=$value ;; socket_device) CS_SOCKET_DEVICE=$value ;;
            socket_inode) CS_SOCKET_INODE=$value ;; socket_uid) CS_SOCKET_UID=$value ;; socket_gid) CS_SOCKET_GID=$value ;;
            approval_sha256) CS_APPROVAL_SHA=$value ;;
        esac
    done
}

# 核验 holder、namespace、socket 与 daemon 身份。
carrier_verify() {
    local state=${1:-} current holder socket actual
    [[ $# == 1 ]] || return 2
    carrier_state_load "$state" || return $?
    [[ $(carrier_host_machine_id) == "$CS_MACHINE_ID" && $(carrier_host_boot_id) == "$CS_BOOT_ID" ]] || return 77
    [[ $(carrier_proc_starttime "$CS_HOLDER_PID") == "$CS_HOLDER_START" ]] || return 77
    current=$(carrier_current_namespace | tr '\n' ' '); holder="$CS_NET_DEVICE $CS_NET_INODE $CS_MNT_DEVICE $CS_MNT_INODE "
    [[ $current == "$holder" ]] || return 77
    [[ $current != "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    socket=$(carrier_socket_facts "$CS_SOCKET_REALPATH") || return 77
    [[ $socket == "$CS_SOCKET_DEVICE $CS_SOCKET_INODE $CS_SOCKET_UID $CS_SOCKET_GID $CS_SOCKET_REALPATH" ]] || return 77
    actual=$(carrier_daemon_id "$CS_ENDPOINT") || return 77
    [[ $actual == "$CS_DAEMON_ID" ]] || return 77
}

# 绑定固定审批副本、state 与 manifest 后运行封闭模式。
carrier_run() {
    local state=$1 manifest=$2 attestation=$3 profile=$4 mode=$5 evidence=$6 order=$7 approval state_hash expected_hash approval_path requested_order
    [[ $# == 7 ]] || return 2
    [[ -f $manifest && ! -L $manifest ]] || return 77
    expected_hash=$(awk -F '\t' '$1=="carrier_state_sha256"{print $2}' "$manifest")
    approval_path=$(awk -F '\t' '$1=="approval_path"{print $2}' "$manifest")
    state_hash=$(sha256sum "$state" 2>/dev/null | cut -d' ' -f1)
    [[ -n $expected_hash && $state_hash == "$expected_hash" ]] || return 77
    carrier_state_load "$state" || return $?
    approval=$approval_path
    carrier_approval_load "$approval" || { [[ $? == 2 ]] && return 77; return 77; }
    [[ $CARRIER_APPROVAL_SHA256 == "$CS_APPROVAL_SHA" ]] || return 77
    requested_order=${order:-none}
    [[ $mode == "$CARRIER_ALLOWED_MODE" && $requested_order == "$CARRIER_ALLOWED_ORDER" ]] || return 77
    carrier_verify "$state" || return $?
    carrier_effect guard "$mode" "$attestation" "$profile" "$evidence" "$order"
}

# 固定宿主只读 Docker argv 清单。
carrier_host_inventory_argv() {
    printf "docker --host unix:///var/run/docker.sock info --format '{{.ID}}'; docker --host unix:///var/run/docker.sock container ls -aq --no-trunc; docker --host unix:///var/run/docker.sock network ls -q --no-trunc; docker --host unix:///var/run/docker.sock volume ls -q; docker --host unix:///var/run/docker.sock image ls -aq --no-trunc\n"
}

# 宿主盘点只接受 root、宿主 namespace 和 before/after 固定阶段。
carrier_host_inventory() {
    local approval=${1:-} state_dir=${2:-} phase=${3:-}
    [[ $# == 3 && -n $approval && -n $state_dir ]] || return 2
    [[ $phase == before || $phase == after ]] || return 2
    [[ $(carrier_current_uid) == 0 ]] || return 77
    carrier_approval_load "$approval" || return $?
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" ]] || return 77
    [[ $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    carrier_effect inventory "$phase" "$(carrier_host_inventory_argv)"
}
