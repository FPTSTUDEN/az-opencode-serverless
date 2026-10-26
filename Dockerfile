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
COPY start-opencode /usr/local/bin/start-opencode
RUN chmod 0755 /usr/local/bin/start-opencode
# OpenCode, Cloudflare Wrangler, and Playwright CLI/test runner.
RUN npm i -g opencode-ai wrangler @playwright/test \
    && npx playwright install --with-deps chromium
COPY opencode.json /root/.config/opencode/opencode.json
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/start-opencode"]
CMD ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]