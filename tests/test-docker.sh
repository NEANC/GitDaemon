#!/usr/bin/env bash

# 容器镜像层静态与本地可执行行为检查：Dockerfile 非 root 约束、依赖组装、.dockerignore 覆盖、
# 入口身份与凭据处理。无法在本地验证的镜像构建、COPY --from 元数据与只读根运行不在此伪造。

set -uo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-docker.XXXXXXXX") || exit 1
FAILURES=0
CHECKS=0

# 仅清理本测试创建的临时目录。
cleanup() {
    if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && ! -L $TEST_ROOT ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

# 用子 Shell 运行单项检查并累计通过/失败。
check() {
    local label=$1
    shift
    CHECKS=$((CHECKS + 1))
    if ( "$@" ); then
        printf '[PASS] %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        FAILURES=$((FAILURES + 1))
    fi
}

# 入口与组装脚本通过 Shell 语法检查；组装脚本要求 POSIX sh 兼容。
docker_scripts_syntax() {
    sh -n "$ROOT/docker/assemble-deps.sh" || return 1
    bash -n "$ROOT/docker/docker-entrypoint.sh" || return 1
    return 0
}

# 每个执行命令的阶段的 RUN 之前必须已设置 USER。
dockerfile_user_before_run() {
    local line stage_user=no
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        case "$line" in
            FROM\ *) stage_user=no ;;
            USER\ *) stage_user=yes ;;
            RUN\ *) [[ $stage_user == yes ]] || return 1 ;;
        esac
    done < "$ROOT/Dockerfile"
    return 0
}

# Dockerfile 不得出现 root 执行、提权、root 安装命令或不安全校验开关。
dockerfile_no_root_or_unsafe() {
    ! grep -Eiq -- '^[[:space:]]*USER[[:space:]]+root' "$ROOT/Dockerfile" || return 1
    ! grep -Eiq -- '--privileged|docker\.sock|fakeroot|userns|newuidmap' "$ROOT/Dockerfile" || return 1
    ! grep -Eq -- '(^|[[:space:]])(sudo|doas|su)[[:space:]]' "$ROOT/Dockerfile" || return 1
    ! grep -Eq -- '(^|[[:space:]])chown[[:space:]]' "$ROOT/Dockerfile" || return 1
    ! grep -Eiq -- 'allow-untrusted|no-check-certificate|check-certificate[= ]+false' "$ROOT/Dockerfile" || return 1
    return 0
}

# 固定 Alpine 版本、设置非零 UID 且不使用浮动 latest。
dockerfile_pins_identity() {
    grep -Eq '^FROM alpine:3\.[0-9]+' "$ROOT/Dockerfile" || return 1
    ! grep -Eq ':latest' "$ROOT/Dockerfile" || return 1
    grep -Fq 'USER 10001:10001' "$ROOT/Dockerfile" || return 1
    return 0
}

# 最终阶段使用 COPY --from 组装，不携带测试夹具、版本库或文档。
dockerfile_excludes_sensitive() {
    ! grep -Eq -- 'COPY[^A-Za-z]*(tests/|\.git|docs/)' "$ROOT/Dockerfile" || return 1
    grep -Fq 'COPY --from=builder' "$ROOT/Dockerfile" || return 1
    return 0
}

# 依赖组装固定包集合包含全部所需依赖且不引入 SSH 组件。
assemble_packages_ok() {
    grep -Fq "PACKAGES='bash git git-daemon curl flock coreutils ca-certificates tzdata openssl openrc'" "$ROOT/docker/assemble-deps.sh" || return 1
    ! grep -Fq 'openssh' "$ROOT/docker/assemble-deps.sh" || return 1
    ! grep -Fq 'dropbear' "$ROOT/docker/assemble-deps.sh" || return 1
    return 0
}

# 组装保持签名与 TLS 校验，不接受不受信任来源。
assemble_keeps_verification() {
    ! grep -Eiq -- 'allow-untrusted|no-check-certificate|check-certificate[= ]+false' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq -- '--usermode' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq -- '--scripts=no' "$ROOT/docker/assemble-deps.sh" || return 1
    return 0
}

# --scripts=no 缺口被显式补齐：CA 哈希、localtime、应用账户、baselayout 文件、/run 与 busybox applet。
assemble_fills_gaps() {
    grep -Fq 'ensure_ca_certificates' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'ca-certificates.crt' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'etc/localtime' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'ensure_account_entry' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'APP_UID=10001' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq '/etc/alpine-release' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'ensure_runtime_directories' "$ROOT/docker/assemble-deps.sh" || return 1
    grep -Fq 'REQUIRED_APPLETS' "$ROOT/docker/assemble-deps.sh" || return 1
    return 0
}

