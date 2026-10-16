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


def list_playlist(playlist_id):
    """
    Lista completă a unui playlist (ID + titlu, în ordinea din playlist),
    fără API-ul YouTube — folosită când API-ul oficial nu poate pagina
    playlistul (repetă aceeași pagină la nesfârșit pentru unele liste).

    Întoarce JSON: {"success": bool, "title": str, "entries": [{"id", "title"}], "error": str}
    """
    import json

    url = f"https://www.youtube.com/playlist?list={playlist_id}"
    try:
        opts = {
            "extract_flat": "in_playlist",
            "skip_download": True,
            "quiet": True,
            "no_warnings": True,
            "extractor_retries": 3,
            "socket_timeout": 30,
        }
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)

        entries = []
        for entry in info.get("entries") or []:
            if not entry:
                continue
            entries.append({
                "id": entry.get("id") or "",
                "title": entry.get("title") or "",
            })

        return json.dumps({
            "success": True,
            "title": info.get("title") or "",
            "entries": entries,
            "error": "",
        })
    except Exception as exc:
        return json.dumps({
            "success": False,
            "title": "",
            "entries": [],
            "error": str(exc),
        })
