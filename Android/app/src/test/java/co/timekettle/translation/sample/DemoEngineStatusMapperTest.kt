package co.timekettle.translation.sample

import org.junit.Assert.assertEquals
import org.junit.Test

class DemoEngineStatusMapperTest {

    @Test
    fun fromAuthSuccess_marksOnlineAvailableAndOfflineAvailableWhenCapabilityEnabled() {
        val snapshot = DemoEngineStatusMapper.fromAuthResult(
            authSuccess = true,
            offlineSupported = true,
            errorMessage = null,
        )

        assertEquals(DemoEngineStatusKind.AVAILABLE, snapshot.online.kind)
        assertEquals("可用", snapshot.online.summary)
        assertEquals(DemoEngineStatusKind.AVAILABLE, snapshot.offline.kind)
        assertEquals("离线翻译已开通", snapshot.offline.detail)
    }

    @Test
    fun fromAuthSuccess_marksOfflineUnavailableWhenAccountHasNoOfflineCapability() {
        val snapshot = DemoEngineStatusMapper.fromAuthResult(
            authSuccess = true,
            offlineSupported = false,
            errorMessage = null,
        )

        assertEquals(DemoEngineStatusKind.AVAILABLE, snapshot.online.kind)
        assertEquals(DemoEngineStatusKind.UNAVAILABLE, snapshot.offline.kind)
        assertEquals("当前账号未开通离线翻译", snapshot.offline.detail)
    }

    @Test
    fun fromAuthFailure_marksOfflineDependentOnAuth() {
        val snapshot = DemoEngineStatusMapper.fromAuthResult(
            authSuccess = false,
            offlineSupported = false,
            errorMessage = "Authentication failed",
        )

        assertEquals(DemoEngineStatusKind.UNAVAILABLE, snapshot.online.kind)
        assertEquals("Authentication failed", snapshot.online.detail)
        assertEquals(DemoEngineStatusKind.UNAVAILABLE, snapshot.offline.kind)
        assertEquals("依赖鉴权结果", snapshot.offline.detail)
    }
}
