import os
import traceback

import certifi

os.environ.setdefault("SSL_CERT_FILE", certifi.where())

import yt_dlp

# bgutil-ytdlp-pot-provider rulează pe serverul Render (are nevoie de
# Node.js, pe care telefonul nu îl are). Telefonul face extragerea +
# descărcarea efectivă (IP rezidențial/mobil, nu e blocat de verificarea
# anti-bot a YouTube), dar cere PO tokenul de la Render prin acest proxy.
BGUTIL_BASE_URL = "https://music-sync-efl7.onrender.com/pot"


def download_audio(video_id, output_path):
    """
    Descarcă audio YouTube local pe telefon.

    video_id:
        ID YouTube, ex: YAZX6cv7OAY

    output_path:
        cale completă fără extensie finală
    """

    url = f"https://www.youtube.com/watch?v={video_id}"

    result = {
        "success": False,
        "path": "",
        "error": "",
    }

    try:
        os.makedirs(
            os.path.dirname(output_path),
            exist_ok=True
        )

        ydl_opts = {
            "format": (
                "bestaudio[ext=m4a]/"
                "bestaudio/best"
            ),

            "outtmpl": output_path + ".%(ext)s",

            "noplaylist": True,

            # mweb + PO token furnizat de bgutil (via proxy Render) —
            # android_vr nu mai funcționează fără PO token (403).
            "extractor_args": {
                "youtube": {
                    "player_client": ["mweb"],
                },
                "youtubepot-bgutilhttp": {
                    "base_url": [BGUTIL_BASE_URL],
                },
            },

            "http_headers": {
                "User-Agent": (
                    "Mozilla/5.0 (Linux; Android 14) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/127.0 Mobile Safari/537.36"
                )
            },

            "retries": 5,
            "fragment_retries": 5,
            "extractor_retries": 3,

            "socket_timeout": 30,

            "quiet": False,
            "no_warnings": False,

            "continuedl": True,
            "overwrites": True,

            "writesubtitles": False,
            "writeautomaticsub": False,
            "writethumbnail": False,
            "writeinfojson": False,
        }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(
                url,
                download=True
            )

            prepared = ydl.prepare_filename(info)

        # yt-dlp poate salva m4a/webm etc.
        if os.path.exists(prepared):
            final_path = prepared
        else:
            final_path = None

            folder = os.path.dirname(output_path)
            prefix = os.path.basename(output_path)

            for name in os.listdir(folder):
                if name.startswith(prefix + "."):
                    candidate = os.path.join(
                        folder,
                        name
                    )

                    if os.path.isfile(candidate):
                        final_path = candidate
                        break

        if final_path is None:
            raise Exception(
                "yt-dlp nu a creat fișierul audio."
            )

        if os.path.getsize(final_path) < 50000:
            try:
                os.remove(final_path)
            except Exception:
                pass

            raise Exception(
                "Fișierul descărcat este incomplet."
            )

        result["success"] = True
        result["path"] = final_path

        return result

    except Exception as exc:
        result["success"] = False
        result["error"] = (
            str(exc)
            + "\n"
            + traceback.format_exc()
        )

        return result
