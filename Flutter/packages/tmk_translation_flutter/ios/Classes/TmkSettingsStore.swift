import Foundation

struct TmkPluginSettings {
    var diagnosisEnabled: Bool
    var consoleLogEnabled: Bool
    var networkEnvironment: String
    var mockEngineEnabled: Bool

    static let `default` = TmkPluginSettings(
        diagnosisEnabled: false,
        consoleLogEnabled: true,
        networkEnvironment: "test",
        mockEngineEnabled: false
    )

    init(diagnosisEnabled: Bool,
         consoleLogEnabled: Bool,
         networkEnvironment: String,
         mockEngineEnabled: Bool) {
        self.diagnosisEnabled = diagnosisEnabled
        self.consoleLogEnabled = consoleLogEnabled
        self.networkEnvironment = networkEnvironment
        self.mockEngineEnabled = mockEngineEnabled
    }

    init(map: [String: Any]) {
        let defaults = TmkPluginSettings.default
        self.diagnosisEnabled = map["diagnosisEnabled"] as? Bool ?? defaults.diagnosisEnabled
        self.consoleLogEnabled = map["consoleLogEnabled"] as? Bool ?? defaults.consoleLogEnabled
        self.networkEnvironment = map["networkEnvironment"] as? String ?? defaults.networkEnvironment
        self.mockEngineEnabled = map["mockEngineEnabled"] as? Bool ?? defaults.mockEngineEnabled
    }

    func toMap() -> [String: Any] {
        [
            "diagnosisEnabled": diagnosisEnabled,
            "consoleLogEnabled": consoleLogEnabled,
            "networkEnvironment": networkEnvironment,
            "mockEngineEnabled": mockEngineEnabled
        ]
    }
}

struct TmkSettingsStore {
    private enum Key {
        static let diagnosisEnabled = "tmk_translation_flutter.diagnosisEnabled"
        static let consoleLogEnabled = "tmk_translation_flutter.consoleLogEnabled"
        static let networkEnvironment = "tmk_translation_flutter.networkEnvironment"
        static let mockEngineEnabled = "tmk_translation_flutter.mockEngineEnabled"
        static let schemaVersion = "tmk_translation_flutter.schemaVersion"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> TmkPluginSettings {
        guard userDefaults.object(forKey: Key.schemaVersion) != nil else {
            return .default
        }
        return TmkPluginSettings(
            diagnosisEnabled: userDefaults.bool(forKey: Key.diagnosisEnabled),
            consoleLogEnabled: userDefaults.object(forKey: Key.consoleLogEnabled) as? Bool ?? true,
            networkEnvironment: userDefaults.string(forKey: Key.networkEnvironment) ?? "test",
            mockEngineEnabled: userDefaults.bool(forKey: Key.mockEngineEnabled)
        )
    }

    func save(_ settings: TmkPluginSettings) {
        userDefaults.set(settings.diagnosisEnabled, forKey: Key.diagnosisEnabled)
        userDefaults.set(settings.consoleLogEnabled, forKey: Key.consoleLogEnabled)
        userDefaults.set(settings.networkEnvironment, forKey: Key.networkEnvironment)
        userDefaults.set(settings.mockEngineEnabled, forKey: Key.mockEngineEnabled)
        userDefaults.set(1, forKey: Key.schemaVersion)
    }
}
