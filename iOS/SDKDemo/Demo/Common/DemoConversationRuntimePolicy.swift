import Foundation
import TmkTranslationSDK

struct DemoConversationPrompt: Equatable {
    enum Style: Equatable {
        case restart
        case leaveOnly
        case reconnectTimeout
    }

    let title: String
    let message: String
    let style: Style
}

enum DemoConversationPromptPresentationPolicy {
    static func shouldReplace(current: DemoConversationPrompt?,
                              with incoming: DemoConversationPrompt) -> Bool {
        guard let current else { return true }
        guard current != incoming else { return false }
        if current.style == .reconnectTimeout { return true }
        return incoming.style != .reconnectTimeout
    }
}

protocol DemoReconnectTimeoutTask: AnyObject {
    func cancel()
}

protocol DemoReconnectTimeoutScheduling {
    func schedule(after delay: TimeInterval,
                  action: @escaping () -> Void) -> DemoReconnectTimeoutTask
}

private final class DemoDispatchReconnectTimeoutTask: DemoReconnectTimeoutTask {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private struct DemoDispatchReconnectTimeoutScheduler: DemoReconnectTimeoutScheduling {
    func schedule(after delay: TimeInterval,
                  action: @escaping () -> Void) -> DemoReconnectTimeoutTask {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return DemoDispatchReconnectTimeoutTask(workItem: workItem)
    }
}

/// Demo 侧持续重连超时监控：只观察 SDK 状态，不主动干预 SDK 重连。
final class DemoReconnectTimeoutMonitor {
    var onPromptRequired: (() -> Void)?
    var onPromptDismissRequired: (() -> Void)?

    private let timeout: TimeInterval
    private let scheduler: DemoReconnectTimeoutScheduling
    private var timeoutTask: DemoReconnectTimeoutTask?
    private var isReconnecting = false
    private var isPromptVisible = false

    init(timeout: TimeInterval = 60,
         scheduler: DemoReconnectTimeoutScheduling? = nil) {
        self.timeout = timeout
        self.scheduler = scheduler ?? DemoDispatchReconnectTimeoutScheduler()
    }

    func handle(isRTMReconnecting: Bool) {
        performOnMain { [weak self] in
            self?.handleOnMain(isRTMReconnecting: isRTMReconnecting)
        }
    }

    func continueWaiting() {
        performOnMain { [weak self] in
            guard let self else { return }
            self.isPromptVisible = false
            self.cancelTimer()
            self.scheduleTimerIfNeeded()
        }
    }

    func confirmRecreation() {
        performOnMain { [weak self] in
            self?.reset(dismissPrompt: false)
        }
    }

    func cancel() {
        performOnMain { [weak self] in
            self?.reset(dismissPrompt: true)
        }
    }

    private func handleOnMain(isRTMReconnecting: Bool) {
        if isRTMReconnecting {
            isReconnecting = true
            scheduleTimerIfNeeded()
            return
        }

        isReconnecting = false
        cancelTimer()
        if isPromptVisible {
            isPromptVisible = false
            onPromptDismissRequired?()
        }
    }

    private func scheduleTimerIfNeeded() {
        guard isReconnecting, isPromptVisible == false, timeoutTask == nil else { return }
        timeoutTask = scheduler.schedule(after: timeout) { [weak self] in
            guard let self else { return }
            self.timeoutTask = nil
            guard self.isReconnecting, self.isPromptVisible == false else { return }
            self.isPromptVisible = true
            self.onPromptRequired?()
        }
    }

    private func cancelTimer() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func reset(dismissPrompt: Bool) {
        isReconnecting = false
        cancelTimer()
        if isPromptVisible {
            isPromptVisible = false
            if dismissPrompt {
                onPromptDismissRequired?()
            }
        }
    }

    private func performOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}

enum DemoConversationRuntimeAction: Equatable {
    case none
    case ignore
    case status(String)
    case weakNetwork(String)
    case reconnecting(String)
    case prompt(DemoConversationPrompt)
}

enum DemoRTMReconnectTimeoutStatePolicy {
    static func reconnecting(from snapshot: TmkTranslationChannelStateSnapshot) -> Bool? {
        if snapshot.reason == .messageChannelFailure {
            if snapshot.state == .reconnecting { return true }
            if snapshot.state == .failed { return false }
        }
        if snapshot.message.hasPrefix("rtm connected") {
            return false
        }
        return nil
    }
}

enum DemoConversationRuntimePolicy {
    private enum OfflineAuthCode {
        static let emptyContent = 2_004_101
        static let decryptOrParseFailed = 2_004_102
        static let signatureInvalid = 2_004_103
        static let clientPackageOrDeviceMismatch = 2_004_104
        static let modelKeyEmpty = 2_004_105
        static let expiredOrNotYetValid = 2_004_106
        static let unsupported = 2_004_107
        static let unauthorizedScopeOrModel = 2_004_108
        static let internalError = 2_004_199
    }

