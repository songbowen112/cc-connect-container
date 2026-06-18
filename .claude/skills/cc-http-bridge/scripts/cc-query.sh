#!/bin/bash
# 同步调 cc-http-service 的 /v1/query
# 用法:
#   cc-query.sh '1+1=?'                              # 一行 prompt
#   echo '分析下当前目录' | cc-query.sh               # stdin 传 prompt
#   cc-query.sh --model sonnet --work-dir /tmp 'hi'  # 显式参数
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
      sed -n '2,8p' "$0"; exit 0 ;;
    *)
      PROMPT="$1"; shift ;;
  esac
done

if [ -z "${PROMPT:-}" ] && [ ! -t 0 ]; then
  PROMPT=$(cat)
fi
if [ -z "${PROMPT:-}" ]; then
  echo "用法: $0 [options] 'prompt'" >&2
  echo "  --model haiku|sonnet|opus|fable" >&2
  echo "  --work-dir PATH" >&2
  echo "  --permission bypassPermissions|default|plan" >&2
  echo "  --base http://host:port" >&2
  exit 1
fi

# 加载 token
if [ -z "${HTTP_API_KEY:-}" ] && [ -f "$(dirname "$0")/../../../.env" ]; then
  HTTP_API_KEY=$(grep '^HTTP_API_KEY=' "$(dirname "$0")/../../../.env" | cut -d= -f2-)
  export HTTP_API_KEY
fi
if [ -z "${HTTP_API_KEY:-}" ]; then
  echo "错误: HTTP_API_KEY 未设置;请 source cc-connect-container/.env" >&2
  exit 2
fi

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
  'prompt': sys.argv[1],
  'work_dir': sys.argv[2],
  'model': sys.argv[3],
  'permission_mode': sys.argv[4],
}))
" "$PROMPT" "$WORK_DIR" "$MODEL" "$PERM")

curl -sS -m 600 \
  -H "Authorization: Bearer $HTTP_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/query" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if 'error' in d:
    print('错误:', d['error'], file=sys.stderr); sys.exit(1)
print(d.get('result', ''))
if d.get('total_cost_usd'):
    print(f'\n[session={d.get(\"session_id\",\"\")} cost=\${d[\"total_cost_usd\"]:.4f} turns={d.get(\"num_turns\",0)}]', file=sys.stderr)
"
