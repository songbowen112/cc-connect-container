# Claude Code HTTP Service

把容器内的 Claude Code 暴露为 HTTP / SSE 接口,同网段其他机器可远程调用。

基于 [claude-agent-sdk](https://github.com/anthropics/claude-agent-sdk-python) + FastAPI + SSE。

## 支持的端点

| 方法 | 路径 | 用途 |
|------|------|------|
| GET  | `/health` | 健康检查(无需鉴权) |
| GET  | `/whoami` | 鉴权测试(返回 `{ok:true}`) |
| POST | `/v1/query` | 单次查询,阻塞返回最终结果 |
| POST | `/v1/query/stream` | 单次查询,SSE 流式返回 |
| POST | `/v1/files` | 上传文件(图片等)到容器内,返回容器路径 |
| POST | `/v1/sessions/create` | 创建多轮会话(常驻 ClaudeSDKClient) |
| GET  | `/v1/sessions/list` | 列出所有活跃 session |
| POST | `/v1/sessions/{sid}/send` | 向 session 发送消息 |
| GET  | `/v1/sessions/{sid}/events` | SSE 订阅 session 事件流 |
| DELETE | `/v1/sessions/{sid}` | 关闭 session |
| GET  | `/docs` | Swagger UI(自动生成) |

## 鉴权

容器启动时 `run.sh` 自动生成 `HTTP_API_KEY` 写入 `.env`(避免局域网裸奔)。
所有 `/v1/*` 端点要求 `Authorization: Bearer <key>` 头。

如果 `HTTP_API_KEY` 为空,**鉴权关闭**(仅调试用,生产别开)。

## 调用示例

```bash
# 1. 健康检查(无需鉴权)
curl http://localhost:8765/health
# {"status":"ok","auth_enabled":true}

# 2. 同步 query
curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "列出当前目录的 Python 文件",
    "work_dir": "/home/vscode/cc-home",
    "model": "haiku",
    "permission_mode": "bypassPermissions"
  }'
# 返回:{"result":"...","session_id":"...","total_cost_usd":0.02,...}

# 3. SSE 流式 query
curl -N -X POST http://localhost:8765/v1/query/stream \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"1+1?","model":"haiku","permission_mode":"bypassPermissions"}'
# 持续输出 SSE 事件(event: system/assistant/result/heartbeat)

# 4. 多轮会话
SID=$(curl -s -X POST http://localhost:8765/v1/sessions/create \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"work_dir":"/home/vscode/cc-home","model":"haiku","permission_mode":"bypassPermissions"}' \
  | jq -r .session_id)

# 后台订阅事件流
curl -N "http://localhost:8765/v1/sessions/$SID/events" \
  -H "Authorization: Bearer $HTTP_API_KEY" &

# 发消息
curl -X POST "http://localhost:8765/v1/sessions/$SID/send" \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"message":"我叫什么?"}'

# 关掉
curl -X DELETE "http://localhost:8765/v1/sessions/$SID" \
  -H "Authorization: Bearer $HTTP_API_KEY"

# 5. 上传图片 + vision
curl -X POST http://localhost:8765/v1/files \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -F "file=@/path/to/image.png"
# 返回:{"filename":"...","path":"/home/vscode/cc-http-uploads/abc.png","size":12345}

curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"prompt":"这张图是什么?","images":["/home/vscode/cc-http-uploads/abc.png"]}'
```

## 请求体字段说明

`QueryRequest` / `SessionCreateRequest` 主要字段:

| 字段 | 类型 | 说明 |
|------|------|------|
| `prompt` | str | 用户消息(必填) |
| `work_dir` | str | Claude Code 工作目录,默认 `/home/vscode/cc-home` |
| `model` | str | `haiku` / `sonnet` / `opus` / `fable` 等,会被 cc-switch 映射 |
| `permission_mode` | str | `default` / `acceptEdits` / `plan` / `bypassPermissions` / `dontAsk` / `auto`,默认 `bypassPermissions` |
| `allowed_tools` | list[str] | 允许的工具,如 `["Read", "Edit", "Glob"]` |
| `system_prompt` | str | 自定义 system prompt |
| `hooks` | object | 生命周期 hook,见下 |
| `agents` | object | 子代理定义,见下 |
| `mcp_servers` | object | MCP 服务器配置(支持 stdio/http/sse) |
| `images` | list[str] | 容器内图片绝对路径(需先通过 `/v1/files` 上传) |
| `extra_options` | object | 透传给 `ClaudeAgentOptions` 的其他字段(如 `cli_path`) |

### Hooks 写法

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "command": "/usr/local/bin/my-hook.sh", "timeout": 30}
    ]
  }
}
```

- `matcher`: 工具名(支持 `|` 分隔多个)
- `command`: 容器内可执行文件路径。SDK 调用时会:
  1. 把 hook input JSON 写到 stdin
  2. 读 stdout JSON 作为决策
  3. 退出码非 0 = 忽略输出,继续默认行为
- 决策 JSON 格式(`PreToolUse` 拒绝示例):
  ```json
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..."}}
  ```

完整 hook 协议参见 [Claude Code Hooks 文档](https://docs.anthropic.com/en/docs/claude-code/hooks)。

### Subagents 写法

```json
{
  "agents": {
    "code-reviewer": {
      "description": "代码审查专家",
      "prompt": "关注安全性和最佳实践,不要改代码只给建议",
      "tools": ["Read", "Glob", "Grep"],
      "model": "haiku"
    }
  }
}
```

## 测试

```bash
# 容器内服务跑起来后,跑完整测试
source /Users/songon/cc-connect-container/.env  # 加载 HTTP_API_KEY
export HTTP_API_KEY
bash cc-http-service/tests/test_api.sh
```

## 文件上传目录

上传的文件存在 `/home/vscode/cc-http-uploads/`,通过 volume 挂载到宿主机的 `cc-http-uploads/`,方便从宿主机直接查看。
