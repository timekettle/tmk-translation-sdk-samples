package co.timekettle.translation.sample

enum class DemoEngineStatusKind {
    CHECKING,
    AVAILABLE,
    UNAVAILABLE,
}

data class DemoEngineStatus(
    val kind: DemoEngineStatusKind,
    val summary: String,
    val detail: String,
) {
    companion object {
        val CHECKING = DemoEngineStatus(
            kind = DemoEngineStatusKind.CHECKING,
            summary = "检查中",
            detail = "正在调用鉴权接口",
        )
    }
}

data class DemoRuntimeStatusSnapshot(
    val online: DemoEngineStatus,
    val offline: DemoEngineStatus,
)

object DemoEngineStatusMapper {
    fun fromAuthResult(
        authSuccess: Boolean,
        offlineSupported: Boolean,
        errorMessage: String?,
    ): DemoRuntimeStatusSnapshot {
        return if (authSuccess) {
            DemoRuntimeStatusSnapshot(
                online = DemoEngineStatus(
                    kind = DemoEngineStatusKind.AVAILABLE,
                    summary = "可用",
                    detail = "鉴权成功",
                ),
                offline = if (offlineSupported) {
                    DemoEngineStatus(
                        kind = DemoEngineStatusKind.AVAILABLE,
                        summary = "可用",
                        detail = "离线翻译已开通",
                    )
                } else {
                    DemoEngineStatus(
                        kind = DemoEngineStatusKind.UNAVAILABLE,
                        summary = "不可用",
                        detail = "当前账号未开通离线翻译",
                    )
                },
            )
        } else {
            val detail = errorMessage?.takeIf { it.isNotBlank() } ?: "鉴权失败"
            DemoRuntimeStatusSnapshot(
                online = DemoEngineStatus(
                    kind = DemoEngineStatusKind.UNAVAILABLE,
                    summary = "不可用",
                    detail = detail,
                ),
                offline = DemoEngineStatus(
                    kind = DemoEngineStatusKind.UNAVAILABLE,
                    summary = "不可用",
                    detail = "依赖鉴权结果",
                ),
            )
        }
    }
}
