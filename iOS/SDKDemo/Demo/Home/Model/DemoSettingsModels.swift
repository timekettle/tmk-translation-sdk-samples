//
//  DemoSettingsModels.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

enum DemoSettingsStatusKind: Equatable {
    case checking
    case available
    case unavailable
    case placeholder
}

struct DemoSettingsEngineStatus: Equatable {
    let kind: DemoSettingsStatusKind
    let summary: String
    let detail: String

    static let checking = DemoSettingsEngineStatus(kind: .checking,
                                                   summary: "检查中",
                                                   detail: "正在调用鉴权接口")
    static let placeholder = DemoSettingsEngineStatus(kind: .placeholder,
                                                      summary: "暂无数据",
                                                      detail: "尚未获取状态")
}

struct DemoSettingsAuthInfo: Equatable {
    let tokenSummary: String
    let tokenDetail: String
    let autoRefreshSummary: String
    let autoRefreshDetail: String

    static let placeholder = DemoSettingsAuthInfo(tokenSummary: "暂无数据",
                                                  tokenDetail: "等待鉴权结果",
                                                  autoRefreshSummary: "暂无数据",
                                                  autoRefreshDetail: "当前版本未暴露详细刷新信息")
}

struct DemoSettingsViewState: Equatable {
    var draftConfig: DemoSettingsConfig
    var persistedConfig: DemoSettingsConfig
    var onlineEngineStatus: DemoSettingsEngineStatus = .checking
    var offlineEngineStatus: DemoSettingsEngineStatus = .checking
    var authInfo: DemoSettingsAuthInfo = .placeholder
    var isApplying = false
    var versionText = "TmkTranslationSDK v\(TmkTranslationSDK.sdkVersion)"

    var isConfirmEnabled: Bool {
        draftConfig != persistedConfig
            && draftConfig.isCustomNetworkBaseURLValid
            && isApplying == false
    }
}

struct DemoSettingsConfig: Equatable {
    var diagnosisEnabled: Bool
    var consoleLogEnabled: Bool
    var networkEnvironment: TmkTranslationNetworkEnvironment
    var customNetworkBaseURLEnabled: Bool
    var customNetworkBaseURL: String
    var sensitiveWordRedactionEnabled: Bool
    var mockEngineEnabled: Bool
    var schemaVersion: Int

    static let rayneoNetworkBaseURL = "https://api-rayneo.timekettle.co"

    var normalizedCustomNetworkBaseURL: String? {
        Self.normalizeCustomNetworkBaseURL(customNetworkBaseURL)
    }

    var isCustomNetworkBaseURLValid: Bool {
        customNetworkBaseURLEnabled == false || normalizedCustomNetworkBaseURL != nil
    }

    static var `default`: DemoSettingsConfig {
        DemoSettingsConfig(
            diagnosisEnabled: false,
            consoleLogEnabled: true,
            networkEnvironment: .test,
            customNetworkBaseURLEnabled: false,
            customNetworkBaseURL: rayneoNetworkBaseURL,
            sensitiveWordRedactionEnabled: true,
            mockEngineEnabled: false,
            schemaVersion: 6
        )
    }

    static func normalizeCustomNetworkBaseURL(_ rawValue: String?) -> String? {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard trimmed.isEmpty == false,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host.isEmpty == false,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else {
            return nil
        }
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }
}
