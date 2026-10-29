package com.kjranyone.futoji

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val saveRequest = 4201
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSource: String? = null
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // カメラ画面のライブ枠・自動撮影の座標変換に使う画面の回転 (度)。
        // CameraX が本撮影とプレビューの向きを決めるのと同じ既定ディスプレイの値を返す
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "futoji/display")
            .setMethodCallHandler { call, result ->
                if (call.method != "rotation") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                @Suppress("DEPRECATION")
                val current = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay
                result.success(
                    when (current?.rotation) {
                        Surface.ROTATION_90 -> 90
                        Surface.ROTATION_180 -> 180
                        Surface.ROTATION_270 -> 270
                        else -> 0
                    }
                )
            }
        // バックアップ zip を「保存先を選んで保存」する (SAF) と、作成前の空き容量の取得。
        // 大きなファイルをメモリに載せないよう、ネイティブ側でストリームコピーする。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "futoji/save")
            .setMethodCallHandler { call, result ->
                if (call.method == "freeBytes") {
                    // バックアップ zip を作る一時領域 (cacheDir) の空き容量
                    result.success(cacheDir.usableSpace)
                    return@setMethodCallHandler
                }
                if (call.method != "saveAs") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "保存ダイアログを表示中です", null)
                    return@setMethodCallHandler
                }
                val source = call.argument<String>("path")
                val name = call.argument<String>("name")
                val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
                if (source == null || name == null) {
                    result.error("args", "path と name が必要です", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                pendingSource = source
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }
                startActivityForResult(intent, saveRequest)
            }
    }

    @Deprecated("FlutterActivity の onActivityResult を使う")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest) return
        val result = pendingResult ?: return
        val source = pendingSource
        pendingResult = null
        pendingSource = null
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            result.success(false) // キャンセル
            return
        }
        io.execute {
            try {
                contentResolver.openOutputStream(uri, "w").use { out ->
                    requireNotNull(out) { "保存先を開けません" }
                    File(source).inputStream().use { it.copyTo(out, 1 shl 16) }
                }
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("io", e.message, null) }
            }
        }
    }
}
