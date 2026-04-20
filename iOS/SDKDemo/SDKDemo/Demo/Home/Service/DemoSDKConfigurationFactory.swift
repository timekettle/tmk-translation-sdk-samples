//
//  DemoSDKConfigurationFactory.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

enum DemoSDKConfigurationFactory {
    private static let appIdInfoPlistKey = "TMKSampleAppID"
    private static let appSecretInfoPlistKey = "TMKSampleAppSecret"
    private static let localSecretsPath = "Config/LocalSecrets.xcconfig"
    private static let credentialKeys = ["TMK_SAMPLE_APP_ID", "TMK_SAMPLE_APP_SECRET"]
    private static let defaultTenantId = "timekettle"

    static func makeGlobalConfig(from config: DemoSettingsConfig) -> TmkTranslationGlobalConfig {
        let credentials = resolveCredentials()
        return TmkTranslationGlobalConfig.Builder()
            .setAuth(appId: credentials.appId, secret: credentials.appSecret)
            .setOnlineAuthContext(tenantId: defaultTenantId)
            .setLogEnabled(config.consoleLogEnabled)
            .setNetworkEnvironment(config.networkEnvironment)
            .setDiagnosisEnabled(config.diagnosisEnabled)
            .build()
    }

    static func onlineAuthFailureMessage(_ error: Error) -> String {
        """
        在线鉴权失败：\(error.localizedDescription)
        请在 \(localSecretsPath) 中配置：\(credentialKeys.joined(separator: " / "))
        """
    }

    static func authFailureMessage(_ error: Error) -> String {
        """
        鉴权失败：\(error.localizedDescription)
        请在 \(localSecretsPath) 中配置：\(credentialKeys.joined(separator: " / "))
        """
    }

    private static func resolveCredentials() -> (appId: String, appSecret: String) {
        (
            requiredCredential(infoPlistKey: appIdInfoPlistKey, buildSettingKey: "TMK_SAMPLE_APP_ID"),
            requiredCredential(infoPlistKey: appSecretInfoPlistKey, buildSettingKey: "TMK_SAMPLE_APP_SECRET")
        )
    }

    private static func requiredCredential(infoPlistKey: String, buildSettingKey: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            fatalError(missingCredentialMessage(for: buildSettingKey))
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed.hasPrefix("$(") == false else {
            fatalError(missingCredentialMessage(for: buildSettingKey))
        }
        return trimmed
    }

    private static func missingCredentialMessage(for buildSettingKey: String) -> String {
        """
        [TmkTranslationSDKDemo] Missing \(buildSettingKey).
        Create \(localSecretsPath) from LocalSecrets.example.xcconfig and provide a value for \(buildSettingKey).
        """
    }
}
