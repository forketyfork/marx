FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    jq \
    curl \
    unzip \
    ca-certificates \
    gnupg \
    tree \
    build-essential \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh ripgrep fd-find \
    && rm -rf /var/lib/apt/lists/*

RUN ln -s $(which fdfind) /usr/local/bin/fd

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@latest \
    && npm install -g @openai/codex@latest \
    && npm install -g @google/gemini-cli@latest

# Download pre-built ast-grep binary
ARG TARGETARCH
RUN AST_GREP_VERSION="0.40.5" \
    && case "${TARGETARCH}" in \
        amd64) AST_GREP_ARCH="x86_64" ;; \
        arm64) AST_GREP_ARCH="aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/app-${AST_GREP_ARCH}-unknown-linux-gnu.zip" -o /tmp/ast-grep.zip \
    && unzip -q /tmp/ast-grep.zip -d /tmp/ast-grep \
    && mv /tmp/ast-grep/sg /usr/local/bin/sg \
    && ln -s /usr/local/bin/sg /usr/local/bin/ast-grep \
    && rm -rf /tmp/ast-grep.zip /tmp/ast-grep

# Compile fastmod from source (no pre-built binaries available)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
    && . "$HOME/.cargo/env" \
    && cargo install fastmod \
    && mv "$HOME/.cargo/bin/fastmod" /usr/local/bin/fastmod \
    && rm -rf "$HOME/.cargo" "$HOME/.rustup"

WORKDIR /workspace

ENV PATH="/root/.local/bin:${PATH}"

CMD ["/bin/bash"]
