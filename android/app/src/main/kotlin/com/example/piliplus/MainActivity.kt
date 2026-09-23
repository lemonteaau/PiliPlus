package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager.LayoutParams
import android.widget.Toast
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val updatePrefs by lazy {
        getSharedPreferences("apk_update", MODE_PRIVATE)
    }
    private var waitingForInstallPermission = false
    private var returningFromInstaller = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.piliplus/apk_installer",
        ).setMethodCallHandler { call, result ->
            if (call.method != "installApk") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val path = call.argument<String>("path")
            if (path == null) {
                result.error("INVALID_APK", "APK path is missing", null)
                return@setMethodCallHandler
            }

            val apkFile = File(path)
            val updateDirectory = File(cacheDir, "apk_updates").canonicalFile
            if (!apkFile.canonicalPath.startsWith(updateDirectory.path + File.separator) ||
                !apkFile.isFile || !apkFile.name.endsWith(".apk", ignoreCase = true)
            ) {
                result.error("INVALID_APK", "APK path is invalid", null)
                return@setMethodCallHandler
            }

            updatePrefs.edit()
                .putString("path", apkFile.absolutePath)
                .putLong("version_code", currentVersionCode())
                .apply()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                try {
                    waitingForInstallPermission = true
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                    result.success(null)
                } catch (e: Exception) {
                    waitingForInstallPermission = false
                    clearPendingApk(deleteFile = true)
                    result.error("INSTALL_PERMISSION", e.message, null)
                }
                return@setMethodCallHandler
            }

            try {
                launchApkInstaller(apkFile)
                result.success(null)
            } catch (e: Exception) {
                clearPendingApk(deleteFile = true)
                result.error("INSTALL_FAILED", e.message, null)
            }
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onResume() {
        super.onResume()
        when {
            waitingForInstallPermission -> {
                waitingForInstallPermission = false
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                    packageManager.canRequestPackageInstalls()
                ) {
                    val path = updatePrefs.getString("path", null)
                    val apkFile = path?.let(::File)
                    if (apkFile != null && apkFile.isFile) {
                        try {
                            launchApkInstaller(apkFile)
                        } catch (e: Exception) {
                            clearPendingApk(deleteFile = true)
                            Toast.makeText(
                                this,
                                "无法打开 APK 安装程序",
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                    } else {
                        clearPendingApk(deleteFile = true)
                    }
                } else {
                    clearPendingApk(deleteFile = true)
                    Toast.makeText(
                        this,
                        "允许 PiliPlus 安装应用后才能更新",
                        Toast.LENGTH_LONG,
                    ).show()
                }
            }

            returningFromInstaller -> {
                returningFromInstaller = false
                clearPendingApk(deleteFile = true)
            }

            else -> cleanupInstalledApk()
        }
    }

    private fun launchApkInstaller(apkFile: File) {
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.apkprovider",
            apkFile,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
        returningFromInstaller = true
    }

    @Suppress("DEPRECATION")
    private fun currentVersionCode(): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(packageName, 0).longVersionCode
        } else {
            packageManager.getPackageInfo(packageName, 0).versionCode.toLong()
        }

    private fun cleanupInstalledApk() {
        val oldVersionCode = updatePrefs.getLong("version_code", -1L)
        if (oldVersionCode >= 0 && currentVersionCode() > oldVersionCode) {
            clearPendingApk(deleteFile = true)
        }
    }

    private fun clearPendingApk(deleteFile: Boolean) {
        if (deleteFile) {
            updatePrefs.getString("path", null)?.let { File(it).delete() }
        }
        updatePrefs.edit().clear().apply()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
