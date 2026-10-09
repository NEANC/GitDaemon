#!/usr/bin/env bash
# 宿主普通用户使用冻结工具树中的 Git，仍访问真实宿主发布端口。
host_git() {
    local tools=${IT_HOST_TOOLS:-$ROOT/host-tools}
    LD_LIBRARY_PATH="$tools/usr/lib:$tools/lib" GIT_EXEC_PATH="$tools/usr/libexec/git-core" "$tools/usr/bin/git" "$@"
}
