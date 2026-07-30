package co.timekettle.translation.sample

import android.content.Context
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment

object DemoSettingsStore {
    private const val PREF_NAME = "demo_settings"
    private const val KEY_NETWORK_ENVIRONMENT = "network_environment"
    private const val KEY_DIAGNOSIS_ENABLED = "diagnosis_enabled"
    private const val DEFAULT_DIAGNOSIS_ENABLED = false
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

    fun loadDiagnosisEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_DIAGNOSIS_ENABLED, DEFAULT_DIAGNOSIS_ENABLED)
    }

    fun saveDiagnosisEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_DIAGNOSIS_ENABLED, enabled)
            .apply()
    }

    fun parseNetworkEnvironment(raw: String?): TmkTranslationNetworkEnvironment {
        val normalized = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return TmkTranslationNetworkEnvironment.TEST
        return supportedNetworkEnvironments.firstOrNull { it.name.equals(normalized, ignoreCase = true) }
            ?: TmkTranslationNetworkEnvironment.TEST
    }
}
