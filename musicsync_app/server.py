import asyncio
import os
import re
import shutil
import tempfile
import time
from pathlib import Path

import yt_dlp
from fastapi import FastAPI, HTTPException, Header
from fastapi.responses import FileResponse
from starlette.background import BackgroundTask


app = FastAPI(
    title="MusicSync API",
    version="2.0.0",
)

# ------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------

# O singură extracție simultan pe Render Free.
# E mai lent pentru mai mulți utilizatori, dar mult mai stabil.
download_semaphore = asyncio.Semaphore(1)

# Un YouTube video ID normal are 11 caractere.
VIDEO_ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{11}$")

# Poți seta MUSICSYNC_API_KEY în Render -> Environment.
# Dacă rămâne gol, API-ul funcționează fără autentificare.
API_KEY = os.getenv("MUSICSYNC_API_KEY", "").strip()

# Limită de siguranță.
MAX_FILE_SIZE = 100 * 1024 * 1024  # 100 MB


# ------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------

def cleanup_directory(directory: str):
    try:
        shutil.rmtree(directory, ignore_errors=True)
    except Exception as exc:
        print(f"[CLEANUP] {exc}")


def verify_api_key(received_key: str | None):
    if not API_KEY:
        return

    if received_key != API_KEY:
        raise HTTPException(
            status_code=401,
            detail="Invalid MusicSync API key.",
        )


def find_downloaded_audio(folder: str) -> Path | None:
    directory = Path(folder)

    allowed_extensions = {
        ".m4a",
        ".mp4",
        ".webm",
        ".opus",
        ".mp3",
        ".aac",
        ".ogg",
    }

    candidates = [
        file
        for file in directory.iterdir()
        if file.is_file()
        and file.suffix.lower() in allowed_extensions
    ]

    if not candidates:
        return None

    # În caz că yt-dlp creează mai multe fișiere,
    # îl luăm pe cel mai mare.
    candidates.sort(
        key=lambda f: f.stat().st_size,
        reverse=True,
    )

    return candidates[0]


def download_with_ytdlp(video_id: str, temp_dir: str):
    video_url = f"https://www.youtube.com/watch?v={video_id}"

    output_template = os.path.join(
        temp_dir,
        "%(id)s.%(ext)s",
    )

    ydl_opts = {
        # Preferă M4A, dar are fallback la orice audio bun.
        "format": (
            "bestaudio[ext=m4a]/"
            "bestaudio[ext=mp4]/"
            "bestaudio/best"
        ),

        "outtmpl": output_template,

        # Nu permitem accidental playlist.
        "noplaylist": True,

        # Evităm fișiere suplimentare.
        "writesubtitles": False,
        "writeautomaticsub": False,
        "writethumbnail": False,
        "writeinfojson": False,

        # Robustness
        "retries": 5,
        "fragment_retries": 5,
        "extractor_retries": 3,
        "socket_timeout": 30,

        # Nu vrem 10 fragmente simultan pe Render Free.
        "concurrent_fragment_downloads": 1,

        # Continuă dacă există probleme recuperabile.
        "continuedl": True,

        # Loguri utile în Render.
        "quiet": False,
        "no_warnings": False,

        # Evităm suprascrieri ciudate.
        "overwrites": True,

        # Nu descărcăm fișiere enorme accidental.
        "max_filesize": MAX_FILE_SIZE,

        # User agent normal.
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Linux; Android 14) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/127.0 Mobile Safari/537.36"
            )
        },
    }

    started = time.time()

    print(f"[DOWNLOAD] START {video_id}")

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(
            video_url,
            download=True,
        )

    elapsed = time.time() - started

    print(
        f"[DOWNLOAD] yt-dlp finished {video_id} "
        f"in {elapsed:.1f}s"
    )

    audio_file = find_downloaded_audio(temp_dir)

    if audio_file is None:
        raise RuntimeError(
            "yt-dlp finished but no audio file was found."
        )

    size = audio_file.stat().st_size

    if size <= 50_000:
        raise RuntimeError(
            "Downloaded audio file is unexpectedly small."
        )

    if size > MAX_FILE_SIZE:
        raise RuntimeError(
            "Downloaded audio exceeds maximum allowed size."
        )

    title = info.get("title") or video_id

    return {
        "path": audio_file,
        "title": title,
        "size": size,
        "ext": audio_file.suffix.lower(),
    }


# ------------------------------------------------------------------
# ROUTES
# ------------------------------------------------------------------

@app.get("/")
async def root():
    return {
        "status": "ok",
        "service": "MusicSync API",
        "version": "2.0.0",
    }


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "service": "MusicSync API",
        "yt_dlp_version": yt_dlp.version.__version__,
    }


@app.get("/download/{video_id}")
async def download(
    video_id: str,
    x_musicsync_key: str | None = Header(
        default=None,
        alias="X-MusicSync-Key",
    ),
):
    verify_api_key(x_musicsync_key)

    video_id = video_id.strip()

    if not VIDEO_ID_PATTERN.fullmatch(video_id):
        raise HTTPException(
            status_code=400,
            detail="Invalid YouTube video ID.",
        )

    temp_dir = tempfile.mkdtemp(
        prefix=f"musicsync_{video_id}_"
    )

    print(f"[REQUEST] {video_id}")

    try:
        async with download_semaphore:

            # yt-dlp este blocking.
            # Îl mutăm într-un worker thread ca să nu blocăm FastAPI.
            result = await asyncio.wait_for(
                asyncio.to_thread(
                    download_with_ytdlp,
                    video_id,
                    temp_dir,
                ),
                timeout=180,
            )

        audio_path: Path = result["path"]
        title = result["title"]

        extension = result["ext"]

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
            f"[SUCCESS] {video_id} "
            f"{result['size']} bytes "
            f"{extension}"
        )

        return FileResponse(
            path=str(audio_path),
            media_type=media_type,
            filename=f"{video_id}{extension}",
            headers={
                "X-MusicSync-Video-Id": video_id,
                "X-MusicSync-Title": title.encode(
                    "ascii",
                    "ignore",
                ).decode(),
                "X-MusicSync-Extension": extension.lstrip("."),
            },

            # CRITIC:
            # Fișierul temporar este șters DUPĂ ce Render
            # termină de trimis răspunsul către telefon.
            background=BackgroundTask(
                cleanup_directory,
                temp_dir,
            ),
        )

    except asyncio.TimeoutError:

        cleanup_directory(temp_dir)

        print(f"[TIMEOUT] {video_id}")

        raise HTTPException(
            status_code=504,
            detail="YouTube extraction timed out.",
        )

    except yt_dlp.utils.DownloadError as exc:

        cleanup_directory(temp_dir)

        message = str(exc)

        print(
            f"[YT-DLP ERROR] {video_id}: "
            f"{message}"
        )

        raise HTTPException(
            status_code=502,
            detail=f"yt-dlp: {message}",
        )

    except Exception as exc:

        cleanup_directory(temp_dir)

        print(
            f"[SERVER ERROR] {video_id}: "
            f"{exc}"
        )

        raise HTTPException(
            status_code=500,
            detail=str(exc),
        )