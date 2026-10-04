#!/usr/bin/env bash
# 在真实用户 OpenRC 服务中验证 init 保存的凭据到首次同步、scheduler worker 的受控通路。
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[[ $UID != 0 && $EUID != 0 ]] || exit 1
work=$(mktemp -d)
export RUN_ROOT=$work/instance INSTALL_ROOT=$work/program TZ=UTC REPOS=fixture/repo
export ENABLE_HOSTS_UPDATE=no ENABLE_CRON=yes CRON_SCHEDULE='* * * * *'
# 无论断言成功或失败，停止本测试实例服务并清理自己的临时目录。
cleanup() {
    if [[ -d $RUN_ROOT/config/rc ]]; then
        rc-service --user git-mirror-scheduler stop >/dev/null 2>&1 || true
        rc-service --user git-daemon stop >/dev/null 2>&1 || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
bash "$ROOT/scripts/deploy-git-mirror.sh" --install --install-root "$INSTALL_ROOT"
export GITHUB_TOKEN=closure-integration-fixture
bash "$INSTALL_ROOT/deploy-git-mirror.sh" --init --install-root "$INSTALL_ROOT" --run-root "$RUN_ROOT"
source "$INSTALL_ROOT/lib/foundation.sh"
gm_set_instance_environment "$RUN_ROOT" "$INSTALL_ROOT"
unset GITHUB_TOKEN GITHUB_TOKEN_FILE
mkdir -p "$work/bin" "$RUN_ROOT/repos/fixture"
# 夹具只放行检测包装器路径，不改变凭据白名单。
printf '\nrc_env_allow="%s PATH"\n' "$(gm_required_env_allow)" >> "$RUN_ROOT/config/rc/rc.conf"
printf '#!/usr/bin/env bash\nif [[ " $* " == *" fetch "* ]]; then\n [[ ${GM_SYNC_TOKEN-} == closure-integration-fixture ]] || exit 91\n [[ " $* " != *closure-integration-fixture* ]] || exit 92\n printf "verified\\n" >> %q\nfi\nexec /usr/bin/git "$@"\n' "$work/credential-checks" > "$work/bin/git"
chmod 755 "$work/bin/git"
export PATH=$work/bin:$PATH

git init --bare -q "$work/upstream.git"
git init --bare -q "$RUN_ROOT/repos/fixture/repo.git"
git --git-dir="$RUN_ROOT/repos/fixture/repo.git" remote add origin "$work/upstream.git"
"$INSTALL_ROOT/git-mirror-sync.sh"
[[ $(wc -l < "$work/credential-checks") == 1 ]]
printf 'PASS init_first_sync\n'
rc-service --user git-mirror-scheduler start
for ((i=0; i<75; i++)); do
    if grep -q '仓库同步 完成' "$RUN_ROOT/logs/scheduler.log"; then break; fi
    sleep 1
done
 grep -q '仓库同步 完成' "$RUN_ROOT/logs/scheduler.log"
rc-service --user git-mirror-scheduler stop
printf 'PASS openrc_scheduler_worker\n'
export GIT_PORT=19418 LISTEN_ADDRESS=127.0.0.1
rc-service --user git-daemon start
pid=$(<"$RUN_ROOT/runtime/git-daemon.pid")
! tr '\0' '\n' < "/proc/$pid/environ" | grep -Eq '^(GITHUB_TOKEN|GITHUB_TOKEN_FILE|GM_SYNC_TOKEN)='
! grep -R -q closure-integration-fixture "$RUN_ROOT/logs"
rc-service --user git-daemon stop
printf 'PASS daemon_credential_isolation\nchecks=3 failed=0 uid=%s\n' "$UID"
