FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    jq \
    curl \
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

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && . "$HOME/.cargo/env" \
    && cargo install fastmod ast-grep \
    && mv "$HOME/.cargo/bin/fastmod" /usr/local/bin/fastmod \
    && mv "$HOME/.cargo/bin/ast-grep" /usr/local/bin/ast-grep \
    && mv "$HOME/.cargo/bin/sg" /usr/local/bin/sg \
    && rm -rf "$HOME/.cargo" "$HOME/.rustup"

WORKDIR /workspace

ENV PATH="/root/.local/bin:${PATH}"

CMD ["/bin/bash"]
