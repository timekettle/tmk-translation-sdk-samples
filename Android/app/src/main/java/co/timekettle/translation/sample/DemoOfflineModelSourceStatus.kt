package co.timekettle.translation.sample

import android.content.Context
import co.timekettle.translation.TmkTranslationSDK
import co.timekettle.translation.config.TmkOfflineModelEndpointConfig
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal data class DemoOfflineModelSourceStatus(
    val baseURL: String?,
    val version: String?,
    val sourceName: String?,
) {
    val summary: String
        get() = when {
            baseURL == null -> "未安装或未记录"
            version != null -> "${sourceName.orEmpty()} · $version"
            else -> "${sourceName.orEmpty()} · 版本未知"
        }

    val entryMessage: String
        get() = "当前离线模型版本：${version ?: "未安装或未记录"}" +
            (sourceName?.let { "（$it）" } ?: "")
}

internal data class DemoOfflineModelProbeResult(
    val available: Boolean,
    val message: String,
)

internal object DemoOfflineModelSourceInspector {
    private const val MANIFEST_FILE_NAME = "model_manifest.json"
    private const val PROBE_PACKAGE_PATH = "asr/zh.zip"
    private const val CONNECT_TIMEOUT_MS = 5_000
    private const val READ_TIMEOUT_MS = 5_000

    fun current(context: Context): DemoOfflineModelSourceStatus {
        val manifestText = runCatching {
            val rootDirectory = File(TmkTranslationSDK.defaultOfflineModelRootDirectory(context))
            File(rootDirectory, MANIFEST_FILE_NAME).takeIf(File::isFile)?.readText()
        }.getOrNull()
        return fromManifestText(manifestText)
    }

    internal fun fromManifestText(text: String?): DemoOfflineModelSourceStatus {
        val baseURL = runCatching {
            text?.let { JSONObject(it).optString("baseURL") }
                ?.trim()
                ?.trimEnd('/')
                ?.takeIf(String::isNotEmpty)
        }.getOrNull()
        val normalizedDefault = TmkOfflineModelEndpointConfig.resolveBaseURL(null).trimEnd('/')
        return DemoOfflineModelSourceStatus(
            baseURL = baseURL,
            version = versionFromBaseURL(baseURL),
            sourceName = baseURL?.let { if (it == normalizedDefault) "默认源" else "自定义源" },
        )
    }

    internal fun versionFromBaseURL(baseURL: String?): String? {
        val path = runCatching { URI(baseURL).path }.getOrNull() ?: return null
        return path.split('/').lastOrNull { it.isNotBlank() }
    }

    internal fun probePackageURL(baseURL: String): String =
        "${baseURL.trimEnd('/')}/$PROBE_PACKAGE_PATH"

    suspend fun probe(rawBaseURL: String?): DemoOfflineModelProbeResult = withContext(Dispatchers.IO) {
        val baseURL = DemoSettingsStore.normalizeOfflineModelBaseURL(rawBaseURL)
            ?: return@withContext DemoOfflineModelProbeResult(false, "地址格式无效")
        val packageURL = probePackageURL(baseURL)
        runCatching {
            val headCode = request(packageURL, method = "HEAD")
            val code = if (headCode == HttpURLConnection.HTTP_BAD_METHOD) {
                request(packageURL, method = "GET", rangeProbe = true)
            } else {
                headCode
            }
            if (code in 200..299) {
                DemoOfflineModelProbeResult(true, "地址检测成功（已找到中文 ASR 模型）")
            } else {
                DemoOfflineModelProbeResult(false, "地址检测失败：HTTP $code")
            }
        }.getOrElse { error ->
            DemoOfflineModelProbeResult(
                available = false,
                message = "地址检测失败：${error.message?.takeIf(String::isNotBlank) ?: error.javaClass.simpleName}",
            )
        }
    }

    private fun request(url: String, method: String, rangeProbe: Boolean = false): Int {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.instanceFollowRedirects = true
            if (rangeProbe) connection.setRequestProperty("Range", "bytes=0-0")
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }
}
