import Foundation
import TmkTranslationSDK

struct DemoConversationPrompt: Equatable {
    enum Style: Equatable {
        case restart
        case leaveOnly
    }

    let title: String
    let message: String
    let style: Style
}

enum DemoConversationRuntimeAction: Equatable {
    case none
    case ignore
    case status(String)
    case weakNetwork(String)
    case reconnecting(String)
    case prompt(DemoConversationPrompt)
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
            if actualCode == 401 || actualCode == 403 {
                return .prompt(.init(title: "鉴权已失效",
                                     message: "服务端拒绝当前鉴权信息，请重新鉴权后再使用。\n\n\(detail)",
                                     style: .leaveOnly))
            }
            return .prompt(.init(title: "服务请求失败",
                                 message: "服务端返回异常状态，可以稍后重试。\n\n\(detail)",
                                 style: .restart))
        case TmkSDKErrorCode.networkBusinessError.rawValue:
            return .prompt(.init(title: "服务端拒绝请求",
                                 message: "服务端返回业务错误，请按错误信息处理后重试。\n\n\(detail)",
                                 style: actualCode == 401 || actualCode == 403 ? .leaveOnly : .restart))
        case TmkSDKErrorCode.audioProcessingError.rawValue,
             TmkSDKErrorCode.bufferOverflow.rawValue,
             TmkSDKErrorCode.audioChannelCreationFailed.rawValue:
            return .prompt(.init(title: "音频通道异常",
                                 message: "当前音频链路无法继续，可以重新创建或重新初始化。\n\n\(detail)",
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
