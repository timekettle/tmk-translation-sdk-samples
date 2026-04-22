package co.timekettle.translation.flutter

import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal object SupportedLanguagesService {
    private const val DEFAULT_CONNECT_TIMEOUT_MS = 5_000
    private const val DEFAULT_READ_TIMEOUT_MS = 5_000
    // private const val DEFAULT_BASE_URL = "https://tmk-translation-test.timekettle.net/"
    private const val DEFAULT_BASE_URL = "https://api-glb.timekettle.co/" // TODO: 服务还没部署，此部分暂使用线上服务
    

    fun defaultServiceRootUrl(): String = DEFAULT_BASE_URL

    fun fetchOnlineLanguages(
        baseUrl: String,
        uiLocales: List<String>,
        version: String? = null,
    ): List<Map<String, Any>> {
        val connection = buildOnlineLanguagesUrl(baseUrl, uiLocales, version).openConnection() as HttpURLConnection
        return connection.useJsonGet { body ->
            parseOnlineLanguagesResponse(body)
        }
    }

    internal fun buildOnlineLanguagesUrl(
        baseUrl: String,
        uiLocales: List<String>,
        version: String? = null,
    ): URL {
        val normalizedBaseUrl = normalizeServiceRootUrl(baseUrl)
        val query = buildString {
            val locales = uiLocales
                .asSequence()
                .map(String::trim)
                .filter(String::isNotEmpty)
                .distinct()
                .toList()
            locales.forEachIndexed { index, locale ->
                if (index > 0) {
                    append('&')
                }
                append("ui_locales=")
                append(locale.urlEncode())
            }
            if (isNotEmpty()) {
                append('&')
            }
            append("flat")
            append('&')
            append("version=")
            append(version?.trim()?.urlEncode().orEmpty())
        }
        return URL("$normalizedBaseUrl/app/config/locales?$query")
    }

    internal fun parseOnlineLanguagesResponse(body: String): List<Map<String, Any>> {
        if (body.isBlank()) {
            throw IOException("empty locales response body")
        }

        val root = JSONObject(body)
        val payload = when {
            root.has("languages") || root.has("version") -> root
            root.has("data") -> {
                val code = root.optInt("code", 0)
                if (code != 0) {
                    throw IOException("locales api error: ${root.optString("message", "unknown")}")
                }
                root.optJSONObject("data") ?: JSONObject()
            }
            else -> root
        }

        val groups = payload.optJSONArray("languages") ?: JSONArray()
        val itemsByCode = linkedMapOf<String, Map<String, Any>>()
        for (index in 0 until groups.length()) {
            val group = groups.optJSONObject(index) ?: continue
            val locales = group.optJSONArray("data")
            if (locales != null && locales.length() > 0) {
                for (localeIndex in 0 until locales.length()) {
                    val locale = locales.optJSONObject(localeIndex) ?: continue
                    putLanguageOption(itemsByCode, locale)
                }
            } else {
                putLanguageOption(itemsByCode, group)
            }
        }

        if (itemsByCode.isEmpty()) {
            throw IOException("locales response did not contain usable languages")
        }
        return itemsByCode.values.toList()
    }

    private fun HttpURLConnection.useJsonGet(transform: (String) -> List<Map<String, Any>>): List<Map<String, Any>> {
        requestMethod = "GET"
        connectTimeout = DEFAULT_CONNECT_TIMEOUT_MS
        readTimeout = DEFAULT_READ_TIMEOUT_MS
        setRequestProperty("Accept", "application/json")
        setRequestProperty("source", "sdk-android")
        return try {
            val statusCode = responseCode
            val body = (if (statusCode in 200..299) inputStream else errorStream)
                ?.bufferedReader()
                ?.use { it.readText() }
                .orEmpty()
            if (statusCode !in 200..299) {
                throw IOException(
                    if (body.isBlank()) {
                        "HTTP $statusCode $responseMessage"
                    } else {
                        "HTTP $statusCode $responseMessage: $body"
                    },
                )
            }
            transform(body)
        } finally {
            disconnect()
        }
    }

    private fun putLanguageOption(
        itemsByCode: LinkedHashMap<String, Map<String, Any>>,
        payload: JSONObject,
    ) {
        val code = payload.optString("code").trim()
        if (code.isEmpty()) {
            return
        }
        val title = payload.optString("uiLang").trim().ifEmpty {
            payload.optString("nativeLang").trim()
        }
        itemsByCode[code] = mapOf(
            "code" to code,
            "familyCode" to code.substringBefore("-"),
            "title" to title,
        )
    }

    private fun String.urlEncode(): String {
        return URLEncoder.encode(this, StandardCharsets.UTF_8)
    }

    private fun normalizeServiceRootUrl(baseUrl: String): String {
        val trimmed = baseUrl.trim().ifBlank { DEFAULT_BASE_URL }.removeSuffix("/")
        return trimmed
    }
}
