//
//  DemoSDKConfigurationFactory.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

enum DemoSDKConfigurationFactory {
    static let networkTimeoutSeconds: TimeInterval = 15

    private static let appIdInfoPlistKey = "TMKSampleAppID"
    private static let appSecretInfoPlistKey = "TMKSampleAppSecret"
    private static let localSecretsPath = "Config/LocalSecrets.xcconfig"
    private static let credentialKeys = ["TMK_SAMPLE_APP_ID", "TMK_SAMPLE_APP_SECRET"]
    private static let defaultTenantId = "timekettle"

    static func makeGlobalConfig(from config: DemoSettingsConfig) -> TmkTranslationGlobalConfig {
        let credentials = resolveCredentials()
        let builder = TmkTranslationGlobalConfig.Builder()
            .setAuth(appId: credentials.appId, secret: credentials.appSecret)
            .setOnlineAuthContext(tenantId: defaultTenantId)
            .setLogEnabled(config.consoleLogEnabled)
            .setNetworkEnvironment(config.networkEnvironment)
            .setDiagnosisConfig(
                TmkDiagnosisConfig(
                    enabled: config.diagnosisEnabled,
                    level: config.diagnosisLevel,
                    rootDirectory: nil,
                    audioCaptureEnabled: config.diagnosisLevel == .trace && config.diagnosisAudioCaptureEnabled
                )
            )
            .setNetworkTimeout(networkTimeoutSeconds)
        if config.customNetworkBaseURLEnabled,
           let baseURLString = config.normalizedCustomNetworkBaseURL,
           let baseURL = URL(string: baseURLString) {
            _ = builder.setNetworkBaseURL(baseURL)
        }
        _ = builder.setOfflineModelBaseURL(config.resolvedOfflineModelBaseURL)
        return builder.build()
    }

    /// 业务延迟探测用 baseURL，与 `makeGlobalConfig` 实际生效地址一致（不读 SDK internal 字段）。
    static func resolvedBusinessBaseURL(from config: DemoSettingsConfig) -> URL {
        if config.customNetworkBaseURLEnabled,
           let baseURLString = config.normalizedCustomNetworkBaseURL,
           let baseURL = URL(string: baseURLString) {
            return baseURL
        }
        switch config.networkEnvironment {
        case .dev:
            return URL(string: "http://8.135.239.158:18080/")!
        case .test:
            return URL(string: "https://tmk-translation-test.timekettle.net/")!
        case .pre:
            return URL(string: "https://api-rayneo.timekettle.co/")!
        }
    }

    static func onlineAuthFailureMessage(_ error: Error) -> String {
        """
        在线鉴权失败：\(diagnosticMessage(for: error))
        请在 \(localSecretsPath) 中配置：\(credentialKeys.joined(separator: " / "))
        """
    }

    static func authFailureMessage(_ error: Error) -> String {
        """
        鉴权失败：\(diagnosticMessage(for: error))
        请在 \(localSecretsPath) 中配置：\(credentialKeys.joined(separator: " / "))
        """
    }

    private static func diagnosticMessage(for error: Error) -> String {
        guard let translationError = error as? TmkTranslationError else {
            return error.localizedDescription
        }
        return DemoConversationRuntimePolicy.diagnosticMessage(for: translationError)
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
