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
CARRIER_DOCKERD_READY_ATTEMPTS=${CARRIER_DOCKERD_READY_ATTEMPTS:-100}

# 外部事实边界。
carrier_now_epoch() { date +%s; }
carrier_current_uid() { id -u; }
carrier_host_machine_id() { tr -d '[:space:]' < /etc/machine-id; }
carrier_host_boot_id() { tr -d '[:space:]' < /proc/sys/kernel/random/boot_id; }
carrier_current_namespace() { stat -Lc '%d %i' /proc/self/ns/net; stat -Lc '%d %i' /proc/self/ns/mnt; }
carrier_host_namespace() { stat -Lc '%d %i' /proc/1/ns/net; stat -Lc '%d %i' /proc/1/ns/mnt; }
carrier_proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
carrier_socket_facts() { local real; real=$(readlink -f -- "$1") || return 1; stat -Lc "%d %i %u %g %a $real" "$real"; }
carrier_daemon_id() { command docker --host "$1" info --format '{{.ID}}'; }
carrier_effect() { "$@"; }
carrier_file_facts() { stat -c '%u %a' "$1" 2>/dev/null; }
carrier_host_readonly_query() { "$@"; }
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
carrier_process_alive() { kill -0 "$1" 2>/dev/null; }
carrier_sleep() { sleep "$1"; }
carrier_stop_process() { kill -TERM "$1" 2>/dev/null || return 0; }
carrier_wait_process() {
    local pid=$1 attempt
    for ((attempt=0; attempt<CARRIER_DOCKERD_READY_ATTEMPTS; attempt++)); do
        carrier_process_alive "$pid" || return 0
        carrier_sleep 0.1
    done
    return 80
}
carrier_remove_tree() { rm -rf -- "$1"; }
carrier_configure_socket() { chown "0:$2" "$1" && chmod 660 "$1"; }
carrier_configure_directory() { chown "$2:$3" "$1" && chmod "$4" "$1"; }
carrier_docker_context() { command docker context show 2>/dev/null; }
carrier_host_socket_facts() { carrier_socket_facts /var/run/docker.sock; }
carrier_host_daemon_id() { carrier_host_readonly_query docker --host unix:///var/run/docker.sock info --format '{{.ID}}'; }

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
    [[ $CARRIER_RUN_ID =~ ^[A-Za-z0-9-]{1,10}$ ]] || return 2
    [[ $CARRIER_HOST_MACHINE_ID =~ ^[0-9A-Fa-f]{16,64}$ ]] || return 2
    [[ $CARRIER_HOST_BOOT_ID =~ ^[0-9A-Fa-f-]{16,64}$ ]] || return 2
    [[ $CARRIER_RUNNER_USER == gmtest ]] || return 2
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
    printf 'dockerd --config-file /var/lib/gitdaemon-validation/%s/daemon.json --data-root /var/lib/gitdaemon-validation/%s/docker-data --exec-root /run/gitdaemon-validation/%s/docker-exec --pidfile /run/gitdaemon-validation/%s/dockerd.pid --host unix:///run/gitdaemon-validation/%s/docker.sock --containerd-namespace gitdaemon-%s --containerd-plugins-namespace gitdaemon-%s-plugins\n' "$run" "$run" "$run" "$run" "$run" "$run" "$run"
}

# 等待私有 daemon 可查询并返回稳定身份。
carrier_wait_dockerd() {
    local endpoint=$1 pid=$2 attempt daemon
    for ((attempt=0; attempt<CARRIER_DOCKERD_READY_ATTEMPTS; attempt++)); do
        carrier_process_alive "$pid" || return 80
        daemon=$(carrier_daemon_id "$endpoint" 2>/dev/null) && [[ -n $daemon ]] && { printf '%s\n' "$daemon"; return 0; }
        carrier_sleep 0.1
    done
    return 80
}

