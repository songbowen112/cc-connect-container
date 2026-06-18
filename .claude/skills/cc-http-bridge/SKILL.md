---
name: cc-http-bridge
description: Use when calling the in-container Claude Code via the HTTP service exposed by cc-connect-container. Triggers: HTTP call to container claude, remote Claude Code, cc-http-service, /v1/query, /v1/sessions, cc HTTP bridge, 调用容器内 cc, 远程调 cc, 容器 Claude API.
---

# cc HTTP Bridge — 通过 HTTP 调容器内的 Claude Code

`cc-connect-container` 项目在容器内跑了一个 FastAPI 服务(`cc-http-service`),把 Claude Code SDK 暴露为 HTTP/SSE 接口。同机或同网段其他机器可以直接 `curl` 调用,无需进容器 / 走 cc-connect 消息通道。

## 何时用 / 何时不用

**用**:
- 想从脚本/工具链/CI 里程序化调用 cc
- 想用 SSE 流式拿实时进度
- 想跑多轮会话(上下文保留)
- 想程序化控制 hooks / 子代理 / MCP / 鉴权
- 不想依赖飞书消息通道

**不用**:
- 只想手动跟 cc 对话 → 继续用 cc-connect + 飞书
- 容器没启 HTTP 服务 → 跑 `bash run.sh` 启动(端口 8765)

## 服务地址

```
http://<容器宿主机IP>:8765
```

- 容器内监听 `0.0.0.0:8765`
- 同 podman 主机直接 `localhost:8765` 即可
- 鉴权默认开启,需 `Authorization: Bearer $HTTP_API_KEY` 头

## 鉴权配置

`HTTP_API_KEY` 在 `cc-connect-container/.env` 里。**没设的话 `run.sh` 第一次启动会自动生成一个 48 位 hex 写入**,记得从启动日志复制。

```bash
# 加载
source /Users/songon/cc-connect-container/.env
export HTTP_API_KEY

# 验证 token
curl -H "Authorization: Bearer $HTTP_API_KEY" http://localhost:8765/whoami
# {"ok":true}
```

## 端点速查

完整文档见 [cc-http-service/API.md](../../cc-http-service/API.md),`cc-http-service/openapi.json` 可直接导入 Apifox / Postman。

| 端点 | 用途 |
|------|------|
| `GET  /health` | 健康检查(无需鉴权) |
| `GET  /whoami` | 鉴权测试 |
| `POST /v1/query` | 单次查询,阻塞返回 |
| `POST /v1/query/stream` | 单次查询,SSE 流式 |
| `POST /v1/files` | 上传图片(给 vision 用) |
| `POST /v1/sessions/create` | 创建多轮会话 |
| `POST /v1/sessions/{sid}/send` | session 发消息 |
| `GET  /v1/sessions/{sid}/events` | session 事件流(SSE) |
| `DELETE /v1/sessions/{sid}` | 关闭 session |
| `GET  /docs` | Swagger UI |

## 快速示例

### 1. 单次查询(同步)

```bash
curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "1+1=?",
    "model": "haiku",
    "work_dir": "/home/vscode/cc-home",
    "permission_mode": "bypassPermissions"
  }'
# {"result":"2","session_id":"...","total_cost_usd":0.003,...}
```

### 2. 流式查询(SSE)

```bash
curl -N -X POST http://localhost:8765/v1/query/stream \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"分析下当前目录结构","model":"haiku","permission_mode":"bypassPermissions"}'
# 持续输出 event: system/assistant/result
```

### 3. 多轮会话

```bash
# 创建
SID=$(curl -s -X POST http://localhost:8765/v1/sessions/create \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"work_dir":"/home/vscode/cc-home","model":"haiku","permission_mode":"bypassPermissions"}' \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["session_id"])')

# 后台订阅事件
curl -N "http://localhost:8765/v1/sessions/$SID/events" \
  -H "Authorization: Bearer $HTTP_API_KEY" &

# 发消息
curl -X POST "http://localhost:8765/v1/sessions/$SID/send" \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"message":"我叫什么?"}'

# 用完关闭
curl -X DELETE "http://localhost:8765/v1/sessions/$SID" \
  -H "Authorization: Bearer $HTTP_API_KEY"
```

