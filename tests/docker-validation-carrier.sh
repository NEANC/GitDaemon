#!/usr/bin/env bash
# 独立 namespace 验证载体：严格绑定审批、holder、socket 与私有 dockerd 路径。

CARRIER_APPROVAL_KEYS='schema_version run_id expires_at_epoch host_machine_id host_boot_id runner_user runner_uid runner_gid source_dir source_sha256 product_image_id tools_image_id product_archive product_archive_sha256 tools_archive tools_archive_sha256 mapping_profile_sha256 dockerd_sha256 storage_driver allowed_mode allowed_order'
CARRIER_STATE_KEYS='schema_version run_id host_machine_id host_boot_id holder_pid holder_start_ticks netns_device netns_inode mntns_device mntns_inode dockerd_pid dockerd_start_ticks daemon_id docker_endpoint socket_realpath socket_device socket_inode socket_uid socket_gid data_root exec_root approval_sha256'
CARRIER_MANIFEST_KEYS='schema_version profile run_id expires_at_epoch machine_id boot_id offline_attestation_sha256 runner_user runner_uid runner_gid source_dir source_sha256 runner_entry docker_endpoint daemon_id socket_realpath socket_device socket_inode socket_uid socket_gid product_image_id tools_image_id mapping_profile_sha256 holder_pid holder_start_ticks netns_device netns_inode mntns_device mntns_inode carrier_state_sha256'
CARRIER_ALLOWED_MODE=''
CARRIER_ALLOWED_ORDER=''
CARRIER_RUN_ID=''
CARRIER_APPROVAL_SHA256=''
CARRIER_HOST_MACHINE_ID=''
CARRIER_HOST_BOOT_ID=''
CARRIER_SOURCE_DIR=''
CARRIER_SOURCE_SHA256=''
CARRIER_PRODUCT_IMAGE_ID=''
CARRIER_TOOLS_IMAGE_ID=''
CARRIER_MAPPING_PROFILE_SHA256=''
CARRIER_RUNNER_USER=''
CARRIER_RUNNER_UID=''
CARRIER_RUNNER_GID=''
CARRIER_EXPIRES_AT_EPOCH=''

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
carrier_host_readonly_query() { local argv=$1; bash -c "$argv"; }
carrier_path_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
carrier_source_sha256() {
    ( CDPATH= cd -- "$1" 2>/dev/null || exit 1
      find . -type f -not -path './.git/*' -not -path './docs/superpowers/*' -print0 |
          LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1 )
}
carrier_dockerd_sha256() { local path; path=$(command -v dockerd) || return 1; carrier_path_sha256 "$path"; }
carrier_state_root() { printf '/var/lib/gitdaemon-validation\n'; }
carrier_runtime_root() { printf '/run/gitdaemon-validation\n'; }
carrier_holder_namespace() { stat -Lc '%d %i' "/proc/$1/ns/net"; stat -Lc '%d %i' "/proc/$1/ns/mnt"; }
carrier_start_holder() { unshare --net --mount --propagation private sleep infinity >/dev/null 2>&1 & printf '%s\n' "$!"; }
carrier_start_dockerd() { local holder=$1; shift; nsenter --target "$holder" --net --mount -- "$@" >/dev/null 2>&1 & printf '%s\n' "$!"; }

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
            expires_at_epoch) CARRIER_EXPIRES_AT_EPOCH=$value ;;
            runner_user) CARRIER_RUNNER_USER=$value ;;
            runner_uid) CARRIER_RUNNER_UID=$value ;;
            runner_gid) CARRIER_RUNNER_GID=$value ;;
            source_dir) CARRIER_SOURCE_DIR=$value ;;
            source_sha256) CARRIER_SOURCE_SHA256=$value ;;
            product_image_id) CARRIER_PRODUCT_IMAGE_ID=$value ;;
            tools_image_id) CARRIER_TOOLS_IMAGE_ID=$value ;;
            mapping_profile_sha256) CARRIER_MAPPING_PROFILE_SHA256=$value ;;
            allowed_mode) CARRIER_ALLOWED_MODE=$value ;;
            allowed_order) CARRIER_ALLOWED_ORDER=$value ;;
        esac
    done
    [[ $CARRIER_RUN_ID =~ ^[A-Za-z0-9-]{1,32}$ ]] || return 2
    [[ $CARRIER_HOST_MACHINE_ID =~ ^[0-9A-Fa-f]{16,64}$ ]] || return 2
    [[ $CARRIER_HOST_BOOT_ID =~ ^[0-9A-Fa-f-]{16,64}$ ]] || return 2
    [[ $CARRIER_RUNNER_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 2
    case "$CARRIER_ALLOWED_MODE" in
        mapping-probe|mapping-fallback|mapping-direct|full) [[ $CARRIER_ALLOWED_ORDER == none ]] || return 2 ;;
        mapping-sequence) [[ $CARRIER_ALLOWED_ORDER == fallback,direct || $CARRIER_ALLOWED_ORDER == direct,fallback ]] || return 2 ;;
        *) return 2 ;;
    esac
    [[ $CARRIER_EXPIRES_AT_EPOCH =~ ^[0-9]{1,12}$ ]] || return 2
    [[ $CARRIER_RUNNER_UID =~ ^[1-9][0-9]{0,9}$ && $CARRIER_RUNNER_GID =~ ^[0-9]{1,10}$ ]] || return 2
    [[ $CARRIER_SOURCE_DIR == /* && $CARRIER_SOURCE_SHA256 =~ ^[0-9a-f]{64}$ ]] || return 2
    [[ $CARRIER_PRODUCT_IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ && $CARRIER_TOOLS_IMAGE_ID =~ ^sha256:[0-9a-f]{64}$ ]] || return 2
    [[ $CARRIER_MAPPING_PROFILE_SHA256 =~ ^[0-9a-f]{64}$ ]] || return 2
    for i in "${!CARRIER_PARSED_KEYS[@]}"; do
        key=${CARRIER_PARSED_KEYS[i]}; value=${CARRIER_PARSED_VALUES[i]}
        case "$key" in
            product_archive|tools_archive) [[ $value == /* ]] || return 2 ;;
            product_archive_sha256|tools_archive_sha256|dockerd_sha256) [[ $value =~ ^[0-9a-f]{64}$ ]] || return 2 ;;
            storage_driver) [[ $value == vfs ]] || return 2 ;;
        esac
    done
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

# 创建固定审批副本、独立 holder/dockerd，并原子写入完整状态。
carrier_create() {
    local approval=${1:-} state_dir=${2:-} state_root runtime_root run_dir approval_copy holder holder_start namespace
    local net_device net_inode mnt_device mnt_inode socket_device socket_inode socket_uid socket_gid socket_realpath
    local dockerd dockerd_start endpoint socket data_root exec_root daemon facts approval_hash
    [[ $# == 2 ]] || return 2
    [[ $(carrier_current_uid) == 0 ]] || return 77
    carrier_approval_load "$approval" || return $?
    [[ $(carrier_now_epoch) -le CARRIER_EXPIRES_AT_EPOCH ]] || return 77
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" && $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    local product_archive tools_archive product_archive_sha tools_archive_sha dockerd_sha i key value
    for i in "${!CARRIER_PARSED_KEYS[@]}"; do
        key=${CARRIER_PARSED_KEYS[i]}; value=${CARRIER_PARSED_VALUES[i]}
        case "$key" in
            product_archive) product_archive=$value ;; product_archive_sha256) product_archive_sha=$value ;;
            tools_archive) tools_archive=$value ;; tools_archive_sha256) tools_archive_sha=$value ;;
            dockerd_sha256) dockerd_sha=$value ;;
        esac
    done
    [[ $(carrier_source_sha256 "$CARRIER_SOURCE_DIR") == "$CARRIER_SOURCE_SHA256" ]] || return 77
    [[ $(carrier_path_sha256 "$product_archive") == "$product_archive_sha" ]] || return 77
    [[ $(carrier_path_sha256 "$tools_archive") == "$tools_archive_sha" ]] || return 77
    [[ $(carrier_dockerd_sha256) == "$dockerd_sha" ]] || return 77
    state_root=$(carrier_state_root); runtime_root=$(carrier_runtime_root)
    [[ $state_dir == "$state_root/$CARRIER_RUN_ID" && ! -e $state_dir ]] || return 77
    run_dir=$runtime_root/$CARRIER_RUN_ID
    mkdir -p "$state_dir" "$run_dir" || return 80
    chmod 700 "$state_dir" "$run_dir" || return 80
    approval_copy=$state_dir/approval.tsv
    cp -- "$approval" "$approval_copy" || return 80
    chmod 600 "$approval_copy" || return 80
    carrier_approval_load "$approval_copy" || return 77
    approval_hash=$CARRIER_APPROVAL_SHA256
    holder=$(carrier_start_holder) || return 80
    holder_start=$(carrier_proc_starttime "$holder") || return 80
    namespace=$(carrier_holder_namespace "$holder" | tr '\n' ' ') || return 80
    read -r net_device net_inode mnt_device mnt_inode <<< "$namespace"
    data_root=$state_dir/docker-data; exec_root=$run_dir/docker-exec
    mkdir -p "$data_root" "$exec_root" || return 80
    printf '{}\n' > "$state_dir/daemon.json" || return 80
    chmod 600 "$state_dir/daemon.json" || return 80
    endpoint=unix://$run_dir/docker.sock; socket=$run_dir/docker.sock
    dockerd=$(carrier_start_dockerd "$holder" dockerd --config-file "$state_dir/daemon.json" --data-root "$data_root" --exec-root "$exec_root" --pidfile "$run_dir/dockerd.pid" --host "$endpoint") || return 80
    dockerd_start=$(carrier_proc_starttime "$dockerd") || return 80
    facts=$(carrier_socket_facts "$socket") || return 80
    daemon=$(carrier_daemon_id "$endpoint") || return 80
    read -r socket_device socket_inode socket_uid socket_gid socket_realpath <<< "$facts"
    {
        printf 'schema_version\t1\nrun_id\t%s\n' "$CARRIER_RUN_ID"
        printf 'host_machine_id\t%s\nhost_boot_id\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID"
        printf 'holder_pid\t%s\nholder_start_ticks\t%s\n' "$holder" "$holder_start"
        printf 'netns_device\t%s\nnetns_inode\t%s\nmntns_device\t%s\nmntns_inode\t%s\n' "$net_device" "$net_inode" "$mnt_device" "$mnt_inode"
        printf 'dockerd_pid\t%s\ndockerd_start_ticks\t%s\ndaemon_id\t%s\n' "$dockerd" "$dockerd_start" "$daemon"
        printf 'docker_endpoint\t%s\nsocket_realpath\t%s\n' "$endpoint" "$socket"
        printf 'socket_device\t%s\nsocket_inode\t%s\nsocket_uid\t%s\nsocket_gid\t%s\n' "$socket_device" "$socket_inode" "$socket_uid" "$socket_gid"
        printf 'data_root\t%s\nexec_root\t%s\napproval_sha256\t%s\n' "$data_root" "$exec_root" "$approval_hash"
    } > "$state_dir/state.tsv.tmp" || return 80
    chmod 600 "$state_dir/state.tsv.tmp" || return 80
    mv "$state_dir/state.tsv.tmp" "$state_dir/state.tsv" || return 80
    [[ $(sha256sum "$approval_copy" | cut -d' ' -f1) == "$approval_hash" ]] || return 77
}

# 测试夹具生成与生产格式相同的 state 和 manifest 摘要链。
carrier_test_state_write() {
    local approval=$1 state=$2 manifest=$3 approval_hash state_hash state_root runtime_root
    carrier_approval_load "$approval" || return $?
    approval_hash=$CARRIER_APPROVAL_SHA256
    state_root=$(carrier_state_root); runtime_root=$(carrier_runtime_root)
    {
        printf 'schema_version\t1\nrun_id\t%s\n' "$CARRIER_RUN_ID"
        printf 'host_machine_id\t0123456789abcdef0123456789abcdef\nhost_boot_id\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
        printf 'holder_pid\t31337\nholder_start_ticks\t888\nnetns_device\t4\nnetns_inode\t4001\nmntns_device\t4\nmntns_inode\t4002\n'
        printf 'dockerd_pid\t31338\ndockerd_start_ticks\t889\ndaemon_id\tdaemon-contract-0001\n'
        printf 'docker_endpoint\tunix://%s/%s/docker.sock\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'socket_realpath\t%s/%s/docker.sock\nsocket_device\t9999\nsocket_inode\t4242\nsocket_uid\t0\nsocket_gid\t10001\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'data_root\t%s/%s/docker-data\nexec_root\t%s/%s/docker-exec\n' "$state_root" "$CARRIER_RUN_ID" "$runtime_root" "$CARRIER_RUN_ID"
        printf 'approval_sha256\t%s\n' "$approval_hash"
    } > "$state"
    chmod 600 "$state"
    state_hash=$(sha256sum "$state" | cut -d' ' -f1)
    {
        printf 'schema_version\t2\nprofile\tisolated-netns\nrun_id\t%s\nexpires_at_epoch\t2000000000\n' "$CARRIER_RUN_ID"
        printf 'machine_id\t%s\nboot_id\t%s\noffline_attestation_sha256\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID" "$CARRIER_MAPPING_PROFILE_SHA256"
        printf 'runner_user\t%s\nrunner_uid\t%s\nrunner_gid\t%s\n' "$CARRIER_RUNNER_USER" "$CARRIER_RUNNER_UID" "$CARRIER_RUNNER_GID"
        printf 'source_dir\t%s\nsource_sha256\t%s\nrunner_entry\ttests/test-docker-network.sh\n' "$CARRIER_SOURCE_DIR" "$CARRIER_SOURCE_SHA256"
        printf 'docker_endpoint\tunix://%s/%s/docker.sock\ndaemon_id\tdaemon-contract-0001\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'socket_realpath\t%s/%s/docker.sock\nsocket_device\t9999\nsocket_inode\t4242\nsocket_uid\t0\nsocket_gid\t10001\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'product_image_id\t%s\ntools_image_id\t%s\nmapping_profile_sha256\t%s\n' "$CARRIER_PRODUCT_IMAGE_ID" "$CARRIER_TOOLS_IMAGE_ID" "$CARRIER_MAPPING_PROFILE_SHA256"
        printf 'holder_pid\t31337\nholder_start_ticks\t888\nnetns_device\t4\nnetns_inode\t4001\nmntns_device\t4\nmntns_inode\t4002\n'
        printf 'carrier_state_sha256\t%s\n' "$state_hash"
    } > "$manifest"
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
            data_root) CS_DATA_ROOT=$value ;; exec_root) CS_EXEC_ROOT=$value ;;
            dockerd_pid) CS_DOCKERD_PID=$value ;; dockerd_start_ticks) CS_DOCKERD_START=$value ;;
            approval_sha256) CS_APPROVAL_SHA=$value ;;
        esac
    done
}

# 加载 schema 2 的完整签认清单，禁止审批路径等额外字段。
carrier_manifest_load() {
    local manifest=$1 i key value
    carrier_parse_exact "$manifest" "$CARRIER_MANIFEST_KEYS" 30 || return $?
    for i in "${!CARRIER_PARSED_KEYS[@]}"; do
        key=${CARRIER_PARSED_KEYS[i]}; value=${CARRIER_PARSED_VALUES[i]}
        case "$key" in
            schema_version) CM_SCHEMA=$value ;; profile) CM_PROFILE=$value ;; run_id) CM_RUN_ID=$value ;;
            machine_id) CM_MACHINE_ID=$value ;; boot_id) CM_BOOT_ID=$value ;;
            runner_user) CM_RUNNER_USER=$value ;; runner_uid) CM_RUNNER_UID=$value ;; runner_gid) CM_RUNNER_GID=$value ;;
            source_dir) CM_SOURCE_DIR=$value ;; source_sha256) CM_SOURCE_SHA=$value ;;
            docker_endpoint) CM_ENDPOINT=$value ;; daemon_id) CM_DAEMON_ID=$value ;;
            socket_realpath) CM_SOCKET_REALPATH=$value ;; socket_device) CM_SOCKET_DEVICE=$value ;;
            socket_inode) CM_SOCKET_INODE=$value ;; socket_uid) CM_SOCKET_UID=$value ;; socket_gid) CM_SOCKET_GID=$value ;;
            product_image_id) CM_PRODUCT_IMAGE=$value ;; tools_image_id) CM_TOOLS_IMAGE=$value ;;
            mapping_profile_sha256) CM_PROFILE_SHA=$value ;; holder_pid) CM_HOLDER_PID=$value ;;
            holder_start_ticks) CM_HOLDER_START=$value ;; netns_device) CM_NET_DEVICE=$value ;;
            netns_inode) CM_NET_INODE=$value ;; mntns_device) CM_MNT_DEVICE=$value ;; mntns_inode) CM_MNT_INODE=$value ;;
            carrier_state_sha256) CM_STATE_SHA=$value ;;
        esac
    done
    [[ $CM_SCHEMA == 2 && $CM_PROFILE == isolated-netns ]] || return 77
}

# 核验 holder、namespace、socket 与 daemon 身份。
carrier_verify() {
    local state=${1:-} current holder_ns socket actual state_root runtime_root
    [[ $# == 1 ]] || return 2
    carrier_state_load "$state" || return $?
    [[ $(carrier_host_machine_id) == "$CS_MACHINE_ID" && $(carrier_host_boot_id) == "$CS_BOOT_ID" ]] || return 77
    [[ $(carrier_proc_starttime "$CS_HOLDER_PID") == "$CS_HOLDER_START" ]] || return 77
    holder_ns=$(carrier_holder_namespace "$CS_HOLDER_PID" | tr '\n' ' ')
    [[ $holder_ns == "$CS_NET_DEVICE $CS_NET_INODE $CS_MNT_DEVICE $CS_MNT_INODE " ]] || return 77
    current=$(carrier_current_namespace | tr '\n' ' ')
    [[ $current == "$holder_ns" ]] || return 77
    [[ $current != "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    state_root=$(carrier_state_root); runtime_root=$(carrier_runtime_root)
    [[ $CS_DATA_ROOT == "$state_root/$CS_RUN_ID/docker-data" && $CS_EXEC_ROOT == "$runtime_root/$CS_RUN_ID/docker-exec" ]] || return 77
    [[ $CS_ENDPOINT == "unix://$runtime_root/$CS_RUN_ID/docker.sock" && $CS_SOCKET_REALPATH == "$runtime_root/$CS_RUN_ID/docker.sock" ]] || return 77
    [[ $(carrier_proc_starttime "$CS_DOCKERD_PID") == "$CS_DOCKERD_START" ]] || return 77
    socket=$(carrier_socket_facts "$CS_SOCKET_REALPATH") || return 77
    [[ $socket == "$CS_SOCKET_DEVICE $CS_SOCKET_INODE $CS_SOCKET_UID $CS_SOCKET_GID $CS_SOCKET_REALPATH" ]] || return 77
    actual=$(carrier_daemon_id "$CS_ENDPOINT") || return 77
    [[ $actual == "$CS_DAEMON_ID" ]] || return 77
}

# 从宿主控制面核验 holder 的持有身份，不要求调用者已进入目标 namespace。
carrier_holder_verify() {
    local state=$1 holder_ns state_root runtime_root
    carrier_state_load "$state" || return $?
    [[ $(carrier_host_machine_id) == "$CS_MACHINE_ID" && $(carrier_host_boot_id) == "$CS_BOOT_ID" ]] || return 77
    [[ $(carrier_proc_starttime "$CS_HOLDER_PID") == "$CS_HOLDER_START" ]] || return 77
    holder_ns=$(carrier_holder_namespace "$CS_HOLDER_PID" | tr '\n' ' ')
    [[ $holder_ns == "$CS_NET_DEVICE $CS_NET_INODE $CS_MNT_DEVICE $CS_MNT_INODE " ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    [[ $holder_ns != "$(carrier_current_namespace | tr '\n' ' ')" ]] || return 77
    state_root=$(carrier_state_root); runtime_root=$(carrier_runtime_root)
    [[ $CS_DATA_ROOT == "$state_root/$CS_RUN_ID/docker-data" && $CS_EXEC_ROOT == "$runtime_root/$CS_RUN_ID/docker-exec" ]] || return 77
    [[ $CS_ENDPOINT == "unix://$runtime_root/$CS_RUN_ID/docker.sock" && $CS_SOCKET_REALPATH == "$runtime_root/$CS_RUN_ID/docker.sock" ]] || return 77
    [[ $(carrier_proc_starttime "$CS_DOCKERD_PID") == "$CS_DOCKERD_START" ]] || return 77
    [[ $(carrier_socket_facts "$CS_SOCKET_REALPATH") == "$CS_SOCKET_DEVICE $CS_SOCKET_INODE $CS_SOCKET_UID $CS_SOCKET_GID $CS_SOCKET_REALPATH" ]] || return 77
    [[ $(carrier_daemon_id "$CS_ENDPOINT") == "$CS_DAEMON_ID" ]] || return 77
}

# 绑定固定审批副本、state 与 manifest 后运行封闭模式。
carrier_run() {
    local state=$1 manifest=$2 attestation=$3 profile=$4 mode=$5 evidence=$6 order=$7 approval state_hash expected_hash requested_order guard_path
    [[ $# == 7 ]] || return 2
    carrier_manifest_load "$manifest" || return $?
    expected_hash=$CM_STATE_SHA
    state_hash=$(sha256sum "$state" 2>/dev/null | cut -d' ' -f1)
    [[ -n $expected_hash && $state_hash == "$expected_hash" ]] || return 77
    carrier_state_load "$state" || return $?
    approval=$(dirname "$state")/approval.tsv
    carrier_approval_load "$approval" || { [[ $? == 2 ]] && return 77; return 77; }
    [[ $CARRIER_APPROVAL_SHA256 == "$CS_APPROVAL_SHA" ]] || return 77
    [[ $CM_RUN_ID == "$CS_RUN_ID" && $CM_MACHINE_ID == "$CS_MACHINE_ID" && $CM_BOOT_ID == "$CS_BOOT_ID" ]] || return 77
    [[ $CM_RUNNER_USER == "$CARRIER_RUNNER_USER" && $CM_RUNNER_UID == "$CARRIER_RUNNER_UID" && $CM_RUNNER_GID == "$CARRIER_RUNNER_GID" ]] || return 77
    [[ $CM_SOURCE_DIR == "$CARRIER_SOURCE_DIR" && $CM_SOURCE_SHA == "$CARRIER_SOURCE_SHA256" ]] || return 77
    [[ $CM_PRODUCT_IMAGE == "$CARRIER_PRODUCT_IMAGE_ID" && $CM_TOOLS_IMAGE == "$CARRIER_TOOLS_IMAGE_ID" && $CM_PROFILE_SHA == "$CARRIER_MAPPING_PROFILE_SHA256" ]] || return 77
    [[ $CM_HOLDER_PID == "$CS_HOLDER_PID" && $CM_HOLDER_START == "$CS_HOLDER_START" ]] || return 77
    [[ $CM_NET_DEVICE == "$CS_NET_DEVICE" && $CM_NET_INODE == "$CS_NET_INODE" && $CM_MNT_DEVICE == "$CS_MNT_DEVICE" && $CM_MNT_INODE == "$CS_MNT_INODE" ]] || return 77
    [[ $CM_ENDPOINT == "$CS_ENDPOINT" && $CM_DAEMON_ID == "$CS_DAEMON_ID" && $CM_SOCKET_REALPATH == "$CS_SOCKET_REALPATH" ]] || return 77
    [[ $CM_SOCKET_DEVICE == "$CS_SOCKET_DEVICE" && $CM_SOCKET_INODE == "$CS_SOCKET_INODE" && $CM_SOCKET_UID == "$CS_SOCKET_UID" && $CM_SOCKET_GID == "$CS_SOCKET_GID" ]] || return 77
    requested_order=${order:-none}
    [[ $mode == "$CARRIER_ALLOWED_MODE" && $requested_order == "$CARRIER_ALLOWED_ORDER" ]] || return 77
    [[ $(carrier_now_epoch) -le CARRIER_EXPIRES_AT_EPOCH ]] || return 77
    [[ $CS_RUN_ID == "$CARRIER_RUN_ID" && $CS_MACHINE_ID == "$CARRIER_HOST_MACHINE_ID" && $CS_BOOT_ID == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    carrier_holder_verify "$state" || return $?
    guard_path=$(dirname "${BASH_SOURCE[0]}")/docker-network-guard.sh
    if [[ $mode == mapping-sequence ]]; then
        carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- env IT_MAPPING_ORDER="$order" bash "$guard_path" "$mode" "$CARRIER_SOURCE_DIR" "$CS_RUN_ID" "$evidence" "$CARRIER_PRODUCT_IMAGE_ID" "$CARRIER_TOOLS_IMAGE_ID" "$manifest" "$attestation" "$profile"
        return $?
    fi
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- env -u IT_MAPPING_ORDER bash "$guard_path" "$mode" "$CARRIER_SOURCE_DIR" "$CS_RUN_ID" "$evidence" "$CARRIER_PRODUCT_IMAGE_ID" "$CARRIER_TOOLS_IMAGE_ID" "$manifest" "$attestation" "$profile"
}

# 在同一 holder namespace 中执行封闭清理入口。
carrier_cleanup() {
    local state=${1:-} evidence=${2:-}
    [[ $# == 2 && $evidence == /* ]] || return 2
    carrier_holder_verify "$state" || return $?
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- cleanup "$state" "$evidence"
}

# 恢复要求操作者显式确认 runner 已停止，再复用同一身份核验边界。
carrier_recover() {
    local state=${1:-} evidence=${2:-} confirmation=${3:-}
    [[ $# == 3 && $evidence == /* ]] || return 2
    [[ $confirmation == --runner-stopped ]] || return 64
    carrier_holder_verify "$state" || return $?
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- recover "$state" "$evidence" "$confirmation"
}

# 固定宿主只读 Docker argv 清单。
carrier_host_inventory_argv() {
    printf "docker --host unix:///var/run/docker.sock info --format '{{.ID}}'; docker --host unix:///var/run/docker.sock container ls -aq --no-trunc; docker --host unix:///var/run/docker.sock network ls -q --no-trunc; docker --host unix:///var/run/docker.sock volume ls -q; docker --host unix:///var/run/docker.sock image ls -aq --no-trunc\n"
}

# 宿主盘点只接受 root、宿主 namespace 和 before/after 固定阶段。
carrier_host_inventory() {
    local approval=${1:-} state_dir=${2:-} phase=${3:-} snapshot identity argv
    [[ $# == 3 && -n $approval && -n $state_dir ]] || return 2
    [[ $phase == before || $phase == after ]] || return 2
    [[ $(carrier_current_uid) == 0 ]] || return 77
    carrier_approval_load "$approval" || return $?
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" ]] || return 77
    [[ $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    snapshot=$state_dir/host-$phase
    [[ ! -e $snapshot ]] || return 77
    mkdir -p "$snapshot" || return 80
    identity=$(carrier_host_namespace | tr '\n' ' ')
    {
        printf 'machine_id\t%s\nboot_id\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID"
        printf 'namespace\t%s\n' "$identity"
    } > "$snapshot/identity.tsv" || return 80
    argv=$(carrier_host_inventory_argv)
    carrier_host_readonly_query "$argv" > "$snapshot/docker.tsv" || return 80
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" && $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$identity" ]] || return 77
    : > "$snapshot/complete" || return 80
}