    /// - Parameter isListening: Demo 当前是否正处于收音中。用于区分 `.running` 状态下
    ///   的文案语义:收音过程中 RTC 自动重连恢复(reason=.rtcConnected)时,应保持
    ///   "正在收听中..."而非退回"点击开始收听"的就绪态文案,避免状态栏与实际收音状态不一致。
    static func action(for snapshot: TmkTranslationChannelStateSnapshot,
                       readyMessage: String = "在线通道已就绪，点击“开始收听”开始采集",
                       isListening: Bool = false) -> DemoConversationRuntimeAction {
        switch snapshot.state {
        case .idle:
            return .status("通道未启动")
        case .starting:
            return .status("通道连接中...")
        case .running:
            // 收音过程中连接恢复(含 RTC 自动重连成功):状态栏保持"收听中"语义,
            // 不覆盖为就绪态文案,确保与实际收音状态一致。
            if isListening {
                return .status("正在收听中...")
            }
            return .status(snapshot.reason == .networkRestored ? "连接已恢复" : readyMessage)
        case .degraded:
            return .weakNetwork("当前网络不稳定，翻译可能延迟")
        case .reconnecting:
            return .reconnecting("连接恢复中...")
        case .stopping:
            return .status("通道停止中...")
        case .stopped:
            return .status("通道已停止")
        case .failed:
            return failedAction(reason: snapshot.reason,
                                code: snapshot.code,
                                message: snapshot.message,
                                isRecoverable: snapshot.isRecoverable)
        }
    }

    static func action(for error: TmkTranslationError) -> DemoConversationRuntimeAction {
        action(forCode: error.code,
               message: error.message,
               constantName: error.constantName,
               actualCode: error.actualErrorCode,
               actualMessage: error.actualErrorMessage)
    }

    static func action(forCode code: Int, message: String) -> DemoConversationRuntimeAction {
        action(forCode: code,
               message: message,
               constantName: nil,
               actualCode: nil,
               actualMessage: nil)
    }