# 只撤销本次 create 已产生的进程和目录。
carrier_create_rollback() {
    local holder=${1:-} dockerd=${2:-} state_dir=${3:-} run_dir=${4:-}
    if [[ -n $dockerd ]]; then
        carrier_stop_process "$dockerd" || return 80
        carrier_wait_process "$dockerd" || return 80
    fi
    if [[ -n $holder ]]; then
        carrier_stop_process "$holder" || return 80
        carrier_wait_process "$holder" || return 80
    fi
    [[ -z $run_dir || ! -e $run_dir ]] || carrier_remove_tree "$run_dir"
    if [[ -n $state_dir && -e $state_dir ]]; then
        if carrier_host_snapshot_complete "$state_dir/host-before"; then
            [[ ! -e $state_dir/approval.tsv ]] || carrier_remove_tree "$state_dir/approval.tsv"
            [[ ! -e $state_dir/state.tsv ]] || carrier_remove_tree "$state_dir/state.tsv"
            [[ ! -e $state_dir/state.tsv.tmp ]] || carrier_remove_tree "$state_dir/state.tsv.tmp"
            [[ ! -e $state_dir/daemon.json ]] || carrier_remove_tree "$state_dir/daemon.json"
            [[ ! -e $state_dir/docker-data ]] || carrier_remove_tree "$state_dir/docker-data"
        else
            carrier_remove_tree "$state_dir"
        fi
    fi
}

carrier_host_snapshot_complete() {
    local snapshot=${1:-} name
    [[ -d $snapshot && ! -L $snapshot && -f $snapshot/complete && -f $snapshot/identity.tsv && -s $snapshot/commands.tsv ]] || return 1
    while IFS= read -r name; do
        [[ -n $name && -f $snapshot/$name.argv && -f $snapshot/$name.exit && -f $snapshot/$name.stdout && -f $snapshot/$name.stderr ]] || return 1
        grep -qx '0' "$snapshot/$name.exit" || return 1
    done < "$snapshot/commands.tsv"
}

carrier_host_snapshot_matches_approval() {
    local snapshot=${1:-} identity namespace
    carrier_host_snapshot_complete "$snapshot" || return 1
    identity=$snapshot/identity.tsv
    namespace=$(carrier_host_namespace | tr '\n' ' ') || return 1
    grep -Fqx $'machine_id\t'"$CARRIER_HOST_MACHINE_ID" "$identity" || return 1
    grep -Fqx $'boot_id\t'"$CARRIER_HOST_BOOT_ID" "$identity" || return 1
    grep -Fqx $'namespace\t'"$namespace" "$identity" || return 1
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
    [[ $state_dir == "$state_root/$CARRIER_RUN_ID" ]] || return 77
    if [[ -e $state_dir ]]; then
        carrier_host_snapshot_matches_approval "$state_dir/host-before" || return 77
        [[ ! -e $state_dir/approval.tsv && ! -e $state_dir/state.tsv && ! -e $state_dir/daemon.json && ! -e $state_dir/docker-data ]] || return 77
        find "$state_dir" -mindepth 1 -maxdepth 1 ! -name host-before -print -quit | grep -q . && return 77
    fi
    run_dir=$runtime_root/$CARRIER_RUN_ID
    [[ ! -e $run_dir ]] || return 77
    mkdir -p "$state_dir" "$run_dir" || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    carrier_configure_directory "$state_dir" 0 0 700 || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    carrier_configure_directory "$run_dir" 0 "$CARRIER_RUNNER_GID" 710 || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    approval_copy=$state_dir/approval.tsv
    cp -- "$approval" "$approval_copy" || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    chmod 600 "$approval_copy" || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    carrier_approval_load "$approval_copy" || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 77; }
    approval_hash=$CARRIER_APPROVAL_SHA256
    holder=$(carrier_start_holder) || { carrier_create_rollback '' '' "$state_dir" "$run_dir"; return 80; }
    holder_start=$(carrier_proc_starttime "$holder") || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    namespace=$(carrier_holder_namespace "$holder" | tr '\n' ' ') || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    read -r net_device net_inode mnt_device mnt_inode <<< "$namespace"
    data_root=$state_dir/docker-data; exec_root=$run_dir/docker-exec
    mkdir -p "$data_root" "$exec_root" || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    printf '{}\n' > "$state_dir/daemon.json" || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    chmod 600 "$state_dir/daemon.json" || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    endpoint=unix://$run_dir/docker.sock; socket=$run_dir/docker.sock
    dockerd=$(carrier_start_dockerd "$holder" dockerd --config-file "$state_dir/daemon.json" --data-root "$data_root" --exec-root "$exec_root" --pidfile "$run_dir/dockerd.pid" --host "$endpoint" --containerd-namespace "gitdaemon-$CARRIER_RUN_ID" --containerd-plugins-namespace "gitdaemon-$CARRIER_RUN_ID-plugins") || { carrier_create_rollback "$holder" '' "$state_dir" "$run_dir"; return 80; }
    dockerd_start=$(carrier_proc_starttime "$dockerd") || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    daemon=$(carrier_wait_dockerd "$endpoint" "$dockerd") || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    carrier_configure_socket "$socket" "$CARRIER_RUNNER_GID" || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    facts=$(carrier_socket_facts "$socket") || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    local socket_mode
    read -r socket_device socket_inode socket_uid socket_gid socket_mode socket_realpath <<< "$facts"
    [[ $socket_uid == 0 && $socket_gid == "$CARRIER_RUNNER_GID" && $socket_mode == 660 ]] || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 77; }
    {
        printf 'schema_version\t1\nrun_id\t%s\n' "$CARRIER_RUN_ID"
        printf 'host_machine_id\t%s\nhost_boot_id\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID"
        printf 'holder_pid\t%s\nholder_start_ticks\t%s\n' "$holder" "$holder_start"
        printf 'netns_device\t%s\nnetns_inode\t%s\nmntns_device\t%s\nmntns_inode\t%s\n' "$net_device" "$net_inode" "$mnt_device" "$mnt_inode"
        printf 'dockerd_pid\t%s\ndockerd_start_ticks\t%s\ndaemon_id\t%s\n' "$dockerd" "$dockerd_start" "$daemon"
        printf 'docker_endpoint\t%s\nsocket_realpath\t%s\n' "$endpoint" "$socket"
        printf 'socket_device\t%s\nsocket_inode\t%s\nsocket_uid\t%s\nsocket_gid\t%s\n' "$socket_device" "$socket_inode" "$socket_uid" "$socket_gid"
        printf 'data_root\t%s\nexec_root\t%s\napproval_sha256\t%s\n' "$data_root" "$exec_root" "$approval_hash"
    } > "$state_dir/state.tsv.tmp" || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    chmod 600 "$state_dir/state.tsv.tmp" || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    mv "$state_dir/state.tsv.tmp" "$state_dir/state.tsv" || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 80; }
    [[ $(sha256sum "$approval_copy" | cut -d' ' -f1) == "$approval_hash" ]] || { carrier_create_rollback "$holder" "$dockerd" "$state_dir" "$run_dir"; return 77; }
}

