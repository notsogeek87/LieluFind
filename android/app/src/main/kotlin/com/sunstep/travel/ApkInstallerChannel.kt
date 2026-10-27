package com.sunstep.travel

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/** Hands a downloaded APK to the system package installer, in-app. */
object ApkInstallerChannel {
    private const val CHANNEL = "com.sunstep.travel/apk_installer"

    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canInstall(context))
                    "openInstallSettings" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${context.packageName}")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                        result.success(null)
                    }
                    "verify" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "path missing", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(
                                verify(context, File(path), call.argument<String>("sha256"))
                            )
                        } catch (e: Exception) {
                            result.success("Verification failed: ${e.message}")
                        }
                    }
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("ARG", "path missing", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val uri = FileProvider.getUriForFile(
                                context, "${context.packageName}.apkprovider", File(path)
                            )
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                            context.startActivity(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Checks a downloaded APK before handing it to the installer. Returns null
     * when it is safe, otherwise a human-readable reason:
     * - its SHA-256 must match the digest GitHub published for the asset;
     * - it must be this very app (same package name), never another one;
     * - it must be signed with the key of the installed app (Android 9+).
     */
    private fun verify(context: Context, file: File, expectedSha256: String?): String? {
        if (expectedSha256 != null) {
            val actual = sha256(file)
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                return "Checksum mismatch: the download is corrupted or was tampered with."
            }
        }

        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            0
        }
        val archive = pm.getPackageArchiveInfo(file.path, flags)
            ?: return "The downloaded file is not a valid APK."
        if (archive.packageName != context.packageName) {
            return "The downloaded APK is another app (${archive.packageName})."
        }

        // Before Android 9 the system installer's own signature check is the guard.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signers = archive.signingInfo?.apkContentsSigners
            if (signers.isNullOrEmpty()) {
                return "The downloaded APK is not signed."
            }
            val trusted = signers.all {
                pm.hasSigningCertificate(
                    context.packageName, it.toByteArray(), PackageManager.CERT_INPUT_RAW_X509
                )
            }
            if (!trusted) {
                return "The downloaded APK is not signed with this app's key."
            }
        }
        return null
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()
}
