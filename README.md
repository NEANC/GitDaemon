# Git 镜像加速节点

基于 Alpine 和用户态 OpenRC 的只读 Git 镜像服务。服务从 GitHub 通过 HTTPS 同步仓库，再通过 `git://` 协议向客户端提供匿名只读访问。

Docker 部署使用非 root 用户运行，只支持 Docker 管理的命名卷，不接受宿主机目录或文件映射。

仅镜像 Git 对象和引用，不包含 Issues、Release 附件或 Git LFS 对象，也不会把子模块地址改写为本地镜像。不要使用可读取私有内容的凭据将私有仓库发布到匿名服务。

本文以 [compose.yml](compose.yml)、[Dockerfile](Dockerfile)、[容器入口](docker/docker-entrypoint.sh) 和 [scripts/](scripts/) 中的交付实现为准；根目录历史安装脚本不是当前容器的部署入口。命令示例使用 Bash，请在含 `compose.yml` 的目录执行；Windows 用户可在合适的 Bash 环境执行，不能将 `export` 和反斜杠续行直接粘贴到 PowerShell。

## Docker 部署

### 前置条件

- Docker Engine 支持命名卷、只读根文件系统和 `no-new-privileges`。
- Docker Compose v2。
- 能拉取所选镜像，并能通过 HTTPS 访问配置上游和可选地址数据源。
- 已确认存在、来源可信且适配宿主平台的镜像标签；本文不保证 GHCR 上已有可用发布。

部署时必须显式设置 `IMAGE_TAG`；缺失或为空时 Compose 拒绝渲染，不会默认使用 `latest`。Compose 不在本地构建镜像。下例先提示输入实际可用标签，再指定仓库：

```bash
read -r -p '请输入已确认可用的镜像标签：' IMAGE_TAG
export IMAGE_TAG
export REPOS='git/git'
export SHORT_LINKS='git/git git'
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 git-daemon
```

### Compose 配置与端口

直接使用仓库内的 `compose.yml`，不要用固定默认值覆盖其环境透传行为。以下为关键结构摘录，完整环境变量列表见实际文件及下一节：

```yaml
services:
  git-daemon:
    image: ghcr.io/neanc/git-daemon:${IMAGE_TAG:?必须显式设置 IMAGE_TAG}
    user: "10001:10001"
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    restart: unless-stopped
    stop_grace_period: 30s
    ports:
      - target: 9418
        published: "${PUBLISHED_PORT:-9418}"
        protocol: tcp
    environment:
      - REPOS
      - SHORT_LINKS
      - TZ
      - GIT_PORT
      - LISTEN_ADDRESS
    volumes:
      - type: volume
        source: git-daemon-data
        target: /var/lib/git-daemon

volumes:
  git-daemon-data:
    name: git-daemon-data
```

- `PUBLISHED_PORT` 只改变宿主机发布端口，容器目标端口仍固定为 `9418`。若改变 `GIT_PORT`（包括卷内配置），必须同步修改 Compose 的 `ports.target`，否则端口发布不会跟随监听端口变化。
- 从容器外访问时，监听地址应允许容器外连接，例如默认的 `0.0.0.0`；容器内 `127.0.0.1` 不能作为宿主端口发布可达的证明。防火墙和云安全组需按实际发布端口放行可信来源。
- 服务名是 `git-daemon`，Compose 未设置 `container_name`；日常操作使用 `docker compose ... git-daemon`，不要假定容器名也是 `git-daemon`。
- 卷名固定为 `git-daemon-data`。不同实例必须使用独立卷与端口，不能将两个运行实例指向同一个卷。

Compose 文件中不得添加以下内容：

- `./local-path:/container-path` 或其他 bind mount。
- `type: bind`。
- `driver_opts` 中的 `type: none`、`o: bind` 或宿主机设备路径。
- 匿名卷。
- 基于宿主机文件的 `configs` 或 `secrets` 映射。
- `privileged: true`。
- Docker socket 映射。
- 本地 `build:` 配置。

