#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FAILURES=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_contains() { grep -Fq -- "$2" "$1" && pass "$3" || fail "$3"; }
assert_absent() { grep -Eiq -- "$2" "$1" && fail "$3" || pass "$3"; }
for file in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$file" || exit 1
    pass "Bash 语法：${file#"$ROOT"/}"
done
for file in "$ROOT"/scripts/openrc/*; do
    sh -n "$file" || exit 1
    pass "OpenRC 定义 Shell 语法（非运行验证）：${file#"$ROOT"/}"
done
if ! bash "$ROOT/tests/test-config-lifecycle.sh"; then
    fail '配置与生命周期行为测试'
fi
if ! bash "$ROOT/tests/test-openrc-config.sh"; then
    fail 'OpenRC 交付入口配置行为测试（外部边界桩）'
fi
if ! bash "$ROOT/tests/test-readonly-install.sh"; then
    fail '只读程序层边界测试'
fi
if ! bash "$ROOT/tests/test-sync-core.sh"; then
    fail '同步核心行为测试（本地 bare 上游）'
fi
if ! bash "$ROOT/tests/test-hosts-refresh.sh"; then
    fail '地址快照刷新行为测试（本地桩下载）'
fi
if ! bash "$ROOT/tests/test-scheduler.sh"; then
    fail '用户态调度行为测试'
fi
for suite in repository-state task-lifecycle repository-recovery recovery-lifecycle gc-schedule gc scheduler-recovery scheduler-stop-windows; do
    if ! bash "$ROOT/tests/test-$suite.sh"; then fail "恢复与 GC：$suite"; fi
done
if ! bash "$ROOT/tests/test-docker.sh"; then
    fail '容器镜像静态与入口行为测试'
fi
assert_contains "$ROOT/scripts/deploy-git-mirror.sh" 'REPOS' '部署使用 REPOS 环境变量'
assert_absent "$ROOT/scripts/deploy-git-mirror.sh" 'systemd|systemctl|apt|yum|sudo|su |doas|SSH|ssh-key|REPOS_FILE' '部署移除非 Alpine 配置与 SSH 回退'
assert_absent "$ROOT/scripts/uninstall-git-mirror.sh" 'systemd|systemctl|apt|yum|sudo|su |doas|/etc/hosts|resolv.conf' '卸载仅操作 OpenRC 文件和应用数据'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'http.curloptResolve' '存在动态地址解析代码（仅静态检查，非功能验收）'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'fetch --progress --atomic --prune' '同步以原子事务拉取引用（静态接线检查）'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'git-daemon-export-ok' '存在仓库发布标记代码（仅静态检查，非发布验收）'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'gm_begin_operation sync' '同步接入共享锁入口（静态接线检查）'
assert_absent "$ROOT/scripts/git-mirror-sync.sh" 'git@|known_hosts|SSH|ssh ' '同步不包含 SSH 回退和凭据'
assert_absent "$ROOT/scripts/update-github-hosts.sh" '/etc/hosts|/etc/resolv.conf' '地址脚本不修改系统网络配置'
for file in "$ROOT"/scripts/openrc/*; do grep -Fq '/sbin/openrc-run' "$file" && pass "OpenRC 服务：$(basename "$file")" || fail "OpenRC 服务：$(basename "$file")"; done
printf '检查失败数：%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]
