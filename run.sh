#!/bin/bash
# claude-agent Podman 容器启动脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="songon/claude-agent"
CONTAINER_NAME="claude-agent"

# ============ 构建 ============
if [[ "${1:-}" == "--build" ]] || ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo ">>> 构建容器镜像..."
    podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" \
        --build-arg http_proxy="http://host.containers.internal:7897" \
        --build-arg https_proxy="http://host.containers.internal:7897" \
        --build-arg HTTP_PROXY="http://host.containers.internal:7897" \
        --build-arg HTTPS_PROXY="http://host.containers.internal:7897"
    echo ">>> 镜像构建完成"
fi

# ============ 停止旧容器 ============
if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    echo ">>> 停止旧容器..."
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# ============ 启动 ============
echo ">>> 启动 claude-agent 容器..."

mkdir -p "$SCRIPT_DIR/data"

podman run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --stop-timeout 30 \
    --add-host host.containers.internal:host-gateway \
    -v "$SCRIPT_DIR/data:/home/vscode/.cc-connect:Z" \
    --mount type=tmpfs,destination=/home/vscode/.cc-connect/run,tmpfs-size=16m,tmpfs-mode=1777 \
    -v "$HOME/.claude:/home/vscode/.claude:Z" \
    -v "$HOME/.ssh:/home/vscode/.ssh:ro,Z" \
    -v "$HOME/repository:/home/vscode/repository:Z" \
    -v "$HOME/cc-home:/home/vscode/cc-home:Z" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OLLAMA_HOST="http://host.containers.internal:11434" \
    -e GIT_TERMINAL_PROMPT=0 \
    -e http_proxy= \
    -e https_proxy= \
    -e HTTP_PROXY= \
    -e HTTPS_PROXY= \
    "$IMAGE_NAME"

echo ">>> 等待 cc-connect 就绪..."
for i in $(seq 1 30); do
  if podman logs "$CONTAINER_NAME" 2>&1 | grep -q "engine started"; then
    echo ">>> ✓ cc-connect 已就绪"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo ">>> ✗ 启动超时，请查看日志: podman logs $CONTAINER_NAME"
    exit 1
  fi
  sleep 1
done
echo ">>> 查看日志: podman logs -f $CONTAINER_NAME"
echo ">>> 停止: podman rm -f $CONTAINER_NAME"