### Compose 环境变量

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `IMAGE_TAG` | 是 | 无 | Compose 使用的镜像标签；不传入容器进程。 |
| `PUBLISHED_PORT` | 否 | `9418` | 宿主机发布端口；不改变容器监听端口。 |
| `REPOS` | 是 | 无 | 多仓库配置，使用分号分隔。每项为 `owner/repo` 或 `owner/repo branch1,branch2`。 |
| `SHORT_LINKS` | 否 | 空 | 短链接映射，使用分号分隔，每项为 `owner/repo short-name`。 |
| `GIT_PORT` | 否 | `9418` | Git daemon 监听端口，只接受 `1024–65535`。 |
| `LISTEN_ADDRESS` | 否 | `0.0.0.0` | Git daemon 监听地址。 |
| `CRON_SCHEDULE` | 否 | `0 * * * *` | 仓库同步频率，使用 5 段 cron 表达式。 |
| `ENABLE_CRON` | 否 | `yes` | 控制同步、地址刷新和 GC 后台调度；`no` 不取消启动检查和启动同步，首次地址刷新仍受自身开关控制。 |
| `TZ` | 否 | `Asia/Shanghai` | 日志和调度使用的时区。 |
| `PROXY_URL` | 否 | 空 | HTTPS 上游代理地址。 |
| `GITHUB_TOKEN` | 否 | 空 | 可选 GitHub HTTPS Token。建议使用卷内凭据文件。 |
| `GITHUB_TOKEN_FILE` | 否 | 空 | 命名卷内 Token 文件路径，与 `GITHUB_TOKEN` 互斥。 |
| `ENABLE_HOSTS_UPDATE` | 否 | `yes` | 是否刷新 GitHub 地址快照并用于直接 HTTPS 同步。 |
| `HOSTS_CRON` | 否 | `0 3 * * *` | GitHub 地址刷新频率。 |
| `HOSTS_URL` | 否 | `https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` | GitHub 地址主数据源。 |
| `HOSTS_URL_FALLBACK` | 否 | `https://raw.hellogithub.com/hosts` | GitHub 地址备用数据源。 |

不支持旧文件型仓库入口 `REPOS_FILE`、`SHORT_LINKS_FILE`，也不支持 SSH 同步、私钥或 agent。不要套用旧安装器参数。

### 参数优先级

普通参数按以下顺序生效：

```text
Compose 显式环境变量 → 命名卷内配置 → 程序默认值
```

规则如下：

1. `REPOS` 是唯一的仓库配置入口，未配置时启动失败。
2. `SHORT_LINKS` 未配置时不创建短链接。
3. 启动时只创建命名卷中缺失的配置，不覆盖已有配置文件。
4. 普通环境参数不自动写回卷内配置；凭据来源会保存到权限为 `600` 的 `runtime/sync-credentials`，用于同步子进程，不应把命名卷当成无秘密数据。
5. `GITHUB_TOKEN` 和 `GITHUB_TOKEN_FILE` 不能同时配置。
6. 空的 `GITHUB_TOKEN` 不会删除卷内凭据；已配置卷内凭据路径时，显式空的 `GITHUB_TOKEN_FILE` 会被拒绝。不要为未使用的变量批量注入空字符串。
7. 配置错误、仓库格式错误或短链接目标不存在时，容器拒绝启动。
8. 修改镜像、端口或环境变量后，需要重新创建容器；命名卷不会被删除。

`REPOS` 和 `SHORT_LINKS` 仅来自环境，不从卷内配置回退。其他允许键读取 `/var/lib/git-daemon/config/mirror.env`，其格式为 **LF 换行的纯 `KEY=VALUE` 数据**，不执行 Shell，不接受 `export`、引号包裹的值、重复键或未知键；即使环境覆盖了某个值，非法的已有文件仍会被拒绝。

例如卷内配置可以写成：

```text
TZ=Asia/Shanghai
ENABLE_CRON=yes
CRON_SCHEDULE=0 * * * *
ENABLE_HOSTS_UPDATE=no
```

