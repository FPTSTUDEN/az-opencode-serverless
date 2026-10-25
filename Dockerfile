FROM node:22-slim
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*
RUN npm i -g opencode-ai
COPY opencode.json /root/.config/opencode/opencode.json
WORKDIR /workspace
CMD ["opencode", "web", "--hostname", "0.0.0.0", "--port", "4096"]