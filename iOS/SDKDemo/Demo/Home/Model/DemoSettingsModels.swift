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
    var activeOfflineModelSource: DemoOfflineModelSourceStatus = DemoOfflineModelSourceInspector.current()
    var offlineModelProbeResult: DemoOfflineModelProbeResult?
    var isProbingOfflineModelURL = false
    var isApplying = false
    var versionText = "TmkTranslationSDK v\(TmkTranslationSDK.sdkVersion)"

    var isConfirmEnabled: Bool {
        draftConfig != persistedConfig
            && draftConfig.isCustomNetworkBaseURLValid
            && draftConfig.isOfflineModelBaseURLValid
            && isApplying == false
    }
}

struct DemoSettingsConfig: Equatable {
    var diagnosisEnabled: Bool
    var diagnosisLevel: TmkDiagnosisLevel
    var diagnosisAudioCaptureEnabled: Bool
    var consoleLogEnabled: Bool
    var networkEnvironment: TmkTranslationNetworkEnvironment
    var customNetworkBaseURLEnabled: Bool
    var customNetworkBaseURL: String
    var customOfflineModelBaseURLEnabled: Bool
    var offlineModelBaseURL: String
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

    var normalizedOfflineModelBaseURL: String? {
        Self.normalizeOfflineModelBaseURL(offlineModelBaseURL)
    }

    var isOfflineModelBaseURLValid: Bool {
        customOfflineModelBaseURLEnabled == false || normalizedOfflineModelBaseURL != nil
    }

    /// 默认模式或异常的自定义配置都返回 nil，让 SDK 沿用内置下载源。
    var resolvedOfflineModelBaseURL: String? {
        customOfflineModelBaseURLEnabled ? normalizedOfflineModelBaseURL : nil
    }

    static var `default`: DemoSettingsConfig {
        DemoSettingsConfig(
            diagnosisEnabled: true,
            diagnosisLevel: .trace,
            diagnosisAudioCaptureEnabled: false,
            consoleLogEnabled: true,
            networkEnvironment: .test,
            customNetworkBaseURLEnabled: false,
            customNetworkBaseURL: rayneoNetworkBaseURL,
            customOfflineModelBaseURLEnabled: false,
            offlineModelBaseURL: "",
            sensitiveWordRedactionEnabled: true,
            mockEngineEnabled: false,
            schemaVersion: 9
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

    static func normalizeOfflineModelBaseURL(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.isEmpty == false,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              host.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let normalizedPath = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = normalizedPath.isEmpty ? "" : "/\(normalizedPath)"
        return components.string
    }
}

extension TmkDiagnosisLevel {
    var demoDisplayName: String {
        switch self {
        case .essential:
            return "Essential"
        case .diagnostic:
            return "Diagnostic"
        case .trace:
            return "Trace"
        }
    }
}
