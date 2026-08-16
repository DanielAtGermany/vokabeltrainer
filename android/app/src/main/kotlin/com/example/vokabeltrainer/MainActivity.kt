package com.example.vokabeltrainer

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "vokabeltrainer/android_updates"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")

                    if (path.isNullOrBlank()) {
                        result.error(
                            "INVALID_PATH",
                            "Es wurde kein APK-Pfad übergeben.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    installApk(File(path), result)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun installApk(
        apkFile: File,
        result: MethodChannel.Result
    ) {
        if (!apkFile.exists()) {
            result.error(
                "APK_NOT_FOUND",
                "Die heruntergeladene APK wurde nicht gefunden:\n${apkFile.absolutePath}",
                null
            )
            return
        }

        if (apkFile.length() < 1024) {
            result.error(
                "APK_INVALID",
                "Die heruntergeladene APK ist leer oder ungewöhnlich klein.",
                null
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val settingsIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )

            startActivity(settingsIntent)

            result.error(
                "INSTALL_PERMISSION_REQUIRED",
                "Bitte erlaube dem Vokabeltrainer die Installation unbekannter Apps. Danach zurück zur App gehen und das Update erneut starten.",
                null
            )
            return
        }

        try {
            val apkUri = FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                apkFile
            )

            // ACTION_VIEW ist auf Android-Geräten deutlich kompatibler als
            // ACTION_INSTALL_PACKAGE. Damit kann der installierte
            // Paketinstaller die content://-URI des FileProviders übernehmen.
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(
                    apkUri,
                    "application/vnd.android.package-archive"
                )
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            val resolver = packageManager.resolveActivity(
                installIntent,
                0
            )

            if (resolver == null) {
                result.error(
                    "NO_PACKAGE_INSTALLER",
                    "Auf diesem Android-Gerät wurde kein Paketinstaller gefunden. Die APK wurde aber erfolgreich heruntergeladen:\n${apkFile.absolutePath}",
                    null
                )
                return
            }

            startActivity(installIntent)
            result.success(true)

        } catch (e: Exception) {
            result.error(
                "INSTALL_ERROR",
                "Android konnte den Paketinstaller nicht öffnen:\n${e.message}",
                null
            )
        }
    }
}
