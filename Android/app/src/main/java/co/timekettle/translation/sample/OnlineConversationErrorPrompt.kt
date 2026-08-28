package co.timekettle.translation.sample

import co.timekettle.translation.TmkTranslationException

import co.timekettle.translation.model.TmkTranslationChannelStateReason
import co.timekettle.translation.model.TmkTranslationChannelStateSnapshot

data class OnlineConversationErrorPrompt(
    val id: String,
    val title: String,
    val message: String,
    val restartText: String = "重新创建",
    val leaveText: String = "离开页面",
)

object OnlineConversationErrorPrompts {
    enum class RuntimeMode {
        ONLINE,
        OFFLINE
    }

    fun fromCloseRoom(): OnlineConversationErrorPrompt {
        return OnlineConversationErrorPrompt(
            id = "close_room",
            title = "房间已关闭",
            message = "服务端已关闭当前房间。当前对话资源已释放，需要重新创建一个全新的对话。"
        )
    }

    fun fromSnapshot(
        snapshot: TmkTranslationChannelStateSnapshot,
        mode: RuntimeMode = RuntimeMode.ONLINE,
    ): OnlineConversationErrorPrompt? {
        val code = snapshot.code ?: return fromReason(snapshot.reason, snapshot.message, null)
        return fromCode(code, snapshot.message, snapshot.reason, mode)
    }

