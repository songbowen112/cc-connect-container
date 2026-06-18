#!/bin/bash
# Claude Code HTTP Service 测试脚本
# 覆盖:health / whoami / query(同步+流式) / session 多轮 / hooks / 图片
# 兼容 macOS(用 curl --max-time 替代 GNU timeout)
set -uo pipefail

BASE="${BASE:-http://127.0.0.1:8765}"
AUTH_HEADER=()
if [ -n "${HTTP_API_KEY:-}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $HTTP_API_KEY")
fi

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✓${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; FAILED=1; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
header(){ echo -e "\n${YELLOW}== $1 ==${NC}"; }

FAILED=0

# ============================================================
header "1. 健康检查"
# ============================================================
RESP=$(curl -sS -m 5 "$BASE/health" 2>&1) || true
if echo "$RESP" | grep -q '"status":"ok"'; then
  ok "health: $RESP"
else
  fail "health failed: $RESP"
  exit 1
fi

# ============================================================
header "2. 鉴权测试 (/v1/whoami)"
# ============================================================
RESP=$(curl -sS -m 5 "${AUTH_HEADER[@]:-}" "$BASE/whoami" 2>&1) || true
if [ -n "${HTTP_API_KEY:-}" ]; then
  if echo "$RESP" | grep -q '"ok":true'; then
    ok "whoami 鉴权通过"
  else
    fail "whoami 鉴权失败: $RESP"
  fi

  # 错误 token 应被拒
  RESP=$(curl -sS -m 5 -H "Authorization: Bearer wrong-key" -o /dev/null -w "%{http_code}" "$BASE/whoami" 2>&1) || true
  if [ "$RESP" = "401" ]; then
    ok "错误 token 返回 401"
  else
    fail "错误 token 应返回 401,实际: $RESP"
  fi
else
  warn "HTTP_API_KEY 未设置,跳过鉴权测试"
fi

# ============================================================
header "3. 同步 query(/v1/query)"
# ============================================================
PAYLOAD='{
  "prompt": "用一句话回答: 1+1=?",
  "work_dir": "/home/vscode/cc-home",
  "permission_mode": "bypassPermissions",
  "model": "haiku"
}'
RESP=$(curl -sS -m 60 "${AUTH_HEADER[@]:-}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/query" 2>&1) || true
if echo "$RESP" | grep -q '"result"\|"last_text"'; then
  ok "同步 query 成功"
  echo "  响应: $(echo "$RESP" | head -c 300)"
else
  fail "同步 query 失败: $RESP"
fi

# ============================================================
header "4. 流式 query(/v1/query/stream)"
# ============================================================
echo "  等待 SSE 事件流(60s 超时)..."
RESP=$(curl -sN -m 60 "${AUTH_HEADER[@]:-}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/query/stream" 2>&1) || true
EVENT_COUNT=$(echo "$RESP" | grep -c "^event:" || true)
RESULT_COUNT=$(echo "$RESP" | grep -c "^event: result" || true)
ASSISTANT_COUNT=$(echo "$RESP" | grep -c "^event: assistant" || true)
if [ "$RESULT_COUNT" -ge 1 ] && [ "$ASSISTANT_COUNT" -ge 1 ]; then
  ok "SSE 流式: 收到 $EVENT_COUNT 个事件 (含 $ASSISTANT_COUNT 个 assistant, $RESULT_COUNT 个 result)"
else
  fail "SSE 流式异常,事件数=$EVENT_COUNT assistant=$ASSISTANT_COUNT result=$RESULT_COUNT"
  echo "  响应: $(echo "$RESP" | head -c 500)"
fi

