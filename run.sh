#!/bin/bash
# claude-agent Podman 容器启动脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 可配置变量（可通过 .env 文件覆盖）
# ============================================================
IMAGE_NAME="${CLAUDE_AGENT_IMAGE:-songon/claude-agent}"
CONTAINER_NAME="${CLAUDE_AGENT_NAME:-claude-agent}"

# 挂载路径
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
REPOSITORY_DIR="${REPOSITORY_DIR:-$HOME/repository}"
CC_HOME_DIR="${CC_HOME_DIR:-$HOME/cc-home}"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"

# 资源限制
MEMORY_LIMIT="${MEMORY_LIMIT:-4g}"
CPU_LIMIT="${CPU_LIMIT:-4}"

# 代理端口（仅用于构建，0 表示禁用。运行时默认不走代理）
PROXY_PORT="${PROXY_PORT:-7897}"

# 加载 .env 文件（优先级高于默认值）
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ============================================================
# 构建 ============================================================
if [[ "${1:-}" == "--build" ]] || ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    echo ">>> 构建容器镜像..."

    BUILD_ARGS=()
    if [ "$PROXY_PORT" != "0" ]; then
        # 容器内用 host.containers.internal，宿主机检测用 127.0.0.1
        PROXY_URL="http://host.containers.internal:$PROXY_PORT"
        if curl -s --max-time 2 "http://127.0.0.1:$PROXY_PORT" >/dev/null 2>&1; then
            BUILD_ARGS=(
                --build-arg http_proxy="$PROXY_URL"
                --build-arg https_proxy="$PROXY_URL"
                --build-arg HTTP_PROXY="$PROXY_URL"
                --build-arg HTTPS_PROXY="$PROXY_URL"
            )
            echo ">>> 代理 $PROXY_URL 已连接"
        else
            echo ">>> ⚠ 代理 127.0.0.1:$PROXY_PORT 不可达，以无代理模式构建"
        fi
    fi

    podman build --format docker -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Containerfile" "${BUILD_ARGS[@]:-}"
    echo ">>> 清理旧镜像..."
    podman image prune -f 2>/dev/null || true
    echo ">>> 镜像构建完成"
fi

# ============================================================
# 停止旧容器 ============================================================
if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
    echo ">>> 停止旧容器..."
    podman stop -t 30 "$CONTAINER_NAME" 2>/dev/null || true
    podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# ============================================================
# 启动 ============================================================
echo ">>> 启动 claude-agent 容器..."

mkdir -p "$DATA_DIR" "$CC_HOME_DIR"

# 代理不自动注入容器运行时环境
# 构建时走代理即可，运行时默认不走代理
# 容器内需要时手动执行 px() 开启，用完后 upx() 关闭

podman run -d \
    --name "$CONTAINER_NAME" \
    --user vscode \
    --restart unless-stopped \
    --stop-timeout 30 \
    --memory "$MEMORY_LIMIT" \
    --cpus "$CPU_LIMIT" \
    --add-host host.containers.internal:host-gateway \
    -v "$DATA_DIR:/home/vscode/.cc-connect:Z" \
    --mount type=tmpfs,destination=/home/vscode/.cc-connect/run,tmpfs-size=16m,tmpfs-mode=1777 \
    -v "$CLAUDE_CONFIG_DIR/settings.json:/home/vscode/.claude/settings.json:Z" \
    -v "$CLAUDE_CONFIG_DIR/CLAUDE.md:/home/vscode/.claude/CLAUDE.md:ro,Z" \
    -v "$SSH_DIR:/home/vscode/.ssh:ro,Z" \
    -v "$REPOSITORY_DIR:/home/vscode/repository:Z" \
    -v "$CC_HOME_DIR:/home/vscode/cc-home:Z" \
    -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    -e OLLAMA_HOST="http://host.containers.internal:11434" \
    -e GIT_TERMINAL_PROMPT=0 \
    "$IMAGE_NAME"

# ============================================================
# 健康检查 ============================================================
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
echo ">>> 状态:   podman ps --filter name=$CONTAINER_NAME"
echo ">>> 停止:   podman rm -f $CONTAINER_NAME"
