//
//  DemoSettingsStore.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

struct DemoSettingsStore {
    private enum Key {
        static let diagnosisEnabled = "demo.settings.diagnosisEnabled"
        static let diagnosisLevel = "demo.settings.diagnosisLevel"
        static let diagnosisAudioCaptureEnabled = "demo.settings.diagnosisAudioCaptureEnabled"
        static let consoleLogEnabled = "demo.settings.consoleLogEnabled"
        static let networkEnvironment = "demo.settings.networkEnvironment"
        static let customNetworkBaseURLEnabled = "demo.settings.customNetworkBaseURLEnabled"
        static let customNetworkBaseURL = "demo.settings.customNetworkBaseURL"
        static let customOfflineModelBaseURLEnabled = "demo.settings.customOfflineModelBaseURLEnabled"
        static let offlineModelBaseURL = "demo.settings.offlineModelBaseURL"
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
            diagnosisLevel: TmkDiagnosisLevel(rawValue: userDefaults.string(forKey: Key.diagnosisLevel) ?? "") ?? .essential,
            diagnosisAudioCaptureEnabled: userDefaults.bool(forKey: Key.diagnosisAudioCaptureEnabled),
            consoleLogEnabled: userDefaults.bool(forKey: Key.consoleLogEnabled),
            networkEnvironment: environment,
            customNetworkBaseURLEnabled: userDefaults.bool(forKey: Key.customNetworkBaseURLEnabled),
            customNetworkBaseURL: storedCustomBaseURL,
            customOfflineModelBaseURLEnabled: userDefaults.object(forKey: Key.customOfflineModelBaseURLEnabled) != nil
                ? userDefaults.bool(forKey: Key.customOfflineModelBaseURLEnabled)
                : DemoSettingsConfig.normalizeOfflineModelBaseURL(
                    userDefaults.string(forKey: Key.offlineModelBaseURL)
                ) != nil,
            offlineModelBaseURL: DemoSettingsConfig.normalizeOfflineModelBaseURL(
                userDefaults.string(forKey: Key.offlineModelBaseURL)
            ) ?? "",
            sensitiveWordRedactionEnabled: (userDefaults.object(forKey: Key.sensitiveWordRedactionEnabled) as? Bool)
                ?? DemoSettingsConfig.default.sensitiveWordRedactionEnabled,
            mockEngineEnabled: userDefaults.bool(forKey: Key.mockEngineEnabled),
            schemaVersion: schemaVersion
        )
        guard schemaVersion < DemoSettingsConfig.default.schemaVersion else {
            return storedConfig
        }
        // 迁移旧 Demo 配置：补齐新增诊断配置，同时保留用户已选择的环境和 Mock 引擎设置。
        let migratedConfig = DemoSettingsConfig(
            diagnosisEnabled: DemoSettingsConfig.default.diagnosisEnabled,
            diagnosisLevel: DemoSettingsConfig.default.diagnosisLevel,
            diagnosisAudioCaptureEnabled: DemoSettingsConfig.default.diagnosisAudioCaptureEnabled,
            consoleLogEnabled: DemoSettingsConfig.default.consoleLogEnabled,
            networkEnvironment: storedConfig.networkEnvironment,
            customNetworkBaseURLEnabled: schemaVersion >= 5 ? storedConfig.customNetworkBaseURLEnabled : false,
            customNetworkBaseURL: storedConfig.customNetworkBaseURL,
            // 兼容 v8 已保存 URL 的测试设备：升级后继续使用自定义源。
            customOfflineModelBaseURLEnabled: schemaVersion >= 8
                ? storedConfig.customOfflineModelBaseURLEnabled
                : false,
            offlineModelBaseURL: schemaVersion >= 8 ? storedConfig.offlineModelBaseURL : "",
            sensitiveWordRedactionEnabled: storedConfig.sensitiveWordRedactionEnabled,
            mockEngineEnabled: storedConfig.mockEngineEnabled,
            schemaVersion: DemoSettingsConfig.default.schemaVersion
        )
        save(migratedConfig)
        return migratedConfig
    }

    func save(_ config: DemoSettingsConfig) {
        userDefaults.set(config.diagnosisEnabled, forKey: Key.diagnosisEnabled)
        userDefaults.set(config.diagnosisLevel.rawValue, forKey: Key.diagnosisLevel)
        userDefaults.set(config.diagnosisAudioCaptureEnabled, forKey: Key.diagnosisAudioCaptureEnabled)
        userDefaults.set(config.consoleLogEnabled, forKey: Key.consoleLogEnabled)
        userDefaults.set(config.networkEnvironment.rawValue, forKey: Key.networkEnvironment)
        userDefaults.set(config.customNetworkBaseURLEnabled, forKey: Key.customNetworkBaseURLEnabled)
        userDefaults.set(config.normalizedCustomNetworkBaseURL ?? DemoSettingsConfig.rayneoNetworkBaseURL, forKey: Key.customNetworkBaseURL)
        userDefaults.set(config.customOfflineModelBaseURLEnabled, forKey: Key.customOfflineModelBaseURLEnabled)
        if let offlineModelBaseURL = config.normalizedOfflineModelBaseURL {
            userDefaults.set(offlineModelBaseURL, forKey: Key.offlineModelBaseURL)
        } else {
            userDefaults.removeObject(forKey: Key.offlineModelBaseURL)
        }
        userDefaults.set(config.sensitiveWordRedactionEnabled, forKey: Key.sensitiveWordRedactionEnabled)
        userDefaults.set(config.mockEngineEnabled, forKey: Key.mockEngineEnabled)
        userDefaults.set(config.schemaVersion, forKey: Key.schemaVersion)
    }
}

