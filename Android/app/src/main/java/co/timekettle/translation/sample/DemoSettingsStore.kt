package co.timekettle.translation.sample

import android.content.Context
import co.timekettle.translation.config.TmkDiagnosisLevel
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import java.net.URI

object DemoSettingsStore {
    private const val PREF_NAME = "demo_settings"
    private const val KEY_NETWORK_ENVIRONMENT = "network_environment"
    private const val KEY_CUSTOM_NETWORK_BASE_URL_ENABLED = "custom_network_base_url_enabled"
    private const val KEY_CUSTOM_NETWORK_BASE_URL = "custom_network_base_url"
    private const val KEY_DIAGNOSIS_ENABLED = "diagnosis_enabled"
    private const val KEY_DIAGNOSIS_LEVEL = "diagnosis_level"
    private const val KEY_DIAGNOSIS_AUDIO_CAPTURE_ENABLED = "diagnosis_audio_capture_enabled"
    private const val KEY_CONSOLE_LOG_ENABLED = "console_log_enabled"
    private const val KEY_SENSITIVE_WORD_REDACTION_ENABLED = "sensitive_word_redaction_enabled"
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

    fun loadDiagnosisEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_DIAGNOSIS_ENABLED, false)
    }

    fun saveDiagnosisEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DIAGNOSIS_ENABLED, enabled)
            .apply()
    }

    fun loadDiagnosisLevel(context: Context): TmkDiagnosisLevel {
        val raw = context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(KEY_DIAGNOSIS_LEVEL, null)
        return parseDiagnosisLevel(raw)
    }

    fun saveDiagnosisLevel(context: Context, level: TmkDiagnosisLevel) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DIAGNOSIS_LEVEL, level.name)
            .apply()
    }

    fun loadDiagnosisAudioCaptureEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_DIAGNOSIS_AUDIO_CAPTURE_ENABLED, false)
    }

    fun saveDiagnosisAudioCaptureEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DIAGNOSIS_AUDIO_CAPTURE_ENABLED, enabled)
            .apply()
    }

    fun loadConsoleLogEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_CONSOLE_LOG_ENABLED, true)
    }

    fun saveConsoleLogEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_CONSOLE_LOG_ENABLED, enabled)
            .apply()
    }

    fun loadSensitiveWordRedactionEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_SENSITIVE_WORD_REDACTION_ENABLED, true)
    }

    fun saveSensitiveWordRedactionEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SENSITIVE_WORD_REDACTION_ENABLED, enabled)
            .apply()
    }

    fun parseNetworkEnvironment(raw: String?): TmkTranslationNetworkEnvironment {
        val normalized = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return TmkTranslationNetworkEnvironment.TEST
        return supportedNetworkEnvironments.firstOrNull { it.name.equals(normalized, ignoreCase = true) }
            ?: TmkTranslationNetworkEnvironment.TEST
    }

    fun parseDiagnosisLevel(raw: String?): TmkDiagnosisLevel {
        val normalized = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return TmkDiagnosisLevel.ESSENTIAL
        return TmkDiagnosisLevel.entries.firstOrNull { it.name.equals(normalized, ignoreCase = true) }
            ?: TmkDiagnosisLevel.ESSENTIAL
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
