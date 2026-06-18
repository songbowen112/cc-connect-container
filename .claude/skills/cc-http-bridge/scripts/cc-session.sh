#!/bin/bash
# 多轮会话交互式 REPL:create → 读 stdin 多行发消息 → ctrl-d 退出自动关 session
# 用法:
#   cc-session.sh                 # 默认参数启动
#   cc-session.sh --model sonnet  # 换模型
#   交互:输完消息回车发送,ctrl-d 退出
set -euo pipefail

BASE="${CC_HTTP_BASE:-http://127.0.0.1:8765}"
MODEL="haiku"
WORK_DIR="/home/vscode/cc-home"
PERM="bypassPermissions"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)       MODEL="$2"; shift 2 ;;
    --work-dir)    WORK_DIR="$2"; shift 2 ;;
    --permission)  PERM="$2"; shift 2 ;;
    --base)        BASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ -z "${HTTP_API_KEY:-}" ] && [ -f "$(dirname "$0")/../../../.env" ]; then
  HTTP_API_KEY=$(grep '^HTTP_API_KEY=' "$(dirname "$0")/../../../.env" | cut -d= -f2-)
  export HTTP_API_KEY
fi
[ -z "${HTTP_API_KEY:-}" ] && { echo "HTTP_API_KEY 未设置" >&2; exit 2; }

# 1. 创建 session(可能因 SDK 初始化慢而失败,重试 3 次)
for attempt in 1 2 3; do
  CREATE_BODY=$(python3 <<PY
import json
print(json.dumps({"work_dir": "$WORK_DIR", "model": "$MODEL", "permission_mode": "$PERM"}))
PY
)
  RESP=$(curl -sS -m 30 -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
    -d "$CREATE_BODY" \
    "$BASE/v1/sessions/create" 2>&1)
  if SID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['session_id'])" 2>/dev/null); then
    break
  fi
  echo "[尝试 $attempt/3] session 创建失败: $RESP" >&2
  if [ $attempt -lt 3 ]; then sleep 3; fi
done

if [ -z "${SID:-}" ]; then
  echo "错误: session 创建失败(可能底层 SDK 初始化超时,稍后重试)" >&2
  exit 3
fi
echo "[session=$SID] 创建成功,开始对话 (空行 + ctrl-d 退出)" >&2

cleanup() {
  echo >&2
  echo "[session=$SID] 关闭..." >&2
  curl -sS -m 5 -H "Authorization: Bearer $HTTP_API_KEY" -X DELETE "$BASE/v1/sessions/$SID" > /dev/null
  kill $EVENTS_PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 2. 后台订阅事件流,输出到 stderr
curl -sN -m 3600 -H "Authorization: Bearer $HTTP_API_KEY" \
  "$BASE/v1/sessions/$SID/events" 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.rstrip()
    if not line.startswith('data: '): continue
    try: d = json.loads(line[6:])
    except: continue
    if 'content' in d:
        for b in d['content']:
            if b.get('type') == 'text':
                print(f'\\ncc> {b.get(\"text\",\"\")}', flush=True)
            elif b.get('type') == 'tool_use':
                print(f'\\ncc> [tool {b.get(\"name\")} {json.dumps(b.get(\"input\",{}), ensure_ascii=False)[:200]}]', flush=True)
    elif d.get('subtype') in ('success','error_max_turns'):
        cost = d.get('total_cost_usd', 0)
        print(f'\\n  [turn cost=\${cost:.4f} turns={d.get(\"num_turns\",0)}]', flush=True)
    elif d.get('event') == 'error':
        print(f'\\n[error] {d.get(\"data\",{}).get(\"message\", d)}', flush=True)
" >&2 &
EVENTS_PID=$!

# 3. 读 stdin,空行发送
echo "你> " >&2
while IFS= read -r -e line; do
  [ -z "$line" ] && break
  SEND_BODY=$(python3 <<PY
import json
print(json.dumps({"message": """$line"""}))
PY
)
  curl -sS -m 10 -H "Authorization: Bearer $HTTP_API_KEY" -H "Content-Type: application/json" \
    -d "$SEND_BODY" \
    "$BASE/v1/sessions/$SID/send" > /dev/null
  # 给点时间让响应事件流过到 stderr(避免立刻 EOF 时丢响应)
  sleep 2
  echo "你> " >&2
done

wait $EVENTS_PID 2>/dev/null || true