### 4. 图片理解(vision)

```bash
# 先上传
PATH=$(curl -s -X POST http://localhost:8765/v1/files \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -F "file=@/path/to/image.png" | python3 -c 'import sys,json; print(json.load(sys.stdin)["path"])')

# 引用
curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d "{\"prompt\":\"这张图是什么?\",\"images\":[\"$PATH\"]}"
```

## 高级功能(透传到 SDK)

| 字段 | 用途 |
|------|------|
| `hooks` | 生命周期 hook,command 形式(写 shell 脚本,SDK 通过 stdin 喂 hook input) |
| `agents` | 子代理字典,Claude 可委派给专用 subagent |
| `mcp_servers` | MCP 服务器(stdio / http / sse) |
| `allowed_tools` | 工具白名单,如 `["Read","Edit","Glob"]` |
| `system_prompt` | 覆盖默认 system prompt |
| `permission_mode` | `default`/`acceptEdits`/`plan`/`bypassPermissions`/`dontAsk`/`auto`,默认 `bypassPermissions` |
| `extra_options` | 透传给 SDK 的其他字段(如 `cli_path`、`max_turns`) |

完整字段说明 + JSON schema 参见 [API.md](../../cc-http-service/API.md) § "QueryRequest"。

## 配套脚本

`scripts/` 下有开箱即用的辅助脚本:

- `cc-query.sh` — 同步调 `/v1/query`,支持 stdin 传 prompt
- `cc-stream.sh` — 流式调 `/v1/query/stream`,把 SSE 事件格式化输出到 stdout
- `cc-session.sh` — 多轮会话交互式 REPL(create → send → events → 退出自动关闭)
- `cc-upload.sh` — 上传文件,打印容器内路径

## 故障排查

### 请求超时

1. **检查容器**: `podman ps --filter name=claude-agent`
2. **检查服务**: `curl http://localhost:8765/health`(< 1s 响应算正常)
3. **看 HTTP 日志**: `podman exec claude-agent tail -50 /tmp/cc-http.log`
4. **看进程**: `podman exec claude-agent ps auxf | grep claude` —— 多个 claude 子进程说明 SDK 子进程泄漏,`podman restart claude-agent` 解决
5. **超时阈值**: `HTTP_QUERY_TIMEOUT_SEC` (默认 600s)

### 401 Unauthorized

- 检查 `HTTP_API_KEY` 是否设置: `source cc-connect-container/.env && echo $HTTP_API_KEY`
- 容器启动时 token 可能重新生成过,重新 `cat cc-connect-container/.env` 拿最新

### 鉴权关闭(裸奔)

- `HTTP_API_KEY=""` 时鉴权关闭
- 局域网暴露前务必设置,否则任何人能调

### 子进程泄漏(内存涨)

每个失败的 query 会留一个 `claude` 子进程(~180MB)。如果 `ps auxf | grep claude` 看到多个,容器快爆了,`podman restart claude-agent` 清理。代码修复后 `aclose()` 会自动回收(见 `app/agent_service.py` 的 `finally: await gen.aclose()`)。

## 不该做的事

- ❌ 不要把 `HTTP_API_KEY` 提交到 git(`.env` 已在 `.gitignore`)
- ❌ 不要把容器端口 8765 暴露到公网,只在内网/本机用
- ❌ 不要绕过 `bypassPermissions` 在无人值守场景用 `default`,会卡在权限确认
- ❌ 不要开 session 不关,空闲超 30 分钟自动回收,主动 `DELETE` 释放

## 相关链接

- 服务实现源码: [cc-http-service/app/](../../cc-http-service/app/)
- 完整 API 文档(Markdown): [cc-http-service/API.md](../../cc-http-service/API.md)
- OpenAPI 规范(导入 Apifox): [cc-http-service/openapi.json](../../cc-http-service/openapi.json)
- 测试脚本: [cc-http-service/tests/test_api.sh](../../cc-http-service/tests/test_api.sh)
- 项目主仓库: [README.md](../../README.md)
