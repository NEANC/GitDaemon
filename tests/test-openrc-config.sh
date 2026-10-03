#!/usr/bin/env bash
set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-openrc-config.XXXXXXXX") || exit 1
CHECKS=0
FAILURES=0
# Git Bash 需要真实符号链接表示，初始化登记链接的行为才与 Alpine 一致。
export MSYS=winsymlinks:sys

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
    # 用户运行级引导边界桩：Windows 无 OpenRC，实例内登记产物仍由真实代码生成。
    gm_bootstrap_user_runlevel() { return 0; }
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
    local executable real_executable
    for executable in dirname id stat realpath; do
        real_executable=$(command -v "$executable") || return 1
        # 包装真实预检命令，只记录凭据变量存在性，不保存凭据值。
        printf '#!/usr/bin/env bash\nprintf "%%s:%%s\\n" "%s" "${GITHUB_TOKEN+present}" >> "$SERVICE_CAPTURE/preflight-environment"\nbuiltin exec %q "$@"\n' \
            "$executable" "$real_executable" > "$work/boundary/$executable"
        chmod 755 -- "$work/boundary/$executable" || return 1
    done
    export PATH="$work/boundary:$PATH"
    cat > "$work/boundary/bash-env" <<'FIXTURE'
# 在配置脚本执行第一条语句前捕获入口环境，不替生产代码清理凭据。
if [[ $0 == "$INSTALL_ROOT/git-daemon-config.sh" ]]; then
    printf 'config:%s\n' "${GITHUB_TOKEN+present}" >> "$SERVICE_CAPTURE/preflight-environment"
fi
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
        if [[ ${SERVICE_FILTER_ENVIRONMENT-} == 1 ]]; then
            source "$INSTALL_ROOT/lib/foundation.sh"
            allowed=$(gm_read_rc_env_allow "$RUN_ROOT/config/rc/rc.conf" | tr "\n" " ") || exit 1
            for key in GIT_PORT LISTEN_ADDRESS TZ ENABLE_CRON CRON_SCHEDULE ENABLE_HOSTS_UPDATE HOSTS_CRON HOSTS_URL HOSTS_URL_FALLBACK PROXY_URL SHORT_LINKS; do
                case " $allowed " in *" $key "*) ;; *) unset "$key" ;; esac
            done
            gm_load_config "$RUN_ROOT/config/mirror.env" || exit 1
            for key in ENABLE_CRON CRON_SCHEDULE ENABLE_HOSTS_UPDATE HOSTS_CRON HOSTS_URL HOSTS_URL_FALLBACK PROXY_URL; do
                [[ ${GM_CONFIG[$key]} == "${!key-}" ]] || { printf "配置未一致传递：%s\n" "$key"; exit 1; }
            done
            [[ ${SHORT_LINKS-} == "git/git fixture" ]] || exit 1
        fi
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

# 检查配置入口和真实预检命令包装器记录的环境，不输出凭据值。
assert_preflight_environment() {
    local boundary presence failed=0
    local -A seen=() reported=()
    [[ -s $work/capture/preflight-environment ]] || {
        printf '缺少配置与预检进程环境证据\n'; return 1;
    }
    while IFS=: read -r boundary presence; do
        seen[$boundary]=1
        if [[ -n $presence ]]; then
            if [[ ! ${reported[$boundary]-} ]]; then
                printf '前置进程不应继承 Token：%s\n' "$boundary"
                reported[$boundary]=1
            fi
            failed=1
        fi
    done < "$work/capture/preflight-environment"
    for boundary in config dirname id stat realpath; do
        [[ ${seen[$boundary]-} == 1 ]] || {
            printf '未捕获必要进程环境：%s\n' "$boundary"; failed=1;
        }
    done
    [[ $failed == 0 ]]
}

