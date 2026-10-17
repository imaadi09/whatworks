package com.whatworks.app

import android.content.ContentUris
import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Public-storage bridge for auto backups.
 *
 * On Android 10+ (API 29+) an app cannot dart:io-write into shared folders like
 * Download/ without the Play-rejected MANAGE_EXTERNAL_STORAGE permission — but
 * MediaStore writes into the public Downloads collection need NO permission, and
 * files there SURVIVE app uninstall (AOSP DownloadKeepTracker), which is exactly
 * the backup guarantee we want. So the Dart side hands us a staged file and we
 * publish it as `Download/WhatWorks/<fileName>`; reads copy the MediaStore row
 * back into the app cache dir so the existing path-based import code works.
 *
 * On API < 29 the legacy direct-file route is used (best effort: without the
 * legacy WRITE permission granted the copy throws and Dart falls back to app
 * storage, i.e. the pre-existing behaviour).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.whatworks.app/public_storage"
    private val relativeDir = "${Environment.DIRECTORY_DOWNLOADS}/WhatWorks/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val fileName = call.argument<String>("fileName")
                if (fileName == null || fileName.contains("/") || fileName.contains("\\")) {
                    result.error("bad_args", "Missing or invalid fileName", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "saveBackup" -> {
                        val srcPath = call.argument<String>("srcPath")
                        if (srcPath == null) {
                            result.error("bad_args", "Missing srcPath", null)
                        } else {
                            runOnWorker(result) { saveBackup(srcPath, fileName) }
                        }
                    }
                    "backupExists" -> runOnWorker(result) { backupExists(fileName) }
                    "readBackup" -> runOnWorker(result) { readBackup(fileName) }
                    "deleteBackup" -> runOnWorker(result) {
                        deleteBackup(fileName)
                        null
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * MediaStore/ file IO off the platform thread, reply back on it. A backup
     * file is multi-MB, so a main-thread copy would ANR the app.
     */
    private fun runOnWorker(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("storage_failed", e.message, null) }
            }
        }.start()
    }

    private fun legacyDir(): File =
        @Suppress("DEPRECATION")
        File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "WhatWorks"
        )

    private fun findUri(fileName: String): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val collection = MediaStore.Files.getContentUri("external")
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        val args = arrayOf(fileName, relativeDir)
        contentResolver.query(collection, arrayOf(MediaStore.MediaColumns._ID), selection, args, null)
            .use { c ->
                if (c != null && c.moveToFirst()) {
                    return ContentUris.withAppendedId(collection, c.getLong(0))
                }
                return null
            }
    }

    private fun saveBackup(srcPath: String, fileName: String): String? {
        val src = File(srcPath)
        if (!src.exists()) throw IllegalStateException("staged file missing: $srcPath")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Files.getContentUri("external")
            // Overwrite semantics: drop any earlier row with the same name first,
            // so the weekly backup never accumulates duplicates in Downloads.
            deleteBackup(fileName)
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore insert failed")
            val out = contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore stream not writable")
            out.use { o -> src.inputStream().use { it.copyTo(o) } }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            return uri.toString()
        } else {
            val dir = legacyDir()
            if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("cannot create ${dir.path}")
            src.copyTo(File(dir, fileName), overwrite = true)
            return File(dir, fileName).absolutePath
        }
    }

    private fun readBackup(fileName: String): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val uri = findUri(fileName) ?: return null
            val cache = File(cacheDir, fileName)
            contentResolver.openInputStream(uri)?.use { input ->
                cache.outputStream().use { input.copyTo(it) }
            } ?: return null
            return cache.absolutePath
        } else {
            val f = File(legacyDir(), fileName)
            if (!f.exists()) return null
            val cache = File(cacheDir, fileName)
            f.copyTo(cache, overwrite = true)
            return cache.absolutePath
        }
    }

    private fun backupExists(fileName: String): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            findUri(fileName) != null
        } else {
            File(legacyDir(), fileName).exists()
        }

    private fun deleteBackup(fileName: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            contentResolver.delete(
                MediaStore.Files.getContentUri("external"),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                arrayOf(fileName, relativeDir)
            )
        } else {
            val f = File(legacyDir(), fileName)
            if (f.exists()) f.delete()
        }
    }
}