# .dockerignore 覆盖版本库、文档、测试夹具、运行数据、日志与凭据。
dockerignore_covers() {
    local file=$ROOT/.dockerignore
    grep -Fxq '.git' "$file" || return 1
    grep -Fxq 'docs' "$file" || return 1
    grep -Fxq 'tests' "$file" || return 1
    grep -Fxq 'logs' "$file" || return 1
    grep -Fxq 'secrets' "$file" || return 1
    grep -Eq '^\*\*/\*\.log$' "$file" || return 1
    return 0
}

# 入口静态约束：核对真实与有效 UID、转发 TERM/INT、复用交付 CLI，且不碰一次性工作服务状态。
entrypoint_static_checks() {
    local file=$ROOT/docker/docker-entrypoint.sh
    grep -Fq 'id -ru' "$file" || return 1
    grep -Fq 'id -u' "$file" || return 1
    grep -Fq 'trap on_stop_signal TERM INT' "$file" || return 1
    grep -Fq -- '--install --install-root' "$file" || return 1
    grep -Fq -- '--init --install-root' "$file" || return 1
    ! grep -Eq 'rc-service[^|]*git-mirror-(sync|hosts)' "$file" || return 1
    ! grep -Eq '(echo|printf)[^|]*GITHUB_TOKEN' "$file" || return 1
    ! grep -Eq 'set[[:space:]]+-[a-z]*x' "$file" || return 1
    return 0
}

# 入口拒绝以实际或有效 UID 0 运行：以桩 id 返回 0 后必须非零退出并给出 root 诊断。
entrypoint_rejects_uid_zero() {
    local dir=$TEST_ROOT/uid0 output status=0
    mkdir -p "$dir/bin" || return 1
    printf '%s\n' '#!/bin/sh' 'echo 0' > "$dir/bin/id" || return 1
    chmod +x "$dir/bin/id" || return 1
    output=$(PATH="$dir/bin:$PATH" INSTALL_ROOT="$ROOT/scripts" RUN_ROOT="$dir/run" \
        bash "$ROOT/docker/docker-entrypoint.sh" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output == *'禁止以 root'* ]] || return 1
    return 0
}

# 入口不把 Token 写入日志：缺少程序层入口而提前失败时，输出不得包含凭据哨兵。
# 使用不含交付入口的空目录，使该用例在本地与真实 Alpine 上都得到相同结论，不依赖平台拒绝。
entrypoint_no_token_logging() {
    local dir=$TEST_ROOT/token output status=0
    mkdir -p "$dir/program" || return 1
    output=$(INSTALL_ROOT="$dir/program" RUN_ROOT="$dir/run" REPOS='octocat/Hello-World' \
        GITHUB_TOKEN='SENTINEL_TOKEN_VALUE' bash "$ROOT/docker/docker-entrypoint.sh" 2>&1) || status=$?
    [[ $status != 0 ]] || return 1
    [[ $output != *SENTINEL_TOKEN_VALUE* ]] || return 1
    [[ $output == *'缺少交付安装入口'* ]] || return 1
    return 0
}

# OpenRC 交付服务定义不得声明用户模式下不可用的依赖。
openrc_user_mode_ready() {
    local file
    for file in "$ROOT"/scripts/openrc/*; do
        if grep -Eq -- '(^|[[:space:]])need[[:space:]]+(localmount|net|firewall)' "$file"; then
            return 1
        fi
        grep -Fq '/sbin/openrc-run' "$file" || return 1
    done
    return 0
}

check '容器脚本通过 Bash 语法检查' docker_scripts_syntax
check '每个执行阶段的 RUN 之前已设置 USER' dockerfile_user_before_run
check 'Dockerfile 无 root 执行、提权与不安全校验开关' dockerfile_no_root_or_unsafe
check 'Dockerfile 固定 Alpine 版本与非零 UID' dockerfile_pins_identity
check 'Dockerfile 不携带测试夹具、版本库与文档' dockerfile_excludes_sensitive
check '依赖包集合完整且不含 SSH 组件' assemble_packages_ok
check '依赖组装保持签名与 TLS 校验' assemble_keeps_verification
check '--scripts=no 缺口被显式补齐' assemble_fills_gaps
check '.dockerignore 覆盖必须排除项' dockerignore_covers
check '入口静态约束满足' entrypoint_static_checks
check '入口拒绝 UID 0' entrypoint_rejects_uid_zero
check '入口不把 Token 写入日志' entrypoint_no_token_logging
check 'OpenRC 服务在用户模式下可用' openrc_user_mode_ready
printf '容器镜像检查：%s；失败：%s\n' "$CHECKS" "$FAILURES"
[[ $FAILURES == 0 ]]