# 测试夹具生成与生产格式相同的 state 和 manifest 摘要链。
carrier_test_state_write() {
    local approval=$1 state=$2 manifest=$3 attestation=${4:-$(dirname "$state")/attestation} profile=${5:-$(dirname "$state")/profile}
    local approval_hash state_hash state_root runtime_root attestation_hash profile_hash explicit_inputs=0
    [[ $# -lt 5 ]] || explicit_inputs=1
    carrier_approval_load "$approval" || return $?
    approval_hash=$CARRIER_APPROVAL_SHA256
    state_root=$(carrier_state_root); runtime_root=$(carrier_runtime_root)
    [[ -f $attestation ]] || printf 'attestation\n' > "$attestation"
    [[ -f $profile ]] || printf 'profile\n' > "$profile"
    if (( explicit_inputs )); then
        attestation_hash=$(sha256sum "$attestation" | cut -d' ' -f1)
        profile_hash=$(sha256sum "$profile" | cut -d' ' -f1)
    else
        attestation_hash=$CARRIER_MAPPING_PROFILE_SHA256
        profile_hash=$CARRIER_MAPPING_PROFILE_SHA256
    fi
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
        printf 'machine_id\t%s\nboot_id\t%s\noffline_attestation_sha256\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID" "$attestation_hash"
        printf 'runner_user\t%s\nrunner_uid\t%s\nrunner_gid\t%s\n' "$CARRIER_RUNNER_USER" "$CARRIER_RUNNER_UID" "$CARRIER_RUNNER_GID"
        printf 'source_dir\t%s\nsource_sha256\t%s\nrunner_entry\ttests/test-docker-network.sh\n' "$CARRIER_SOURCE_DIR" "$CARRIER_SOURCE_SHA256"
        printf 'docker_endpoint\tunix://%s/%s/docker.sock\ndaemon_id\tdaemon-contract-0001\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'socket_realpath\t%s/%s/docker.sock\nsocket_device\t9999\nsocket_inode\t4242\nsocket_uid\t0\nsocket_gid\t10001\n' "$runtime_root" "$CARRIER_RUN_ID"
        printf 'product_image_id\t%s\ntools_image_id\t%s\nmapping_profile_sha256\t%s\n' "$CARRIER_PRODUCT_IMAGE_ID" "$CARRIER_TOOLS_IMAGE_ID" "$profile_hash"
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
            expires_at_epoch) CM_EXPIRES_AT=$value ;; machine_id) CM_MACHINE_ID=$value ;; boot_id) CM_BOOT_ID=$value ;;
            offline_attestation_sha256) CM_ATTESTATION_SHA=$value ;;
            runner_user) CM_RUNNER_USER=$value ;; runner_uid) CM_RUNNER_UID=$value ;; runner_gid) CM_RUNNER_GID=$value ;;
            source_dir) CM_SOURCE_DIR=$value ;; source_sha256) CM_SOURCE_SHA=$value ;; runner_entry) CM_RUNNER_ENTRY=$value ;;
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
    [[ $CM_EXPIRES_AT =~ ^[0-9]{1,12}$ && $CM_RUNNER_ENTRY == tests/test-docker-network.sh ]] || return 77
    [[ $CM_ATTESTATION_SHA =~ ^[0-9a-f]{64}$ && $CM_PROFILE_SHA =~ ^[0-9a-f]{64}$ && $CM_STATE_SHA =~ ^[0-9a-f]{64}$ ]] || return 77
}

