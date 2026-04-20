//
//  DemoSettingsViewModel.swift
//  TmkTranslationSDKDemo
//

import Foundation
import Combine
import TmkTranslationSDK

final class DemoSettingsViewModel {
    @Published private(set) var state: DemoSettingsViewState

    private let store: DemoSettingsStore
    private let runtimeService: DemoSettingsRuntimeService

    init(store: DemoSettingsStore = DemoSettingsStore(),
         runtimeService: DemoSettingsRuntimeService = DemoSettingsRuntimeService()) {
        self.store = store
        self.runtimeService = runtimeService
        let persisted = store.loadCurrentConfig()
        self.state = DemoSettingsViewState(draftConfig: persisted,
                                           persistedConfig: persisted,
                                           onlineEngineStatus: .checking,
                                           offlineEngineStatus: .checking,
                                           authInfo: .placeholder,
                                           isApplying: false,
                                           versionText: Self.makeVersionText())
    }

    func onViewDidLoad() {
        refreshRuntimeStatus()
    }

    func setDiagnosisEnabled(_ enabled: Bool) {
        state.draftConfig.diagnosisEnabled = enabled
        publishState()
    }

    func setConsoleLogEnabled(_ enabled: Bool) {
        state.draftConfig.consoleLogEnabled = enabled
        publishState()
    }

    func setNetworkEnvironment(_ environment: TmkTranslationNetworkEnvironment) {
        state.draftConfig.networkEnvironment = environment
        publishState()
    }

    func setMockEngineEnabled(_ enabled: Bool) {
        state.draftConfig.mockEngineEnabled = enabled
        publishState()
    }

    func applyChanges(completion: @escaping () -> Void) {
        guard state.isConfirmEnabled else { return }
        let targetConfig = state.draftConfig
        state.isApplying = true
        publishState()
        store.save(targetConfig)
        runtimeService.apply(config: targetConfig) { [weak self] snapshot in
            guard let self else { return }
            self.state.persistedConfig = targetConfig
            self.state.draftConfig = targetConfig
            self.state.onlineEngineStatus = snapshot.onlineEngineStatus
            self.state.offlineEngineStatus = snapshot.offlineEngineStatus
            self.state.authInfo = snapshot.authInfo
            self.state.isApplying = false
            self.publishState()
            completion()
        }
    }

    private func refreshRuntimeStatus() {
        state.onlineEngineStatus = .checking
        state.offlineEngineStatus = .checking
        state.authInfo = .placeholder
        publishState()
        runtimeService.refreshStatus { [weak self] snapshot in
            guard let self else { return }
            self.state.onlineEngineStatus = snapshot.onlineEngineStatus
            self.state.offlineEngineStatus = snapshot.offlineEngineStatus
            self.state.authInfo = snapshot.authInfo
            self.publishState()
        }
    }

    private func publishState() {
        DispatchQueue.main.async {
            self.state = self.state
        }
    }

    private static func makeVersionText() -> String {
        let bundleVersion = Bundle(for: TmkTranslationSDK.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "TmkTranslationSDK v\(bundleVersion ?? "1.0.0")"
    }
}
