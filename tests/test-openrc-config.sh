#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-openrc-config.XXXXXXXX") || exit 1
CHECKS=0
FAILURES=0

# 仅删除本轮测试自行创建的临时树。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

# 每项检查使用独立进程环境，输出具体断言失败而不隐藏子进程诊断。
check() {
    local label=$1
    shift
    if [[ -n ${TEST_FILTER-} && $label != *"$TEST_FILTER"* ]]; then return 0; fi
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 安装真实交付文件；初始化在子 Shell 内运行，不能替服务父环境准备配置。
prepare_fixture() {
    mkdir -p -- "$work/capture" "$work/boundary" || return 1
    unset GIT_PORT LISTEN_ADDRESS TZ PROXY_URL ENABLE_CRON CRON_SCHEDULE
    unset ENABLE_HOSTS_UPDATE HOSTS_CRON HOSTS_URL HOSTS_URL_FALLBACK
    unset GITHUB_TOKEN GITHUB_TOKEN_FILE REPOS SHORT_LINKS BASH_ENV
    source "$ROOT/scripts/deploy-git-mirror.sh"
    # 平台、私有模式位和 flock 为明确边界桩，其他预检与文件读写使用真实代码。
    gm_check_platform() { return 0; }
    gm_check_private_directory() { return 0; }
    flock() { return 0; }
    gm_deploy_main --install --install-root "$work/program" || return 1
    export REPOS=git/git
    ( gm_deploy_main --init --install-root "$work/program" --run-root "$work/instance" ) || return 1
    export INSTALL_ROOT=$work/program RUN_ROOT=$work/instance
    export XDG_RUNTIME_DIR=$RUN_ROOT/runtime SERVICE_CAPTURE=$work/capture
    export SERVICE_BOUNDARY=$work/boundary
    cat > "$work/boundary/git" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SERVICE_CAPTURE/argv"
printf '%s\n' "${TZ-unset}" "${GITHUB_TOKEN+present}" "${GITHUB_TOKEN_FILE+present}" > "$SERVICE_CAPTURE/environment"
FIXTURE
    chmod 755 -- "$work/boundary/git" || return 1
    cat > "$work/boundary/bash-env" <<'FIXTURE'
# 真实入口加载真实共享模块后，仅替换宿主无法提供的外部边界。
source() {
    builtin source "$@" || return $?
    if [[ ${1-} == "$INSTALL_ROOT/lib/foundation.sh" ]]; then
        gm_check_platform() { return 0; }
        gm_check_private_directory() { return 0; }
        flock() { return 0; }
    fi
    return 0
}
# 截获最终 Git 执行；保留真实生产入口构造的 argv，不启动监听进程。
exec() {
    if [[ ${1-} == /usr/bin/git ]]; then
        shift
        builtin exec "$SERVICE_BOUNDARY/git" "$@"
    fi
    builtin exec "$@"
}
FIXTURE
    export BASH_ENV=$work/boundary/bash-env
}

# OpenRC 调度边界桩仅执行服务自己的 start_pre 和 command，不补任何配置接线。
run_service() {
    bash -c '
        source "$INSTALL_ROOT/openrc/git-daemon" || exit $?
        printf "%s\n" "${pidfile-}" > "$SERVICE_CAPTURE/pidfile"
        if [[ ${SERVICE_DISCONNECT-} == 1 ]]; then
            # 故障注入：仅断开真实服务启动前接线，恢复此前的环境默认参数。
            unset -f start_pre
            command_args="daemon --base-path=$RUN_ROOT/repos --listen=${LISTEN_ADDRESS:-0.0.0.0} --port=${GIT_PORT:-9418}"
        fi
        if declare -F start_pre >/dev/null; then start_pre || exit $?; fi
        printf "%s\n" command > "$SERVICE_CAPTURE/launched"
        arguments=()
        if [[ -n ${command_args-} ]]; then read -r -a arguments <<< "$command_args"; fi
        if [[ $command == /usr/bin/git ]]; then
            "$SERVICE_BOUNDARY/git" "${arguments[@]}"
        else
            "$command" "${arguments[@]}"
        fi
    '
}

# 从安装后的服务定义启动，核验真实最终参数、时区、拒绝行为和配置字节保持。
daemon_configuration() {
    local scenario=$1 work=$TEST_ROOT/$1 status=0 output
    local expected_port=12345 expected_address=127.0.0.1 expected_timezone=UTC expected_error=
    local argument port= address= base=
    local -a arguments=() environment=()
    prepare_fixture || return 1
    printf '%s\n' '# 保留原始配置字节' 'GIT_PORT=12345' 'LISTEN_ADDRESS=127.0.0.1' 'TZ=UTC' > "$RUN_ROOT/config/mirror.env"
    case "$scenario" in
        defaults)
            printf '%s\n' '# 使用默认值' > "$RUN_ROOT/config/mirror.env"
            expected_port=9418; expected_address=0.0.0.0; expected_timezone=Asia/Shanghai
            ;;
        environment)
            export GIT_PORT=23456 LISTEN_ADDRESS=::1 TZ=Asia/Hong_Kong
            expected_port=23456; expected_address=::1; expected_timezone=Asia/Hong_Kong
            ;;
        invalid-address)
            printf '%s\n' 'LISTEN_ADDRESS=::1:' > "$RUN_ROOT/config/mirror.env"
            export LISTEN_ADDRESS=127.0.0.1
            expected_error='git-mirror: 配置值非法：LISTEN_ADDRESS'
            ;;
        invalid-port)
            printf '%s\n' 'GIT_PORT=80' > "$RUN_ROOT/config/mirror.env"
            export GIT_PORT=23456
            expected_error='git-mirror: 配置值非法：GIT_PORT'
            ;;
        empty-environment)
            export GIT_PORT=
            expected_error='git-mirror: 有效配置值非法：GIT_PORT'
            ;;
        token) export GITHUB_TOKEN=service-sensitive-fixture ;;
        file) ;;
        *) return 1 ;;
    esac
    cp -- "$RUN_ROOT/config/mirror.env" "$work/config.before" || return 1
    run_service > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    cmp -s -- "$work/config.before" "$RUN_ROOT/config/mirror.env" || {
        printf '服务启动改写了配置文件\n'; return 1;
    }
    if [[ -n $expected_error ]]; then
        [[ $status == 1 && $output == "$expected_error" && ! -e $work/capture/launched && ! -e $work/capture/argv ]] || {
            printf '非法配置未在启动前阻断：status=%s，诊断=%s\n' "$status" "$output"
            return 1
        }
        return 0
    fi
    [[ $status == 0 && -f $work/capture/argv ]] || {
        printf '服务命令未成功到达 Git 边界：status=%s，诊断=%s\n' "$status" "$output"
        return 1
    }
    mapfile -d '' -t arguments < "$work/capture/argv"
    mapfile -t environment < "$work/capture/environment"
    [[ ${arguments[0]-} == daemon ]] || { printf '未执行 daemon 子命令\n'; return 1; }
    for argument in "${arguments[@]}"; do
        case "$argument" in
            --port=*) port=${argument#*=} ;;
            --listen=*) address=${argument#*=} ;;
            --base-path=*) base=${argument#*=} ;;
        esac
    done
    [[ $port == "$expected_port" && $address == "$expected_address" && $base == "$RUN_ROOT/repos" ]] || {
        printf 'daemon argv 不匹配：port=%s，listen=%s，base=%s；预期 port=%s，listen=%s\n' "$port" "$address" "$base" "$expected_port" "$expected_address"
        return 1
    }
    [[ ${environment[0]-} == "$expected_timezone" ]] || {
        printf 'daemon 时区不匹配：实际=%s，预期=%s\n' "${environment[0]-}" "$expected_timezone"
        return 1
    }
    [[ -z ${environment[1]-} && -z ${environment[2]-} ]] || {
        printf 'daemon 不应接收 GitHub 凭据环境\n'; return 1;
    }
    [[ $(<"$work/capture/pidfile") == "$XDG_RUNTIME_DIR/git-daemon.pid" ]] || return 1
    [[ $output != *service-sensitive-fixture* ]] || return 1
    if [[ $scenario == environment ]]; then
        [[ $GIT_PORT == 23456 && $LISTEN_ADDRESS == ::1 && $TZ == Asia/Hong_Kong ]] || return 1
    else
        [[ ! -v GIT_PORT && ! -v LISTEN_ADDRESS && ! -v TZ ]] || return 1
    fi
    return 0
}

