#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FAILURES=0
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_contains() { grep -Fq -- "$2" "$1" && pass "$3" || fail "$3"; }
assert_absent() { grep -Eiq -- "$2" "$1" && fail "$3" || pass "$3"; }
for file in "$ROOT"/scripts/*.sh; do bash -n "$file" || exit 1; done
pass 'Shell 脚本语法'
assert_contains "$ROOT/scripts/deploy-git-mirror.sh" 'REPOS' '部署使用 REPOS 环境变量'
assert_absent "$ROOT/scripts/deploy-git-mirror.sh" 'systemd|systemctl|apt|yum|sudo|su |doas|SSH|ssh-key|REPOS_FILE' '部署移除非 Alpine 配置与 SSH 回退'
assert_absent "$ROOT/scripts/uninstall-git-mirror.sh" 'systemd|systemctl|apt|yum|sudo|su |doas|/etc/hosts|resolv.conf' '卸载仅操作 OpenRC 文件和应用数据'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'http.curloptResolve' '同步使用 Git 动态地址解析'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'git-daemon-export-ok' '成功后发布仓库'
assert_contains "$ROOT/scripts/git-mirror-sync.sh" 'flock -n 9' '同步使用排他锁'
assert_absent "$ROOT/scripts/git-mirror-sync.sh" 'git@|known_hosts|SSH|ssh ' '同步不包含 SSH 回退和凭据'
assert_absent "$ROOT/scripts/update-github-hosts.sh" '/etc/hosts|/etc/resolv.conf' '地址脚本不修改系统网络配置'
for file in "$ROOT"/scripts/openrc/*; do grep -Fq '/sbin/openrc-run' "$file" && pass "OpenRC 服务：$(basename "$file")" || fail "OpenRC 服务：$(basename "$file")"; done
printf '检查失败数：%s\n' "$FAILURES"
[ "$FAILURES" -eq 0 ]