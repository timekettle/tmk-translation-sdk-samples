//
//  DemoSettingsRuntimeService.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

struct DemoRuntimeSnapshot {
    let onlineEngineStatus: DemoSettingsEngineStatus
    let offlineEngineStatus: DemoSettingsEngineStatus
    let authInfo: DemoSettingsAuthInfo
}

final class DemoSettingsRuntimeService {
    private let queue = DispatchQueue(label: "co.timekettle.demo.settings.runtime", qos: .userInitiated)

    func refreshStatus(completion: @escaping (DemoRuntimeSnapshot) -> Void) {
        queue.async {
            TmkTranslationSDK.shared.verifyAuth { result in
                let snapshot = Self.makeSnapshot(from: result)
                DispatchQueue.main.async {
                    completion(snapshot)
                }
            }
        }
    }

    func apply(config: DemoSettingsConfig, completion: @escaping (DemoRuntimeSnapshot) -> Void) {
        queue.async {
            let globalConfig = DemoSDKConfigurationFactory.makeGlobalConfig(from: config)
            TmkTranslationSDK.shared.destroy()
            TmkTranslationSDK.shared.sdkInit(globalConfig)
            TmkTranslationSDK.shared.verifyAuth { result in
                let snapshot = Self.makeSnapshot(from: result)
                DispatchQueue.main.async {
                    completion(snapshot)
                }
            }
        }
    }

    private static func makeSnapshot(from result: Result<Void, TmkTranslationError>) -> DemoRuntimeSnapshot {
        switch result {
        case .success:
            let offlineSupported = TmkTranslationSDK.shared.isOfflineTranslationSupported()
            let onlineStatus = DemoSettingsEngineStatus(kind: .available,
                                                        summary: "可用",
                                                        detail: "鉴权成功")
            let offlineStatus = offlineSupported
                ? DemoSettingsEngineStatus(kind: .available, summary: "可用", detail: "离线翻译已开通")
                : DemoSettingsEngineStatus(kind: .unavailable, summary: "不可用", detail: "当前账号未开通离线翻译")
            let authInfo = DemoSettingsAuthInfo(tokenSummary: "有效",
                                                tokenDetail: "鉴权成功，可继续创建房间或通道",
                                                autoRefreshSummary: "暂无数据",
                                                autoRefreshDetail: "当前版本未暴露详细刷新信息")
            return DemoRuntimeSnapshot(onlineEngineStatus: onlineStatus,
                                       offlineEngineStatus: offlineStatus,
                                       authInfo: authInfo)
        case .failure(let error):
            let detail = error.localizedDescription
            let unavailable = DemoSettingsEngineStatus(kind: .unavailable,
                                                       summary: "不可用",
                                                       detail: detail)
            let authInfo = DemoSettingsAuthInfo(tokenSummary: "不可用",
                                                tokenDetail: detail,
                                                autoRefreshSummary: "暂无数据",
                                                autoRefreshDetail: "当前版本未暴露详细刷新信息")
            return DemoRuntimeSnapshot(onlineEngineStatus: unavailable,
                                       offlineEngineStatus: DemoSettingsEngineStatus(kind: .unavailable,
                                                                                     summary: "不可用",
                                                                                     detail: "依赖鉴权结果"),
                                       authInfo: authInfo)
        }
    }
}
