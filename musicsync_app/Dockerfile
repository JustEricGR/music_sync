FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --upgrade pip && \
    pip install -r requirements.txt

# Clonează bgutil provider
RUN git clone https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /opt/bgutil

# Instalează pluginul yt-dlp
RUN mkdir -p /root/yt-dlp-plugins/bgutil-ytdlp-pot-provider && \
    cp -r /opt/bgutil/plugin/* /root/yt-dlp-plugins/bgutil-ytdlp-pot-provider/

# Compilează providerul HTTP
WORKDIR /opt/bgutil/server
RUN npm ci && npm run build

WORKDIR /app

COPY server.py .

EXPOSE 10000
EXPOSE 4416

CMD ["sh", "-c", "node /opt/bgutil/server/build/main.js & sleep 3 && pip install --quiet --upgrade yt-dlp && uvicorn server:app --host 0.0.0.0 --port ${PORT:-10000}"]