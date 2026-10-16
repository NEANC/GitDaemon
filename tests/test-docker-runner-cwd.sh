#!/usr/bin/env bash
# 验证正式 runner 不把调用者目录传给降权后的 Compose。
set -Eeuo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/source/tests" "$scratch/evidence/control" "$scratch/caller"
touch "$scratch/evidence/control/start"
cp "$HERE/test-docker-network.sh" "$scratch/source/tests/"
cp "$HERE/docker-validation-environment.sh" "$scratch/source/tests/"
cat > "$scratch/source/tests/docker-network-fixture.sh" <<'FIXTURE'
# 只观测 runner 的当前目录，不启动网络资源。
network_probe() {
    pwd > "$CWD_RESULT"
}
FIXTURE
runner_bash=$(command -v bash)
export CWD_RESULT="$scratch/cwd"
(
    cd "$scratch/caller"
    IT_EVIDENCE_DIR="$scratch/evidence" IT_NETWORK_GUARD_READY=1 \
        "$runner_bash" "$scratch/source/tests/test-docker-network.sh" --live
)
expected=$(CDPATH= cd -- "$scratch/source" && pwd)
actual=$(< "$CWD_RESULT")
printf 'RUNNER_CWD expected=%s actual=%s\n' "$expected" "$actual"
[[ $actual == "$expected" ]]
