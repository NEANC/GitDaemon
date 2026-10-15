#!/usr/bin/env bash
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export IT_SOURCE_ONLY=1 IT_RUN_ID=trust IT_NETWORK=gm-trust-net
source "$HERE/test-docker-integration.sh"
trap 'rm -rf "$TEST_ROOT"' EXIT

# 记录真实启动与同步函数的参数，拒绝可写数据卷作为实际信任源。
docker() {
    printf '%s\n' "$*" >> "$TEST_ROOT/docker.calls"
    case "$1" in logs) printf '容器前台就绪\n' ;; esac
    return 0
}
container_networks_internal() { return 0; }
timeout() { shift; "$@"; }
fixture_start_product
fixture_start_auth_product
fixture_exec_sync acme/demo
failed=0
for name in "$FIXTURE_PROD" "$AUTH_PROD"; do
    line=$(grep "run -d --name $name " "$TEST_ROOT/docker.calls")
    if [[ $line != *"-v $FIXTURE_CA_VOL:/ca:ro"* || $line != *'GIT_SSL_CAINFO=/ca/fixture/tls/ca.crt'* ]]; then
        printf 'FAIL actual trust mount: %s\n' "$name"
        failed=1
    fi
done
line=$(grep 'exec -e REPOS=' "$TEST_ROOT/docker.calls")
if [[ $line != *'GIT_SSL_CAINFO=/ca/fixture/tls/ca.crt'* ]]; then
    printf 'FAIL exec trust path\n'
    failed=1
fi
[[ $failed == 0 ]] || exit "$failed"

# 只读挂载不能替代实际环境路径校验；覆盖错误卷、可写卷和路径覆盖。
docker() {
    case "$*" in
        *'.Config.Env'*) printf '%s\n' "GIT_SSL_CAINFO=$trust_path" ;;
        *'.Destination'*'/ca'*) printf '%s\n' "$trust_volume $trust_rw" ;;
        *'.Mounts'*) printf 'volume %s\n' "$trust_volume" ;;
    esac
    return 0
}
for fault in valid writable wrong-volume data-path nested; do
    trust_path=/ca/fixture/tls/ca.crt trust_volume=gm-trust-fixture-ca trust_rw=false
    case "$fault" in
        writable) trust_rw=true ;;
        wrong-volume) trust_volume=gm-trust-ca ;;
        data-path) trust_path=/var/lib/git-daemon/fixture/tls/ca.crt ;;
        nested) trust_path=/ca/../var/lib/git-daemon/ca.crt ;;
    esac
    rc=0
    assert_container_trust_configuration product || rc=$?
    printf 'TRUST_CASE=%s EXIT=%s\n' "$fault" "$rc"
    if [[ $fault == valid ]]; then [[ $rc == 0 ]]; else [[ $rc != 0 ]]; fi
done

# 独立映射 CA 路径只在映射角色开放，且必须挂在专属映射 CA 卷上。
for fault in mapping-upstream mapping-proxy mapping-old-role mapping-wrong-volume; do
    trust_path=/ca/upstream-ca.crt trust_volume=gm-trust-mapping-ca trust_rw=false
    unset IT_MAPPING
    case "$fault" in
        mapping-upstream) IT_MAPPING=1 ;;
        mapping-proxy) IT_MAPPING=1; trust_path=/ca/proxy-ca.crt ;;
        mapping-wrong-volume) IT_MAPPING=1; trust_volume=gm-trust-ca ;;
    esac
    rc=0
    assert_container_trust_configuration product || rc=$?
    printf 'TRUST_CASE=%s EXIT=%s\n' "$fault" "$rc"
    if [[ $fault == mapping-upstream || $fault == mapping-proxy ]]; then
        [[ $rc == 0 ]]
    else
        [[ $rc != 0 ]]
    fi
done
unset IT_MAPPING
