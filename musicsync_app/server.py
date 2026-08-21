import os
import json
import re
import shutil
import tempfile
import urllib.request
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask

import yt_dlp


app = FastAPI(
    title="MusicSync API",
    version="2.0.0",
)

VIDEO_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{11}$")
MAX_FILE_SIZE = 100 * 1024 * 1024


def cleanup_directory(path: str):
    try:
        shutil.rmtree(path, ignore_errors=True)
    except Exception as e:
        print(f"[CLEANUP ERROR] {e}")


def find_downloaded_audio(folder: str):
    allowed_extensions = {
        ".m4a",
        ".mp4",
        ".webm",
        ".opus",
        ".mp3",
        ".aac",
        ".ogg",
    }

    files = [
        f for f in Path(folder).iterdir()
        if f.is_file() and f.suffix.lower() in allowed_extensions
    ]

    if not files:
        return None

    files.sort(
        key=lambda f: f.stat().st_size,
        reverse=True,
    )

    return files[0]


@app.get("/")
def root():
    return {
        "status": "ok",
        "service": "MusicSync API",
        "version": "2.0.0",
    }


@app.get("/health")
def health():
    provider_ok = False
    provider_version = None

    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:4416/ping",
            timeout=5,
        ) as response:
            data = json.loads(response.read().decode())

            provider_ok = True
            provider_version = data.get("version")

    except Exception as e:
        print(f"[PO TOKEN HEALTH ERROR] {e}")

    return {
        "status": "healthy",
        "service": "MusicSync API",
        "yt_dlp_version": yt_dlp.version.__version__,
        "po_token_provider": provider_ok,
        "po_token_provider_version": provider_version,
    }


@app.get("/download/{video_id}")
def download(video_id: str):
    video_id = video_id.strip()

    if not VIDEO_ID_PATTERN.fullmatch(video_id):
        raise HTTPException(
            status_code=400,
            detail="Invalid YouTube video ID.",
        )

    temp_dir = tempfile.mkdtemp(
        prefix=f"musicsync_{video_id}_"
    )

    output_template = os.path.join(
        temp_dir,
        "%(id)s.%(ext)s"
    )

    video_url = f"https://www.youtube.com/watch?v={video_id}"

    ydl_opts = {
        "format": (
            "bestaudio[ext=m4a]/"
            "bestaudio[ext=mp4]/"
            "bestaudio/best"
        ),

        "outtmpl": output_template,
        "noplaylist": True,

        "extractor_args": {
            "youtube": {
                "player_client": ["mweb"],
            },
            "youtubepot-bgutilhttp": {
                "base_url": ["http://127.0.0.1:4416"],
            },
        },

        "retries": 5,
        "fragment_retries": 5,
        "extractor_retries": 3,
        "socket_timeout": 30,

        "concurrent_fragment_downloads": 1,
        "continuedl": True,

        "writesubtitles": False,
        "writeautomaticsub": False,
        "writethumbnail": False,
        "writeinfojson": False,

        "quiet": False,
        "no_warnings": False,
        "overwrites": True,

        "max_filesize": MAX_FILE_SIZE,

        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Linux; Android 14) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/127.0 Mobile Safari/537.36"
            )
        },
    }

    try:
        print(f"[DOWNLOAD START] {video_id}")

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(
                video_url,
                download=True,
            )

        downloaded_file = find_downloaded_audio(temp_dir)

        if downloaded_file is None:
            cleanup_directory(temp_dir)

            raise HTTPException(
                status_code=500,
                detail="yt-dlp nu a creat niciun fișier audio.",
            )

        file_size = downloaded_file.stat().st_size

        if file_size < 50000:
            cleanup_directory(temp_dir)

            raise HTTPException(
                status_code=500,
                detail="Fișierul audio rezultat este prea mic.",
            )

        extension = downloaded_file.suffix.lower()

        media_types = {
            ".m4a": "audio/mp4",
            ".mp4": "audio/mp4",
            ".mp3": "audio/mpeg",
            ".webm": "audio/webm",
            ".opus": "audio/ogg",
            ".ogg": "audio/ogg",
            ".aac": "audio/aac",
        }

        media_type = media_types.get(
            extension,
            "application/octet-stream",
        )

        print(
            f"[DOWNLOAD SUCCESS] {video_id} "
            f"{file_size} bytes "
            f"{extension}"
        )

        return FileResponse(
            path=str(downloaded_file),
            media_type=media_type,
            filename=f"{video_id}{extension}",
            headers={
                "X-MusicSync-Video-Id": video_id,
                "X-MusicSync-Extension": extension.lstrip("."),
            },
            background=BackgroundTask(
                cleanup_directory,
                temp_dir,
            ),
        )

    except yt_dlp.utils.DownloadError as e:
        cleanup_directory(temp_dir)

        print(f"[YT-DLP ERROR] {video_id}: {e}")

        raise HTTPException(
            status_code=502,
            detail=str(e),
        )

    except HTTPException:
        raise

    except Exception as e:
        cleanup_directory(temp_dir)

        print(f"[SERVER ERROR] {video_id}: {e}")

        raise HTTPException(
            status_code=500,
            detail=str(e),
        )