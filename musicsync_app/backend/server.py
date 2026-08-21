import os
import tempfile

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
import yt_dlp

app = FastAPI()


@app.get("/")
def root():
    return {
        "status": "ok",
        "service": "MusicSync API"
    }


@app.get("/health")
def health():
    return {
        "status": "healthy"
    }


@app.get("/download/{video_id}")
def download(video_id: str):
    temp_dir = tempfile.mkdtemp()

    output_template = os.path.join(
        temp_dir,
        "%(id)s.%(ext)s"
    )

    video_url = f"https://www.youtube.com/watch?v={video_id}"

    ydl_opts = {
        "format": "bestaudio/best",
        "outtmpl": output_template,
        "noplaylist": True,
        "quiet": False,
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(
                video_url,
                download=True
            )

            downloaded_file = ydl.prepare_filename(info)

        if not os.path.exists(downloaded_file):
            raise HTTPException(
                status_code=500,
                detail="Fișierul audio nu a fost creat."
            )

        return FileResponse(
            downloaded_file,
            media_type="application/octet-stream",
            filename=os.path.basename(downloaded_file),
        )

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=str(e)
        )