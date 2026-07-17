package co.timekettle.translation.sample

import android.content.Context
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import java.net.URI

object DemoSettingsStore {
    private const val PREF_NAME = "demo_settings"
    private const val KEY_NETWORK_ENVIRONMENT = "network_environment"
    private const val KEY_CUSTOM_NETWORK_BASE_URL_ENABLED = "custom_network_base_url_enabled"
    private const val KEY_CUSTOM_NETWORK_BASE_URL = "custom_network_base_url"
    const val RAYNEO_NETWORK_BASE_URL = "https://api-rayneo.timekettle.co"

    val supportedNetworkEnvironments = listOf(
        TmkTranslationNetworkEnvironment.DEV,
        TmkTranslationNetworkEnvironment.TEST,
        TmkTranslationNetworkEnvironment.PRE,
    )

    fun loadNetworkEnvironment(context: Context): TmkTranslationNetworkEnvironment {
        val raw = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(KEY_NETWORK_ENVIRONMENT, null)
        return parseNetworkEnvironment(raw)
    }

    fun saveNetworkEnvironment(context: Context, environment: TmkTranslationNetworkEnvironment) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_NETWORK_ENVIRONMENT, environment.name)
            .apply()
    }

    fun loadCustomNetworkBaseURLEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_CUSTOM_NETWORK_BASE_URL_ENABLED, false)
    }

    fun saveCustomNetworkBaseURLEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_CUSTOM_NETWORK_BASE_URL_ENABLED, enabled)
            .apply()
    }

    fun loadCustomNetworkBaseURL(context: Context): String? {
        val raw = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(KEY_CUSTOM_NETWORK_BASE_URL, null)
        return normalizeCustomNetworkBaseURL(raw)
    }

    fun saveCustomNetworkBaseURL(context: Context, url: String?) {
        val normalized = normalizeCustomNetworkBaseURL(url)
        val editor = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
        if (normalized == null) {
            editor.remove(KEY_CUSTOM_NETWORK_BASE_URL)
        } else {
            editor.putString(KEY_CUSTOM_NETWORK_BASE_URL, normalized)
        }
        editor.apply()
    }

    fun parseNetworkEnvironment(raw: String?): TmkTranslationNetworkEnvironment {
        val normalized = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return TmkTranslationNetworkEnvironment.TEST
        return supportedNetworkEnvironments.firstOrNull { it.name.equals(normalized, ignoreCase = true) }
            ?: TmkTranslationNetworkEnvironment.TEST
    }

    fun normalizeCustomNetworkBaseURL(raw: String?): String? {
        val trimmed = raw?.trim()?.trimEnd('/')?.takeIf { it.isNotEmpty() } ?: return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        if (uri.host.isNullOrBlank()) return null
        if (!uri.rawPath.isNullOrBlank()) return null
        if (!uri.rawQuery.isNullOrBlank() || !uri.rawFragment.isNullOrBlank()) return null
        return trimmed
    }
}
