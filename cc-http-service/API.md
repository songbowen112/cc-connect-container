# Claude Code HTTP Service API

> 容器内 Claude Code 的 HTTP / SSE 接口文档。基于 `claude-agent-sdk` + FastAPI + SSE。
>
> **Base URL**: `http://<容器宿主机IP>:8765`
> **鉴权**: 除 `/health` 外所有 `/v1/*` 端点需要 `Authorization: Bearer <HTTP_API_KEY>` 头。
> **Content-Type**: `application/json`(除 `/v1/files` 用 `multipart/form-data`)

---

## 全局说明

### 鉴权

```http
Authorization: Bearer <HTTP_API_KEY>
```

- `HTTP_API_KEY` 由 `run.sh` 启动时自动生成,持久化到 `cc-connect-container/.env`
- 如果 `HTTP_API_KEY` 为空(未设置环境变量、`.env` 也没写),鉴权**关闭**(仅本地调试用)

### 错误码

| 状态码 | 含义 |
|--------|------|
| 200 | 成功 |
| 401 | 鉴权失败(Bearer token 缺失或错误) |
| 404 | Session 不存在 |
| 422 | 请求体校验失败(Pydantic 校验错误,返回 `{detail: [{loc, msg, type}, ...]}`) |
| 500 | 内部错误 / SDK 调用失败 |

### SSE 事件格式

`/v1/query/stream` 和 `/v1/sessions/{sid}/events` 返回 `text/event-stream`,事件类型:

| event 字段 | 含义 |
|------------|------|
| `system` | SDK 系统消息(包含 init / hook_started / hook_response 等) |
| `assistant` | Claude 助手消息(content 为 text/tool_use 块数组) |
| `result` | 最终结果(包含 session_id / total_cost_usd / result 文本) |
| `turn_complete` | 多轮会话中,一轮响应结束 |
| `heartbeat` | 多轮会话无活动超时(120s)时发送保活 |
| `session_closed` | session 关闭事件 |
| `error` | 错误事件 |

---

## 1. 健康检查

### `GET /health`

服务存活 + 鉴权开关状态。

**无需鉴权**

#### 请求参数

无

#### 响应示例

```json
{
  "status": "ok",
  "auth_enabled": true
}
```

#### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `status` | string | 固定 `"ok"` 表示服务正常 |
| `auth_enabled` | boolean | 鉴权是否开启(`true` = 需带 Bearer token) |

---

## 2. 鉴权测试

### `GET /whoami`

仅用于验证 `HTTP_API_KEY` 是否生效。鉴权开启时,带正确 token 返回 `{ok: true}`,错误/缺失返回 401。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |

#### 响应示例

```json
{
  "ok": true
}
```

---

## 3. 同步查询

### `POST /v1/query`