    fun fromCode(
        code: Int,
        message: String,
        reason: TmkTranslationChannelStateReason? = null,
        mode: RuntimeMode = RuntimeMode.ONLINE,
    ): OnlineConversationErrorPrompt? {
        val restartText = restartText(mode)
        val actionText = actionText(mode)
        return when (code) {
            TmkTranslationException.ErrorCodes.REQUEST_CANCELLED,
            TmkTranslationException.ErrorCodes.MESSAGE_DECODING_FAILED,
            TmkTranslationException.ErrorCodes.TRACK_EVENT_NOT_CONFIGURED,
            TmkTranslationException.ErrorCodes.TRACK_EVENT_INVALID_EVENT_NAME,
            TmkTranslationException.ErrorCodes.TTS_SYNTHESIS_ERROR,
            TmkTranslationException.ErrorCodes.TRANSLATION_ERROR,
            TmkTranslationException.ErrorCodes.BUFFER_OVERFLOW -> null

            TmkTranslationException.ErrorCodes.SDK_NOT_INITIALIZED -> restartPrompt(
                id = "sdk_not_initialized_$code",
                title = "SDK 未初始化",
                message = "请先完成 SDK 初始化，再$actionText。\n\n错误[$code]：$message",
                restartText = "重新初始化",
            )

            TmkTranslationException.ErrorCodes.AUTHENTICATION_FAILED -> restartPrompt(
                id = "authentication_$code",
                title = "鉴权失败",
                message = "当前鉴权信息无效，请重新鉴权后$actionText。\n\n错误[$code]：$message",
                restartText = "重新鉴权",
            )

            TmkTranslationException.ErrorCodes.SESSION_EXPIRED -> restartPrompt(
                id = "session_expired_$code",
                title = "会话已过期",
                message = "当前对话 token 已失效，需要重新鉴权并$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.NETWORK_INVALID_URL,
            TmkTranslationException.ErrorCodes.NETWORK_RESPONSE_DECODING_ERROR -> restartPrompt(
                id = "network_config_$code",
                title = "网络配置或响应异常",
                message = "当前网络地址或服务响应不可用，请检查配置后重试。\n\n错误[$code]：$message",
                restartText = "重新检查",
            )

            TmkTranslationException.ErrorCodes.AUDIO_PROCESSING_ERROR,
            TmkTranslationException.ErrorCodes.AUDIO_CHANNEL_CREATION_FAILED,
            TmkTranslationException.ErrorCodes.ENGINE_INITIALIZATION_FAILED,
            TmkTranslationException.ErrorCodes.DEPENDENCY_UNAVAILABLE,
            TmkTranslationException.ErrorCodes.INVALID_STATE,
            TmkTranslationException.ErrorCodes.THREAD_INTERRUPTED,
            TmkTranslationException.ErrorCodes.UNKNOWN_ERROR -> restartPrompt(
                id = "runtime_$code",
                title = "通道异常",
                message = "当前对话通道无法继续使用，请释放资源并$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.ENGINE_NOT_SUPPORTED,
            TmkTranslationException.ErrorCodes.INVALID_CONFIGURATION,
            TmkTranslationException.ErrorCodes.QUOTA_EXCEEDED -> restartPrompt(
                id = "configuration_$code",
                title = "对话配置不可用",
                message = "当前配置、能力或服务配额不满足启动条件，请调整后$actionText。\n\n错误[$code]：$message",
                restartText = "检查配置",
            )

            TmkTranslationException.ErrorCodes.INVALID_LANGUAGE_CODE -> invalidLanguagePrompt(
                code = code,
                message = message,
                mode = mode,
            )

            TmkTranslationException.ErrorCodes.NETWORK_UNAVAILABLE,
            TmkTranslationException.ErrorCodes.NETWORK_TRANSPORT_ERROR -> restartPrompt(
                id = "network_$code",
                title = "连接已断开",
                message = "连接已断开或网络不可用。请确认网络恢复后$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.RTC_OPERATION_FAILED -> if (
                reason == TmkTranslationChannelStateReason.SERVICE_REJECTED &&
                isServiceAudioUserOffline(message)
            ) {
                restartPrompt(
                    id = "service_user_offline_$code",
                    title = "服务端音频通道已断开",
                    message = "服务端音频通道已断开，当前对话无法继续使用。请重新创建一个全新的对话。\n\n错误[$code]：$message",
                    restartText = restartText,
                )
            } else {
                restartPrompt(
                    id = "channel_$code",
                    title = "通道连接失败",
                    message = "当前通道无法继续使用，需要释放资源并$actionText。\n\n错误[$code]：$message",
                    restartText = restartText,
                )
            }

            TmkTranslationException.ErrorCodes.RTC_BANNED_BY_SERVER,
            TmkTranslationException.ErrorCodes.RTC_JOIN_FAILED,
            TmkTranslationException.ErrorCodes.RTC_REJECTED_BY_SERVER,
            TmkTranslationException.ErrorCodes.RTC_USER_BANNED,
            TmkTranslationException.ErrorCodes.CHANNEL_CREATION_FAILED -> restartPrompt(
                id = "channel_$code",
                title = "通道连接失败",
                message = "当前通道无法继续使用，需要释放资源并$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.ROOM_CREATION_FAILED -> restartPrompt(
                id = "room_$code",
                title = "房间创建失败",
                message = "当前在线房间创建失败，请检查网络或鉴权信息后重试。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.NETWORK_HTTP_STATUS_ERROR -> restartPrompt(
                id = "http_$code",
                title = "服务请求失败",
                message = "服务端返回异常状态，请检查鉴权信息或稍后重试。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.NETWORK_BUSINESS_ERROR -> restartPrompt(
                id = "business_$code",
                title = "服务端拒绝请求",
                message = "服务端返回业务错误，请按错误信息处理后重试。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.OFFLINE_MODEL_NOT_READY -> restartPrompt(
                id = "offline_model_$code",
                title = "离线模型未就绪",
                message = "当前离线模型缺失、需要更新或离线能力不可用。请先下载/更新模型或重新鉴权。\n\n错误[$code]：$message",
                restartText = "重新检查",
            )

            // HTTP 状态码细分（2002400-2002599）
            in 2002400..2002599 -> {
                val httpStatus = code - 2002000
                if (httpStatus == 401 || httpStatus == 403) {
                    restartPrompt(
                        id = "http_auth_$code",
                        title = "鉴权已失效",
                        message = "服务端拒绝当前鉴权信息，请重新鉴权后再使用。\n\n错误[$code]：$message",
                        restartText = "重新鉴权"
                    )
                } else if (httpStatus >= 500) {
                    restartPrompt(
                        id = "http_server_$code",
                        title = "服务请求失败",
                        message = "服务端返回异常状态，可以稍后重试。\n\n错误[$code]：$message",
                        restartText = restartText,
                    )
                } else {
                    restartPrompt(
                        id = "http_client_$code",
                        title = "服务请求失败",
                        message = "请求参数有误，请按错误信息处理后重试。\n\n错误[$code]：$message"
                    )
                }
            }
            // 后台业务码细分（2005xxx/2006xxx/2007xxx）
            in 2005000..2007999 -> restartPrompt(
                id = "biz_$code",
                title = "服务端拒绝请求",
                message = "服务端返回业务错误，请按错误信息处理后重试。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            else -> fromReason(reason, message, code, mode)
        }
    }

    /**
     * 将 Android 回调中的异常字段同步到 Demo 文案，保留统一码与脱敏后的底层诊断码。
     */
    fun fromException(
        errorCode: Int,
        error: Exception,
        reason: TmkTranslationChannelStateReason? = null,
        mode: RuntimeMode = RuntimeMode.ONLINE,
    ): OnlineConversationErrorPrompt? {
        val sdkError = error as? TmkTranslationException
        return fromCode(errorCode, buildExceptionMessage(error, sdkError), reason, mode)
    }

    /**
     * 依据错误契约判断 Demo 是否应停止当前采集。
     * warning/ignored 错误只记录或弱提示，不主动打断正在进行的对话。
     */
    fun shouldStopChannel(code: Int): Boolean {
        return when (code) {
            TmkTranslationException.ErrorCodes.REQUEST_CANCELLED,
            TmkTranslationException.ErrorCodes.MESSAGE_DECODING_FAILED,
            TmkTranslationException.ErrorCodes.TRACK_EVENT_NOT_CONFIGURED,
            TmkTranslationException.ErrorCodes.TRACK_EVENT_INVALID_EVENT_NAME,
            TmkTranslationException.ErrorCodes.TTS_SYNTHESIS_ERROR,
            TmkTranslationException.ErrorCodes.TRANSLATION_ERROR,
            TmkTranslationException.ErrorCodes.BUFFER_OVERFLOW -> false
            else -> true
        }
    }

    private fun fromReason(
        reason: TmkTranslationChannelStateReason?,
        message: String,
        code: Int?,
        mode: RuntimeMode = RuntimeMode.ONLINE,
    ): OnlineConversationErrorPrompt? {
        val restartText = restartText(mode)
        val actionText = actionText(mode)
        return when (reason) {
            TmkTranslationChannelStateReason.BANNED_BY_SERVER,
            TmkTranslationChannelStateReason.SERVICE_REJECTED -> restartPrompt(
                id = "server_${code ?: reason.rawValue}",
                title = "对话被服务端中断",
                message = buildMessage("服务端拒绝或关闭了当前对话，需要$actionText。", code, message),
                restartText = restartText,
            )

            TmkTranslationChannelStateReason.RTC_LOST,
            TmkTranslationChannelStateReason.RTC_KEEP_ALIVE_TIMEOUT,
            TmkTranslationChannelStateReason.MESSAGE_CHANNEL_FAILURE -> restartPrompt(
                id = "connection_${code ?: reason.rawValue}",
                title = "连接已断开",
                message = buildMessage("连接已经不可用，需要$actionText。", code, message),
                restartText = restartText,
            )

            TmkTranslationChannelStateReason.SESSION_EXPIRED -> restartPrompt(
                id = "session_${code ?: reason.rawValue}",
                title = "会话已过期",
                message = buildMessage("当前会话已失效，需要重新鉴权并$actionText。", code, message),
                restartText = restartText,
            )

            TmkTranslationChannelStateReason.ENGINE_ERROR -> if (mode == RuntimeMode.OFFLINE) {
                restartPrompt(
                    id = "offline_engine_${code ?: reason.rawValue}",
                    title = "离线通道异常",
                    message = buildMessage("离线引擎运行失败，需要重新初始化离线通道。", code, message),
                    restartText = restartText,
                )
            } else {
                null
            }

            TmkTranslationChannelStateReason.INVALID_CONFIGURATION -> restartPrompt(
                id = "invalid_config_${code ?: reason.rawValue}",
                title = "配置错误",
                message = buildMessage("当前配置无效，无法继续启动对话。", code, message),
                restartText = restartText,
            )

            else -> null
        }
    }

    private fun restartPrompt(
        id: String,
        title: String,
        message: String,
        restartText: String = "重新创建",
    ): OnlineConversationErrorPrompt {
        return OnlineConversationErrorPrompt(
            id = id,
            title = title,
            message = message,
            restartText = restartText,
        )
    }

    private fun invalidLanguagePrompt(
        code: Int,
        message: String,
        mode: RuntimeMode,
    ): OnlineConversationErrorPrompt {
        val action = if (mode == RuntimeMode.OFFLINE) {
            "重新初始化离线通道"
        } else {
            "重新创建对话"
        }
        return restartPrompt(
            id = "invalid_language_$code",
            title = "语言不支持",
            message = "当前语言不受支持。请选择支持的语言后$action。\n\n错误[$code]：$message",
            restartText = "重新选择",
        )
    }

    private fun restartText(mode: RuntimeMode): String {
        return if (mode == RuntimeMode.OFFLINE) "重新初始化" else "重新创建"
    }

    private fun isServiceAudioUserOffline(message: String): Boolean {
        return message.contains("service audio uid offline", ignoreCase = true) ||
            message.contains("server audio user offline", ignoreCase = true)
    }

    private fun actionText(mode: RuntimeMode): String {
        return if (mode == RuntimeMode.OFFLINE) "重新初始化离线通道" else "重新创建对话"
    }

    private fun buildMessage(prefix: String, code: Int?, message: String): String {
        return if (code == null) {
            "$prefix\n\n$message"
        } else {
            "$prefix\n\n错误[$code]：$message"
        }
    }

    private fun buildExceptionMessage(error: Exception, sdkError: TmkTranslationException?): String {
        val message = error.message?.takeIf { it.isNotBlank() } ?: "未提供错误信息"
        if (sdkError?.actualErrorCode == null && sdkError?.actualErrorMessage == null) {
            return message
        }
        val domain = sdkError.actualErrorDomain?.let { " $it" } ?: ""
        val actualCode = sdkError.actualErrorCode?.toString() ?: "unknown"
        val actualMessage = sdkError.actualErrorMessage ?: ""
        return "$message\n底层错误[$actualCode$domain]：$actualMessage"
    }
}
