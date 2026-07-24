package co.timekettle.translation.sample

import co.timekettle.translation.TmkTranslationSDK
import android.app.Application
import android.util.Log
import dagger.hilt.android.HiltAndroidApp

@HiltAndroidApp
class TranslationApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // 进程启动即初始化 SDK,确保首页等任意界面在请求语言列表等接口前 SDK 已就绪,
        // 避免因未初始化(SDK_NOT_INITIALIZED)而回退到硬编码语言。凭据缺失时仅记录日志,
        // 不阻断启动——具体界面的 ViewModel 仍会再次尝试初始化并向用户提示。
        if (SampleSdkConfig.hasCredentials()) {
            runCatching {
                TmkTranslationSDK.sdkInit(this, SampleSdkConfig.globalConfig(this))
                TmkTranslationSDK.lingCastTelemetrySetTraceReportingEnabled(true)
            }.onFailure { e ->
                Log.e(TAG, "应用启动初始化 SDK 失败", e)
            }
        }
    }

    private companion object {
        const val TAG = "TranslationApp"
    }
}
