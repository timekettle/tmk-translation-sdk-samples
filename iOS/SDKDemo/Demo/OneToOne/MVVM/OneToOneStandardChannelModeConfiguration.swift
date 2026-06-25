import Foundation
import TmkTranslationSDK

struct OneToOneStandardChannelModeConfiguration: OneToOneChannelModeConfiguration {
    let audioMode: TmkDialogConversationAudioMode = .standard
    let pcmChannels = 2

    func makeInputAudioPushPlan(fileData: Data, rightMicData: Data) -> [OneToOneChannelAudioPushPlan] {
        let mixed = TmkTranslationPCMTools.mixStereo16LE(left: fileData, right: rightMicData) ?? Data()
        guard mixed.isEmpty == false else { return [] }
        return [
            OneToOneChannelAudioPushPlan(data: mixed,
                                         destination: .interleaved(channelCount: pcmChannels))
        ]
    }
}
