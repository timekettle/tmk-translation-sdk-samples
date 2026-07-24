//
//  DemoSettingsStore.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

struct DemoSettingsStore {
    private enum Key {
        static let diagnosisEnabled = "demo.settings.diagnosisEnabled"
        static let consoleLogEnabled = "demo.settings.consoleLogEnabled"
        static let networkEnvironment = "demo.settings.networkEnvironment"
        static let customNetworkBaseURLEnabled = "demo.settings.customNetworkBaseURLEnabled"
        static let customNetworkBaseURL = "demo.settings.customNetworkBaseURL"
        static let sensitiveWordRedactionEnabled = "demo.settings.sensitiveWordRedactionEnabled"
        static let mockEngineEnabled = "demo.settings.mockEngineEnabled"
        static let schemaVersion = "demo.settings.schemaVersion"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadCurrentConfig() -> DemoSettingsConfig {
        guard userDefaults.object(forKey: Key.schemaVersion) != nil else {
            return .default
        }
        let schemaVersion = userDefaults.integer(forKey: Key.schemaVersion)
        let rawEnvironment = userDefaults.string(forKey: Key.networkEnvironment) ?? DemoSettingsConfig.default.networkEnvironment.rawValue
        let environment = TmkTranslationNetworkEnvironment(rawValue: rawEnvironment) ?? .test
        let storedCustomBaseURL = DemoSettingsConfig.normalizeCustomNetworkBaseURL(userDefaults.string(forKey: Key.customNetworkBaseURL))
            ?? DemoSettingsConfig.rayneoNetworkBaseURL
        let storedConfig = DemoSettingsConfig(
            diagnosisEnabled: userDefaults.bool(forKey: Key.diagnosisEnabled),
            consoleLogEnabled: userDefaults.bool(forKey: Key.consoleLogEnabled),
            networkEnvironment: environment,
            customNetworkBaseURLEnabled: userDefaults.bool(forKey: Key.customNetworkBaseURLEnabled),
            customNetworkBaseURL: storedCustomBaseURL,
            sensitiveWordRedactionEnabled: (userDefaults.object(forKey: Key.sensitiveWordRedactionEnabled) as? Bool)
                ?? DemoSettingsConfig.default.sensitiveWordRedactionEnabled,
            mockEngineEnabled: userDefaults.bool(forKey: Key.mockEngineEnabled),
            schemaVersion: schemaVersion
        )
        guard schemaVersion < DemoSettingsConfig.default.schemaVersion else {
            return storedConfig
        }
        // 迁移旧 Demo 配置：默认打开日志，同时保留用户已选择的环境和 Mock 引擎设置。
        let migratedConfig = DemoSettingsConfig(
            diagnosisEnabled: DemoSettingsConfig.default.diagnosisEnabled,
            consoleLogEnabled: DemoSettingsConfig.default.consoleLogEnabled,
            networkEnvironment: storedConfig.networkEnvironment,
            customNetworkBaseURLEnabled: schemaVersion >= 5 ? storedConfig.customNetworkBaseURLEnabled : false,
            customNetworkBaseURL: storedConfig.customNetworkBaseURL,
            sensitiveWordRedactionEnabled: storedConfig.sensitiveWordRedactionEnabled,
            mockEngineEnabled: storedConfig.mockEngineEnabled,
            schemaVersion: DemoSettingsConfig.default.schemaVersion
        )
        save(migratedConfig)
        return migratedConfig
    }

    func save(_ config: DemoSettingsConfig) {
        userDefaults.set(config.diagnosisEnabled, forKey: Key.diagnosisEnabled)
        userDefaults.set(config.consoleLogEnabled, forKey: Key.consoleLogEnabled)
        userDefaults.set(config.networkEnvironment.rawValue, forKey: Key.networkEnvironment)
        userDefaults.set(config.customNetworkBaseURLEnabled, forKey: Key.customNetworkBaseURLEnabled)
        userDefaults.set(config.normalizedCustomNetworkBaseURL ?? DemoSettingsConfig.rayneoNetworkBaseURL, forKey: Key.customNetworkBaseURL)
        userDefaults.set(config.sensitiveWordRedactionEnabled, forKey: Key.sensitiveWordRedactionEnabled)
        userDefaults.set(config.mockEngineEnabled, forKey: Key.mockEngineEnabled)
        userDefaults.set(config.schemaVersion, forKey: Key.schemaVersion)
    }
}