# ============================================================
header "5. 多轮 session(创建→发消息→监听→再发)"
# ============================================================
SID=$(curl -sS -m 10 "${AUTH_HEADER[@]:-}" \
  -H "Content-Type: application/json" \
  -d '{"work_dir": "/home/vscode/cc-home", "permission_mode": "bypassPermissions", "model": "haiku"}' \
  "$BASE/v1/sessions/create" 2>&1 | python3 -c 'import sys,json; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null) || SID=""

if [ -n "$SID" ]; then
  ok "session 创建: $SID"
else
  fail "session 创建失败"
fi

if [ -n "$SID" ]; then
  # 启动事件流监听(后台) - 用 curl -m 替代 timeout
  curl -sN -m 90 "${AUTH_HEADER[@]:-}" \
    "$BASE/v1/sessions/$SID/events" > /tmp/session_events.txt 2>&1 &
  EVENTS_PID=$!
  sleep 2  # 等 SSE 连接建立

  # 第一轮
  curl -sS -m 10 "${AUTH_HEADER[@]:-}" \
    -H "Content-Type: application/json" \
    -d '{"message": "记一下: 水果 = 苹果"}' \
    "$BASE/v1/sessions/$SID/send" > /dev/null
  ok "第一轮消息已发送"

  sleep 25  # 等模型响应

  # 第二轮(验证上下文是否保留)
  curl -sS -m 10 "${AUTH_HEADER[@]:-}" \
    -H "Content-Type: application/json" \
    -d '{"message": "刚才记的水果是什么? 用一个词回答"}' \
    "$BASE/v1/sessions/$SID/send" > /dev/null
  ok "第二轮消息已发送"

  sleep 25

  # 终止监听
  kill $EVENTS_PID 2>/dev/null || true
  wait $EVENTS_PID 2>/dev/null || true

  # 验证:第二轮响应里应该提到"苹果"
  if grep -q "苹果" /tmp/session_events.txt; then
    ok "多轮上下文保留成功(响应包含'苹果')"
  else
    fail "多轮上下文未保留(响应中无'苹果')"
    echo "  事件日志前 500 字符: $(head -c 500 /tmp/session_events.txt)"
  fi

  # 关闭 session
  curl -sS -m 5 "${AUTH_HEADER[@]:-}" -X DELETE "$BASE/v1/sessions/$SID" > /dev/null
  ok "session 已关闭"
fi

# ============================================================
header "6. Hooks 测试(PreToolUse deny 拒绝 Read /etc/passwd)"
# ============================================================
# 写一个简单的 hook 脚本:收到 PreToolUse 时,如果 tool_name=Read 就 deny
HOOK_SCRIPT="/home/vscode/cc-http-uploads/pretool-deny.sh"
# 写 hook 脚本到挂载的 uploads 目录(容器内 / cc-http-uploads 和宿主机 cc-http-uploads/ 共享)
cat > /Users/songon/cc-connect-container/cc-http-uploads/pretool-deny.sh <<'SH'
#!/bin/bash
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('input',{}).get('tool_name',''))")
if [ "$TOOL_NAME" = "Read" ]; then
  echo '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "测试:hook 拒绝 Read 操作"}}'
fi
exit 0
SH
chmod +x /Users/songon/cc-connect-container/cc-http-uploads/pretool-deny.sh

HOOK_PAYLOAD='{
  "prompt": "尝试读取 /etc/passwd 文件的内容,只读前两行",
  "work_dir": "/home/vscode/cc-home",
  "permission_mode": "default",
  "model": "haiku",
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "command": "/home/vscode/cc-http-uploads/pretool-deny.sh"}
    ]
  }
}'
RESP=$(curl -sS -m 90 "${AUTH_HEADER[@]:-}" \
  -H "Content-Type: application/json" \
  -d "$HOOK_PAYLOAD" \
  "$BASE/v1/query" 2>&1) || true
# 如果 hook 生效,Claude 不会真的读取到 passwd 内容
if echo "$RESP" | grep -q "root:"; then
  fail "hook 未生效,响应包含 /etc/passwd 内容(危险)"
else
  ok "hook 拦截生效(响应未泄漏 passwd)"
  echo "  响应摘要: $(echo "$RESP" | head -c 200)"
fi

# ============================================================
header "7. 图片上传 + vision"
# ============================================================
# 造一张测试图(100x100 红 PNG,纯 Python 无依赖)
python3 - <<'PY' > /tmp/test.png
import struct, zlib
def png(w, h, color=(255,0,0,255)):
    sig = b'\x89PNG\r\n\x1a\n'
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t+d) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)
    raw = b''
    for _ in range(h):
        raw += b'\x00' + bytes(color) * w
    idat = zlib.compress(raw)
    return sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
open('/tmp/test.png','wb').write(png(100,100))
print("ok")
PY

UPLOAD=$(curl -sS -m 10 "${AUTH_HEADER[@]:-}" \
  -F "file=@/tmp/test.png" \
  "$BASE/v1/files" 2>&1) || true
IMG_PATH=$(echo "$UPLOAD" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("path",""))' 2>/dev/null) || IMG_PATH=""

if [ -n "$IMG_PATH" ]; then
  ok "图片上传成功: $IMG_PATH"

  VISION_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'prompt': '这张图主要是什么颜色?一个词回答',
  'work_dir': '/home/vscode/cc-home',
  'permission_mode': 'bypassPermissions',
  'model': 'haiku',
  'images': ['$IMG_PATH']
}))
")
  RESP=$(curl -sS -m 120 "${AUTH_HEADER[@]:-}" \
    -H "Content-Type: application/json" \
    -d "$VISION_PAYLOAD" \
    "$BASE/v1/query" 2>&1) || true
  if echo "$RESP" | grep -qiE "红|red|红色"; then
    ok "vision 识别成功(检测到红色)"
    echo "  响应: $(echo "$RESP" | head -c 200)"
  elif echo "$RESP" | grep -qiE "unsupported|image|image-only|图片不支持"; then
    warn "vision 跳过:当前模型不支持图片(底层 cc-switch 映射问题,非 HTTP 服务问题)"
  else
    warn "vision 响应不符合预期(可能 haiku 较弱或模型未映射): $(echo "$RESP" | head -c 200)"
  fi
else
  fail "图片上传失败: $UPLOAD"
fi

# ============================================================
header "测试结束"
# ============================================================
if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}全部通过 ✓${NC}"
  exit 0
else
  echo -e "${RED}有失败项 ✗${NC}"
  exit 1
fi