卷内允许键为上表中从 `GIT_PORT` 到 `HOSTS_URL_FALLBACK` 的运行参数，但不含 `GITHUB_TOKEN`；Token 文件路径可以使用 `GITHUB_TOKEN_FILE`。修改时保留非 root 属主和私密权限，不要对配置执行 `source`。要让卷内值生效，先取消相应显式环境变量，再重建容器。

### 凭据与网络

公开仓库通常不需要 Token。确需认证时，建议通过受控输入将凭据放入命名卷的 `secrets/` 普通文件，确保 UID `10001` 可读且权限为 `600`，再设置例如 `GITHUB_TOKEN_FILE=/var/lib/git-daemon/secrets/github-token`；不能指向宿主机文件或其他目录。不在命令行字面量、镜像、Git URL、Compose 文件或日志中粘贴真实 Token。`GITHUB_TOKEN` 环境方式仍可能被有 Docker 管理权限的人查看。

轮换或撤销凭据需要同步处理环境来源、卷内 `GITHUB_TOKEN_FILE` 配置及对应凭据文件，再重建容器刷新运行期来源记录；仅传空值或删除文件并不等于完成撤销。

上游按可用条件依次尝试配置的 HTTPS 代理、卷内地址映射、系统 DNS；非代理尝试显式清除代理影响。地址快照只接受白名单 `github.com` 的合法公网地址并保留 TLS 校验，不代表配置后必然连通，也不代表真实 mapping 链路已经通过验收。

## docker run 部署

这是 Compose 的替代部署方式，不要同时启动同卷实例。必须使用 Docker 命名卷，不得使用宿主机路径映射；先设置已确认可用的 `IMAGE_TAG`。

```bash
docker volume create git-daemon-data

docker run -d \
  --name git-daemon \
  --restart unless-stopped \
  --stop-timeout 30 \
  --user 10001:10001 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --mount type=volume,source=git-daemon-data,target=/var/lib/git-daemon \
  --publish 9418:9418/tcp \
  --env 'REPOS=git/git' \
  --env 'SHORT_LINKS=git/git git' \
  "ghcr.io/neanc/git-daemon:${IMAGE_TAG:?请先设置镜像标签}"
```

这里显式命名的容器才可使用 `docker logs git-daemon`、`docker stop --time 30 git-daemon`。修改运行参数或升级时，先停止并删除旧容器，再以完整参数重建，保留原命名卷。

禁止使用以下形式：

```bash
-v "$(pwd)/data:/var/lib/git-daemon"
--volume /host/path:/var/lib/git-daemon
--mount type=bind,src=/host/path,dst=/var/lib/git-daemon
--mount type=volume,volume-driver=local,volume-opt=o=bind
```

## 多仓库配置

`REPOS` 使用分号分隔仓库项，仓库后的空格内容表示分支列表：

```yaml
REPOS: "git/git;octocat/Hello-World main;torvalds/linux master,next,stable"
```

含义：

| 配置项 | 含义 |
| --- | --- |
| `git/git` | 同步全部 refs、分支和标签。 |
| `octocat/Hello-World main` | 只同步 `main` 分支。 |
| `torvalds/linux master,next,stable` | 只同步 `master`、`next` 和 `stable` 分支。 |

注意：

- 仓库之间必须使用 `;`，不能使用逗号。
- 分支之间使用 `,`。
- 仓库名使用完整的 `owner/repo`，不要带 `.git`。
- 每个仓库只能配置一次。
- 空项、重复仓库、非法仓库名或非法分支名会导致启动失败。
- `REPOS` 是必填参数。
- 分支名示例只演示语法，请换成上游实际存在的分支；限定分支模式不拉取标签。配置合法不代表网络同步成功，应核对日志和实际引用。

## 短链接配置

`SHORT_LINKS` 使用分号分隔映射，每项格式为：

```text
owner/repo short-name
```

示例：

```yaml
SHORT_LINKS: "git/git git;octocat/Hello-World hello;torvalds/linux linux"
```

会生成以下访问路径：

