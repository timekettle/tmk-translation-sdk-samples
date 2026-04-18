//
//  DemoHomeViewModel.swift
//  TmkTranslationSDKDemo
//

import Foundation
import Combine
import TmkTranslationSDK

final class DemoHomeViewModel {
    @Published private(set) var state = DemoHomeViewState()

    private var requestID = 0
    private var hasLoadedOnce = false

    func onViewDidLoad() {
        loadSupportedLanguages()
    }

    func onViewWillAppear() {
        guard hasLoadedOnce else { return }
        loadSupportedLanguages()
    }

    func selectScenario(_ scenario: DemoHomeScenario) {
        guard state.selectedScenario != scenario else { return }
        state.selectedScenario = scenario
        publishState()
    }

    func selectMode(_ mode: DemoHomeMode) {
        guard mode.isSelectable, state.selectedMode != mode else { return }
        state.selectedMode = mode
        state.footerText = mode == .online ? "正在准备在线语言列表..." : "正在准备离线语言列表..."
        publishState()
        loadSupportedLanguages()
    }

    func selectSourceLanguage(_ option: DemoLanguageOption) {
        guard option != state.targetLanguage else { return }
        state.sourceLanguage = option
        normalizeTargetLanguage()
        publishState()
    }

    func selectTargetLanguage(_ option: DemoLanguageOption) {
        guard option != state.sourceLanguage else { return }
        state.targetLanguage = option
        normalizeTargetLanguage()
        publishState()
    }

    func swapLanguages() {
        guard let source = state.sourceLanguage,
              let target = state.targetLanguage,
              source != target else { return }
        state.sourceLanguage = target
        state.targetLanguage = source
        normalizeTargetLanguage()
        publishState()
    }

    private func loadSupportedLanguages() {
        guard let source = state.selectedMode.source else {
            state.languages = []
            state.isLoadingLanguages = false
            state.isStartEnabled = false
            publishState()
            return
        }

        hasLoadedOnce = true
        requestID += 1
        let currentRequestID = requestID
        state.isLoadingLanguages = true
        state.isStartEnabled = false
        publishState()

        let handleResult: (Result<TmkSupportedLanguagesResponse, TmkTranslationError>) -> Void = { [weak self] result in
            guard let self, currentRequestID == self.requestID else { return }
            switch result {
            case .success(let response):
                let options = Self.makeLanguageOptions(from: response)
                self.applyLoadedLanguages(options, source: source)
            case .failure(let error):
                self.state.isLoadingLanguages = false
                self.state.languages = []
                self.state.sourceLanguage = nil
                self.state.targetLanguage = nil
                self.state.footerText = "语言列表加载失败：\(error.localizedDescription)"
                self.publishState()
            }
        }

        switch source {
        case .online:
            TmkTranslationSDK.shared.verifyAuth { result in
                guard currentRequestID == self.requestID else { return }
                switch result {
                case .success:
                    _ = TmkTranslationSDK.shared.getSupportedLanguages(source: .online, uiLocales: ["zh-CN"], handleResult)
                case .failure(let error):
                    self.state.isLoadingLanguages = false
                    self.state.languages = []
                    self.state.sourceLanguage = nil
                    self.state.targetLanguage = nil
                    self.state.footerText = "在线鉴权失败：\(error.localizedDescription)"
                    self.publishState()
                }
            }
        case .offline:
            _ = TmkTranslationSDK.shared.getSupportedLanguages(source: .offline, uiLocales: ["zh-CN"], handleResult)
        }
    }

    private func applyLoadedLanguages(_ options: [DemoLanguageOption], source: TmkSupportedLanguagesSource) {
        state.isLoadingLanguages = false
        state.languages = options
        state.sourceLanguage = preferredOption(from: options,
                                               preferredFamilyCode: state.sourceLanguage?.familyCode ?? "zh",
                                               preferredActualCode: state.sourceLanguage?.actualCode ?? (source == .online ? "zh-CN" : "zh"))
        let preferredTarget = preferredOption(from: options,
                                              preferredFamilyCode: state.targetLanguage?.familyCode ?? "en",
                                              preferredActualCode: state.targetLanguage?.actualCode ?? (source == .online ? "en-US" : "en"))
        if let sourceLanguage = state.sourceLanguage,
           let preferredTarget,
           preferredTarget != sourceLanguage {
            state.targetLanguage = preferredTarget
        } else {
            state.targetLanguage = options.first(where: { $0 != state.sourceLanguage })
        }
        state.footerText = source == .online
            ? "在线语言列表已加载，自动使用 SDK 最新能力"
            : "离线语言列表已加载，可直接切换到本地翻译"
        publishState()
    }

    private func preferredOption(from options: [DemoLanguageOption],
                                 preferredFamilyCode: String,
                                 preferredActualCode: String) -> DemoLanguageOption? {
        if let exact = options.first(where: { $0.actualCode.caseInsensitiveCompare(preferredActualCode) == .orderedSame }) {
            return exact
        }
        if let family = options.first(where: { $0.familyCode == preferredFamilyCode }) {
            return family
        }
        return options.first
    }

    private func normalizeTargetLanguage() {
        guard state.targetLanguage == state.sourceLanguage else { return }
        state.targetLanguage = state.languages.first(where: { $0 != state.sourceLanguage })
    }

    private func publishState() {
        state.isStartEnabled = state.isLoadingLanguages == false
            && state.selectedMode.isSelectable
            && state.sourceLanguage != nil
            && state.targetLanguage != nil
            && state.sourceLanguage != state.targetLanguage
        DispatchQueue.main.async {
            self.state = self.state
        }
    }

    private static func makeLanguageOptions(from response: TmkSupportedLanguagesResponse) -> [DemoLanguageOption] {
        response.localeOptions.map {
            DemoLanguageOption(actualCode: $0.code,
                               familyCode: $0.code.split(separator: "-").first.map(String.init) ?? $0.code,
                               title: $0.uiLang.isEmpty ? $0.nativeLang : $0.uiLang)
        }
    }
}