阻塞模式:等待 Claude 处理完所有事件,把最终结果作为一次 JSON 响应返回。适合一次性脚本调用。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Content-Type` | 是 | `application/json` |

#### 请求体 (QueryRequest)

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|------|------|------|
| `prompt` | string | 是 | - | 用户消息 |
| `work_dir` | string | 否 | `/home/vscode/cc-home` | Claude Code 工作目录 |
| `model` | string | 否 | 跟随 cc-switch | 模型别名:`haiku` / `sonnet` / `opus` / `fable`,实际被 cc-switch 映射 |
| `permission_mode` | string | 否 | `bypassPermissions` | 权限模式,见下表 |
| `allowed_tools` | string[] | 否 | - | 允许的工具列表,如 `["Read", "Edit", "Glob"]` |
| `system_prompt` | string | 否 | - | 自定义 system prompt |
| `hooks` | object | 否 | - | 生命周期 hook,见 [§3.1 Hooks](#31-hooks-结构) |
| `agents` | object | 否 | - | 子代理定义,见 [§3.2 Subagents](#32-subagents-结构) |
| `mcp_servers` | object | 否 | - | MCP 服务器配置,见 [§3.3 MCP](#33-mcp-结构) |
| `images` | string[] | 否 | - | 容器内图片绝对路径(需先通过 `/v1/files` 上传) |
| `extra_options` | object | 否 | - | 透传给 `ClaudeAgentOptions` 的其他字段 |

**`permission_mode` 可选值**:

| 值 | 含义 |
|----|------|
| `default` | 默认,需要用户确认 |
| `acceptEdits` | 自动接受文件编辑 |
| `plan` | 计划模式,只读不写 |
| `bypassPermissions` | 跳过所有权限检查(**默认,云端推荐**) |
| `dontAsk` | 工具权限不询问 |
| `auto` | SDK 自动判断 |

#### 请求示例

```json
{
  "prompt": "列出当前目录的 Python 文件",
  "work_dir": "/home/vscode/cc-home",
  "model": "haiku",
  "permission_mode": "bypassPermissions"
}
```

#### 响应示例

```json
{
  "result": "当前目录包含: app/, tests/, requirements.txt, run.py",
  "session_id": "9c6817c0-a641-4ab3-8489-8c16898af961",
  "total_cost_usd": 0.0029,
  "is_error": false,
  "num_turns": 1,
  "last_text": "当前目录包含: app/, tests/, requirements.txt, run.py"
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `result` | string \| null | Claude 最终输出文本 |
| `session_id` | string | 本次调用的 SDK session ID |
| `total_cost_usd` | number | 本次调用消耗美元 |
| `is_error` | boolean | 是否出错 |
| `num_turns` | integer | SDK 内部 turn 数 |
| `last_text` | string | 最后一条 assistant 文本(拼接所有 text block) |

---

## 4. 流式查询

### `POST /v1/query/stream`

SSE 流式模式:边生成边推送事件,适合需要实时显示进度的场景。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Content-Type` | 是 | `application/json` |
| `Accept` | 否 | `text/event-stream` |

#### 请求体

同 `POST /v1/query` 的 `QueryRequest`。

#### 响应

`Content-Type: text/event-stream`,持续输出 SSE 事件直到流结束。

#### SSE 事件示例

```http
event: system
data: {"subtype": "init", "session_id": "abc-123", "details": {"cwd": "/home/vscode/cc-home", "tools": [...], "model": "claude-haiku-4-5"}}

event: assistant
data: {"content": [{"type": "text", "text": "我来分析"}], "parent_tool_use_id": null}

event: assistant
data: {"content": [{"type": "tool_use", "id": "toolu_xxx", "name": "Glob", "input": {"pattern": "**/*.py"}}], "parent_tool_use_id": null}

event: result
data: {"subtype": "success", "result": "...", "total_cost_usd": 0.01, "is_error": false, "num_turns": 2, "session_id": "abc-123"}
```

#### 客户端示例

```bash
curl -N -X POST http://localhost:8765/v1/query/stream \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"1+1?","model":"haiku","permission_mode":"bypassPermissions"}'
```

---

### 3.1 Hooks 结构

```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "command": "/usr/local/bin/my-hook.sh", "timeout": 30}
    ],
    "PostToolUse": [...],
    "Stop": [...],
    "SubagentStop": [...]
  }
}
```

#### HookMatcher 字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `matcher` | string | 否 | 工具名匹配模式,支持 `\|` 分隔多个,默认 `"*"` 匹配所有 |
| `command` | string | 否 | 容器内可执行文件路径,SDK 调用时把 hook input 写到 stdin,读 stdout 作为决策 |
| `timeout` | number | 否 | 超时秒数,默认 60 |

**command 协议**:

1. SDK 把以下 JSON 写到 stdin:
   ```json
   {
     "hook_event_name": "PreToolUse",
     "input": {"tool_name": "Read", "tool_input": {...}},
     "tool_use_id": "toolu_xxx"
   }
   ```
2. 如果 stdout 是合法 JSON 决策 → 采纳
3. 如果退出码非 0 或 stdout 为空 → 忽略,继续默认行为

**PreToolUse 拒绝示例**(hook 脚本 stdout):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "禁止读取 /etc/passwd"
  }
}
```

完整 hook 协议参考: https://docs.anthropic.com/en/docs/claude-code/hooks

---

### 3.2 Subagents 结构

```json
{
  "agents": {
    "code-reviewer": {
      "description": "代码审查专家",
      "prompt": "关注安全性和最佳实践,只给建议不改代码",
      "tools": ["Read", "Glob", "Grep"],
      "model": "haiku"
    }
  }
}
```

#### SubagentDef 字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `description` | string | 是 | 子代理描述(Claude 用它决定何时委派) |
| `prompt` | string | 是 | 子代理 system prompt |
| `tools` | string[] | 否 | 允许使用的工具列表 |
| `model` | string | 否 | 子代理使用的模型 |

---