# 核验 holder、namespace、socket 与 daemon 身份。
carrier_verify() {
    local state=${1:-} current holder_ns socket actual state_root runtime_root socket_mode
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
    read -r _ _ _ _ socket_mode _ <<< "$socket"
    [[ $socket == "$CS_SOCKET_DEVICE $CS_SOCKET_INODE $CS_SOCKET_UID $CS_SOCKET_GID 660 $CS_SOCKET_REALPATH" ]] || return 77
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
    [[ $(carrier_socket_facts "$CS_SOCKET_REALPATH") == "$CS_SOCKET_DEVICE $CS_SOCKET_INODE $CS_SOCKET_UID $CS_SOCKET_GID 660 $CS_SOCKET_REALPATH" ]] || return 77
    [[ $(carrier_daemon_id "$CS_ENDPOINT") == "$CS_DAEMON_ID" ]] || return 77
}

# 绑定固定审批副本、state 与 manifest 后运行封闭模式。
carrier_run() {
    local state=$1 manifest=$2 attestation=$3 profile=$4 mode=$5 evidence=$6 order=$7 approval state_hash expected_hash requested_order guard_path
    [[ $# == 7 ]] || return 2
    carrier_manifest_load "$manifest" || return $?
    [[ $(carrier_path_sha256 "$attestation") == "$CM_ATTESTATION_SHA" ]] || return 77
    [[ $(carrier_path_sha256 "$profile") == "$CM_PROFILE_SHA" ]] || return 77
    expected_hash=$CM_STATE_SHA
    state_hash=$(sha256sum "$state" 2>/dev/null | cut -d' ' -f1)
    [[ -n $expected_hash && $state_hash == "$expected_hash" ]] || return 77
    carrier_state_load "$state" || return $?
    approval=$(dirname "$state")/approval.tsv
    carrier_approval_load "$approval" || { [[ $? == 2 ]] && return 77; return 77; }
    [[ $CARRIER_APPROVAL_SHA256 == "$CS_APPROVAL_SHA" ]] || return 77
    [[ $CM_EXPIRES_AT == "$CARRIER_EXPIRES_AT_EPOCH" ]] || return 77
    [[ $CM_RUN_ID == "$CS_RUN_ID" && $CM_MACHINE_ID == "$CS_MACHINE_ID" && $CM_BOOT_ID == "$CS_BOOT_ID" ]] || return 77
    [[ $CM_RUNNER_USER == "$CARRIER_RUNNER_USER" && $CM_RUNNER_UID == "$CARRIER_RUNNER_UID" && $CM_RUNNER_GID == "$CARRIER_RUNNER_GID" ]] || return 77
    [[ $CM_SOURCE_DIR == "$CARRIER_SOURCE_DIR" && $CM_SOURCE_SHA == "$CARRIER_SOURCE_SHA256" ]] || return 77
    [[ $(carrier_source_sha256 "$CARRIER_SOURCE_DIR") == "$CARRIER_SOURCE_SHA256" ]] || return 77
    [[ $CM_PRODUCT_IMAGE == "$CARRIER_PRODUCT_IMAGE_ID" && $CM_TOOLS_IMAGE == "$CARRIER_TOOLS_IMAGE_ID" && $CM_PROFILE_SHA == "$CARRIER_MAPPING_PROFILE_SHA256" ]] || return 77
    [[ $CM_HOLDER_PID == "$CS_HOLDER_PID" && $CM_HOLDER_START == "$CS_HOLDER_START" ]] || return 77
    [[ $CM_NET_DEVICE == "$CS_NET_DEVICE" && $CM_NET_INODE == "$CS_NET_INODE" && $CM_MNT_DEVICE == "$CS_MNT_DEVICE" && $CM_MNT_INODE == "$CS_MNT_INODE" ]] || return 77
    [[ $CM_ENDPOINT == "$CS_ENDPOINT" && $CM_DAEMON_ID == "$CS_DAEMON_ID" && $CM_SOCKET_REALPATH == "$CS_SOCKET_REALPATH" ]] || return 77
    [[ $CM_SOCKET_DEVICE == "$CS_SOCKET_DEVICE" && $CM_SOCKET_INODE == "$CS_SOCKET_INODE" && $CM_SOCKET_UID == "$CS_SOCKET_UID" && $CM_SOCKET_GID == "$CS_SOCKET_GID" ]] || return 77
    requested_order=${order:-none}
    [[ $mode == "$CARRIER_ALLOWED_MODE" && $requested_order == "$CARRIER_ALLOWED_ORDER" ]] || return 77
    [[ $mode != mapping-sequence ]] || return 77
    [[ $(carrier_now_epoch) -le CARRIER_EXPIRES_AT_EPOCH ]] || return 77
    [[ $CS_RUN_ID == "$CARRIER_RUN_ID" && $CS_MACHINE_ID == "$CARRIER_HOST_MACHINE_ID" && $CS_BOOT_ID == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ $evidence == "$(dirname "$state")/evidence" ]] || return 77
    carrier_holder_verify "$state" || return $?
    guard_path=$(dirname "${BASH_SOURCE[0]}")/docker-network-guard.sh
    if [[ $mode == mapping-sequence ]]; then
        carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- env IT_MAPPING_ORDER="$order" bash "$guard_path" --mode "$mode" --source-dir "$CARRIER_SOURCE_DIR" --run-id "$CS_RUN_ID" --evidence-dir "$evidence" --runner-user "$CARRIER_RUNNER_USER" --product-image "$CARRIER_PRODUCT_IMAGE_ID" --tools-image "$CARRIER_TOOLS_IMAGE_ID" --environment-manifest "$manifest" --offline-attestation "$attestation" --mapping-profile "$profile"
        return $?
    fi
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- env -u IT_MAPPING_ORDER bash "$guard_path" --mode "$mode" --source-dir "$CARRIER_SOURCE_DIR" --run-id "$CS_RUN_ID" --evidence-dir "$evidence" --runner-user "$CARRIER_RUNNER_USER" --product-image "$CARRIER_PRODUCT_IMAGE_ID" --tools-image "$CARRIER_TOOLS_IMAGE_ID" --environment-manifest "$manifest" --offline-attestation "$attestation" --mapping-profile "$profile"
}

# 在已验证的 holder 内复用统一资源账本执行真实精确清理。
carrier_internal_cleanup() {
    local state=${1:-} evidence=${2:-} source
    [[ $# == 2 && $evidence == /* ]] || return 2
    carrier_verify "$state" || return $?
    source=$(dirname "${BASH_SOURCE[0]}")
    source "$source/docker-validation-environment.sh" || return 2
    source "$source/docker-resource-ledger.sh" || return 2
    VE_SCHEMA_VERSION=2
    VE_RUN_ID=$CS_RUN_ID
    VE_DOCKER_ENDPOINT=$CS_ENDPOINT
    resource_docker() { validation_docker "$@"; }
    RESOURCE_LEDGER_DIR=$evidence/control/resources RESOURCE_RUN=$CS_RUN_ID
    resource_cleanup "$RESOURCE_LEDGER_DIR" || return 2
}

# 在同一 holder namespace 中执行封闭清理入口。
carrier_cleanup() {
    local state=${1:-} evidence=${2:-} script state_dir run_dir
    [[ $# == 2 && $evidence == /* ]] || return 2
    carrier_holder_verify "$state" || return $?
    script=$(readlink -f -- "${BASH_SOURCE[0]}") || return 77
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- bash "$script" internal-cleanup "$state" "$evidence" || return $?
    state_dir=$(dirname "$state"); run_dir=$(dirname "$CS_EXEC_ROOT")
    carrier_stop_process "$CS_DOCKERD_PID"
    carrier_stop_process "$CS_HOLDER_PID"
    [[ ! -e $run_dir ]] || carrier_remove_tree "$run_dir" || return 2
    [[ ! -e $CS_DATA_ROOT ]] || carrier_remove_tree "$CS_DATA_ROOT" || return 2
}

# 恢复要求操作者显式确认 runner 已停止，再复用同一身份核验边界。
carrier_recover() {
    local state=${1:-} evidence=${2:-} confirmation=${3:-} recovery binding run digest actual rc=0 summary
    [[ $# == 3 && $evidence == /* ]] || return 2
    [[ $confirmation == --runner-stopped ]] || return 64
    carrier_holder_verify "$state" || return $?
    [[ $evidence == "$(dirname "$state")/evidence" && -d $evidence && ! -L $evidence ]] || return 77
    recovery=$evidence/recover.sh
    binding=$evidence/recovery-binding.tsv
    carrier_file_guard "$recovery" || return 77
    carrier_file_guard "$binding" || return 77
    run=$(awk -F '\t' '$1 == "run_id" {print $2}' "$binding")
    digest=$(awk -F '\t' '$1 == "recover_sha256" {print $2}' "$binding")
    [[ $(wc -l < "$binding") == 2 && $run == "$CS_RUN_ID" && $digest =~ ^[0-9a-f]{64}$ ]] || return 77
    actual=$(carrier_path_sha256 "$recovery")
    [[ $actual == "$digest" ]] || return 77
    carrier_effect nsenter --target "$CS_HOLDER_PID" --net --mount -- bash "$recovery" "$confirmation" || rc=$?
    summary=$evidence/recovery-summary.tsv
    {
        printf 'run_id\t%s\nrecover_sha256\t%s\nrecover_exit\t%s\n' "$CS_RUN_ID" "$digest" "$rc"
    } > "$summary.tmp" || return 2
    chmod 600 "$summary.tmp" && mv "$summary.tmp" "$summary" || return 2
    return "$rc"
}

# 固定宿主只读 Docker argv 清单。
carrier_host_inventory_argv() {
    printf "%s\n" \
        "docker --host unix:///var/run/docker.sock info --format '{{.ID}}'" \
        'docker --host unix:///var/run/docker.sock container ls -aq --no-trunc' \
        'docker --host unix:///var/run/docker.sock network ls -q --no-trunc' \
        'docker --host unix:///var/run/docker.sock volume ls -q' \
        'docker --host unix:///var/run/docker.sock image ls -aq --no-trunc' \
        'ip -4 route show table all' 'ip -6 route show table all' 'ip -4 rule show' 'ip -6 rule show' \
        'ip -4 address show' 'ip -6 address show' 'iptables-save' 'ip6tables-save'
}

# 将固定命令的 argv、退出码和输出分别持久化。
carrier_host_inventory_command() {
    local snapshot=$1 name=$2; shift 2
    local rc=0
    printf '%q ' "$@" > "$snapshot/$name.argv"; printf '\n' >> "$snapshot/$name.argv"
    carrier_host_readonly_query "$@" > "$snapshot/$name.stdout" 2> "$snapshot/$name.stderr" || rc=$?
    printf '%s\n' "$rc" > "$snapshot/$name.exit"
    printf '%s\n' "$name" >> "$snapshot/commands.tsv"
    [[ $rc == 0 ]]
}

# 对列表结果逐项执行对应 inspect，并保留每个对象的独立命令证据。
carrier_host_inventory_inspect() {
    local snapshot=$1 kind=$2 list_name=$3 identity evidence_id
    while IFS= read -r identity; do
        [[ -z $identity ]] && continue
        [[ $identity != -* ]] || return 80
        case "$kind" in
            container|network) [[ $identity =~ ^[0-9a-f]{64}$ ]] || return 80 ;;
            image) [[ $identity =~ ^sha256:[0-9a-f]{64}$ ]] || return 80 ;;
            volume) [[ $identity =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$ ]] || return 80 ;;
            *) return 80 ;;
        esac
        evidence_id=${identity#sha256:}
        carrier_host_inventory_command "$snapshot" "$kind-inspect-$evidence_id" docker --host unix:///var/run/docker.sock "$kind" inspect "$identity" || return 80
    done < <(LC_ALL=C sort -u "$snapshot/$list_name.stdout")
}

# 规范化宿主快照的无语义顺序、规则计数与工具时间戳。
carrier_host_inventory_normalize() {
    local name=$1 path=$2
    case "$name" in
        iptables|ip6tables)
            sed -E '/^# (Generated|Completed) /d; s/^\[[0-9]+:[0-9]+\][[:space:]]*//' "$path" ;;
        containers|networks|volumes|images) LC_ALL=C sort -u "$path" ;;
        *) cat "$path" ;;
    esac
}

# 核验宿主 socket 与 daemon 仍为同一登记身份。
carrier_host_identity_verify() {
    local expected_socket=$1 expected_daemon=$2 actual_socket actual_daemon
    actual_socket=$(carrier_host_socket_facts) || return 77
    [[ $actual_socket == "$expected_socket" ]] || return 77
    actual_daemon=$(carrier_host_daemon_id) || return 80
    [[ $actual_daemon == "$expected_daemon" ]] || return 77
}

# 比较完整前后命令集合与输出，不把查询失败当作空集合。
carrier_host_inventory_compare() {
    local state_dir=${1:-} before after name
    [[ $# == 1 ]] || return 2
    before=$state_dir/host-before; after=$state_dir/host-after
    [[ -f $before/complete && -f $after/complete ]] || return 2
    cmp -s "$before/commands.tsv" "$after/commands.tsv" || return 1
    while IFS= read -r name; do
        cmp -s "$before/$name.argv" "$after/$name.argv" || return 1
        grep -qx '0' "$before/$name.exit" && grep -qx '0' "$after/$name.exit" || return 1
        cmp -s <(carrier_host_inventory_normalize "$name" "$before/$name.stdout") <(carrier_host_inventory_normalize "$name" "$after/$name.stdout") || return 1
        cmp -s "$before/$name.stderr" "$after/$name.stderr" || return 1
    done < "$before/commands.tsv"
}

# 宿主盘点只接受 root、宿主 namespace 和 before/after 固定阶段。
carrier_host_inventory() {
    local approval=${1:-} state_dir=${2:-} phase=${3:-} snapshot identity socket daemon context key before
    [[ $# == 3 && -n $approval && -n $state_dir ]] || return 2
    [[ $phase == before || $phase == after ]] || return 2
    [[ $(carrier_current_uid) == 0 ]] || return 77
    for key in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
        [[ -z ${!key:-} ]] || return 77
    done
    context=$(carrier_docker_context) || context=''
    [[ -z $context || $context == default || $context == unix:///var/run/docker.sock ]] || return 77
    carrier_approval_load "$approval" || return $?
    [[ $state_dir == "$(carrier_state_root)/$CARRIER_RUN_ID" ]] || return 77
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" ]] || return 77
    [[ $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$(carrier_host_namespace | tr '\n' ' ')" ]] || return 77
    snapshot=$state_dir/host-$phase
    [[ ! -e $snapshot ]] || return 77
    mkdir -p "$snapshot" || return 80
    identity=$(carrier_host_namespace | tr '\n' ' ')
    socket=$(carrier_host_socket_facts) || return 77
    read -r socket_device socket_inode socket_uid socket_gid socket_mode socket_realpath <<< "$socket"
    [[ $socket_realpath == /var/run/docker.sock && $socket_uid == 0 && $socket_mode =~ ^0?660$ ]] || return 77
    daemon=$(carrier_host_daemon_id) || return 80
    [[ -n $daemon ]] || return 80
    if [[ $phase == after ]]; then
        before=$state_dir/host-before/identity.tsv
        [[ -f $state_dir/host-before/complete && -f $before ]] || return 77
        grep -Fqx $'socket_realpath\t'"$socket_realpath" "$before" || return 77
        grep -Fqx $'socket_device\t'"$socket_device" "$before" || return 77
        grep -Fqx $'socket_inode\t'"$socket_inode" "$before" || return 77
        grep -Fqx $'socket_uid\t'"$socket_uid" "$before" || return 77
        grep -Fqx $'socket_gid\t'"$socket_gid" "$before" || return 77
        grep -Fqx $'daemon_id\t'"$daemon" "$before" || return 77
    fi
    {
        printf 'machine_id\t%s\nboot_id\t%s\n' "$CARRIER_HOST_MACHINE_ID" "$CARRIER_HOST_BOOT_ID"
        printf 'namespace\t%s\n' "$identity"
        printf 'socket_realpath\t%s\nsocket_device\t%s\nsocket_inode\t%s\nsocket_uid\t%s\nsocket_gid\t%s\n' "$socket_realpath" "$socket_device" "$socket_inode" "$socket_uid" "$socket_gid"
        printf 'daemon_id\t%s\n' "$daemon"
    } > "$snapshot/identity.tsv" || return 80
    : > "$snapshot/commands.tsv"
    carrier_host_inventory_command "$snapshot" docker-info docker --host unix:///var/run/docker.sock info --format '{{.ID}}' || return 80
    carrier_host_inventory_command "$snapshot" containers docker --host unix:///var/run/docker.sock container ls -aq --no-trunc || return 80
    carrier_host_inventory_inspect "$snapshot" container containers || return 80
    carrier_host_inventory_command "$snapshot" networks docker --host unix:///var/run/docker.sock network ls -q --no-trunc || return 80
    carrier_host_inventory_inspect "$snapshot" network networks || return 80
    carrier_host_inventory_command "$snapshot" volumes docker --host unix:///var/run/docker.sock volume ls -q || return 80
    carrier_host_inventory_inspect "$snapshot" volume volumes || return 80
    carrier_host_inventory_command "$snapshot" images docker --host unix:///var/run/docker.sock image ls -aq --no-trunc || return 80
    carrier_host_inventory_inspect "$snapshot" image images || return 80
    carrier_host_inventory_command "$snapshot" route4 ip -4 route show table all || return 80
    carrier_host_inventory_command "$snapshot" route6 ip -6 route show table all || return 80
    carrier_host_inventory_command "$snapshot" rule4 ip -4 rule show || return 80
    carrier_host_inventory_command "$snapshot" rule6 ip -6 rule show || return 80
    carrier_host_inventory_command "$snapshot" address4 ip -4 address show || return 80
    carrier_host_inventory_command "$snapshot" address6 ip -6 address show || return 80
    carrier_host_inventory_command "$snapshot" iptables iptables-save || return 80
    carrier_host_inventory_command "$snapshot" ip6tables ip6tables-save || return 80
    carrier_host_identity_verify "$socket" "$daemon" || return $?
    [[ $(carrier_host_machine_id) == "$CARRIER_HOST_MACHINE_ID" && $(carrier_host_boot_id) == "$CARRIER_HOST_BOOT_ID" ]] || return 77
    [[ "$(carrier_current_namespace | tr '\n' ' ')" == "$identity" ]] || return 77
    : > "$snapshot/complete" || return 80
}

# 封闭 CLI 只暴露载体入口，不接受任意命令。
carrier_cli() {
    local action=${1:-}; shift || true
    case "$action" in
        create) carrier_create "$@" ;;
        run) carrier_run "$@" ;;
        cleanup) carrier_cleanup "$@" ;;
        recover) carrier_recover "$@" ;;
        host-inventory) carrier_host_inventory "$@" ;;
        internal-cleanup) carrier_internal_cleanup "$@" ;;
        *) return 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    carrier_cli "$@"
fi
