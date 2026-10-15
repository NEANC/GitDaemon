#!/usr/bin/env bash
# HTTPS 夹具产物所有权契约：夹具创建的每个容器都必须携带 run/scenario/role 三 label，
# 使资源账本、guard 残留枚举与恢复脚本能识别它们，中途失败不会被静默泄漏。
# 以本地 docker 替身记录 argv，不触碰真实 daemon，也不改变夹具 CLI。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FIXTURE=$HERE/docker-https-fixture.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failed=0

# 记录型 docker 替身：argv 逐行落盘；容器「保持运行」探测通过，其余无输出。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_STUB_LOG"
case "$*" in
    *'.State.Running'*) printf 'true\n' ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/docker"
export FIXTURE_STUB_LOG=$WORK/calls
: > "$FIXTURE_STUB_LOG"
export IT_RUN_ID=labels IT_SCENARIO=mapping IT_NETWORK=gm-labels-net
# 包装器直通：夹具的 docker 调用直达本地替身，绝不触碰真实 daemon。
export IT_NETWORK_LIBRARY_RUN=1
export PATH="$WORK/bin:$PATH"

# 指定角色的创建行必须同时携带 run/scenario/role 三 label。
assert_labels() {
    local role=$1 line
    line=$(grep -m1 -- "--label gitdaemon.role=$role" "$FIXTURE_STUB_LOG") || {
        printf 'missing fixture container role=%s\n' "$role"
        return 1
    }
    [[ $line == *'--label gitdaemon.run=labels'* ]] || { printf 'role %s missing run label\n' "$role"; return 1; }
    [[ $line == *'--label gitdaemon.scenario=mapping'* ]] || { printf 'role %s missing scenario label\n' "$role"; return 1; }
    printf 'FIXTURE_LABELS %s=%s\n' "$role" "$line"
    return 0
}

# 覆盖夹具全部容器创建子命令：上游、拒绝端点、hosts 端点、认证上游、代理与一次性 helper。
run_fixture() {
    local rc=0
    bash "$FIXTURE" start vol img net gm-upstream >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'start exit=%s\n' "$rc"; return 1; }
    assert_labels upstream || return 1
    rc=0
    bash "$FIXTURE" reject-start vol img net gm-reject >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'reject-start exit=%s\n' "$rc"; return 1; }
    assert_labels reject || return 1
    rc=0
    bash "$FIXTURE" hosts-serve vol img net gm-hosts >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'hosts-serve exit=%s\n' "$rc"; return 1; }
    assert_labels hosts || return 1
    rc=0
    bash "$FIXTURE" hosts-serve-bad vol img net gm-hosts-bad >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'hosts-serve-bad exit=%s\n' "$rc"; return 1; }
    assert_labels hosts-bad || return 1
    rc=0
    bash "$FIXTURE" auth-start vol img net gm-auth expected-auth >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'auth-start exit=%s\n' "$rc"; return 1; }
    assert_labels auth || return 1
    rc=0
    bash "$FIXTURE" proxy-start vol img net gm-proxy >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'proxy-start exit=%s\n' "$rc"; return 1; }
    assert_labels proxy || return 1
    rc=0
    bash "$FIXTURE" ca vol img >/dev/null 2>&1 || rc=$?
    [[ $rc == 0 ]] || { printf 'ca exit=%s\n' "$rc"; return 1; }
    assert_labels helper || return 1
    return 0
}

run_fixture || failed=1
exit "$failed"