### 3.3 MCP 结构

支持 stdio / http / sse 三种传输。

```json
{
  "mcp_servers": {
    "github": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {"GITHUB_TOKEN": "ghp_xxx"}
    },
    "remote": {
      "type": "http",
      "url": "https://mcp.example.com/api",
      "headers": {"Authorization": "Bearer xxx"}
    }
  }
}
```

#### McpServerConfig 字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `type` | string | 否 | `stdio` / `http` / `sse`,省略时按字段推断 |
| `command` | string | stdio 必填 | stdio 模式的启动命令 |
| `args` | string[] | 否 | stdio 模式的命令行参数 |
| `env` | object | 否 | stdio 模式的环境变量 |
| `url` | string | http/sse 必填 | MCP 服务端 URL |
| `headers` | object | 否 | http/sse 模式的请求头 |

---

## 5. 文件上传

### `POST /v1/files`

上传文件(图片等)到容器内的 `cc-http-uploads/` 目录,返回容器内可访问的绝对路径。
然后在 `query` 请求的 `images` 字段里传这个路径,让 Claude 看到。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Content-Type` | 是 | `multipart/form-data`(自动) |

#### 请求体 (multipart/form-data)

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file` | file | 是 | 上传的文件(支持任意类型) |

#### 响应示例

```json
{
  "filename": "a1b26d79_test.png",
  "path": "/home/vscode/cc-http-uploads/a1b26d79_test.png",
  "size": 310
}
```

#### 响应字段 (FileUploadResponse)

| 字段 | 类型 | 说明 |
|------|------|------|
| `filename` | string | 服务器保存的文件名(原文件名前加了 8 位随机前缀) |
| `path` | string | 容器内可访问的绝对路径,用于在 `query.images` 中引用 |
| `size` | integer | 文件字节数 |

#### 客户端示例

```bash
# 上传图片
curl -X POST http://localhost:8765/v1/files \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -F "file=@/path/to/image.png"

# 用返回的 path 调 query
curl -X POST http://localhost:8765/v1/query \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "这张图是什么?",
    "images": ["/home/vscode/cc-http-uploads/a1b26d79_test.png"]
  }'
```

---

## 6. 创建多轮会话

### `POST /v1/sessions/create`

创建一个常驻的会话(在服务端维持一个 `ClaudeSDKClient` 实例),后续通过 `/send` 和 `/events` 与之交互,保留完整上下文。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Content-Type` | 是 | `application/json` |

#### 请求体 (SessionCreateRequest)

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|------|------|------|
| `work_dir` | string | 否 | `/home/vscode/cc-home` | Claude Code 工作目录 |
| `model` | string | 否 | - | 模型别名 |
| `permission_mode` | string | 否 | `bypassPermissions` | 权限模式(取值同 `QueryRequest`) |
| `allowed_tools` | string[] | 否 | - | 允许的工具列表 |
| `system_prompt` | string | 否 | - | 自定义 system prompt |

> 注:`SessionCreateRequest` 不含 `prompt` 字段,创建时不发消息,只建立 session。

#### 响应示例

```json
{
  "session_id": "3a7fef0d154a462e",
  "work_dir": "/home/vscode/cc-home"
}
```

#### 响应字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `session_id` | string | session 唯一标识,后续 `/send` / `/events` / `DELETE` 都用这个 |
| `work_dir` | string | session 实际使用的工作目录 |

---

## 7. 列出活跃会话

### `GET /v1/sessions/list`

列出当前所有活跃的 session ID。

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |

#### 响应示例

```json
{
  "sessions": ["3a7fef0d154a462e", "9b2c4d7e1a8f0e12"]
}
```

---

## 8. 发送消息到 session

### `POST /v1/sessions/{session_id}/send`

往指定 session 发送一条消息。`session_id` 必须在 `/v1/sessions/create` 之后存在。

#### 路径参数

| 名称 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `session_id` | string | 是 | URL 路径参数,create 时返回的 ID |

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Content-Type` | 是 | `application/json` |

#### 请求体 (SessionSendRequest)

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `message` | string | 是 | 用户消息 |
| `images` | string[] | 否 | 容器内图片绝对路径(需先通过 `/v1/files` 上传) |

#### 响应示例

```json
{
  "ok": true,
  "session_id": "3a7fef0d154a462e"
}
```

#### 错误响应

