//
//  DemoSDKConfigurationFactory.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

enum DemoSDKConfigurationFactory {
    static let appId = "73318e8adadd0b320c37"
    static let appSecret = "b128655a24f21df5ee66d057cc9d8626e31975e6"

    static func makeGlobalConfig(from config: DemoSettingsConfig) -> TmkTranslationGlobalConfig {
        TmkTranslationGlobalConfig.Builder()
            .setAuth(appId: appId, secret: appSecret)
            .setLogEnabled(config.consoleLogEnabled)
            .setNetworkEnvironment(config.networkEnvironment)
            .setDiagnosisEnabled(config.diagnosisEnabled)
            .build()
    }
}
