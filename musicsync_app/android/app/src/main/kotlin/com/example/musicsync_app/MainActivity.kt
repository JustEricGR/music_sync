package com.example.musicsync_app

import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

import com.ryanheise.audioservice.AudioServiceActivity

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        private const val CHANNEL = "musicsync/ytdlp"
    }

    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)

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

            } else {
                result.notImplemented()
            }
        }
    }
}
