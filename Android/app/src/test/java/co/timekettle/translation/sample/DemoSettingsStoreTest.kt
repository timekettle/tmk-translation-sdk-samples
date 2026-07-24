package co.timekettle.translation.sample

import co.timekettle.translation.config.TmkTranslationNetworkEnvironment
import org.junit.Assert.assertEquals
import org.junit.Test

class DemoSettingsStoreTest {

    @Test
    fun parseNetworkEnvironment_defaultsToTestForBlankOrUnknownValues() {
        assertEquals(TmkTranslationNetworkEnvironment.TEST, DemoSettingsStore.parseNetworkEnvironment(null))
        assertEquals(TmkTranslationNetworkEnvironment.TEST, DemoSettingsStore.parseNetworkEnvironment(""))
        assertEquals(TmkTranslationNetworkEnvironment.TEST, DemoSettingsStore.parseNetworkEnvironment("prod"))
    }

    @Test
    fun parseNetworkEnvironment_acceptsStoredEnumName() {
        assertEquals(TmkTranslationNetworkEnvironment.PRE, DemoSettingsStore.parseNetworkEnvironment("PRE"))
    }

    @Test
    fun parseNetworkEnvironment_rejectsRemovedEnvironmentNames() {
        assertEquals(TmkTranslationNetworkEnvironment.TEST, DemoSettingsStore.parseNetworkEnvironment("PRE_US"))
        assertEquals(TmkTranslationNetworkEnvironment.TEST, DemoSettingsStore.parseNetworkEnvironment("UAT"))
    }

    @Test
    fun normalizeCustomNetworkBaseURL_acceptsRayneoStyleURL() {
        assertEquals(
            "https://api-rayneo.timekettle.co",
            DemoSettingsStore.normalizeCustomNetworkBaseURL(" https://api-rayneo.timekettle.co ")
        )
    }

    @Test
    fun normalizeCustomNetworkBaseURL_rejectsInvalidOrNonRootURL() {
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL(null))
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL(""))
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL("api-rayneo.timekettle.co"))
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL("ftp://api-rayneo.timekettle.co"))
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL("https://api-rayneo.timekettle.co/apis"))
        assertEquals(null, DemoSettingsStore.normalizeCustomNetworkBaseURL("https://api-rayneo.timekettle.co?debug=true"))
    }
}
