package com.junkfeathers.orpheusdeck

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publishToMusicFolder" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val fileName = call.argument<String>("fileName")
                    if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                        result.error("bad_args", "missing sourcePath or fileName", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(publishToMusicFolder(sourcePath, fileName))
                    } catch (e: Exception) {
                        result.error("publish_failed", e.message, null)
                    }
                }

                "deleteMusicExport" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr.isNullOrBlank()) {
                        result.error("bad_args", "missing uri", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val n = applicationContext.contentResolver.delete(
                            Uri.parse(uriStr),
                            null,
                            null,
                        )
                        result.success(n > 0)
                    } catch (e: Exception) {
                        result.error("delete_failed", e.message, null)
                    }
                }

                "contentUriExists" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        applicationContext.contentResolver.query(
                            Uri.parse(uriStr),
                            arrayOf(MediaStore.Audio.Media._ID),
                            null,
                            null,
                            null,
                        )?.use { cursor ->
                            result.success(cursor.count > 0)
                        } ?: result.success(false)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                "tryOpenExportLocation" -> {
                    val uriStr = call.argument<String>("uri")
                    if (uriStr.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val uri = Uri.parse(uriStr)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "audio/wav")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(Intent.createChooser(intent, "Open export"))
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Scoped storage–safe: inserts into MediaStore under Music/Orpheus Deck/.
     * Requires API 29+ ([Build.VERSION_CODES.Q]) for RELATIVE_PATH + IS_PENDING.
     */
    private fun publishToMusicFolder(sourcePath: String, fileName: String): Map<String, String?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            throw IllegalStateException("Android 10 (API 29)+ required for Music folder export")
        }

        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw IllegalStateException("source missing")
        }

        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Audio.Media.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )

        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/wav")
            put(
                MediaStore.Audio.Media.RELATIVE_PATH,
                Environment.DIRECTORY_MUSIC + "/Orpheus Deck",
            )
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert failed")

        resolver.openOutputStream(uri)?.use { out ->
            FileInputStream(sourceFile).use { input -> input.copyTo(out) }
        } ?: throw IllegalStateException("openOutputStream failed")

        values.clear()
        values.put(MediaStore.Audio.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)

        val displayPath = "Music/Orpheus Deck/$fileName"
        return mapOf(
            "uri" to uri.toString(),
            "displayPath" to displayPath,
            "fileName" to fileName,
        )
    }

    companion object {
        private const val CHANNEL = "com.junkfeathers.orpheusdeck/export"
    }
}
