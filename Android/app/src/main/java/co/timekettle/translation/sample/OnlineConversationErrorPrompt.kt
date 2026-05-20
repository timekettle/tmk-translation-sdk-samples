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
            TmkTranslationException.ErrorCodes.SESSION_EXPIRED -> restartPrompt(
                id = "session_expired_$code",
                title = "会话已过期",
                message = "当前对话 token 已失效，需要重新鉴权并$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.NETWORK_UNAVAILABLE,
            TmkTranslationException.ErrorCodes.NETWORK_TRANSPORT_ERROR -> restartPrompt(
                id = "network_$code",
                title = "连接已断开",
                message = "连接已断开或网络不可用。请确认网络恢复后$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.RTC_OPERATION_FAILED,
            TmkTranslationException.ErrorCodes.CHANNEL_CREATION_FAILED,
            TmkTranslationException.ErrorCodes.AUDIO_CHANNEL_CREATION_FAILED -> restartPrompt(
                id = "channel_$code",
                title = "通道连接失败",
                message = "当前通道无法继续使用，需要释放资源并$actionText。\n\n错误[$code]：$message",
                restartText = restartText,
            )

            TmkTranslationException.ErrorCodes.INVALID_CONFIGURATION,
            TmkTranslationException.ErrorCodes.AUTHENTICATION_FAILED -> restartPrompt(
                id = "fatal_$code",
                title = "对话无法继续",
                message = "当前配置或鉴权信息无效，无法继续启动对话。\n\n错误[$code]：$message"
            )

            TmkTranslationException.ErrorCodes.OFFLINE_MODEL_NOT_READY -> restartPrompt(
                id = "offline_model_$code",
                title = "离线模型未就绪",
                message = "当前离线模型缺失、需要更新或离线能力不可用。请先下载/更新模型或重新鉴权。\n\n错误[$code]：$message",
                restartText = "重新检查",
            )

            else -> fromReason(reason, message, code, mode)
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

    private fun restartText(mode: RuntimeMode): String {
        return if (mode == RuntimeMode.OFFLINE) "重新初始化" else "重新创建"
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
}
