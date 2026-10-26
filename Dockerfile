FROM node:22-slim
# Base tools plus browser dependencies for Playwright interactions.
RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# OpenCode, Cloudflare Wrangler, and Playwright CLI/test runner.
RUN npm i -g opencode-ai wrangler @playwright/test \
    && npx playwright install --with-deps chromium
COPY opencode.json /root/.config/opencode/opencode.json
WORKDIR /workspace
CMD ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]