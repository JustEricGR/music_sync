import os
import traceback

import certifi

os.environ.setdefault("SSL_CERT_FILE", certifi.where())

import yt_dlp


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

            # visionos e client nativ (nu are nevoie de motor JS pentru
            # semnături) și, spre deosebire de android/android_vr/ios,
            # nu cere deloc PO token pentru HTTPS/DASH/HLS — nu avem
            # nevoie de niciun provider PO token pentru el.
            "extractor_args": {
                "youtube": {
                    "player_client": ["visionos"],
                },
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
