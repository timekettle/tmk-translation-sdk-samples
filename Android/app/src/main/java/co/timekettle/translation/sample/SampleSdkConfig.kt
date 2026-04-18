package co.timekettle.translation.sample

import co.timekettle.translation.config.TmkTransGlobalConfig
import co.timekettle.translation.sample.BuildConfig

object SampleSdkConfig {

    fun globalConfig(): TmkTransGlobalConfig {
        check(BuildConfig.TMK_SAMPLE_APP_ID.isNotBlank()) {
            "Missing TMK_SAMPLE_APP_ID. Configure it in AndroidSample/gradle.properties or ~/.gradle/gradle.properties."
        }
        check(BuildConfig.TMK_SAMPLE_APP_SECRET.isNotBlank()) {
            "Missing TMK_SAMPLE_APP_SECRET. Configure it in AndroidSample/gradle.properties or ~/.gradle/gradle.properties."
        }

        return TmkTransGlobalConfig.Builder()
            .setAuth(BuildConfig.TMK_SAMPLE_APP_ID, BuildConfig.TMK_SAMPLE_APP_SECRET)
            .build()
    }
}