struct DemoOfflineModelSourceStatus: Equatable {
    let baseURL: String?
    let version: String?
    let sourceName: String?

    var summary: String {
        guard baseURL != nil else { return "未安装或未记录" }
        return "\(sourceName ?? "模型源") · \(version ?? "版本未知")"
    }

    var entryMessage: String {
        "当前离线模型版本：\(version ?? "未安装或未记录")"
            + (sourceName.map { "（\($0)）" } ?? "")
    }
}

struct DemoOfflineModelProbeResult: Equatable {
    let available: Bool
    let message: String
}

enum DemoOfflineModelSourceInspector {
    private static let manifestFileName = "model_manifest.json"
    private static let probePackagePath = "asr/zh.zip"
    private static let timeout: TimeInterval = 5

    static func current(store: DemoSettingsStore = DemoSettingsStore()) -> DemoOfflineModelSourceStatus {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tmkOfflineModel", isDirectory: true)
        let manifestURL = root?.appendingPathComponent(manifestFileName, isDirectory: false)
        let baseURL: String? = manifestURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["baseURL"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

        let config = store.loadCurrentConfig()
        let sourceName: String?
        if let baseURL {
            sourceName = config.customOfflineModelBaseURLEnabled
                && config.normalizedOfflineModelBaseURL == baseURL ? "自定义源" : "已安装源"
        } else {
            sourceName = nil
        }
        return DemoOfflineModelSourceStatus(
            baseURL: baseURL,
            version: version(from: baseURL),
            sourceName: sourceName
        )
    }

    static func version(from baseURL: String?) -> String? {
        guard let baseURL,
              let components = URLComponents(string: baseURL) else { return nil }
        return components.path.split(separator: "/").last.map(String.init)
    }

    static func probePackageURL(for baseURL: String) -> URL? {
        URL(string: "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(probePackagePath)")
    }

    static func probe(_ rawBaseURL: String?, completion: @escaping (DemoOfflineModelProbeResult) -> Void) {
        guard let baseURL = DemoSettingsConfig.normalizeOfflineModelBaseURL(rawBaseURL),
              let url = probePackageURL(for: baseURL) else {
            completion(.init(available: false, message: "地址格式无效"))
            return
        }
        request(url: url, method: "HEAD") { statusCode, error in
            if statusCode == 405 {
                request(url: url, method: "GET", rangeProbe: true) { code, retryError in
                    finishProbe(statusCode: code, error: retryError, completion: completion)
                }
            } else {
                finishProbe(statusCode: statusCode, error: error, completion: completion)
            }
        }
    }

    private static func request(url: URL,
                                method: String,
                                rangeProbe: Bool = false,
                                completion: @escaping (Int?, Error?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if rangeProbe {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            completion((response as? HTTPURLResponse)?.statusCode, error)
        }.resume()
    }

    private static func finishProbe(statusCode: Int?,
                                    error: Error?,
                                    completion: @escaping (DemoOfflineModelProbeResult) -> Void) {
        let result: DemoOfflineModelProbeResult
        if let statusCode, (200...299).contains(statusCode) {
            result = .init(available: true, message: "地址检测成功（已找到中文 ASR 模型）")
        } else if let statusCode {
            result = .init(available: false, message: "地址检测失败：HTTP \(statusCode)")
        } else {
            result = .init(
                available: false,
                message: "地址检测失败：\(error?.localizedDescription ?? "未知错误")"
            )
        }
        DispatchQueue.main.async { completion(result) }
    }
}