| 状态码 | 含义 |
|--------|------|
| 404 | session 不存在或已关闭 |
| 400 | 图片文件不存在 |

---

## 9. 订阅 session 事件流

### `GET /v1/sessions/{session_id}/events`

SSE 长连接,持续推送 session 的所有事件。客户端可以同时开 `/send` 发消息,事件会按顺序到达。

#### 路径参数

| 名称 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `session_id` | string | 是 | URL 路径参数 |

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |
| `Accept` | 否 | `text/event-stream` |

#### 响应

`Content-Type: text/event-stream`

#### SSE 事件

| event 字段 | 含义 |
|------------|------|
| `system` | SDK 系统消息 |
| `assistant` | Claude 助手消息 |
| `result` | 本轮结果(每轮一个) |
| `turn_complete` | 一轮响应结束,下一轮可以继续 send |
| `heartbeat` | 120s 无活动时发送保活 |
| `session_closed` | session 已关闭(流结束前最后一个事件) |
| `error` | 错误事件 |

#### 客户端示例(典型多轮对话流程)

```bash
# 1. 创建 session
SID=$(curl -s -X POST http://localhost:8765/v1/sessions/create \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"haiku","permission_mode":"bypassPermissions"}' | jq -r .session_id)

# 2. 后台订阅事件流
curl -N "http://localhost:8765/v1/sessions/$SID/events" \
  -H "Authorization: Bearer $HTTP_API_KEY" &

# 3. 第一轮
curl -X POST "http://localhost:8765/v1/sessions/$SID/send" \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"message":"记一下: 水果 = 苹果"}'

# 4. 第二轮(上下文保留)
curl -X POST "http://localhost:8765/v1/sessions/$SID/send" \
  -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
  -d '{"message":"刚才记的水果是什么?"}'

# 5. 关闭
curl -X DELETE "http://localhost:8765/v1/sessions/$SID" \
  -H "Authorization: Bearer $HTTP_API_KEY"
```

#### 错误响应

| 状态码 | 含义 |
|--------|------|
| 404 | session 不存在 |

---

## 10. 关闭 session

### `DELETE /v1/sessions/{session_id}`

主动关闭指定 session,释放服务端资源。

#### 路径参数

| 名称 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `session_id` | string | 是 | URL 路径参数 |

#### 请求头

| 名称 | 必填 | 说明 |
|------|------|------|
| `Authorization` | 是 | `Bearer <HTTP_API_KEY>` |

#### 响应示例

```json
{
  "ok": true,
  "session_id": "3a7fef0d154a462e"
}
```

#### 错误响应

| 状态码 | 含义 |
|--------|------|
| 404 | session 不存在或已关闭 |

---

## 附录:Object Schema 速查

### QueryRequest

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|------|------|------|
| `prompt` | string | 是 | - | 用户消息 |
| `work_dir` | string | 否 | `/home/vscode/cc-home` | 工作目录 |
| `model` | string | 否 | - | 模型别名 |
| `permission_mode` | enum | 否 | `bypassPermissions` | 权限模式 |
| `allowed_tools` | string[] | 否 | - | 工具白名单 |
| `system_prompt` | string | 否 | - | 自定义 system prompt |
| `hooks` | HooksConfig | 否 | - | 生命周期 hook |
| `agents` | map<SubagentDef> | 否 | - | 子代理字典 |
| `mcp_servers` | map<McpServerConfig> | 否 | - | MCP 服务器字典 |
| `images` | string[] | 否 | - | 容器内图片路径 |
| `extra_options` | object | 否 | - | 透传给 SDK 的其他选项 |

### SessionCreateRequest

| 字段 | 类型 | 必填 | 默认 | 说明 |
|------|------|------|------|------|
| `work_dir` | string | 否 | `/home/vscode/cc-home` | 工作目录 |
| `model` | string | 否 | - | 模型别名 |
| `permission_mode` | enum | 否 | `bypassPermissions` | 权限模式 |
| `allowed_tools` | string[] | 否 | - | 工具白名单 |
| `system_prompt` | string | 否 | - | 自定义 system prompt |

### SessionSendRequest

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `message` | string | 是 | 用户消息 |
| `images` | string[] | 否 | 容器内图片路径 |

### FileUploadResponse

| 字段 | 类型 | 说明 |
|------|------|------|
| `filename` | string | 服务器文件名 |
| `path` | string | 容器内绝对路径 |
| `size` | integer | 字节数 |