```text
git://server.example.com:9418/git
git://server.example.com:9418/git.git
git://server.example.com:9418/hello
git://server.example.com:9418/hello.git
git://server.example.com:9418/linux
git://server.example.com:9418/linux.git
```

短链接规则：

- 目标仓库必须已经出现在 `REPOS` 中。
- 目标仓库经过检查、允许发布并存在 `git-daemon-export-ok` 后才建立短链接；短链接存在本身不证明上游已同步到最新。
- 短链接名只允许字母、数字、`.`、`_` 和 `-`。
- 短链接名不能为 `.`，不能包含 `/`、`..`、空白或绝对路径，也不能以 `.git` 结尾。
- 每个短链接名只能配置一次。
- 每个目标仓库最多配置一个短链接。
- 短链接使用相对符号链接，不复制仓库内容。
- 删除短链接配置不会删除目标仓库。
- `/repo` 和 `/repo.git` 同时可用，配置中只需写一次 `repo`。

## 命名卷目录

所有运行期生成或修改的应用文件保存在 `git-daemon-data` 命名卷内：

| 目录 | 内容 |
| --- | --- |
| `/var/lib/git-daemon/repos` | 裸 Git 仓库和短链接。 |
| `/var/lib/git-daemon/config` | 运行配置和实例信息。 |
| `/var/lib/git-daemon/secrets` | 可选 Token 文件，不保存 SSH 私钥。 |
| `/var/lib/git-daemon/home` | 最小用户状态，不使用 `.ssh`。 |
| `/var/lib/git-daemon/hosts` | GitHub 动态地址快照和刷新元数据。 |
| `/var/lib/git-daemon/logs` | 同步、地址刷新、服务和调度日志。 |
| `/var/lib/git-daemon/runtime` | 锁、PID 和 OpenRC 用户状态。 |
| `/var/lib/git-daemon/cache` | 应用缓存。 |
| `/var/lib/git-daemon/tmp` | 应用临时文件。 |
| `/var/lib/git-daemon/state` | 仓库健康、同步、GC、操作与替换事务的持久记录。 |
| `/var/lib/git-daemon/staging` | 独立重建过程中的候选副本。 |
| `/var/lib/git-daemon/quarantine` | 替换过程中隔离保留的旧副本。 |

根文件系统保持只读。应用通过 Git 的 `http.curloptResolve` 使用卷内地址快照，不直接修改容器 `/etc/hosts`，也不修改 `/etc/resolv.conf`。

## 访问镜像

完整路径：

```bash
git clone git://server.example.com:9418/git/git.git
git clone git://server.example.com:9418/octocat/Hello-World.git
```

短链接：

```bash
git clone git://server.example.com:9418/git
git clone git://server.example.com:9418/hello
```

验证远端引用：

```bash
git ls-remote git://server.example.com:9418/git/git.git HEAD
git ls-remote git://server.example.com:9418/git HEAD
```

Git daemon 只发布带有 `git-daemon-export-ok` 的仓库，并显式禁止 `receive-pack`。该服务不支持推送，也不提供身份认证和传输加密，只适合发布允许匿名读取的仓库。

读取成功只证明该访问路径在测试时可读，不证明所有仓库已同步，也不证明容器外端口、代理或地址映射路径都正常。请从实际客户端网络分别检查完整路径与短链接。

## 镜像来源与构建

使用前检查 GHCR 的实际标签和摘要，不根据本文推断 `latest`、Git 标签、提交短哈希或 PR 标签已发布。当前仓库不能提供已完成自动构建、推送及 Linux 集成验收的发布保证；PR 镜像不能直接视为可信生产版本。

需要自行构建时，单独执行构建命令，不向交付 Compose 添加 `build:`：

```bash
export IMAGE_TAG=local-check
docker build --tag "ghcr.io/neanc/git-daemon:$IMAGE_TAG" .
docker compose up -d
```

