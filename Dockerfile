# Git 镜像加速节点镜像：非 root 组装依赖树，运行时只使用 UID 10001。
# 所有执行命令的阶段在首条 RUN 之前固定 USER 10001:10001，任何 RUN 都不以 UID 0 执行。

# 构建阶段：在固定 Alpine 版本上以非 root 身份组装可执行依赖树并补齐缺口。
FROM alpine:3.24 AS builder

# 以 COPY 声明式提供构建输入并声明归属，建立构建用户可写目录；此时尚未执行任何命令。
COPY --chown=10001:10001 docker/assemble-deps.sh /work/assemble-deps.sh
COPY --chown=10001:10001 scripts/ /usr/local/lib/git-mirror/
COPY --chown=10001:10001 docker/docker-entrypoint.sh /work/docker-entrypoint.sh

# 首条 RUN 之前固定非 root 身份；此后所有 RUN 均以 UID 10001 执行。
USER 10001:10001

# 组装依赖树：以镜像自带的 POSIX sh 运行，官方源与签名校验保持开启，禁用安装脚本。
RUN sh /work/assemble-deps.sh --root /work/rootfs --cache-dir /work/cache

# 显式设置程序层执行位：Windows 检出可能丢失执行位，COPY 只保留源模式。
RUN chmod 755 /usr/local/lib/git-mirror/*.sh /usr/local/lib/git-mirror/openrc/* /work/docker-entrypoint.sh

# 预置程序层安装记录，使只读程序层可被交付 CLI 的 --install 幂等核验而不产生写入。
RUN printf '%s\n' 'FORMAT=1' 'MODE=program' 'UID=10001' 'INSTALL_ROOT=/usr/local/lib/git-mirror' > /usr/local/lib/git-mirror/installation.conf \
    && printf '%s\n' 'FORMAT=1' 'SCHEDULER=present' > /usr/local/lib/git-mirror/service-capabilities.conf \
    && chmod 600 /usr/local/lib/git-mirror/installation.conf /usr/local/lib/git-mirror/service-capabilities.conf

# 最终镜像：依赖树位于 /，程序层与入口归属 UID 10001；不含 Token、凭据、测试夹具、.git 或 docs。
FROM scratch
COPY --from=builder /work/rootfs/ /
COPY --from=builder --chown=10001:10001 /usr/local/lib/git-mirror/ /usr/local/lib/git-mirror/
COPY --from=builder --chown=10001:10001 /work/docker-entrypoint.sh /usr/local/bin/git-mirror-entrypoint

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV RUN_ROOT=/var/lib/git-daemon
ENV INSTALL_ROOT=/usr/local/lib/git-mirror
STOPSIGNAL SIGTERM
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/git-mirror-entrypoint"]
