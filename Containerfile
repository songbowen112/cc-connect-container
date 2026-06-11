# 基于微软 devcontainer 镜像（自带 git/curl/sudo/build-essential 等）
FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04

# 构建时代理（通过 host.containers.internal 访问宿主机代理）
ENV http_proxy="http://host.containers.internal:7897"
ENV https_proxy="http://host.containers.internal:7897"
ENV HTTP_PROXY="http://host.containers.internal:7897"
ENV HTTPS_PROXY="http://host.containers.internal:7897"

# ============================================================
# 系统工具（镜像已含大部分，补充缺失的）
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    bsdmainutils bison mercurial \
    jq htop tree file which rsync \
    sqlite3 libsqlite3-dev \
    dnsutils iputils-ping net-tools \
    tzdata \
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
    npm install -g npm@11.9.0 && \
    npm install -g cc-connect @anthropic-ai/claude-code

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
# Ollama CLI（连接宿主机）
# ============================================================
RUN curl -fsSL https://ollama.com/install.sh | sh || true

# ============================================================
# Shell 配置
# ============================================================
# cc 别名
RUN echo "alias cc='claude --dangerously-skip-permissions'" >> /home/vscode/.bashrc && \
    echo "alias cc='claude --dangerously-skip-permissions'" >> /home/vscode/.zshrc

# SDKMAN
RUN echo 'export SDKMAN_DIR="/home/vscode/.sdkman"' >> /home/vscode/.bashrc && \
    echo '[[ -s "/home/vscode/.sdkman/bin/sdkman-init.sh" ]] && source "/home/vscode/.sdkman/bin/sdkman-init.sh"' >> /home/vscode/.bashrc && \
    echo 'export SDKMAN_DIR="/home/vscode/.sdkman"' >> /home/vscode/.zshrc && \
    echo '[[ -s "/home/vscode/.sdkman/bin/sdkman-init.sh" ]] && source "/home/vscode/.sdkman/bin/sdkman-init.sh"' >> /home/vscode/.zshrc

# NVM
RUN echo 'export NVM_DIR="/home/vscode/.nvm"' >> /home/vscode/.bashrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' >> /home/vscode/.bashrc && \
    echo 'export NVM_DIR="/home/vscode/.nvm"' >> /home/vscode/.zshrc && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"' >> /home/vscode/.zshrc

# GVM
RUN echo '[[ -s "/home/vscode/.gvm/scripts/gvm" ]] && source "/home/vscode/.gvm/scripts/gvm"' >> /home/vscode/.bashrc && \
    echo '[[ -s "/home/vscode/.gvm/scripts/gvm" ]] && source "/home/vscode/.gvm/scripts/gvm"' >> /home/vscode/.zshrc

# Python venv
RUN echo 'source /home/vscode/.venv/bin/activate' >> /home/vscode/.bashrc && \
    echo 'source /home/vscode/.venv/bin/activate' >> /home/vscode/.zshrc

# Ollama 连宿主机
RUN echo 'export OLLAMA_HOST="http://host.containers.internal:11434"' >> /home/vscode/.bashrc && \
    echo 'export OLLAMA_HOST="http://host.containers.internal:11434"' >> /home/vscode/.zshrc

# 代理管理函数（默认关闭，通过 px/pxs/upx 控制）
# 插入到 .bashrc 最开头（非交互式检查之前）
RUN printf '%s\n' \
    'px() { export http_proxy="http://host.containers.internal:7897"; export https_proxy="http://host.containers.internal:7897"; export HTTP_PROXY="http://host.containers.internal:7897"; export HTTPS_PROXY="http://host.containers.internal:7897"; echo "Proxy enabled: http://host.containers.internal:7897"; }' \
    'pxs() { if [ -n "$http_proxy" ]; then echo "Proxy enabled: $http_proxy"; else echo "⚠️ Proxy 未开启"; fi; }' \
    'upx() { unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; echo "Proxy disabled"; }' \
    | cat - /home/vscode/.bashrc > /tmp/bashrc && mv /tmp/bashrc /home/vscode/.bashrc

# PATH
RUN echo 'export PATH="/home/vscode/.local/bin:/home/vscode/.venv/bin:$PATH"' >> /home/vscode/.bashrc

# macOS 路径兼容
USER root
RUN mkdir -p /Users && ln -sf /home/vscode /Users/songon && \
    ln -sf /home/vscode /Users/songbowen

# cc-connect 数据目录
USER vscode
RUN mkdir -p /home/vscode/.cc-connect

ENV PATH="/home/vscode/.nvm/versions/node/v24.14.0/bin:/home/vscode/.local/bin:/home/vscode/.venv/bin:${PATH}"

WORKDIR /home/vscode
ENTRYPOINT ["cc-connect"]
CMD ["--config", "/home/vscode/.cc-connect/config.toml"]
