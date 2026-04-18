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
        let rawEnvironment = userDefaults.string(forKey: Key.networkEnvironment) ?? DemoSettingsConfig.default.networkEnvironment.rawValue
        let environment = TmkTranslationNetworkEnvironment(rawValue: rawEnvironment) ?? .test
        return DemoSettingsConfig(
            diagnosisEnabled: userDefaults.bool(forKey: Key.diagnosisEnabled),
            consoleLogEnabled: userDefaults.bool(forKey: Key.consoleLogEnabled),
            networkEnvironment: environment,
            mockEngineEnabled: userDefaults.bool(forKey: Key.mockEngineEnabled),
            schemaVersion: userDefaults.integer(forKey: Key.schemaVersion)
        )
    }

    func save(_ config: DemoSettingsConfig) {
        userDefaults.set(config.diagnosisEnabled, forKey: Key.diagnosisEnabled)
        userDefaults.set(config.consoleLogEnabled, forKey: Key.consoleLogEnabled)
        userDefaults.set(config.networkEnvironment.rawValue, forKey: Key.networkEnvironment)
        userDefaults.set(config.mockEngineEnabled, forKey: Key.mockEngineEnabled)
        userDefaults.set(config.schemaVersion, forKey: Key.schemaVersion)
    }
}
