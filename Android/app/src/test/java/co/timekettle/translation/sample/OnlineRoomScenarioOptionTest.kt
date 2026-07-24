package co.timekettle.translation.sample

import co.timekettle.translation.enums.TmkRoomScenario
import org.junit.Assert.assertEquals
import org.junit.Test

class OnlineRoomScenarioOptionTest {
    @Test
    fun optionsExposeDemoTitlesAndRoomScenarioValues() {
        assertEquals("语音到语音", OnlineRoomScenarioOption.SPEECH_TO_SPEECH.title)
        assertEquals(TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH, OnlineRoomScenarioOption.SPEECH_TO_SPEECH.roomScenario)

        assertEquals("单识别", OnlineRoomScenarioOption.RECOGNIZE.title)
        assertEquals(TmkRoomScenario.RECOGNIZE, OnlineRoomScenarioOption.RECOGNIZE.roomScenario)

        assertEquals("语音到文本", OnlineRoomScenarioOption.SPEECH_TO_TEXT.title)
        assertEquals(TmkRoomScenario.TRANSLATE_SPEECH_TO_TEXT, OnlineRoomScenarioOption.SPEECH_TO_TEXT.roomScenario)
    }

    @Test
    fun defaultOptionKeepsSpeechToSpeech() {
        assertEquals(OnlineRoomScenarioOption.SPEECH_TO_SPEECH, OnlineRoomScenarioOption.defaultOption)
    }
}