# 断开生产钩子必须使同一文件配置断言失败，且失败原因只能是最终 argv 错误。
disconnected_wiring_guard() {
    local output status=0
    export SERVICE_DISCONNECT=1
    output=$(daemon_configuration file) || status=$?
    [[ $status == 1 && $output == *'daemon argv 不匹配：port=9418，listen=0.0.0.0'* ]] || {
        printf '断线故障未被实际参数断言捕获：status=%s\n%s\n' "$status" "$output"
        return 1
    }
    printf '%s\n' "$output" '断线后的同一服务测试退出 1，符合预期。'
    return 0
}

# 验证同步和刷新已有入口实际读取同一配置契约，不增加新的启动包装层。
worker_configuration() {
    local service=$1 work=$TEST_ROOT/worker-$1 status=0
    prepare_fixture || return 1
    printf '%s\n' 'TZ=UTC' 'HOSTS_URL=https://example.invalid/service-config' > "$RUN_ROOT/config/mirror.env"
    cp -- "$RUN_ROOT/config/mirror.env" "$work/config.before" || return 1
    cat >> "$work/boundary/bash-env" <<'FIXTURE'
# Git 与下载边界不联网，记录真实同步、刷新入口传来的配置。
git() {
    printf '%s\n' "${TZ-unset}" >> "$SERVICE_CAPTURE/worker-timezone"
    return 0
}
curl() {
    printf '%s\n' "$@" > "$SERVICE_CAPTURE/curl-argv"
    printf '%s\n' "${TZ-unset}" >> "$SERVICE_CAPTURE/worker-timezone"
    printf '%s\n' snapshot > "$RUN_ROOT/hosts/github-hosts.snapshot.tmp"
}
FIXTURE
    mkdir -p -- "$RUN_ROOT/repos/git/git.git" || return 1
    bash -c 'source "$INSTALL_ROOT/openrc/$1" || exit $?; "$command"' worker "$service" > "$work/output" 2>&1 || status=$?
    [[ $status == 0 && -s $work/capture/worker-timezone ]] || {
        printf '工作服务配置调用失败：%s，status=%s\n%s\n' "$service" "$status" "$(<"$work/output")"
        return 1
    }
    local timezone
    while IFS= read -r timezone; do [[ $timezone == UTC ]] || return 1; done < "$work/capture/worker-timezone"
    if [[ $service == git-mirror-hosts ]]; then
        [[ $(<"$work/capture/curl-argv") == *'https://example.invalid/service-config'* ]] || return 1
    fi
    cmp -s -- "$work/config.before" "$RUN_ROOT/config/mirror.env"
}

check '同步交付入口使用文件时区（外部边界桩）' worker_configuration git-mirror-sync
check '刷新交付入口使用文件 URL 与时区（外部边界桩）' worker_configuration git-mirror-hosts
check 'OpenRC 生产接线断开必须失败（故障注入）' disconnected_wiring_guard
for scenario in file defaults environment invalid-address invalid-port empty-environment token; do
    check "OpenRC 交付入口配置：$scenario（外部边界桩，非 Alpine 集成）" daemon_configuration "$scenario"
done
printf 'OpenRC 入口行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
