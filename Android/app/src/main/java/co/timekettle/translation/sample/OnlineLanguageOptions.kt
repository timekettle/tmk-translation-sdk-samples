package co.timekettle.translation.sample
import co.timekettle.translation.TmkTranslationSDK

import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import co.timekettle.translation.listener.TmkLocaleListCallback
import co.timekettle.translation.model.TmkLocaleListResponse
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

private const val TAG = "LanguageOptions"

/** 语言列表加载状态(在线/离线通用)。 */
sealed interface LanguageOptionsState {
    /** 正在拉取。 */
    data object Loading : LanguageOptionsState

    /** 拉取成功且非空。 */
    data class Ready(val options: Map<String, String>) : LanguageOptionsState

    /** 拉取失败「或」结果为空,均视为失败,由上层禁用入口并提供重试。 */
    data object Failed : LanguageOptionsState
}

/** 语言列表 UI 状态,附带重试回调。 */
data class LanguageOptionsUiState(
    val state: LanguageOptionsState,
    val retry: () -> Unit,
)

/** 在线语言列表(SDK 动态获取,失败/为空即 Failed,不回退硬编码)。 */
@Composable
fun rememberOnlineLanguageOptions(): LanguageOptionsUiState =
    rememberLanguageOptions(online = true)

/** 离线语言列表(SDK 动态获取,失败/为空即 Failed,不回退硬编码)。 */
@Composable
fun rememberOfflineLanguageOptions(): LanguageOptionsUiState =
    rememberLanguageOptions(online = false)

/**
 * 语言列表进程级缓存。
 *
 * 首页成功拉取后常驻内存,使对话页弹窗、返回首页等场景可立即拿到 Ready,
 * 无需每次重新异步请求(否则会出现「弹窗无语言可选」「返回首页按钮不可点」)。
 */
private object LanguageOptionsCache {
    @Volatile
    private var online: Map<String, String>? = null

    @Volatile
    private var offline: Map<String, String>? = null

    fun get(online: Boolean): Map<String, String>? = if (online) this.online else offline

    fun put(online: Boolean, options: Map<String, String>) {
        if (online) this.online = options else offline = options
    }
}

@Composable
private fun rememberLanguageOptions(online: Boolean): LanguageOptionsUiState {
    // attempt 自增触发 LaunchedEffect 重新拉取,实现重试(强制刷新,忽略缓存)。
    var attempt by remember(online) { mutableIntStateOf(0) }
    // 初始态:命中缓存直接 Ready,避免回到首页/打开弹窗时闪烁与重复请求。
    var state by remember(online) {
        val cached = LanguageOptionsCache.get(online)
        mutableStateOf<LanguageOptionsState>(
            if (cached != null) LanguageOptionsState.Ready(cached) else LanguageOptionsState.Loading
        )
    }

    LaunchedEffect(online, attempt) {
        // 已有缓存且非主动重试:沿用缓存,不重复发起请求。
        if (attempt == 0 && LanguageOptionsCache.get(online) != null) return@LaunchedEffect
        state = LanguageOptionsState.Loading
        try {
            val remoteMap = fetchLocaleList(online).toDisplayMap()
            val map = if (online) mergeOnlineLanguageDefaults(remoteMap) else remoteMap
            // 空列表与失败同等处理:上层据此禁用「开始翻译」。
            state = if (map.isNotEmpty()) {
                LanguageOptionsCache.put(online, map)
                LanguageOptionsState.Ready(map)
            } else {
                LanguageOptionsState.Failed
            }
        } catch (e: Exception) {
            // 记录日志以便排查(如 SDK 未初始化、网络/鉴权失败)。
            Log.w(TAG, "获取${if (online) "在线" else "离线"}语言列表失败", e)
            state = LanguageOptionsState.Failed
        }
    }

    return LanguageOptionsUiState(state = state, retry = { attempt++ })
}

/** 把结构化响应映射为 UI 下拉所需的 code → 显示名 Map。 */
private fun TmkLocaleListResponse.toDisplayMap(): Map<String, String> =
    localeOptions
        .filter { it.code.isNotEmpty() }
        .associate { it.code to it.displayName.ifBlank { it.code } }

internal fun mergeOnlineLanguageDefaults(remote: Map<String, String>): Map<String, String> {
    if (remote.isEmpty()) return remote
    return LinkedHashMap<String, String>().apply {
        putAll(TranslationLanguages.online)
        putAll(remote)
    }
}

/** 桥接 SDK 的 Callback 接口为 suspend 调用,随协程取消而取消请求。 */
private suspend fun fetchLocaleList(online: Boolean): TmkLocaleListResponse =
    suspendCancellableCoroutine { cont ->
        val callback = object : TmkLocaleListCallback {
            override fun onSuccess(response: TmkLocaleListResponse) {
                if (cont.isActive) cont.resume(response)
            }

            override fun onError(errorId: Int, e: Exception) {
                if (cont.isActive) cont.resumeWith(Result.failure(e))
            }
        }
        val cancelable = if (online) {
            TmkTranslationSDK.getOnlineSupportedLanguages(callback = callback)
        } else {
            TmkTranslationSDK.getOfflineSupportedLanguages(callback = callback)
        }
        cont.invokeOnCancellation { cancelable.cancel() }
    }