# 从安装后的服务定义启动，核验真实最终参数、时区、拒绝行为和配置字节保持。
daemon_configuration() {
    local scenario=$1 work=$TEST_ROOT/$1 status=0 output
    local expected_port=12345 expected_address=127.0.0.1 expected_timezone=UTC expected_error=
    local argument port= address= base= disable_receive=no forbid_receive=no
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
            if [[ ${SERVICE_FILTER_ENVIRONMENT-} == 1 ]]; then
                export ENABLE_CRON=no CRON_SCHEDULE='5 4 * * *' ENABLE_HOSTS_UPDATE=no HOSTS_CRON='6 4 * * *'
                export HOSTS_URL=https://example.invalid/primary HOSTS_URL_FALLBACK=https://example.invalid/fallback
                export PROXY_URL=https://example.invalid:8443 SHORT_LINKS='git/git fixture'
            fi
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
        token-invalid-port)
            export GITHUB_TOKEN=service-sensitive-fixture
            printf '%s\n' 'GIT_PORT=80' > "$RUN_ROOT/config/mirror.env"
            expected_error='git-mirror: 配置值非法：GIT_PORT'
            ;;
        token-file-conflict)
            export GITHUB_TOKEN=service-sensitive-fixture
            printf 'GITHUB_TOKEN_FILE=%s\n' "$RUN_ROOT/secrets/token" >> "$RUN_ROOT/config/mirror.env"
            expected_error='git-mirror: GITHUB_TOKEN 与 GITHUB_TOKEN_FILE 互斥'
            ;;
        token-environment-conflict)
            export GITHUB_TOKEN=service-sensitive-fixture GITHUB_TOKEN_FILE=$RUN_ROOT/secrets/token
            expected_error='git-mirror: GITHUB_TOKEN 与 GITHUB_TOKEN_FILE 互斥'
            ;;
        token-control)
            export GITHUB_TOKEN=$'service-sensitive-fixture\n'
            expected_error='git-mirror: 凭据包含非法控制字符'
            ;;
        token-empty)
            export GITHUB_TOKEN=
            ;;
        credential-file|credential-override|credential-empty|credential-missing)
            printf 'GITHUB_TOKEN_FILE=%s\n' "$RUN_ROOT/secrets/token" >> "$RUN_ROOT/config/mirror.env"
            if [[ $scenario != credential-missing ]]; then
                printf '%s\n' service-file-fixture > "$RUN_ROOT/secrets/token"
            fi
            case "$scenario" in
                credential-override)
                    printf 'GITHUB_TOKEN_FILE=%s\n' "$RUN_ROOT/secrets/not-used" > "$RUN_ROOT/config/mirror.env"
                    export GITHUB_TOKEN_FILE=$RUN_ROOT/secrets/token
                    expected_port=9418; expected_address=0.0.0.0; expected_timezone=Asia/Shanghai
                    ;;
                credential-empty)
                    export GITHUB_TOKEN_FILE=
                    expected_error='git-mirror: 不能以显式空值清除已配置凭据来源'
                    ;;
                credential-missing) expected_error='git-mirror: 凭据文件不存在或不可读' ;;
            esac
            ;;
        credential-invalid)
            export GITHUB_TOKEN_FILE=relative-token
            expected_error='git-mirror: 有效配置值非法：GITHUB_TOKEN_FILE'
            ;;
        file) ;;
        *) return 1 ;;
    esac
    cp -- "$RUN_ROOT/config/mirror.env" "$work/config.before" || return 1
    local token_before=${GITHUB_TOKEN+x}:${GITHUB_TOKEN-}
    local token_file_before=${GITHUB_TOKEN_FILE+x}:${GITHUB_TOKEN_FILE-}
    run_service > "$work/output" 2>&1 || status=$?
    output=$(<"$work/output")
    [[ ${GITHUB_TOKEN+x}:${GITHUB_TOKEN-} == "$token_before" && ${GITHUB_TOKEN_FILE+x}:${GITHUB_TOKEN_FILE-} == "$token_file_before" ]] || {
        printf '服务启动意外修改了调用者凭据环境\n'; return 1;
    }
    [[ $output != *service-sensitive-fixture* && $output != *service-file-fixture* ]] || {
        printf '服务诊断包含测试凭据值\n'; return 1;
    }
    if [[ ${SERVICE_DISCONNECT-} != 1 ]]; then
        assert_preflight_environment || return 1
    fi
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
            --disable=receive-pack) disable_receive=yes ;;
            --forbid-override=receive-pack) forbid_receive=yes ;;
            --export-all) printf 'daemon 不应绕过仓库导出标记\n'; return 1 ;;
        esac
    done
    [[ $port == "$expected_port" && $address == "$expected_address" && $base == "$RUN_ROOT/repos" ]] || {
        printf 'daemon argv 不匹配：port=%s，listen=%s，base=%s；预期 port=%s，listen=%s\n' "$port" "$address" "$base" "$expected_port" "$expected_address"
        return 1
    }
    [[ $disable_receive == yes && $forbid_receive == yes ]] || {
        printf 'daemon 必须禁用 receive-pack 并禁止仓库覆盖\n'; return 1;
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
    printf '%s\n' "${GITHUB_TOKEN+present}" >> "$SERVICE_CAPTURE/worker-token"
    return 0
}
curl() {
    printf '%s\n' "$@" > "$SERVICE_CAPTURE/curl-argv"
    printf '%s\n' "${TZ-unset}" >> "$SERVICE_CAPTURE/worker-timezone"
    printf '%s\n' '140.82.121.3 github.com' > "$RUN_ROOT/hosts/github-hosts.snapshot.tmp"
}
FIXTURE
    mkdir -p -- "$RUN_ROOT/repos/git/git.git" || return 1
    if [[ $service == git-mirror-sync ]]; then export GITHUB_TOKEN=service-sensitive-fixture; fi
    bash -c 'source "$INSTALL_ROOT/openrc/$1" || exit $?; "$command"' worker "$service" > "$work/output" 2>&1 || status=$?
    [[ $status == 0 && -s $work/capture/worker-timezone ]] || {
        printf '工作服务配置调用失败：%s，status=%s\n%s\n' "$service" "$status" "$(<"$work/output")"
        return 1
    }
    local timezone
    while IFS= read -r timezone; do [[ $timezone == UTC ]] || return 1; done < "$work/capture/worker-timezone"
    if [[ $service == git-mirror-hosts ]]; then
        [[ $(<"$work/capture/curl-argv") == *'https://example.invalid/service-config'* ]] || return 1
    else
        [[ -s $work/capture/worker-token && $GITHUB_TOKEN == service-sensitive-fixture ]] || return 1
        local presence
        while IFS= read -r presence; do [[ $presence == present ]] || return 1; done < "$work/capture/worker-token"
        [[ $(<"$work/output") != *service-sensitive-fixture* ]] || return 1
    fi
    cmp -s -- "$work/config.before" "$RUN_ROOT/config/mirror.env"
}

# 使用初始化生成的白名单模拟真实 OpenRC 过滤，验证环境仍优先且不回写。
filtered_environment_configuration() {
    export SERVICE_FILTER_ENVIRONMENT=1
    daemon_configuration environment
}

check 'OpenRC 白名单过滤后环境优先且不回写' filtered_environment_configuration
check '同步交付入口使用文件时区（外部边界桩）' worker_configuration git-mirror-sync
check '刷新交付入口使用文件 URL 与时区（外部边界桩）' worker_configuration git-mirror-hosts
check 'OpenRC 生产接线断开必须失败（故障注入）' disconnected_wiring_guard
for scenario in file defaults environment invalid-address invalid-port empty-environment token token-invalid-port token-file-conflict token-environment-conflict token-control token-empty credential-file credential-override credential-empty credential-missing credential-invalid; do
    check "OpenRC 交付入口配置：$scenario（外部边界桩，非 Alpine 集成）" daemon_configuration "$scenario"
done
printf 'OpenRC 入口行为检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
