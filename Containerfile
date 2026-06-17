# 基于微软 devcontainer 镜像（自带 git/curl/sudo/build-essential 等）
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04

# ============================================================
# OCI 镜像标签
# ============================================================
LABEL org.opencontainers.image.title="claude-agent"
LABEL org.opencontainers.image.description="cc-connect + Claude Code 全功能 AI Agent 容器"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.source="https://github.com/songbowen112/cc-connect-container"
LABEL org.opencontainers.image.authors="songon"
LABEL org.opencontainers.image.licenses="MIT"

# 构建时代理（默认不开启，需时通过 podman build --build-arg 传入）
ARG http_proxy=""
ARG https_proxy=""
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""

# ============================================================
# 系统工具（镜像已含大部分，补充缺失的）
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    bsdmainutils bison mercurial \
    jq htop tree file which rsync \
    sqlite3 libsqlite3-dev \
    dnsutils iputils-ping net-tools \
    tzdata tini \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================================
# 时区：Asia/Shanghai (UTC+8)
# ============================================================
ENV TZ=Asia/Shanghai
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

# ============================================================
# NVM + Node 24 + cc-connect + Claude Code
# ============================================================
USER vscode
ENV NVM_DIR="/home/vscode/.nvm"
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash && \
    . /home/vscode/.nvm/nvm.sh && \
    nvm install 24.14.0 && \
    nvm alias default 24.14.0 && \
    npm config set registry https://registry.npmmirror.com && \
    npm install -g npm@11.9.0 && \
    npm config set registry https://registry.npmmirror.com && \
    npm install -g cc-connect@1.3.2 @anthropic-ai/claude-code@2.1.173

# ============================================================
# SDKMAN: JDK 21 + Maven 3.9.14
# ============================================================
RUN curl -s "https://get.sdkman.io" | bash
ENV SDKMAN_DIR="/home/vscode/.sdkman"
RUN bash -c '. /home/vscode/.sdkman/bin/sdkman-init.sh && \
    sdk install java 21.0.6-tem && \
    sdk install maven 3.9.14 && \
    sdk default java 21.0.6-tem && \
    sdk default maven 3.9.14'

# ============================================================
# GVM + Go 1.22.4
# ============================================================
RUN curl -s -S -L https://raw.githubusercontent.com/moovweb/gvm/master/binscripts/gvm-installer | bash
RUN bash -c '. /home/vscode/.gvm/scripts/gvm && \
    gvm install go1.22.4 -B && \
    gvm use go1.22.4 --default'

# ============================================================
# uv + Python 虚拟环境
# ============================================================
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    /home/vscode/.local/bin/uv python install 3.12 && \
    /home/vscode/.local/bin/uv venv /home/vscode/.venv --python 3.12

# ============================================================
# Shell 配置（合并为单层，减少镜像层数）
RUN \
  # cc 别名 \
  echo "alias cc='claude --dangerously-skip-permissions'" >> /home/vscode/.bashrc && \
  echo "alias cc='claude --dangerously-skip-permissions'" >> /home/vscode/.zshrc && \
  \
  # SDKMAN \
  echo 'export SDKMAN_DIR="/home/vscode/.sdkman"' >> /home/vscode/.bashrc && \
  echo '[[ -s "/home/vscode/.sdkman/bin/sdkman-init.sh" ]] && source "/home/vscode/.sdkman/bin/sdkman-init.sh"' >> /home/vscode/.bashrc && \
  echo 'export SDKMAN_DIR="/home/vscode/.sdkman"' >> /home/vscode/.zshrc && \
  echo '[[ -s "/home/vscode/.sdkman/bin/sdkman-init.sh" ]] && source "/home/vscode/.sdkman/bin/sdkman-init.sh"' >> /home/vscode/.zshrc && \
  \
  # NVM \
  echo 'export NVM_DIR="/home/vscode/.nvm"' >> /home/vscode/.bashrc && \
  echo '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' >> /home/vscode/.bashrc && \
  echo 'export NVM_DIR="/home/vscode/.nvm"' >> /home/vscode/.zshrc && \
  echo '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' >> /home/vscode/.zshrc && \
  \
  # GVM \
  echo '[[ -s "/home/vscode/.gvm/scripts/gvm" ]] && source "/home/vscode/.gvm/scripts/gvm"' >> /home/vscode/.bashrc && \
  echo '[[ -s "/home/vscode/.gvm/scripts/gvm" ]] && source "/home/vscode/.gvm/scripts/gvm"' >> /home/vscode/.zshrc && \
  \
  # Python venv \
  echo 'source /home/vscode/.venv/bin/activate' >> /home/vscode/.bashrc && \
  echo 'source /home/vscode/.venv/bin/activate' >> /home/vscode/.zshrc && \
  \
  # Ollama 连宿主机 \
  echo 'export OLLAMA_HOST="http://host.containers.internal:11434"' >> /home/vscode/.bashrc && \
  echo 'export OLLAMA_HOST="http://host.containers.internal:11434"' >> /home/vscode/.zshrc && \
  \
  # PATH \
  echo 'export PATH="/home/vscode/.local/bin:/home/vscode/.venv/bin:$PATH"' >> /home/vscode/.bashrc && \
  \
  # 代理管理函数（插入到 .bashrc 最开头） \
  printf '%s\n' \
    'px() { export http_proxy="http://host.containers.internal:7897"; export https_proxy="http://host.containers.internal:7897"; export HTTP_PROXY="http://host.containers.internal:7897"; export HTTPS_PROXY="http://host.containers.internal:7897"; echo "Proxy enabled: http://host.containers.internal:7897"; }' \
    'pxs() { if [ -n "$http_proxy" ]; then echo "Proxy enabled: $http_proxy"; else echo "⚠️ Proxy 未开启"; fi; }' \
    'upx() { unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; echo "Proxy disabled"; }' \
    | cat - /home/vscode/.bashrc > /tmp/bashrc && mv /tmp/bashrc /home/vscode/.bashrc

# macOS 路径兼容
USER root
RUN mkdir -p /Users && ln -sf /home/vscode /Users/songon && \
    ln -sf /home/vscode /Users/songbowen

# cc-connect 数据目录
USER vscode
RUN mkdir -p /home/vscode/.cc-connect /home/vscode/.claude

ENV PATH="/home/vscode/.nvm/versions/node/v24.14.0/bin:/home/vscode/.local/bin:/home/vscode/.venv/bin:${PATH}"

# ============================================================
# 入口脚本（tini 管理进程 + socat 代理转发）
# ============================================================
RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -e' \
    '' \
    '# cc-switch 本地代理转发（异常退出自动重连）' \
    '(' \
    '  until socat TCP-LISTEN:15721,bind=127.0.0.1,fork,reuseaddr \' \
    '      TCP:host.containers.internal:15721; do' \
    '    echo "socat: connection lost, restarting in 1s..." >&2' \
    '    sleep 1' \
    '  done' \
    ') &' \
    '' \
    '# 启动 cc-connect' \
    'exec cc-connect --config /home/vscode/.cc-connect/config.toml' \
    > /home/vscode/entrypoint.sh && \
    chmod +x /home/vscode/entrypoint.sh

WORKDIR /home/vscode

# 健康检查：确保 cc-connect 进程存活
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
  CMD pgrep -f "cc-connect --config" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/home/vscode/entrypoint.sh"]
CMD []
