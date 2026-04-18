import Foundation
import TmkTranslationSDK

final class DemoLingCastAspect {
    func updateLanguages(source: String, target: String) {}
    func updateModeName(_ modeName: String) {}
    func updateTransEngineName(_ transEngineName: String) {}
    func setTraceReportingEnabled(_ enabled: Bool) {}
    func onCreateRoomStarted() {}
    func onCreateRoomFinished(roomNo: String, error: Error?) {}
    func onJoinRoomStarted() {}
    func onJoinRoomFinished(error: Error?) {}
    func onSubscribeStarted() {}
    func onSubscribeFinished(error: Error?) {}
    func onSDKError(_ error: TmkTranslationError) {}
    func onEvent(name: String, args: Any?) {}
    func onTraceStarted(traceId: String?) {}
    func onConversationEnd() {}
}
