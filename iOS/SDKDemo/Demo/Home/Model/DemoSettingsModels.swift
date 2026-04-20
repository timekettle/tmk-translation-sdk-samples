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
    var versionText = "TmkTranslationSDK v1.0.0"

    var isConfirmEnabled: Bool {
        draftConfig != persistedConfig && isApplying == false
    }
}

struct DemoSettingsConfig: Equatable {
    var diagnosisEnabled: Bool
    var consoleLogEnabled: Bool
    var networkEnvironment: TmkTranslationNetworkEnvironment
    var mockEngineEnabled: Bool
    var schemaVersion: Int

    static var `default`: DemoSettingsConfig {
        DemoSettingsConfig(
            diagnosisEnabled: false,
            consoleLogEnabled: {
                #if DEBUG
                true
                #else
                false
                #endif
            }(),
            networkEnvironment: .test,
            mockEngineEnabled: false,
            schemaVersion: 1
        )
    }
}