Dockerfile 基于固定 Alpine manifest 组装依赖，所有 `RUN` 前均设置 UID/GID `10001:10001`，最终镜像来自 `scratch`；当前基础摘要对应 `linux/amd64`，不要据此承诺多架构可用。精确部署可在部署配置中将完整 `image` 替换为已核实的 `ghcr.io/neanc/git-daemon@sha256:...`；不能直接把摘要填进只拼接标签的 `IMAGE_TAG`。

## 安全限制

- 容器固定使用 `10001:10001`，禁止 root 运行。
- 构建命令和运行进程不得使用 UID 0。
- 默认丢弃全部 Linux capabilities。
- 启用 `no-new-privileges`。
- 根文件系统只读。
- 不使用 `privileged`、宿主机 PID 命名空间、宿主机网络命名空间或 Docker socket。
- 不安装 SSH 客户端或服务端，不支持 SSH 回退和 SSH 私钥。
- 不使用宿主机路径 bind mount。
- 不把 GitHub Token 写入镜像、Git URL、命令参数或普通日志。
- GitHub 地址数据只作为数据解析，不执行远端响应内容。
- 地址快照下载及重定向仅允许 HTTPS，并保持证书校验；下载后的快照记录只接受白名单 `github.com` 的合法公网地址，拒绝环回、私网、链路本地和元数据服务地址。这是快照记录过滤，不是对下载源或重定向目标实际连接 IP 的防护。

## 日常操作

查看 Compose 服务与日志：

```bash
docker compose ps
docker compose logs --tail=100 -f git-daemon
docker compose exec git-daemon tail -n 100 /var/lib/git-daemon/logs/sync.log
```

实例正常运行且未冻结时，可以通过交付入口执行同步、单库恢复或到期 GC 检查：

```bash
docker compose exec git-daemon /usr/local/lib/git-mirror/git-mirror-sync.sh
docker compose exec git-daemon /usr/local/lib/git-mirror/git-mirror-recover.sh --repo git/git
docker compose exec git-daemon /usr/local/lib/git-mirror/git-mirror-gc.sh --repo git/git
```

`--repo` 使用当前 `REPOS` 中的完整名称。恢复命令不等同于强制同步；需要恢复后同步时使用 `git-mirror-recover.sh --repo git/git --sync`。共同写锁繁忙可能返回 `75`，应稍后重试，不要另起绕过锁的 `git fetch` 或 `git gc`。退出成功也可能只是 GC 尚未到期，需同时看 `result` 和 `reason`。

OpenRC 使用实例内用户服务，不操作宿主服务。入口负责其环境准备与监督；一次性任务退出后的服务状态不能替代任务退出码、日志和仓库状态。

## 升级、备份与清理

计划停机先停止整个 Compose 服务，保留 30 秒停止宽限与命名卷：

```bash
docker compose stop --timeout 30 git-daemon
```

备份前确认容器已停止、没有其他写入者；备份**整个命名卷**及部署环境参数，并保护其中凭据。仅复制 `repos/` 会遗漏恢复记录和 GC 周期。恢复到独立命名卷后，应保持文件属主、权限和实例路径，使用匹配的配置与镜像启动，并重新验证引用；备份成功不等于恢复已演练。

升级前保留可恢复的备份和原镜像摘要，确认目标版本兼容现有状态。设置目标标签后拉取并重建，复用原卷：

```bash
read -r -p '请输入目标镜像标签：' IMAGE_TAG
export IMAGE_TAG
docker compose config --quiet
docker compose pull
docker compose up -d --force-recreate
docker compose logs --tail=100 git-daemon
```

不要用旧安装器覆盖只读程序层；`--install` 用于构建期，运行期由入口执行 `--init` 和启动恢复。普通 `--resume` 不是升级或解冻入口。升级后需核对启动检查、最近成功同步及客户端引用；回退镜像前确认状态格式兼容，必要时恢复匹配备份，不能保证直接降级安全。

移除 Compose 容器但保留卷：

```bash
docker compose down --timeout 30
```

不要将 `docker compose down -v` 用作普通停止或升级。确认备份与数据保留要求、移除所有使用者后，才可永久删除命名卷：

```bash
docker volume rm git-daemon-data
```

删除命名卷会永久删除仓库、配置、凭据、日志和恢复状态。

