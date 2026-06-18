# claude-agent

cc-connect + Claude Code 全功能 AI Agent 容器。通过飞书消息与 Claude Code 交互，支持 cc-switch 实时切换大模型。

## 前置条件

- **Podman** ≥ 5.x（macOS 通过 `podman machine` 运行）
- **飞书应用**（已创建企业自建应用，开通机器人能力）
- **cc-switch**（可选，用于在宿主机切换大模型）

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/songbowen112/cc-connect-container.git
cd cc-connect-container

# 2. 配置飞书应用
cp .env.example .env
# 编辑 data/config.toml，填入你的飞书 app_id 和 app_secret

# 3. 构建并启动
bash run.sh --build
```

首次构建约 10-15 分钟（需要下载 JDK、Go、Node 等工具链），后续启动秒级。

## 配置说明

### config.toml（必需）

放在 `data/config.toml`，容器通过 volume 挂载读取：

```toml
data_dir = "/home/vscode/.cc-connect"
language = "zh"

[[projects]]
name = "my-project"
admin_from = "*"
reset_on_idle_mins = 0

[projects.agent]
type = "claudecode"

[projects.agent.options]
work_dir = "/home/vscode/cc-home"
mode = "yolo"
# model = "sonnet"  # 不设置则跟随 cc-switch

[[projects.platforms]]
type = "feishu"

[projects.platforms.options]
allow_from = "*"
app_id = "cli_xxxxxxxxxxxxxxxxx"
app_secret = "xxxxxxxxxxxxxxxxxxxx"
```

### .env（可选）

复制 `.env.example` 为 `.env`，可按需覆盖默认值：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CLAUDE_AGENT_IMAGE` | `songon/claude-agent` | 镜像名 |
| `CLAUDE_AGENT_NAME` | `claude-agent` | 容器名 |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Claude Code 配置目录 |
| `SSH_DIR` | `$HOME/.ssh` | SSH key 目录（只读挂载） |
| `REPOSITORY_DIR` | `$HOME/repository` | 代码仓库目录 |
| `CC_HOME_DIR` | `$HOME/cc-home` | cc-connect 工作目录 |
| `MEMORY_LIMIT` | `4g` | 容器内存上限 |
| `CPU_LIMIT` | `4` | 容器 CPU 核心数上限 |
| `PROXY_PORT` | `7897` | 构建时代理端口（0 禁用） |

## 目录挂载

| 宿主机路径 | 容器路径 | 权限 | 说明 |
|-----------|---------|------|------|
| `./data/` | `~/.cc-connect` | rw | cc-connect 配置和会话存储 |
| `~/.claude/` | `~/.claude` | rw | Claude Code 配置（与 cc-switch 共享） |
| `~/.ssh/` | `~/.ssh` | ro | SSH 密钥（只读） |
| `~/repository/` | `~/repository` | rw | 代码仓库 |
| `~/cc-home/` | `~/cc-home` | rw | Agent 工作目录 |

## 常用命令

```bash
# 查看日志
podman logs -f claude-agent

# 查看状态（含健康检查）
podman ps --filter name=claude-agent

# 停止
podman rm -f claude-agent

# 进入容器调试
podman exec -it claude-agent bash

# 查看资源使用
podman stats claude-agent
```

## 健康检查

容器内置健康检查，每 30 秒检测 cc-connect 进程是否存活。状态可通过以下方式查看：

```bash
podman inspect claude-agent --format '{{.State.Health.Status}}'
# 输出: healthy / unhealthy / starting
```

## 容器内工具

| 工具 | 版本 | 用途 |
|------|------|------|
| Node.js | 24.14.0 | 运行时（cc-connect 依赖） |
| Java | 21.0.6 | JVM 项目开发 |
| Go | 1.22.4 | Go 项目开发 |
| Python | 3.12.13 | Python 项目开发 |
| Git | latest | 版本管理 |
| SQLite | 3.45 | 数据查询 |

## HTTP 远程调用（同网段程序化访问 cc）

容器内 `cc-http-service` 把 Claude Code 暴露为 HTTP/SSE 接口,同网段机器可直接 `curl` 调,无需走飞书通道。

```bash
# 加载鉴权 token
source .env && export HTTP_API_KEY

# 同步 query
curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"1+1?","model":"haiku","permission_mode":"bypassPermissions"}'

# 流式 query(SSE)
curl -N -X POST http://localhost:8765/v1/query/stream \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"分析当前目录"}'
```

10 个端点(`/v1/query`、`/v1/sessions/{sid}/send` 等)完整文档:
- Markdown: [cc-http-service/API.md](cc-http-service/API.md)
- OpenAPI(导入 Apifox): [cc-http-service/openapi.json](cc-http-service/openapi.json)
- 测试: `bash cc-http-service/tests/test_api.sh`

`.claude/skills/cc-http-bridge/` 内置了 4 个开箱即用脚本(sync / stream / session REPL / upload),Claude Code 触发 skill 后可直接 `Bash` 调它们。

## 飞书配置要点

1. 飞书开放平台创建**企业自建应用**
2. 开通权限：`im:message`、`im:message:send_as_bot`
3. 订阅事件：`im.message.receive_v1`、`card.action.trigger`
4. 填写 `app_id` 和 `app_secret` 到 `config.toml`

## 许可

MIT
