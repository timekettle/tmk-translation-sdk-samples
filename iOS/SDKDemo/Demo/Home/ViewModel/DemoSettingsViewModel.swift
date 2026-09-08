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
                                           activeOfflineModelSource: DemoOfflineModelSourceInspector.current(store: store),
                                           offlineModelProbeResult: nil,
                                           isProbingOfflineModelURL: false,
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

    func setDiagnosisLevel(_ level: TmkDiagnosisLevel) {
        state.draftConfig.diagnosisLevel = level
        publishState()
    }

    func setDiagnosisAudioCaptureEnabled(_ enabled: Bool) {
        state.draftConfig.diagnosisAudioCaptureEnabled = enabled
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

    func setCustomNetworkBaseURLEnabled(_ enabled: Bool) {
        state.draftConfig.customNetworkBaseURLEnabled = enabled
        if enabled && state.draftConfig.normalizedCustomNetworkBaseURL == nil {
            state.draftConfig.customNetworkBaseURL = DemoSettingsConfig.rayneoNetworkBaseURL
        }
        publishState()
    }

    func setCustomNetworkBaseURL(_ url: String) {
        state.draftConfig.customNetworkBaseURL = url
        publishState()
    }

    func setOfflineModelBaseURL(_ url: String) {
        state.draftConfig.offlineModelBaseURL = url
        state.offlineModelProbeResult = nil
        publishState()
    }

    func setCustomOfflineModelBaseURLEnabled(_ enabled: Bool) {
        state.draftConfig.customOfflineModelBaseURLEnabled = enabled
        state.offlineModelProbeResult = nil
        publishState()
    }

    func probeOfflineModelBaseURL(completion: @escaping (DemoOfflineModelProbeResult) -> Void) {
        guard state.draftConfig.isOfflineModelBaseURLValid,
              state.draftConfig.customOfflineModelBaseURLEnabled,
              state.isProbingOfflineModelURL == false else { return }
        state.isProbingOfflineModelURL = true
        state.offlineModelProbeResult = nil
        publishState()
        DemoOfflineModelSourceInspector.probe(state.draftConfig.offlineModelBaseURL) { [weak self] result in
            guard let self else { return }
            self.state.isProbingOfflineModelURL = false
            self.state.offlineModelProbeResult = result
            self.publishState()
            completion(result)
        }
    }

    func setSensitiveWordRedactionEnabled(_ enabled: Bool) {
        state.draftConfig.sensitiveWordRedactionEnabled = enabled
        publishState()
    }

    func selectRayneoNetworkBaseURL() {
        state.draftConfig.customNetworkBaseURL = DemoSettingsConfig.rayneoNetworkBaseURL
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
            self.state.activeOfflineModelSource = DemoOfflineModelSourceInspector.current(store: self.store)
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
        return "TmkTranslationSDK v\(TmkTranslationSDK.sdkVersion)"
    }
}
