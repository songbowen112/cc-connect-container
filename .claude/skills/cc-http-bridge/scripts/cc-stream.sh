#!/bin/bash
# 流式调 cc-http-service 的 /v1/query/stream,格式化 SSE 事件输出
# 用法同 cc-query.sh;输出:
#   [system] init session=...
#   [assistant] text=...  (只打 text 块)
#   [assistant] tool=Bash input={"command":"ls"}  (tool_use 块)
#   [result] text=... cost=$0.01 turns=2
#   [error] message=...
#   [heartbeat] session=...
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
    -h|--help)
      sed -n '2,4p' "$0"; exit 0 ;;
    *)
      PROMPT="$1"; shift ;;
  esac
done

if [ -z "${PROMPT:-}" ] && [ ! -t 0 ]; then
  PROMPT=$(cat)
fi
if [ -z "${PROMPT:-}" ]; then
  echo "用法: $0 'prompt' (选项同 cc-query.sh)" >&2; exit 1
fi

if [ -z "${HTTP_API_KEY:-}" ] && [ -f "$(dirname "$0")/../../../.env" ]; then
  HTTP_API_KEY=$(grep '^HTTP_API_KEY=' "$(dirname "$0")/../../../.env" | cut -d= -f2-)
  export HTTP_API_KEY
fi
[ -z "${HTTP_API_KEY:-}" ] && { echo "HTTP_API_KEY 未设置" >&2; exit 2; }

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
  'prompt': sys.argv[1], 'work_dir': sys.argv[2],
  'model': sys.argv[3], 'permission_mode': sys.argv[4],
}))" "$PROMPT" "$WORK_DIR" "$MODEL" "$PERM")

curl -sN -m 600 \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/query/stream" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.rstrip()
    if not line.startswith('data: '):
        continue
    try:
        d = json.loads(line[6:])
    except Exception:
        continue
    # 提取 session_id 从 system init
    if d.get('subtype') == 'init':
        sid = d.get('session_id', '')
        print(f'[system] init session={sid[:16] if sid else \"\"}...', flush=True)
    elif 'content' in d:
        for block in d['content']:
            if block.get('type') == 'text':
                t = block.get('text', '')
                print(f'[assistant] text={t}', flush=True)
            elif block.get('type') == 'tool_use':
                print(f'[assistant] tool={block.get(\"name\")} input={json.dumps(block.get(\"input\",{}), ensure_ascii=False)[:200]}', flush=True)
    elif d.get('subtype') in ('success', 'error_max_turns', 'error'):
        print(f'[result] text={d.get(\"result\",\"\")[:500]} cost=\${d.get(\"total_cost_usd\",0):.4f} turns={d.get(\"num_turns\",0)} is_error={d.get(\"is_error\",False)}', flush=True)
    elif d.get('event') == 'error':
        print(f'[error] message={d.get(\"data\",{}).get(\"message\", d)}', flush=True)
    elif 'session_id' in d and not d.get('subtype'):
        print(f'[heartbeat] session={d[\"session_id\"][:16]}...', flush=True)
"
