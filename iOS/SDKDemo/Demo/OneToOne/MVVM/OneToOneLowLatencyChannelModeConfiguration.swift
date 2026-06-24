import Foundation
import TmkTranslationSDK

struct OneToOneLowLatencyChannelModeConfiguration: OneToOneChannelModeConfiguration {
    let audioMode: TmkDialogConversationAudioMode = .lowLatency
    let pcmChannels = 1

    func makeInputAudioPushPlan(fileData: Data, rightMicData: Data) -> [OneToOneChannelAudioPushPlan] {
        [
            OneToOneChannelAudioPushPlan(data: fileData,
                                         destination: .speaker(.left)),
            OneToOneChannelAudioPushPlan(data: rightMicData,
                                         destination: .speaker(.right))
        ].filter { $0.data.isEmpty == false }
    }
}
