package co.timekettle.translation.sample

import co.timekettle.translation.enums.TmkDialogConversationAudioMode
import co.timekettle.translation.enums.TmkOfflineAudioChannelMode
import co.timekettle.translation.enums.TmkOnlineRecognizeEngine
import co.timekettle.translation.enums.TmkOnlineTranslateEngine
import co.timekettle.translation.enums.TmkRoomScenario
import co.timekettle.translation.enums.TmkTranslateDeliveryMode
import co.timekettle.sdk.common.models.SpeakerGender

/** 一对一页面共享的默认值；只描述 Demo 配置，不持有 Room、Channel 或系统资源。 */
object OneToOneDemoDefaults {
    const val sampleRate = 16_000
    const val channelCount = 2

    val online = OnlineProfile()
    val offline = OfflineProfile()

    /** Concurrent 的跨平台契约默认值；不改变既有在线/离线页面的历史默认值。 */
    val concurrentOnline = online.copy(
        leftSpeaker = SpeakerGender.MALE,
        rightSpeaker = SpeakerGender.FEMALE,
        translateEngine = TmkOnlineTranslateEngine.FAST,
    )
    val concurrentOffline = offline.copy(
        leftSpeaker = SpeakerGender.MALE,
        rightSpeaker = SpeakerGender.FEMALE,
    )

    data class OnlineProfile(
        val leftSpeaker: SpeakerGender = SpeakerGender.MALE,
        val rightSpeaker: SpeakerGender = SpeakerGender.FEMALE,
        val translateEngine: TmkOnlineTranslateEngine = TmkOnlineTranslateEngine.ACCURATE,
        val recognizeEngine: TmkOnlineRecognizeEngine = TmkOnlineRecognizeEngine.DEFAULT,
        val translateMode: TmkTranslateDeliveryMode = TmkTranslateDeliveryMode.DEFAULT,
        val roomScenario: TmkRoomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH,
        val audioMode: TmkDialogConversationAudioMode = TmkDialogConversationAudioMode.STANDARD,
    )

    data class OfflineProfile(
        val leftSpeaker: SpeakerGender = SpeakerGender.FEMALE,
        val rightSpeaker: SpeakerGender = SpeakerGender.MALE,
        val translateMode: TmkTranslateDeliveryMode = TmkTranslateDeliveryMode.PARTIAL,
        val roomScenario: TmkRoomScenario = TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH,
        // 与 iOS `.standard` 相同：输出混合双声道；低延迟模式再改为 MONO。
        val audioMode: TmkOfflineAudioChannelMode = TmkOfflineAudioChannelMode.STEREO,
    )
}
