package co.timekettle.translation.flutter

import android.content.Context

internal data class TmkSettings(
    val diagnosisEnabled: Boolean,
    val consoleLogEnabled: Boolean,
    val networkEnvironment: String,
    val mockEngineEnabled: Boolean,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "diagnosisEnabled" to diagnosisEnabled,
            "consoleLogEnabled" to consoleLogEnabled,
            "networkEnvironment" to networkEnvironment,
            "mockEngineEnabled" to mockEngineEnabled,
        )
    }

    companion object {
        fun defaults(): TmkSettings {
            return TmkSettings(
                diagnosisEnabled = false,
                consoleLogEnabled = true,
                networkEnvironment = "test",
                mockEngineEnabled = false,
            )
        }

        fun fromMap(raw: Map<*, *>?): TmkSettings {
            val defaults = defaults()
            return TmkSettings(
                diagnosisEnabled = raw?.get("diagnosisEnabled") as? Boolean ?: defaults.diagnosisEnabled,
                consoleLogEnabled = raw?.get("consoleLogEnabled") as? Boolean ?: defaults.consoleLogEnabled,
                networkEnvironment = raw?.get("networkEnvironment") as? String ?: defaults.networkEnvironment,
                mockEngineEnabled = raw?.get("mockEngineEnabled") as? Boolean ?: defaults.mockEngineEnabled,
            )
        }
    }
}

internal class TmkSettingsStore(context: Context) {
    private val preferences = context.getSharedPreferences("tmk_translation_flutter", Context.MODE_PRIVATE)

    fun load(): TmkSettings {
        if (!preferences.contains(KEY_NETWORK_ENVIRONMENT)) {
            return TmkSettings.defaults()
        }
        return TmkSettings(
            diagnosisEnabled = preferences.getBoolean(KEY_DIAGNOSIS_ENABLED, false),
            consoleLogEnabled = preferences.getBoolean(KEY_CONSOLE_LOG_ENABLED, true),
            networkEnvironment = preferences.getString(KEY_NETWORK_ENVIRONMENT, "test") ?: "test",
            mockEngineEnabled = preferences.getBoolean(KEY_MOCK_ENGINE_ENABLED, false),
        )
    }

    fun save(settings: TmkSettings) {
        preferences.edit()
            .putBoolean(KEY_DIAGNOSIS_ENABLED, settings.diagnosisEnabled)
            .putBoolean(KEY_CONSOLE_LOG_ENABLED, settings.consoleLogEnabled)
            .putString(KEY_NETWORK_ENVIRONMENT, settings.networkEnvironment)
            .putBoolean(KEY_MOCK_ENGINE_ENABLED, settings.mockEngineEnabled)
            .apply()
    }

    private companion object {
        private const val KEY_DIAGNOSIS_ENABLED = "diagnosis_enabled"
        private const val KEY_CONSOLE_LOG_ENABLED = "console_log_enabled"
        private const val KEY_NETWORK_ENVIRONMENT = "network_environment"
        private const val KEY_MOCK_ENGINE_ENABLED = "mock_engine_enabled"
    }
}
