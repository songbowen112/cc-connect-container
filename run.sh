#!/bin/bash
# claude-agent Podman 容器启动脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="songon/claude-agent"
CONTAINER_NAME="claude-agent"

# ============ 构建 ============
if [[ "${1:-}" == "--build" ]] || ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo ">>> 构建容器镜像..."
    podman build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile"
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
    --entrypoint /bin/bash \
    "$IMAGE_NAME" \
    -lc 'socat TCP-LISTEN:15721,bind=127.0.0.1,fork,reuseaddr TCP:host.containers.internal:15721 & exec cc-connect --config /home/vscode/.cc-connect/config.toml'

echo ">>> 容器已启动"
echo ">>> 查看日志: podman logs -f $CONTAINER_NAME"
echo ">>> 停止: podman rm -f $CONTAINER_NAME"
