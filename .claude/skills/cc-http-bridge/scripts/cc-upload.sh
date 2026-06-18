#!/bin/bash
# 上传文件到 cc-http-service,打印容器内绝对路径
# 用法:
#   cc-upload.sh /path/to/image.png
#   cc-upload.sh -                # 从 stdin 读(保存为 stdin.bin)
set -euo pipefail

BASE="${CC_HTTP_BASE:-http://127.0.0.1:8765}"

if [ -z "${HTTP_API_KEY:-}" ] && [ -f "$(dirname "$0")/../../../.env" ]; then
  HTTP_API_KEY=$(grep '^HTTP_API_KEY=' "$(dirname "$0")/../../../.env" | cut -d= -f2-)
  export HTTP_API_KEY
fi
[ -z "${HTTP_API_KEY:-}" ] && { echo "HTTP_API_KEY 未设置" >&2; exit 2; }

FILE="${1:-}"
if [ -z "$FILE" ]; then
  echo "用法: $0 <file-path>" >&2; exit 1
fi

if [ "$FILE" = "-" ]; then
  TMP=$(mktemp /tmp/cc-upload.XXXXXX)
  cat > "$TMP"
  FILE="$TMP"
  trap 'rm -f "$TMP"' EXIT
fi

[ -f "$FILE" ] || { echo "文件不存在: $FILE" >&2; exit 1; }

curl -sS -m 30 -H "Authorization: Bearer $HTTP_API_KEY" \
  -F "file=@$FILE" \
  "$BASE/v1/files" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['path'])
"
