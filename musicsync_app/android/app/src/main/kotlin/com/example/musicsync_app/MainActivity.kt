package com.example.musicsync_app

import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

import com.ryanheise.audioservice.AudioServiceActivity

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.telephony.TelephonyManager

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        private const val CHANNEL = "musicsync/ytdlp"
        private const val WIFI_LOCK_CHANNEL = "musicsync/wifilock"
        private const val DEVICE_CHANNEL = "musicsync/device"

        // Trebuie să fie identic cu androidNotificationChannelId din main.dart.
        private const val PLAYER_CHANNEL = "com.example.musicsync_app.player"
        private const val OLD_PLAYER_CHANNEL = "com.example.musicsync_app.audio"
    }

    /**
     * Canalul notificării playerului. audio_service îl creează "Silențios"
     * (importanță scăzută), iar Samsung ascunde din bara de stare iconițele
     * notificărilor silențioase — steluța nu mai apărea sus. Îl creăm noi,
     * înainte de audio_service, cu importanță normală dar fără sunet/vibrații.
     */
    private fun ensurePlayerChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(NotificationManager::class.java) ?: return
        if (nm.getNotificationChannel(PLAYER_CHANNEL) == null) {
            val channel = NotificationChannel(PLAYER_CHANNEL, "MusicSync Player", NotificationManager.IMPORTANCE_DEFAULT).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(channel)
        }
        try {
            nm.deleteNotificationChannel(OLD_PLAYER_CHANNEL)
        } catch (_: Exception) {
            // Canalul vechi e încă folosit de serviciul de redare pornit — rămâne până la următoarea pornire.
        }
    }

    // Ține Wi-Fi-ul treaz cât timp rulează un post de radio — cu ecranul
    // stins, Wi-Fi-ul intră altfel în economie de energie și stream-ul se
    // întrerupe sau se oprește.
    private var wifiLock: WifiManager.WifiLock? = null

    @Suppress("DEPRECATION")
    private fun setWifiLock(enabled: Boolean) {
        if (enabled) {
            if (wifiLock?.isHeld == true) return
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wifi.createWifiLock(mode, "MusicSync:radio").apply {
                setReferenceCounted(false)
                acquire()
            }
        } else {
            wifiLock?.let { if (it.isHeld) it.release() }
            wifiLock = null
        }
    }

    override fun onDestroy() {
        setWifiLock(false)
        super.onDestroy()
    }

    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)
        ensurePlayerChannel()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIFI_LOCK_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquire" -> { setWifiLock(true); result.success(null) }
                "release" -> { setWifiLock(false); result.success(null) }
                else -> result.notImplemented()
            }
        }

        // Țara rețelei mobile (fără GPS) — radioul o folosește când locația e oprită.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "networkCountry") {
                val tm = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                val iso = tm?.networkCountryIso?.takeIf { it.isNotBlank() } ?: tm?.simCountryIso
                result.success(iso?.uppercase())
            } else {
                result.notImplemented()
            }
        }

        if (!Python.isStarted()) {
            Python.start(
                AndroidPlatform(this)
            )
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            if (call.method == "downloadAudio") {

                val videoId =
                    call.argument<String>("videoId")

                val outputPath =
                    call.argument<String>("outputPath")

                if (
                    videoId.isNullOrBlank() ||
                    outputPath.isNullOrBlank()
                ) {
                    result.error(
                        "INVALID_ARGS",
                        "videoId sau outputPath lipsă",
                        null
                    )

                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        val py = Python.getInstance()

                        val module =
                            py.getModule(
                                "youtube_downloader"
                            )

                        val response =
                            module.callAttr(
                                "download_audio",
                                videoId,
                                outputPath
                            )

                        val map = response.asMap()

                        var success = false
                        var path = ""
                        var error = ""

                        for ((key, value) in map) {
                            when (key.toString()) {

                                "success" -> {
                                    success =
                                        value.toString()
                                            .equals(
                                                "true",
                                                ignoreCase = true
                                            )
                                }

                                "path" -> {
                                    path =
                                        value.toString()
                                }

                                "error" -> {
                                    error =
                                        value.toString()
                                }
                            }
                        }

                        runOnUiThread {
                            result.success(
                                mapOf(
                                    "success" to success,
                                    "path" to path,
                                    "error" to error
                                )
                            )
                        }

                    } catch (e: Exception) {

                        runOnUiThread {
                            result.error(
                                "YTDLP_ERROR",
                                e.message ?: e.toString(),
                                e.stackTraceToString()
                            )
                        }
                    }
                }.start()

            } else if (call.method == "listPlaylist") {

                val playlistId = call.argument<String>("playlistId")
                if (playlistId.isNullOrBlank()) {
                    result.error("INVALID_ARGS", "playlistId lipsă", null)
                    return@setMethodCallHandler
                }

                // Lista playlistului prin yt-dlp (JSON), pe un fir separat.
                Thread {
                    try {
                        val json = Python.getInstance()
                            .getModule("youtube_downloader")
                            .callAttr("list_playlist", playlistId)
                            .toString()
                        runOnUiThread { result.success(json) }
                    } catch (e: Exception) {
                        runOnUiThread {
                            result.error("YTDLP_ERROR", e.message ?: e.toString(), null)
                        }
                    }
                }.start()

            } else {
                result.notImplemented()
            }
        }
    }
}