    private static func action(forCode code: Int,
                               message: String,
                               constantName: String?,
                               actualCode: Int?,
                               actualMessage: String?) -> DemoConversationRuntimeAction {
        let detail = buildErrorMessage(code: code,
                                       name: constantName,
                                       message: message,
                                       actualCode: actualCode,
                                       actualMessage: actualMessage)
        switch code {
        case TmkSDKErrorCode.requestCancelled.rawValue,
             TmkSDKErrorCode.trackEventNotConfigured.rawValue,
             TmkSDKErrorCode.trackEventInvalidEventName.rawValue:
            return .ignore
        case TmkSDKErrorCode.networkUnavailable.rawValue:
            return .reconnecting("网络不可用，连接恢复中...")
        case TmkSDKErrorCode.authenticationFailed.rawValue:
            if isOfflineAuthCode(actualCode) {
                return .prompt(.init(title: "离线鉴权失败",
                                     message: "\(offlineAuthMessage(for: actualCode))\n\n\(detail)",
                                     style: .leaveOnly))
            }
            return .prompt(.init(title: "鉴权失败",
                                 message: "请重新鉴权后再创建对话。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.ttsSynthesisError.rawValue,
             TmkSDKErrorCode.translationError.rawValue,
             TmkSDKErrorCode.messageDecodingFailed.rawValue:
            return .weakNetwork("当前对话部分结果异常，可继续使用")
        case TmkSDKErrorCode.sessionExpired.rawValue:
            return .prompt(.init(title: "会话已过期",
                                 message: "当前对话 token 已失效，需要重新鉴权并创建新的对话。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.offlineModelNotReady.rawValue:
            return .prompt(.init(title: "离线资源未就绪",
                                 message: "请先下载或更新离线模型；如果模型已就绪，请重新鉴权后再启动离线通道。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.roomCreationFailed.rawValue:
            return .prompt(.init(title: "房间创建失败",
                                 message: "当前在线房间创建失败，可以重新创建对话。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.channelCreationFailed.rawValue:
            return .prompt(.init(title: "通道创建失败",
                                 message: "当前通道无法完成启动，可以重新创建或重新初始化。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.engineInitializationFailed.rawValue:
            return .prompt(.init(title: "引擎初始化失败",
                                 message: "当前引擎启动失败，可以重新初始化；如果多次失败，请检查离线资源完整性。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.networkTransportError.rawValue:
            return .prompt(.init(title: "网络请求失败",
                                 message: "当前网络请求失败，可以检查网络后重试。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.networkHTTPStatusError.rawValue:
            // 旧的通用 HTTP 错误码（2002003），已被细分码取代，此分支保留作兜底
            if actualCode == 401 || actualCode == 403 {
                return .prompt(.init(title: "鉴权已失效",
                                     message: "服务端拒绝当前鉴权信息，请重新鉴权后再使用。\n\n\(detail)",
                                     style: .leaveOnly))
            }
            return .prompt(.init(title: "服务请求失败",
                                 message: "服务端返回异常状态，可以稍后重试。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.networkBusinessError.rawValue:
            // 旧的通用后台业务错误码（2002005），已被细分码取代，此分支保留作兜底
            return .prompt(.init(title: "服务端拒绝请求",
                                 message: "服务端返回业务错误，请按错误信息处理后重试。\n\n\(detail)",
                                 style: actualCode == 401 || actualCode == 403 ? .leaveOnly : .restart))

        // ── HTTP 状态码细分（2002400-2002599 = 2002000 + statusCode）────────────────
        case 2002400...2002599:
            let httpStatus = code - 2002000
            if httpStatus == 401 || httpStatus == 403 {
                return .prompt(.init(title: "鉴权已失效",
                                     message: "服务端拒绝当前鉴权信息，请重新鉴权后再使用。\n\n\(detail)",
                                     style: .leaveOnly))
            } else if httpStatus >= 500 {
                return .prompt(.init(title: "服务请求失败",
                                     message: "服务端返回异常状态，可以稍后重试。\n\n\(detail)",
                                     style: .restart))
            } else {
                return .prompt(.init(title: "服务请求失败",
                                     message: "请求参数有误，请按错误信息处理后重试。\n\n\(detail)",
                                     style: .restart))
            }

        // ── 后台业务码细分（2005xxx/2006xxx/2007xxx = 2004000 + 后台码）─────────────
        case 2005000...2007999:
            return .prompt(.init(title: "服务端拒绝请求",
                                 message: "服务端返回业务错误，请按错误信息处理后重试。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.audioProcessingError.rawValue,
             TmkSDKErrorCode.bufferOverflow.rawValue,
             TmkSDKErrorCode.audioChannelCreationFailed.rawValue:
            return .prompt(.init(title: "音频通道异常",
                                 message: "当前音频链路无法继续，可以重新创建或重新初始化。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.rtcBannedByServer.rawValue,
             TmkSDKErrorCode.rtcUserBanned.rawValue:
            return .prompt(.init(title: "对话已被服务端终止",
                                 message: "当前账号或对话已被服务端封禁，无法继续使用。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.rtcRejectedByServer.rawValue:
            return .prompt(.init(title: "对话被服务端拒绝",
                                 message: "服务端拒绝了当前对话，无法继续使用。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.rtcJoinFailed.rawValue:
            return .prompt(.init(title: "加入频道失败",
                                 message: "当前无法加入实时频道，可以重新创建对话或检查网络。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.threadInterrupted.rawValue,
             TmkSDKErrorCode.invalidState.rawValue,
             TmkSDKErrorCode.rtcOperationFailed.rawValue,
             TmkSDKErrorCode.unknownError.rawValue:
            return .prompt(.init(title: "通道异常",
                                 message: "当前对话通道无法继续使用，需要重新创建或重新初始化。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.quotaExceeded.rawValue:
            return .prompt(.init(title: "配额不足",
                                 message: "当前服务配额不足，无法继续对话。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.networkInvalidURL.rawValue:
            return .prompt(.init(title: "网络配置错误",
                                 message: "当前后台地址或下载地址配置无效，无法继续使用。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.networkResponseDecodingError.rawValue:
            return .prompt(.init(title: "服务响应异常",
                                 message: "服务端响应、模型清单或语言列表解析失败。\n\n\(detail)",
                                 style: .leaveOnly))
        case TmkSDKErrorCode.invalidConfiguration.rawValue,
             TmkSDKErrorCode.sdkNotInitialized.rawValue,
             TmkSDKErrorCode.engineNotSupported.rawValue,
             TmkSDKErrorCode.invalidLanguageCode.rawValue,
             TmkSDKErrorCode.dependencyUnavailable.rawValue:
            return .prompt(.init(title: "对话无法继续",
                                 message: "当前配置、语言、SDK 状态或依赖不满足启动条件。\n\n\(detail)",
                                 style: .leaveOnly))
        default:
            return .prompt(.init(title: "通道异常",
                                 message: "当前对话通道无法继续使用，需要重新创建。\n\n\(detail)",
                                 style: .restart))
        }
    }

    static func isCloseRoomEvent(name: String, args: Any?) -> Bool {
        guard name == "online_notification" || name == "notification" || name == "room_closed" else {
            return false
        }
        if name == "room_closed" {
            return true
        }
        if let result = args as? TmkResult<String> {
            return isCloseRoomExtraData(result.extraData)
        }
        if let extraData = args as? [String: Any] {
            return isCloseRoomExtraData(extraData)
        }
        return false
    }

    private static func failedAction(reason: TmkTranslationChannelStateReason,
                                     code: Int?,
                                     message: String,
                                     isRecoverable: Bool) -> DemoConversationRuntimeAction {
        if let code, shouldPreferCodeActionInFailedState(code) {
            return action(forCode: code, message: message)
        }

        switch reason {
        case .sessionExpired:
            return .prompt(.init(title: "会话已过期",
                                 message: buildMessage("当前会话已失效，需要重新鉴权并创建新的对话。", code: code, message: message),
                                 style: .restart))
        case .serviceRejected, .rtcKeepAliveTimeout, .rtcLost, .messageChannelFailure, .engineError:
            return .prompt(.init(title: "通道异常",
                                 message: buildMessage("当前对话通道无法继续使用，需要重新创建。", code: code, message: message),
                                 style: isRecoverable ? .restart : .leaveOnly))
        case .invalidConfiguration:
            return .prompt(.init(title: "配置错误",
                                 message: buildMessage("当前配置无效，无法继续对话。", code: code, message: message),
                                 style: .leaveOnly))
        case .permissionDenied:
            return .prompt(.init(title: "权限不足",
                                 message: buildMessage("当前缺少必要权限，无法继续对话。", code: code, message: message),
                                 style: .leaveOnly))
        case .bannedByServer:
            return .prompt(.init(title: "对话不可用",
                                 message: buildMessage("服务端已拒绝当前对话，无法继续使用。", code: code, message: message),
                                 style: .leaveOnly))
        default:
            return .prompt(.init(title: "通道异常",
                                 message: buildMessage("当前对话通道异常，需要重新创建。", code: code, message: message),
                                 style: .restart))
        }
    }

    private static func shouldPreferCodeActionInFailedState(_ code: Int) -> Bool {
        switch code {
        case TmkSDKErrorCode.requestCancelled.rawValue,
             TmkSDKErrorCode.authenticationFailed.rawValue,
             TmkSDKErrorCode.sessionExpired.rawValue,
             TmkSDKErrorCode.offlineModelNotReady.rawValue,
             TmkSDKErrorCode.networkInvalidURL.rawValue,
             TmkSDKErrorCode.networkHTTPStatusError.rawValue,
             TmkSDKErrorCode.networkBusinessError.rawValue,
             TmkSDKErrorCode.networkResponseDecodingError.rawValue,
             TmkSDKErrorCode.quotaExceeded.rawValue:
            return true
        // HTTP 状态码细分段（2002400-2002599）和后台业务码细分段（2005xxx-2007xxx）
        // 同样需要优先产出具体弹窗，不被 failed reason 吞掉
        case 2002400...2002599, 2005000...2007999:
            return true
        // 声网 RTC 细分码（banned/join/rejected/userBanned）在 failed 状态下也优先产出具体弹窗
        case TmkSDKErrorCode.rtcBannedByServer.rawValue,
             TmkSDKErrorCode.rtcJoinFailed.rawValue,
             TmkSDKErrorCode.rtcRejectedByServer.rawValue,
             TmkSDKErrorCode.rtcUserBanned.rawValue:
            return true
        default:
            return false
        }
    }

    private static func isCloseRoomExtraData(_ extraData: [String: Any]) -> Bool {
        let kind = eventValue(extraData["kind"])
        let event = eventValue(extraData["event"])
        let eventType = eventValue(extraData["event_type"])
        return kind == "close_room" &&
            (event == "notification" || event == "notify" || eventType == "notification")
    }

    private static func eventValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string.lowercased()
        }
        if let value {
            return String(describing: value).lowercased()
        }
        return ""
    }

    private static func buildMessage(_ prefix: String, code: Int?, message: String) -> String {
        guard let code else {
            return message.isEmpty ? prefix : "\(prefix)\n\n\(message)"
        }
        return "\(prefix)\n\n错误[\(code)]：\(message)"
    }

    private static func buildErrorMessage(code: Int,
                                          name: String?,
                                          message: String,
                                          actualCode: Int?,
                                          actualMessage: String?) -> String {
        var parts = ["错误[\(code)\(name.map { " \($0)" } ?? "")]：\(message)"]
        if let actualCode {
            parts.append("底层错误[\(actualCode)]：\(actualMessage ?? "")")
        } else if let actualMessage, actualMessage.isEmpty == false {
            parts.append("底层错误：\(actualMessage)")
        }
        return parts.joined(separator: "\n")
    }

    private static func isOfflineAuthCode(_ code: Int?) -> Bool {
        guard let code else {
            return false
        }
        return (OfflineAuthCode.emptyContent...OfflineAuthCode.unauthorizedScopeOrModel).contains(code)
            || code == OfflineAuthCode.internalError
    }

    private static func offlineAuthMessage(for code: Int?) -> String {
        switch code {
        case OfflineAuthCode.emptyContent:
            return "离线 License 内容为空，请重新鉴权。"
        case OfflineAuthCode.decryptOrParseFailed:
            return "离线 License 解密或解析失败，请清空本地 License 后重新鉴权。"
        case OfflineAuthCode.signatureInvalid:
            return "离线 License 签名无效，请重新鉴权。"
        case OfflineAuthCode.clientPackageOrDeviceMismatch:
            return "当前 client、包名或设备绑定与 License 不匹配，请检查 Demo bundleId/clientId 后重新鉴权。"
        case OfflineAuthCode.modelKeyEmpty:
            return "离线 License 缺少模型密钥，请重新鉴权或联系服务端排查。"
        case OfflineAuthCode.expiredOrNotYetValid:
            return "离线 License 已过期或尚未生效，请联网重新鉴权。"
        case OfflineAuthCode.unsupported:
            return "当前 License 版本或算法不支持，请更新 SDK/离线库后重试。"
        case OfflineAuthCode.unauthorizedScopeOrModel:
            return "当前账号未授权离线 scope 或模型，请确认离线能力后重新鉴权。"
        case OfflineAuthCode.internalError:
            return "离线 License 鉴权内部错误，请重新鉴权或导出诊断日志。"
        default:
            return "离线 License 鉴权失败，请重新鉴权。"
        }
    }
}

final class DemoOnlineNetworkEventPolicy {
    private var weakNetworkCount = 0
    private var severeNetworkCount = 0
    private var packetLossCount = 0

    func action(forEvent name: String, args: Any?) -> DemoConversationRuntimeAction {
        switch name {
        case "online_network_quality":
            return actionForNetworkQuality(extraData(from: args))
        case "online_rtc_stats",
             "online_remote_audio_stats",
             "online_local_audio_stats":
            return actionForPacketLoss(extraData(from: args))
        default:
            return .none
        }
    }

    private func actionForNetworkQuality(_ extraData: [String: Any]) -> DemoConversationRuntimeAction {
        let txQuality = intValue(extraData["tx_quality"])
        let rxQuality = intValue(extraData["rx_quality"])
        let worstQuality = max(txQuality, rxQuality)
        guard worstQuality > 0 else { return .none }

        if worstQuality >= 6 {
            severeNetworkCount += 1
            weakNetworkCount = 0
            return severeNetworkCount >= 2 ? .reconnecting("网络连接异常，正在恢复...") : .none
        }
        severeNetworkCount = 0

        if worstQuality >= 4 {
            weakNetworkCount += 1
            return weakNetworkCount >= 3 ? .weakNetwork("当前网络较差，翻译可能延迟") : .none
        }
        if worstQuality >= 3 {
            weakNetworkCount += 1
            return weakNetworkCount >= 3 ? .weakNetwork("当前网络不稳定，翻译可能延迟") : .none
        }

        weakNetworkCount = 0
        return .none
    }

    private func actionForPacketLoss(_ extraData: [String: Any]) -> DemoConversationRuntimeAction {
        let packetLoss = [
            intValue(extraData["tx_packet_loss_rate"]),
            intValue(extraData["rx_packet_loss_rate"]),
            intValue(extraData["audio_loss_rate"])
        ].max() ?? 0

        if packetLoss >= 25 {
            packetLossCount += 1
            return packetLossCount >= 2 ? .reconnecting("音频网络丢包严重，正在恢复...") : .none
        }
        if packetLoss >= 10 {
            packetLossCount += 1
            return packetLossCount >= 3 ? .weakNetwork("当前音频网络不稳定，翻译可能延迟") : .none
        }

        packetLossCount = 0
        return .none
    }

    private func extraData(from args: Any?) -> [String: Any] {
        if let result = args as? TmkResult<String> {
            return result.extraData
        }
        if let extraData = args as? [String: Any] {
            return extraData
        }
        return [:]
    }

    private func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let uintValue = value as? UInt { return Int(uintValue) }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let floatValue = value as? Float { return Int(floatValue) }
        if let stringValue = value as? String { return Int(stringValue) ?? 0 }
        return 0
    }
}

// MARK: - Demo Network Loss Overlay (Host App Side)
// 对齐时空壶 LC_SHOW_NETWORK：只展示上丢 / 下丢。

struct DemoOnlineNetworkStatsSnapshot: Equatable {
    /// 上行丢包率（%），对应时空壶「上丢」
    var txLossRate: Int? = nil
    /// 下行丢包率（%），对应时空壶「下丢」
    var rxLossRate: Int? = nil

    func formatLoss(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)%"
    }
}

final class DemoOnlineNetworkStatsTracker {
    private var snapshot = DemoOnlineNetworkStatsSnapshot()

    func current() -> DemoOnlineNetworkStatsSnapshot {
        snapshot
    }

    @discardableResult
    func reset() -> DemoOnlineNetworkStatsSnapshot {
        snapshot = DemoOnlineNetworkStatsSnapshot()
        return snapshot
    }

    func consume(eventName: String, args: Any?) -> DemoOnlineNetworkStatsSnapshot? {
        let extra = extraData(from: args)
        switch eventName {
        case "online_remote_audio_stats":
            snapshot.rxLossRate = Self.intValueOrNull(extra["audio_loss_rate"])
            return snapshot

        case "online_local_audio_stats":
            snapshot.txLossRate = Self.intValueOrNull(extra["audio_loss_rate"])
            return snapshot

        default:
            return nil
        }
    }

    private func extraData(from args: Any?) -> [String: Any] {
        if let result = args as? TmkResult<String> {
            return result.extraData
        }
        if let dict = args as? [String: Any] {
            return dict
        }
        return [:]
    }

    private static func intValueOrNull(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let intValue = value as? Int { return intValue }
        if let uintValue = value as? UInt { return Int(uintValue) }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let floatValue = value as? Float { return Int(floatValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }
}

// MARK: - Demo Bootstrap Pipeline (Host App Side)
// 鉴权 → 建房 → 建通道 → 就绪，与 Android Demo 对齐。

enum DemoBootstrapStage: CaseIterable, Equatable {
    case auth
    case createRoom
    case createChannel
    case channelReady

    var label: String {
        switch self {
        case .auth: return "鉴权"
        case .createRoom: return "建房"
        case .createChannel: return "建通道"
        case .channelReady: return "就绪"
        }
    }
}

enum DemoBootstrapNodeStatus: Equatable {
    case pending
    case running
    case done
    case failed
}

struct DemoBootstrapNodeSnapshot: Equatable {
    var stage: DemoBootstrapStage
    var status: DemoBootstrapNodeStatus = .pending
    var durationMs: Int64? = nil
    var startedAtMs: Int64? = nil
}

struct DemoBootstrapSnapshot: Equatable {
    var nodes: [DemoBootstrapNodeSnapshot] = DemoBootstrapStage.allCases.map {
        DemoBootstrapNodeSnapshot(stage: $0)
    }
    var totalMs: Int64? = nil
    var startedAtMs: Int64? = nil
    var completedAtMs: Int64? = nil
    var failed: Bool = false

    var isRunning: Bool {
        !failed && totalMs == nil && nodes.contains { $0.status == .running }
    }

    func formatDuration(_ ms: Int64?) -> String {
        guard let ms else { return "-" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    func nodeLine(_ node: DemoBootstrapNodeSnapshot, nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> String {
        let elapsed: Int64?
        switch node.status {
        case .running:
            if let started = node.startedAtMs {
                elapsed = max(0, nowMs - started)
            } else {
                elapsed = nil
            }
        case .done, .failed:
            elapsed = node.durationMs
        case .pending:
            elapsed = nil
        }
        let mark: String
        switch node.status {
        case .pending: mark = "·"
        case .running: mark = "…"
        case .done: mark = "✓"
        case .failed: mark = "✗"
        }
        return "\(node.stage.label)\(mark) \(formatDuration(elapsed))"
    }

    func summaryLine(nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> String {
        nodes.map { nodeLine($0, nowMs: nowMs) }.joined(separator: "  ")
    }

    func totalLine(nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> String {
        let ms: Int64?
        if let totalMs {
            ms = totalMs
        } else if let startedAtMs, isRunning || failed {
            ms = max(0, nowMs - startedAtMs)
        } else {
            ms = nil
        }
        let suffix: String
        if failed {
            suffix = "失败"
        } else if totalMs != nil {
            suffix = "完成"
        } else if isRunning {
            suffix = "进行中"
        } else {
            suffix = ""
        }
        if suffix.isEmpty {
            return "Bootstrap \(formatDuration(ms))"
        }
        return "Bootstrap \(suffix) \(formatDuration(ms))"
    }
}

final class DemoBootstrapPipelineTracker {
    private var snapshot = DemoBootstrapSnapshot()

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    func current() -> DemoBootstrapSnapshot {
        snapshot
    }

    @discardableResult
    func reset() -> DemoBootstrapSnapshot {
        snapshot = DemoBootstrapSnapshot()
        return snapshot
    }

    @discardableResult
    func begin(_ stage: DemoBootstrapStage, nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> DemoBootstrapSnapshot {
        if stage == .auth {
            snapshot = DemoBootstrapSnapshot(
                nodes: DemoBootstrapStage.allCases.map { s in
                    if s == .auth {
                        return DemoBootstrapNodeSnapshot(stage: s, status: .running, startedAtMs: nowMs)
                    }
                    return DemoBootstrapNodeSnapshot(stage: s)
                },
                startedAtMs: nowMs
            )
            return snapshot
        }

        let nodes = snapshot.nodes.map { node -> DemoBootstrapNodeSnapshot in
            guard node.stage == stage else { return node }
            return DemoBootstrapNodeSnapshot(stage: stage, status: .running, startedAtMs: nowMs)
        }
        snapshot = DemoBootstrapSnapshot(
            nodes: nodes,
            totalMs: nil,
            startedAtMs: snapshot.startedAtMs,
            completedAtMs: nil,
            failed: false
        )
        return snapshot
    }

    @discardableResult
    func complete(_ stage: DemoBootstrapStage, nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> DemoBootstrapSnapshot {
        let nodes = snapshot.nodes.map { node -> DemoBootstrapNodeSnapshot in
            guard node.stage == stage else { return node }
            let start = node.startedAtMs ?? snapshot.startedAtMs ?? nowMs
            return DemoBootstrapNodeSnapshot(
                stage: stage,
                status: .done,
                durationMs: max(0, nowMs - start),
                startedAtMs: start
            )
        }
        var next = DemoBootstrapSnapshot(
            nodes: nodes,
            totalMs: snapshot.totalMs,
            startedAtMs: snapshot.startedAtMs,
            completedAtMs: snapshot.completedAtMs,
            failed: false
        )
        if stage == .channelReady {
            let totalStart = next.startedAtMs ?? nowMs
            next.totalMs = max(0, nowMs - totalStart)
            next.completedAtMs = nowMs
        }
        snapshot = next
        return snapshot
    }

    @discardableResult
    func fail(_ stage: DemoBootstrapStage, nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> DemoBootstrapSnapshot {
        let nodes = snapshot.nodes.map { node -> DemoBootstrapNodeSnapshot in
            guard node.stage == stage else { return node }
            let start = node.startedAtMs ?? snapshot.startedAtMs ?? nowMs
            return DemoBootstrapNodeSnapshot(
                stage: stage,
                status: .failed,
                durationMs: max(0, nowMs - start),
                startedAtMs: start
            )
        }
        let totalStart = snapshot.startedAtMs
        snapshot = DemoBootstrapSnapshot(
            nodes: nodes,
            totalMs: totalStart.map { max(0, nowMs - $0) },
            startedAtMs: snapshot.startedAtMs,
            completedAtMs: nowMs,
            failed: true
        )
        return snapshot
    }

    @discardableResult
    func beginChannelReady(nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> DemoBootstrapSnapshot {
        if node(.createChannel)?.status == .running {
            _ = complete(.createChannel, nowMs: nowMs)
        }
        return begin(.channelReady, nowMs: nowMs)
    }

    @discardableResult
    func completeChannelReady(nowMs: Int64 = DemoBootstrapPipelineTracker.nowMs()) -> DemoBootstrapSnapshot {
        guard let ready = node(.channelReady) else { return snapshot }
        if ready.status == .done { return snapshot }
        if ready.status == .pending {
            _ = begin(.channelReady, nowMs: nowMs)
        }
        return complete(.channelReady, nowMs: nowMs)
    }

    private func node(_ stage: DemoBootstrapStage) -> DemoBootstrapNodeSnapshot? {
        snapshot.nodes.first { $0.stage == stage }
    }
}

// MARK: - Demo Wi-Fi Speed Probe (Host App Side)

enum DemoWifiSpeedStatus: Equatable {
    case idle
    case running
    case done
    case cancelled
    case failed
}

struct DemoWifiSpeedSnapshot: Equatable {
    static let poorBandwidthKbps: Double = 100
    static let measureWindowMs: Int64 = 10_000

    var status: DemoWifiSpeedStatus = .idle
    var bandwidthKbps: Double? = nil
    var latencyMs: Int64? = nil
    var elapsedMs: Int64? = nil
    var errorMessage: String? = nil

    var isBandwidthPoor: Bool {
        guard let bandwidthKbps else { return false }
        return bandwidthKbps < Self.poorBandwidthKbps
    }

    func formatBandwidth() -> String {
        guard let bandwidthKbps else { return "-" }
        if bandwidthKbps >= 1000 {
            return String(format: "%.2fMbps", bandwidthKbps / 1000.0)
        }
        return String(format: "%.0fkbps", bandwidthKbps)
    }

    func formatLatency() -> String {
        guard let latencyMs else { return "-" }
        return "\(latencyMs)ms"
    }

    func displayLine() -> String {
        switch status {
        case .idle:
            return "测速 -"
        case .running:
            let bw = bandwidthKbps == nil ? "…" : formatBandwidth()
            let lat = formatLatency()
            let elapsed = elapsedMs.map { "\($0 / 1000)s" } ?? "…"
            return "测速中 \(elapsed)  带宽 \(bw)  业务延迟 \(lat)"
        case .done:
            return "带宽 \(formatBandwidth())  业务延迟 \(formatLatency())"
        case .cancelled:
            return "测速已取消"
        case .failed:
            return "测速失败 \(errorMessage ?? "")".trimmingCharacters(in: .whitespaces)
        }
    }

    static func bytesToKbps(bytes: Int64, elapsedMs: Int64) -> Double {
        let seconds = Double(max(1, elapsedMs)) / 1000.0
        return (Double(bytes) * 8.0) / 1000.0 / seconds
    }
}

final class DemoWifiSpeedProbe {
    private let downloadURLs: [URL] = [
        URL(string: "https://speed.cloudflare.com/__down?bytes=100000000")!,
        URL(string: "https://proof.ovh.net/files/100Mb.dat")!,
        URL(string: "https://cachefly.cachefly.net/100mb.test")!,
    ]
    private let measureWindowMs = DemoWifiSpeedSnapshot.measureWindowMs

    private let lock = NSLock()
    private var cancelled = false
    private var generation: UInt64 = 0
    private var session: URLSession?
    private var workItem: DispatchWorkItem?
    private var streamDelegate: SpeedStreamDelegate?

    /// - Parameter businessBaseURL: Demo 当前生效的业务 API 根地址（与 SDK 网络配置一致）
    func start(businessBaseURL: URL, onUpdate: @escaping (DemoWifiSpeedSnapshot) -> Void) {
        cancel()
        lock.lock()
        cancelled = false
        generation &+= 1
        let runGeneration = generation
        let runLatencyURLs = Self.latencyURLs(forBusinessBase: businessBaseURL)
        let delegate = SpeedStreamDelegate()
        streamDelegate = delegate
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
            "Cache-Control": "no-cache",
        ]
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        lock.unlock()

        publish(DemoWifiSpeedSnapshot(status: .running, elapsedMs: 0), generation: runGeneration, onUpdate: onUpdate)
        let item = DispatchWorkItem { [weak self] in
            self?.runProbe(
                session: session,
                delegate: delegate,
                latencyURLs: runLatencyURLs,
                generation: runGeneration,
                onUpdate: onUpdate
            )
        }
        workItem = item
        DispatchQueue.global(qos: .utility).async(execute: item)
    }

    static func latencyURLs(forBusinessBase baseURL: URL) -> [URL] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        // 业务根路径测 RTT；去掉 query，保留 path（通常是 /）
        components?.query = nil
        components?.fragment = nil
        guard let url = components?.url else { return [baseURL] }
        return [url]
    }

    /// 与 Demo SDK 初始化一致的业务 baseURL（不访问 SDK internal 配置字段）。
    static func resolvedBusinessBaseURL(
        settings: DemoSettingsConfig = DemoSettingsStore().loadCurrentConfig()
    ) -> URL {
        DemoSDKConfigurationFactory.resolvedBusinessBaseURL(from: settings)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        generation &+= 1
        workItem?.cancel()
        workItem = nil
        session?.invalidateAndCancel()
        session = nil
        streamDelegate = nil
        lock.unlock()
    }

    private func isCancelled(generation runGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || generation != runGeneration
    }

    private func publish(
        _ snapshot: DemoWifiSpeedSnapshot,
        generation runGeneration: UInt64,
        onUpdate: @escaping (DemoWifiSpeedSnapshot) -> Void
    ) {
        guard !isCancelled(generation: runGeneration) else { return }
        onUpdate(snapshot)
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if url.host?.contains("speed.cloudflare.com") == true {
            request.setValue("https://speed.cloudflare.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://speed.cloudflare.com", forHTTPHeaderField: "Origin")
        }
        return request
    }

    private func runProbe(session: URLSession,
                          delegate: SpeedStreamDelegate,
                          latencyURLs: [URL],
                          generation runGeneration: UInt64,
                          onUpdate: @escaping (DemoWifiSpeedSnapshot) -> Void) {
        if isCancelled(generation: runGeneration) { return }

        let latency = measureLatency(urls: latencyURLs, session: session, generation: runGeneration)
        if isCancelled(generation: runGeneration) { return }
        publish(
            DemoWifiSpeedSnapshot(status: .running, latencyMs: latency, elapsedMs: 0),
            generation: runGeneration,
            onUpdate: onUpdate
        )

        let startMs = DemoBootstrapPipelineTracker.nowMs()
        var lastPublishMs: Int64 = 0
        var totalBytes: Int64 = 0
        var lastError: Error?

        for url in downloadURLs {
            if isCancelled(generation: runGeneration) { return }
            if DemoBootstrapPipelineTracker.nowMs() - startMs >= measureWindowMs {
                break
            }

            let sema = DispatchSemaphore(value: 0)
            delegate.reset()
            delegate.onBytes = { [weak self] roundTotal in
                guard let self, !self.isCancelled(generation: runGeneration) else { return }
                let combined = totalBytes + roundTotal
                let now = DemoBootstrapPipelineTracker.nowMs()
                if now - lastPublishMs >= 400 {
                    lastPublishMs = now
                    let elapsed = max(1, now - startMs)
                    self.publish(
                        DemoWifiSpeedSnapshot(
                            status: .running,
                            bandwidthKbps: DemoWifiSpeedSnapshot.bytesToKbps(bytes: combined, elapsedMs: elapsed),
                            latencyMs: latency,
                            elapsedMs: elapsed
                        ),
                        generation: runGeneration,
                        onUpdate: onUpdate
                    )
                }
                if now - startMs >= self.measureWindowMs {
                    sema.signal()
                }
            }
            delegate.onFinished = { _ in
                sema.signal()
            }

            let task = session.dataTask(with: makeRequest(url: url))
            task.resume()

            while true {
                if isCancelled(generation: runGeneration) {
                    task.cancel()
                    return
                }
                let now = DemoBootstrapPipelineTracker.nowMs()
                if now - startMs >= measureWindowMs {
                    task.cancel()
                    break
                }
                if sema.wait(timeout: .now() + 0.2) == .success {
                    task.cancel()
                    break
                }
            }

            if let status = delegate.httpStatus, !(200...299).contains(status) {
                lastError = NSError(
                    domain: "DemoWifiSpeedProbe",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
                )
                continue
            }
            if let error = delegate.error {
                let ns = error as NSError
                if !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) {
                    lastError = error
                    if delegate.totalBytes == 0 {
                        continue
                    }
                }
            }

            totalBytes += delegate.totalBytes
            lastError = nil
            if DemoBootstrapPipelineTracker.nowMs() - startMs >= measureWindowMs {
                break
            }
            // 当前文件已读完但窗口未满：继续下一个 URL
        }

        if isCancelled(generation: runGeneration) { return }

        if totalBytes <= 0 {
            publish(
                DemoWifiSpeedSnapshot(
                    status: .failed,
                    latencyMs: latency,
                    errorMessage: lastError?.localizedDescription ?? "测速无数据"
                ),
                generation: runGeneration,
                onUpdate: onUpdate
            )
            return
        }

        let elapsedFinal = max(1, DemoBootstrapPipelineTracker.nowMs() - startMs)
        publish(
            DemoWifiSpeedSnapshot(
                status: .done,
                bandwidthKbps: DemoWifiSpeedSnapshot.bytesToKbps(bytes: totalBytes, elapsedMs: elapsedFinal),
                latencyMs: latency,
                elapsedMs: elapsedFinal
            ),
            generation: runGeneration,
            onUpdate: onUpdate
        )
    }

    private func measureLatency(urls: [URL], session: URLSession, generation runGeneration: UInt64) -> Int64? {
        guard !urls.isEmpty else { return nil }

        var samples: [Int64] = []
        for url in urls {
            if isCancelled(generation: runGeneration) { break }
            for _ in 0..<3 {
                if isCancelled(generation: runGeneration) { break }
                if let ms = measureLatencyOnce(url: url, session: session, generation: runGeneration) {
                    samples.append(ms)
                }
            }
            if !samples.isEmpty { break }
        }
        return samples.min()
    }

    /// 业务延迟：拿到任意 HTTP 响应头即计 RTT（401/404 也算可达）。
    private func measureLatencyOnce(url: URL, session: URLSession, generation runGeneration: UInt64) -> Int64? {
        for method in ["HEAD", "GET"] {
            if isCancelled(generation: runGeneration) { return nil }
            let started = DemoBootstrapPipelineTracker.nowMs()
            let sema = DispatchSemaphore(value: 0)
            var ok = false
            var request = makeRequest(url: url)
            request.httpMethod = method
            let task = session.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, (100...599).contains(http.statusCode) {
                    ok = true
                }
                sema.signal()
            }
            task.resume()
            let waitResult = sema.wait(timeout: .now() + 5)
            if waitResult == .timedOut {
                task.cancel()
                continue
            }
            if isCancelled(generation: runGeneration) {
                task.cancel()
                return nil
            }
            if ok {
                return max(0, DemoBootstrapPipelineTracker.nowMs() - started)
            }
        }
        return nil
    }
}

private final class SpeedStreamDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private(set) var totalBytes: Int64 = 0
    private(set) var error: Error?
    private(set) var httpStatus: Int?
    var onBytes: ((Int64) -> Void)?
    var onFinished: ((Error?) -> Void)?

    func reset() {
        lock.lock()
        totalBytes = 0
        error = nil
        httpStatus = nil
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                     dataTask: URLSessionDataTask,
                     didReceive response: URLResponse,
                     completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        lock.lock()
        httpStatus = status
        lock.unlock()
        if let status, !(200...299).contains(status) {
            completionHandler(.cancel)
            let err = NSError(
                domain: "DemoWifiSpeedProbe",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
            )
            lock.lock()
            error = err
            lock.unlock()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        totalBytes += Int64(data.count)
        let total = totalBytes
        lock.unlock()
        onBytes?(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        let finalError = self.error
        lock.unlock()
        onFinished?(finalError)
    }
}
