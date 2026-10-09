#!/usr/bin/env bash
# 使用真实集成入口验证必需 Compose 缺失时在业务开始前失败。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/docker" <<'CLI'
#!/usr/bin/env bash
case "$*" in
    info) exit 0 ;;
    'compose version') exit 1 ;;
    *) printf 'BUSINESS_CALLED %s\n' "$*" >> "$CALLS"; exit 1 ;;
esac
CLI
cat > "$scratch/id" <<'CLI'
#!/usr/bin/env bash
printf '1000\n'
CLI
chmod +x "$scratch/docker" "$scratch/id"
for filter in o1 ''; do
    rc=0
    CALLS="$scratch/calls" PATH="$scratch:$PATH" IT_FILTER="$filter" \
        IT_NETWORK_GUARD_READY=1 IT_RUN_ID=compose-contract IT_NETWORK=gm-contract-net \
        IT_DNS_IP=172.30.243.53 IT_PRODUCT_IMAGE=product \
        bash "$HERE/test-docker-integration.sh" > "$scratch/output" 2>&1 || rc=$?
    printf 'FILTER=%s EXIT=%s\n' "${filter:-full}" "$rc"
    if [[ $rc == 0 ]] || ! grep -q 'FAIL：必需的 Docker Compose 不可用' "$scratch/output"; then
        cat "$scratch/output"
        exit 1
    fi
    if [[ -f $scratch/calls ]] && grep -q 'BUSINESS_CALLED image inspect' "$scratch/calls"; then
        printf 'FAIL：缺少 Compose 仍启动业务\n'
        exit 1
    fi
done
