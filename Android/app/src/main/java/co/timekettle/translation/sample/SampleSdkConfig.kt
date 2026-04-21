package co.timekettle.translation.sample

import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.sample.BuildConfig

object SampleSdkConfig {

    private const val ENV_APP_ID = "TMK_SAMPLE_APP_ID"
    private const val ENV_APP_SECRET = "TMK_SAMPLE_APP_SECRET"
    private const val USER_GRADLE_PROPERTIES_PATH = "~/.gradle/gradle.properties"

    fun globalConfig(): TmkTransGlobalConfig {
        check(BuildConfig.TMK_SAMPLE_APP_ID.isNotBlank()) {
            "Missing $ENV_APP_ID. Export it in your shell or configure it in $USER_GRADLE_PROPERTIES_PATH."
        }
        check(BuildConfig.TMK_SAMPLE_APP_SECRET.isNotBlank()) {
            "Missing $ENV_APP_SECRET. Export it in your shell or configure it in $USER_GRADLE_PROPERTIES_PATH."
        }

        return TmkTransGlobalConfig.Builder()
            .setAuth(BuildConfig.TMK_SAMPLE_APP_ID, BuildConfig.TMK_SAMPLE_APP_SECRET)
            .build()
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