交付的 `scripts/uninstall-git-mirror.sh` 默认仅停止实例并保留数据；显式分类参数为 `--delete-repos`、`--delete-config`、`--delete-credentials`、`--delete-logs`。它不是容器内清空一切的快捷入口：需要通过服务停止、记录、路径和锁检查，`--yes` 不绕过检查；`--delete-config` 仅删除 `mirror.env`，`runtime/` 与安装记录保留。`state/`、`staging/`、`quarantine/` 不属于仓库删除选项，不应当作临时缓存清空。容器部署优先使用上述 Compose 停止和生命周期操作。

## 启动检查与仓库恢复

每次容器启动先撤销旧导出，串行执行 `git fsck --full`，逐库检查通过后开放下载，再进行网络同步。健康旧缓存允许离线下载；完整性检查通过不代表缓存与上游实时一致，需另看最近成功同步记录。配置外遗留仓库不自动导出，也不自动删除。

本地写入失败、维护失败、中断或结果未知会要求重新检查；只有明确的网络失败且没有本地异常时保留健康发布。确认对象损坏后才从配置上游独立重建，新副本验证、发布及记录持久化成功前保留旧副本。曾在本轮启动中发布的仓库无法可靠证明读者排空时，仅撤销新下载入口，物理移动和替换延后到容器重启，不能靠一次进程扫描或手工删除标记绕过。

`git-mirror-recover.sh --startup` 需要有效的容器启动上下文，不是供人工 `exec` 的解冻命令。无法安全回收进程或持久化关键状态时会停止或冻结，不能凭“容器前台就绪”推断所有仓库已恢复。

## 自动 GC

每个仓库以首次发布日期为锚点，按有效 `TZ` 在锚点日期加 14 个日历日的 02:00 调用 `git gc --auto`；成功后沿原锚点每 14 天推进。没有达到 Git 清理阈值也算正常完成，不保证释放空间。离线错过的周期在启动检查后的下一个 02:00 补一次；失败或中断不推进周期，最早在失败当地日期次日 02:00 重试，重启不缩短或重复后移已保存的重试下限。

`ENABLE_CRON=no` 同时关闭自动 GC、同步和地址刷新调度，不取消启动检查与启动同步。手工单次 GC 仍受到期、冻结和共同写锁约束，不是强制清理入口。fetch 自身仍可能触发受监督的前台自动维护，因此不能承诺只在双周时刻运行维护；程序不使用 `--prune=now` 或 `--aggressive`，也不覆盖 Git 默认清理阈值。

Git 原生锁和 `gc.log` 不自动删除。出现 `manual_intervention` 时先停止相关写入、保存诊断并确认没有使用者，再按具体原因人工处理；检查健康仅恢复读取，不表示磁盘空间、权限或写入锁已经恢复。不要删除应用锁文件、修改其 inode 或手工编辑持久状态来解除阻塞。

### 人工恢复写入

先检查 `state/gc/<owner>/<repo>.state` 的 `reason`、`write_blocked`、`operation_id` 和诊断日志，而不是只看下载是否恢复：

| 原因 | 处理边界 |
| --- | --- |
| `manual_intervention` | 存在 Git 原生 `*.lock`、`gc.pid` 或 `gc.log`。保存证据，停写并确认无使用者后按具体原因处理，不批量删除。 |
| `environment` | 先修复磁盘空间、权限或 I/O 问题；健康检查和实际写入探测通过后才可能解除写阻塞。 |
| `interrupted`、`unknown`、`state_failed`、`check_failed` | 排除根因后，使用当前操作 ID 显式确认；仅通过 `fsck` 不足以自动恢复写入。 |
| `rebuild_pending` | 等待独立重建及替换事务证据闭合，不能用手工确认冒充新副本已发布。 |

若之前冻结，先通过受控容器重启完成新一轮启动检查。确认根因已解决、没有并发写入或未收尾任务后，在运行实例中读取当前记录，按 `reason` 选择恢复入口：

