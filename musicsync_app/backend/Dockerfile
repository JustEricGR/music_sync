FROM node:25-bookworm-slim AS bgutil-build

WORKDIR /opt/bgutil

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN git clone \
    https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git \
    /opt/bgutil-src

WORKDIR /opt/bgutil-src/server

RUN npm ci --no-audit --no-fund && \
    npx tsc


FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        curl \
        nodejs && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY --from=bgutil-build \
    /opt/bgutil-src/server/build \
    /opt/bgutil/server/build

COPY --from=bgutil-build \
    /opt/bgutil-src/server/node_modules \
    /opt/bgutil/server/node_modules

COPY --from=bgutil-build \
    /opt/bgutil-src/server/package.json \
    /opt/bgutil/server/package.json

COPY server.py .

EXPOSE 10000
EXPOSE 4416

CMD ["sh", "-c", "node /opt/bgutil/server/build/main.js --port 4416 & sleep 5 && uvicorn server:app --host 0.0.0.0 --port ${PORT:-10000}"]