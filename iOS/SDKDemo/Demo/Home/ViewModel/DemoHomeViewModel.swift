//
//  DemoHomeViewModel.swift
//  TmkTranslationSDKDemo
//

import Foundation
import Combine
import TmkTranslationSDK

final class DemoHomeViewModel {
    @Published private(set) var state = DemoHomeViewState()

    private static let languageCache = DemoHomeLanguageCache()

    private var requestID = 0
    private var hasLoadedOnce = false
    private var shouldRetryOnlineLanguagesOnBecomeActive = false
    private var lastOnlineLanguagesLoadFailed = false

    func onViewDidLoad() {
        loadSupportedLanguages()
    }

    func onViewWillAppear() {
        guard hasLoadedOnce else { return }
        loadSupportedLanguages()
    }

    func onAppDidBecomeActive() {
        guard state.selectedMode.source == .online else { return }
        guard shouldRetryOnlineLanguagesOnBecomeActive else { return }
        guard state.isLoadingLanguages == false else { return }
        guard state.languages.isEmpty || lastOnlineLanguagesLoadFailed else { return }
        state.footerText = "检测到应用已恢复，正在重新获取在线语言列表..."
        publishState()
        loadSupportedLanguages()
    }

    func selectScenario(_ scenario: DemoHomeScenario) {
        guard state.selectedScenario != scenario else { return }
        state.selectedScenario = scenario
        // 一对一场景即拉取离线列表，用于判断语言对是否支持「在线&离线」（不受当前 mode 影响，避免死锁）。
        if scenario == .oneToOne {
            loadOfflineLanguageSupport()
        }
        if state.selectedMode.isAvailable(for: scenario) == false {
            state.selectedMode = .online
            state.footerText = "正在准备在线语言列表..."
            publishState()
            loadSupportedLanguages()
            return
        }
        publishState()
    }

    func selectMode(_ mode: DemoHomeMode) {
        guard mode.isAvailable(for: state.selectedScenario), state.selectedMode != mode else { return }
        // 切到「在线&离线」前校验语言对是否支持离线；不支持则不切换。
        if mode == .concurrentOneToOne && !concurrentSelectable() {
            state.footerText = "该语言对不支持离线翻译，无法选择在线&离线"
            publishState()
            return
        }
        state.selectedMode = mode
        if mode.source != .online {
            shouldRetryOnlineLanguagesOnBecomeActive = false
            lastOnlineLanguagesLoadFailed = false
        }
        state.footerText = mode.source == .online ? "正在准备在线语言列表..." : "正在准备离线语言列表..."
        publishState()
        loadSupportedLanguages()
    }

    func selectSourceLanguage(_ option: DemoLanguageOption) {
        guard option != state.targetLanguage else { return }
        state.sourceLanguage = option
        normalizeTargetLanguage()
        recheckConcurrent()
        publishState()
    }

    func selectTargetLanguage(_ option: DemoLanguageOption) {
        guard option != state.sourceLanguage else { return }
        state.targetLanguage = option
        normalizeTargetLanguage()
        recheckConcurrent()
        publishState()
    }

    func swapLanguages() {
        guard let source = state.sourceLanguage,
              let target = state.targetLanguage,
              source != target else { return }
        state.sourceLanguage = target
        state.targetLanguage = source
        normalizeTargetLanguage()
        recheckConcurrent()
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
        // 并发模式额外拉取离线列表，用于判断语言对是否支持离线。
        if state.selectedMode == .concurrentOneToOne {
            loadOfflineLanguageSupport()
        }
        requestID += 1
        let currentRequestID = requestID
        if let cachedOptions = Self.languageCache.options(for: source) {
            if source == .online {
                lastOnlineLanguagesLoadFailed = false
                shouldRetryOnlineLanguagesOnBecomeActive = false
            }
            applyLoadedLanguages(cachedOptions, source: source)
            return
        }
        state.isLoadingLanguages = true
        state.isStartEnabled = false
        publishState()

        let handleResult: (Result<TmkLocaleListResponse, TmkTranslationError>) -> Void = { [weak self] result in
            guard let self, currentRequestID == self.requestID else { return }
            switch result {
            case .success(let response):
                if source == .online {
                    self.lastOnlineLanguagesLoadFailed = false
                    self.shouldRetryOnlineLanguagesOnBecomeActive = false
                }
                let options = Self.makeLanguageOptions(from: response)
                Self.languageCache.store(options, for: source)
                self.applyLoadedLanguages(options, source: source)
            case .failure(let error):
                if source == .online {
                    self.lastOnlineLanguagesLoadFailed = true
                    self.shouldRetryOnlineLanguagesOnBecomeActive = true
                }
                self.state.isLoadingLanguages = false
                self.state.languages = []
                self.state.sourceLanguage = nil
                self.state.targetLanguage = nil
                self.state.footerText = source == .online
                    ? "在线语言列表加载失败，请检查网络或权限；应用恢复后会自动重试"
                    : "语言列表加载失败：\(error.localizedDescription)"
                self.publishState()
            }
        }

        switch source {
        case .online:
            _ = TmkTranslationSDK.shared.getOnlineSupportedLanguages(handleResult)
        case .offline:
            _ = TmkTranslationSDK.shared.getOfflineSupportedLanguages(handleResult)
        }
    }

    private func applyLoadedLanguages(_ options: [DemoLanguageOption], source: DemoLanguageSource) {
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
        state.isConcurrentSelectable = state.selectedScenario == .oneToOne && concurrentSelectable()
        DispatchQueue.main.async {
            self.state = self.state
        }
    }

    /// 拉取离线语言列表，用于判断某语言对的 base code 是否同时支持离线。
    private func loadOfflineLanguageSupport() {
        TmkTranslationSDK.shared.getOfflineSupportedLanguages { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .success(let response) = result {
                    self.state.offlineFamilyCodes = Set(response.localeOptions.map {
                        $0.code.split(separator: "-").first.map(String.init) ?? $0.code
                    }.map { $0.lowercased() })
                } else {
                    self.state.offlineFamilyCodes = []
                }
                self.recheckConcurrent()
                self.publishState()
            }
        }
    }

    /// 语言对是否同时支持在线+离线（按离线 base code 判定）。
    private func concurrentSelectable() -> Bool {
        guard let source = state.sourceLanguage, let target = state.targetLanguage else { return false }
        return state.offlineFamilyCodes.contains(source.familyCode.lowercased()) &&
            state.offlineFamilyCodes.contains(target.familyCode.lowercased())
    }

    /// 已在「在线&离线」模式下时，若语言对不再支持离线则自动回退到「在线」。
    private func recheckConcurrent() {
        guard state.selectedMode == .concurrentOneToOne else { return }
        if !concurrentSelectable() {
            state.selectedMode = .online
            state.footerText = "该语言对不支持离线翻译，已切换为在线模式"
        }
    }

    private static func makeLanguageOptions(from response: TmkLocaleListResponse) -> [DemoLanguageOption] {
        response.localeOptions.map {
            DemoLanguageOption(actualCode: $0.code,
                               familyCode: $0.code.split(separator: "-").first.map(String.init) ?? $0.code,
                               title: $0.displayName)
        }
    }
}
