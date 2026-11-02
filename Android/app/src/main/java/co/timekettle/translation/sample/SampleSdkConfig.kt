package co.timekettle.translation.sample

import co.timekettle.translation.*

import android.content.Context
import android.util.Log
import co.timekettle.translation.config.TmkDiagnosisConfig
import co.timekettle.translation.config.TmkDiagnosisLevel
import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import java.io.File

object SampleSdkConfig {

    private const val ENV_APP_ID = "TMK_SAMPLE_APP_ID"
    private const val ENV_APP_SECRET = "TMK_SAMPLE_APP_SECRET"
    private const val USER_GRADLE_PROPERTIES_PATH = "~/.gradle/gradle.properties"
    private const val DIAGNOSIS_DIRECTORY_NAME = "sdk_diagnosis"
    private const val TAG = "SampleSdkConfig"

    fun globalConfig(
        networkEnvironment: TmkTranslationNetworkEnvironment = TmkTranslationNetworkEnvironment.TEST,
        customNetworkBaseURLEnabled: Boolean = false,
        customNetworkBaseURL: String? = null,
        customOfflineModelBaseURLEnabled: Boolean = false,
        offlineModelBaseURL: String? = null,
        diagnosisEnabled: Boolean = true,
        diagnosisLevel: TmkDiagnosisLevel = TmkDiagnosisLevel.TRACE,
        diagnosisAudioCaptureEnabled: Boolean = false,
        diagnosisConsoleEnabled: Boolean = true,
        diagnosisRootDirectory: File? = null,
        diagnosisMaxTotalSizeMB: Long = 500L,
        diagnosisMaxSessionCount: Int? = null,
    ): TmkTransGlobalConfig {
        check(BuildConfig.TMK_SAMPLE_APP_ID.isNotBlank()) {
            "Missing $ENV_APP_ID. Export it in your shell or configure it in $USER_GRADLE_PROPERTIES_PATH."
        }
        check(BuildConfig.TMK_SAMPLE_APP_SECRET.isNotBlank()) {
            "Missing $ENV_APP_SECRET. Export it in your shell or configure it in $USER_GRADLE_PROPERTIES_PATH."
        }

        val builder = TmkTransGlobalConfig.Builder()
            .setAuth(BuildConfig.TMK_SAMPLE_APP_ID, BuildConfig.TMK_SAMPLE_APP_SECRET)
            .setOnlineAuthContext(tenantId = "timekettle")
            .setNetworkEnvironment(networkEnvironment)
            .setDiagnosisConfig(
                TmkDiagnosisConfig(
                    enabled = diagnosisEnabled,
                    level = diagnosisLevel,
                    rootDirectory = diagnosisRootDirectory,
                    audioCaptureEnabled = diagnosisLevel == TmkDiagnosisLevel.TRACE && diagnosisAudioCaptureEnabled,
                    maxTotalSizeMB = diagnosisMaxTotalSizeMB,
                    maxSessionCount = diagnosisMaxSessionCount,
                )
            )
            .setDiagnosisConsoleEnabled(diagnosisConsoleEnabled)
        val normalizedBaseURL = DemoSettingsStore.normalizeCustomNetworkBaseURL(customNetworkBaseURL)
        if (customNetworkBaseURLEnabled && normalizedBaseURL != null) {
            builder.setNetworkBaseURL(normalizedBaseURL)
        }
        DemoSettingsStore.resolveOfflineModelBaseURL(
            customEnabled = customOfflineModelBaseURLEnabled,
            raw = offlineModelBaseURL,
        )?.let(builder::setOfflineModelBaseURL)
        return builder.build()
    }

    fun globalConfig(context: Context): TmkTransGlobalConfig {
        val requestedDiagnosisEnabled = DemoSettingsStore.loadDiagnosisEnabled(context)
        val diagnosisRootDirectory = if (requestedDiagnosisEnabled) {
            resolveDiagnosisRootDirectory(context.getExternalFilesDir(null))
        } else {
            null
        }
        val effectiveDiagnosisEnabled = requestedDiagnosisEnabled && diagnosisRootDirectory != null
        if (requestedDiagnosisEnabled && !effectiveDiagnosisEnabled) {
            Log.w(TAG, "External diagnosis directory is unavailable; file diagnosis is disabled.")
        }
        return globalConfig(
            networkEnvironment = DemoSettingsStore.loadNetworkEnvironment(context),
            customNetworkBaseURLEnabled = DemoSettingsStore.loadCustomNetworkBaseURLEnabled(context),
            customNetworkBaseURL = DemoSettingsStore.loadCustomNetworkBaseURL(context),
            customOfflineModelBaseURLEnabled = DemoSettingsStore.loadCustomOfflineModelBaseURLEnabled(context),
            offlineModelBaseURL = DemoSettingsStore.loadOfflineModelBaseURL(context),
            diagnosisEnabled = effectiveDiagnosisEnabled,
            diagnosisLevel = DemoSettingsStore.loadDiagnosisLevel(context),
            diagnosisAudioCaptureEnabled = effectiveDiagnosisEnabled &&
                DemoSettingsStore.loadDiagnosisAudioCaptureEnabled(context),
            diagnosisConsoleEnabled = DemoSettingsStore.loadConsoleLogEnabled(context),
            diagnosisRootDirectory = diagnosisRootDirectory,
            diagnosisMaxTotalSizeMB = DemoSettingsStore.loadDiagnosisMaxTotalSizeMB(context),
            diagnosisMaxSessionCount = DemoSettingsStore.loadDiagnosisMaxSessionCount(context),
        )
    }

    /** 只取已应用 SDK 的路径，不 flush、不创建目录、不读取设置页草稿。 */
    internal fun appliedDiagnosisRootDirectory(): File? =
        co.timekettle.offlinesdk.diagnosis.SdkDiagnosisManager.currentRootDir()
            .takeIf { it.isNotBlank() }?.let(::File)

    internal fun resolveDiagnosisRootDirectory(externalFilesDirectory: File?): File? {
        val directory = externalFilesDirectory?.let { File(it, DIAGNOSIS_DIRECTORY_NAME) } ?: return null
        return directory.takeIf { (it.isDirectory || it.mkdirs()) && it.canWrite() }
    }

    fun hasCredentials(): Boolean {
        return BuildConfig.TMK_SAMPLE_APP_ID.isNotBlank() && BuildConfig.TMK_SAMPLE_APP_SECRET.isNotBlank()
    }

    fun buildInitErrorMessage(error: Throwable): String {
        val detail = error.message?.takeIf { it.isNotBlank() } ?: "Unknown error"
        return buildString {
            appendLine("SDK 初始化失败")
            appendLine()
            appendLine("异常信息：")
            appendLine(detail)
            appendLine()
            appendLine("请通过全局环境变量或 Gradle 属性填写：")
            appendLine(ENV_APP_ID)
            appendLine(ENV_APP_SECRET)
            appendLine()
            appendLine("建议配置位置：")
            appendLine(USER_GRADLE_PROPERTIES_PATH)
            appendLine()
            appendLine("示例：")
            appendLine("$ENV_APP_ID=your_app_id")
            append("$ENV_APP_SECRET=your_app_secret")
        }
    }
}
