FROM node:22-slim
# Base tools plus browser dependencies for Playwright interactions.
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    git \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*
RUN git config --system url."https://github.com/".insteadOf "git@github.com:" \
    && git config --system --add url."https://github.com/".insteadOf "ssh://git@github.com/"
# OpenCode, Cloudflare Wrangler, and Playwright CLI/test runner.
RUN npm i -g opencode-ai@1.19.4 wrangler @playwright/test \
    && npx playwright install --with-deps chromium
COPY runtime/package.json runtime/package-lock.json /opt/opencode-runtime/
RUN npm ci --prefix /opt/opencode-runtime --omit=dev
COPY runtime/aca-identity.mjs runtime/blob-client.mjs runtime/config-sync.mjs runtime/session-sync.mjs runtime/runner.mjs /opt/opencode-runtime/
COPY start-opencode /usr/local/bin/start-opencode
RUN chmod 0755 /usr/local/bin/start-opencode
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/start-opencode"]
CMD ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]