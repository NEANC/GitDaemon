#!/usr/bin/env bash
# 验证宿主 Git 通过明确工具树运行，不依赖源码目录内不存在的文件。
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tests/docker-host-git.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tools/usr/bin" "$WORK/tools/usr/lib" "$WORK/tools/lib"
cat > "$WORK/tools/usr/bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$LD_LIBRARY_PATH" "$GIT_EXEC_PATH" "$@"
EOF
chmod +x "$WORK/tools/usr/bin/git"
export IT_HOST_TOOLS="$WORK/tools"
actual=$(host_git --version)
expected=$(printf '%s\n' "$WORK/tools/usr/lib:$WORK/tools/lib" "$WORK/tools/usr/libexec/git-core" --version)
[[ $actual == "$expected" ]] || { printf 'FAIL: explicit host tool tree not used\n'; exit 1; }
printf 'PASS: explicit host Git and runtime paths\n'