```bash
docker compose exec git-daemon cat /var/lib/git-daemon/state/gc/git/git.state
```

对于 `manual_intervention` 或 `environment`，处理根因后使用普通 `--repo` 入口进行恢复检查。首次 GC 预检查失败时尚未生成操作 UUID，记录可能为 `operation_id=none`；不能传入 `--recover none`，也不要自行生成 UUID：

```bash
docker compose exec git-daemon /usr/local/lib/git-mirror/git-mirror-gc.sh --repo git/git
```

存在写阻塞时，该入口先执行恢复检查；仓库健康、原生锁检查和实际写入探测通过后才可能解除阻塞，不会在同一次恢复检查中执行 GC。无写阻塞时，普通入口仍按到期条件执行 GC 检查。

对于需要显式确认的 `interrupted`、`unknown`、`state_failed` 或 `check_failed`，使用当前记录中已核实的操作 UUID：

```bash
read -r -p '请输入已核实的当前 operation_id：' OPERATION_ID
docker compose exec git-daemon /usr/local/lib/git-mirror/git-mirror-gc.sh --repo git/git --recover "$OPERATION_ID"
```

显式确认入口检查操作 UUID 与当前记录一致、当前写阻塞、仓库健康、原生锁和实际写入条件；不会执行 GC，也不能代替 `rebuild_pending` 所需的替换事务证据。两种恢复方式均不绕过冻结或重试下限。`result=NOT_DUE` 可以表示恢复检查完成而未运行清理。读取恢复和写阻塞解除应分别核对；仍有错误时保留诊断，不修改状态文件制造成功。

## 停止与冻结

单任务 TERM 只取消该任务；实例或 scheduler 停止会冻结后续写入。OpenRC restart 和普通 resume 不解除冻结，必须经过新的容器启动检查。Compose 的 `restart: unless-stopped` 可能在 scheduler 停止导致入口退出后自动重启容器，从而进入新代次检查；不能据此承诺冻结一直持续到人工操作。计划停机请使用 Compose stop，并保留 30 秒停止宽限；所有裸 `docker run` 示例也必须指定 `--stop-timeout 30`。

受控恢复可在排除根因后执行 `docker compose start git-daemon`（已停止且配置未变），或 `docker compose up -d --force-recreate`（配置或镜像改变）。不要删除 `runtime/frozen`、`runtime/stopped` 或应用锁文件来绕过启动检查。

## 验证与验收边界

以下是可执行的验证入口，不代表本 README 已在某台机器完成部署验收。脚本测试需要 Bash 及各测试所需的 Linux 工具；容器实机测试需要可用的 Linux Docker 环境与 Compose。

逐文件语法检查，不能用 `bash -n scripts/*.sh` 冒充检查全部脚本：

```bash
for file in scripts/*.sh scripts/lib/*.sh docker/*.sh tests/*.sh; do
  bash -n "$file" || exit 1
done
for file in scripts/openrc/*; do
  sh -n "$file" || exit 1
done
```

行为回归与 Compose 渲染检查：

```bash
bash tests/test-git-mirror.sh
docker compose config --quiet
```

`IMAGE_TAG` 须已设置。Compose 渲染成功不验证容器启动、卷权限、端口可达或 Git 引用；上述回归包含静态检查和桩边界测试，不能整体称为容器实机验收。

实机集成入口：

```bash
bash tests/test-docker-integration.sh
```

报告应分别记录环境、执行入口、退出码、失败、跳过与延期项目。Docker 不可用时集成入口可返回 `77`，属于跳过而非通过；缺失 Compose 也不能宣称其编排已验证。使用 `IT_FILTER` 只运行部分场景时，不得报告全套通过。

**真实 mapping 成功验证不能被静态接线、日志出现 mapping、系统 DNS 回退成功或延期计数替代。** `IT_DEFER_MAPPING=1` 会显式输出 `DEFER` 并累计延期，相关 NAT 与真实 mapping 成功断言仍未验收。没有真实执行证据时，只报告已完成的文档或静态检查，不承诺 CI、代理、映射或容器集成通过。
