package dev.hongguo.hongguo_studio

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.media.AudioManager
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import dev.hongguo.hongguo_studio.protocol.Signer
import dev.hongguo.hongguo_studio.protocol.PlayerSigner
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val signer = Signer()
    private var saveReply: MethodChannel.Result? = null
    private var saveSource: File? = null
    private var originalPlaybackBrightness: Float? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.hongguo.studio/platform").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "installUpdate" -> {
                        val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                        val updateDir = File(filesDir, "data/updates").canonicalFile
                        require(file.isFile && file.extension == "apk" && file.path.startsWith(updateDir.path + File.separator))
                        val archive = requireNotNull(packageManager.getPackageArchiveInfo(file.path, 0))
                        require(archive.packageName == packageName)
                        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                            result.success(false)
                        } else {
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success(true)
                        }
                    }
                    "playbackLevels" -> {
                        if (originalPlaybackBrightness == null) originalPlaybackBrightness = window.attributes.screenBrightness
                        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
                        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        val current = window.attributes.screenBrightness
                        val brightness = if (current >= 0) current.toDouble() else
                            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255.0
                        result.success(mapOf("brightness" to brightness, "volume" to audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maximum))
                    }
                    "playbackBrightness" -> {
                        if (originalPlaybackBrightness == null) originalPlaybackBrightness = window.attributes.screenBrightness
                        val value = requireNotNull(call.argument<Number>("value")).toFloat().coerceIn(0.05f, 1f)
                        window.attributes = window.attributes.apply { screenBrightness = value }
                        result.success(null)
                    }
                    "resetPlaybackBrightness" -> {
                        originalPlaybackBrightness?.let { value -> window.attributes = window.attributes.apply { screenBrightness = value } }
                        originalPlaybackBrightness = null
                        result.success(null)
                    }
                    "playbackVolume" -> {
                        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
                        val value = requireNotNull(call.argument<Number>("value")).toDouble().coerceIn(0.0, 1.0)
                        val maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        audio.setStreamVolume(AudioManager.STREAM_MUSIC, kotlin.math.round(value * maximum).toInt(), 0)
                        result.success(null)
                    }
                    "sign" -> {
                        val body = requireNotNull(call.argument<String>("body"))
                        val device = requireNotNull(call.argument<Map<String, String>>("device"))
                        require(body.length <= 65536)
                        worker.execute {
                            try {
                                require(listOf("iid", "device_id").all { device[it]?.matches(Regex("^[1-9]\\d{15,19}$")) == true })
                                val ids=org.json.JSONObject(body).getJSONObject("mixed_video_id_map").getJSONArray("1004")
                                require(ids.length()==1)
                                val signed = PlayerSigner.request(ids.getString(0),device)
                                runOnUiThread { result.success(mapOf("url" to signed.url, "headers" to signed.headers, "body" to "", "method" to "GET")) }
                            } catch (_: Exception) { runOnUiThread { result.error("SIGN", "无法准备播放请求，请重试", null) } }
                        }
                    }
                    "signSearch" -> {
                        val query = requireNotNull(call.argument<Map<String, String>>("query"))
                        val identity = requireNotNull(call.argument<Map<String, String>>("device"))
                        val allowed = setOf("query", "tab_type", "count", "bookshelf_search_plan", "user_is_login", "offset", "search_id", "passback")
                        require(query.keys.all { it in allowed } && query.values.all { it.length <= 2048 && it.none { c -> c.code < 32 } })
                        require((query["query"] ?: "").codePointCount(0, (query["query"] ?: "").length) in 1..80)
                        require(listOf("device_id", "iid").all { Regex("^[1-9]\\d{15,19}$").matches(identity[it] ?: "") })
                        worker.execute {
                            try {
                                val signed = signer.signSearch(query, identity)
                                runOnUiThread { result.success(mapOf("url" to signed.url, "headers" to signed.headers, "body" to "")) }
                            } catch (_: Exception) { runOnUiThread { result.error("SEARCH_SIGN", "无法准备搜索请求，请重试", null) } }
                        }
                    }
                    "startTask" -> {
                        val intent = Intent(this, ExportService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    "stopTask" -> { stopService(Intent(this, ExportService::class.java)); result.success(true) }
                    "importFile" -> {
                        val uri = Uri.parse(requireNotNull(call.argument<String>("uri")))
                        require(uri.scheme == "content")
                        val name = (call.argument<String>("name") ?: "video.mp4").replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").take(140)
                        worker.execute {
                            var target: File? = null
                            try {
                                val dir = File(cacheDir, "imports").apply { mkdirs() }
                                target = File(dir, "${System.nanoTime()}-$name")
                                contentResolver.openInputStream(uri).use { input -> requireNotNull(input); target!!.outputStream().use { input.copyTo(it) } }
                                val path = target!!.absolutePath
                                runOnUiThread { result.success(path) }
                            } catch (_: Exception) { target?.delete(); runOnUiThread { result.error("IMPORT", "导入失败，请检查空间或重新选择文件", null) } }
                        }
                    }
                    "saveFile" -> {
                        require(saveReply == null) { "已有保存窗口" }
                        val file = ownedFile(requireNotNull(call.argument<String>("path")))
                        saveSource = file; saveReply = result
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "video/mp4"; putExtra(Intent.EXTRA_TITLE, file.name)
                        }, 801)
                    }
                    "openFile" -> {
                        val file = ownedFile(requireNotNull(call.argument<String>("path")))
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("PLATFORM", "无法完成操作，请重试或选择其他应用", null) }
        }
    }
    private fun ownedFile(path: String): File {
        val file = File(path).canonicalFile
        require(file.isFile && file.path.startsWith(File(filesDir, "exports").canonicalPath + File.separator))
        return file
    }
    @Deprecated("Activity result API retained for FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 801) return
        val reply = saveReply ?: return; val file = saveSource
        saveReply = null; saveSource = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) { reply.success(false); return }
        worker.execute {
            try {
                contentResolver.openOutputStream(uri, "w").use { out -> requireNotNull(out); file.inputStream().use { it.copyTo(out) } }
                runOnUiThread { reply.success(true) }
            } catch (_: Exception) { runOnUiThread { reply.error("SAVE", "保存失败，请检查目标目录空间", null) } }
        }
    }
}
