FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        ca-certificates \
        curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .

RUN pip install --upgrade pip && \
    pip install -r requirements.txt

COPY server.py .

EXPOSE 10000

CMD ["sh", "-c", "pip install --quiet --upgrade yt-dlp && uvicorn server:app --host 0.0.0.0 --port ${PORT:-10000}"]