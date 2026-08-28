//
//  DemoHomeModels.swift
//  TmkTranslationSDKDemo
//

import Foundation
import TmkTranslationSDK

enum DemoHomeScenario: String {
    case listen
    case oneToOne

    var title: String {
        switch self {
        case .listen:
            return "收听模式"
        case .oneToOne:
            return "一对一对话"
        }
    }

    var subtitle: String {
        switch self {
        case .listen:
            return "收听外语内容，实时翻译"
        case .oneToOne:
            return "双人面对面，双声道分离"
        }
    }

    var icon: String {
        switch self {
        case .listen:
            return "👂"
        case .oneToOne:
            return "💬"
        }
    }
}

enum DemoLanguageSource: Equatable {
    case online
    case offline
}

enum DemoHomeMode: String, CaseIterable {
    case online
    case offline
    case concurrentOneToOne
    case auto
    case mix

    var title: String {
        switch self {
        case .online:
            return "在线翻译"
        case .offline:
            return "离线翻译"
        case .concurrentOneToOne:
            return "在线&离线"
        case .auto:
            return "智能切换"
        case .mix:
            return "双引擎竞速"
        }
    }

    var subtitle: String {
        switch self {
        case .online:
            return "云端引擎，语言覆盖更全"
        case .offline:
            return "本地引擎，无需网络"
        case .concurrentOneToOne:
            return "在线和离线同时翻译，对比输出"
        case .auto:
            return "暂不支持"
        case .mix:
            return "暂不支持"
        }
    }

    var icon: String {
        switch self {
        case .online:
            return "☁️"
        case .offline:
            return "📦"
        case .concurrentOneToOne:
            return "🔀"
        case .auto:
            return "🔄"
        case .mix:
            return "⚡"
        }
    }

    var badgeText: String {
        switch self {
        case .online:
            return "ONLINE"
        case .offline:
            return "OFFLINE"
        case .concurrentOneToOne:
            return "CONCURRENT"
        case .auto:
            return "AUTO"
        case .mix:
            return "MIX"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .online, .offline, .concurrentOneToOne:
            return true
        case .auto, .mix:
            return false
        }
    }

    /// Concurrent 只属于一对一场景，收听模式下保持不可点击。
    func isAvailable(for scenario: DemoHomeScenario) -> Bool {
        guard isSelectable else { return false }
        if self == .concurrentOneToOne {
            return scenario == .oneToOne
        }
        return true
    }

    var source: DemoLanguageSource? {
        switch self {
        case .online:
            return .online
        case .offline:
            return .offline
        case .concurrentOneToOne:
            return .online
        case .auto, .mix:
            return nil
        }
    }
}

struct DemoLanguageOption: Equatable {
    let actualCode: String
    let familyCode: String
    let title: String
}

/// 首页语言列表的进程内缓存。在线和离线列表在首次有效加载后分别复用。
final class DemoHomeLanguageCache {
    private let lock = NSLock()
    private var onlineOptions: [DemoLanguageOption]?
    private var offlineOptions: [DemoLanguageOption]?

    func options(for source: DemoLanguageSource) -> [DemoLanguageOption]? {
        lock.lock()
        defer { lock.unlock() }
        return source == .online ? onlineOptions : offlineOptions
    }

    func store(_ options: [DemoLanguageOption], for source: DemoLanguageSource) {
        guard options.isEmpty == false else { return }
        lock.lock()
        defer { lock.unlock() }
        if source == .online {
            onlineOptions = options
        } else {
            offlineOptions = options
        }
    }
}

struct DemoHomeViewState: Equatable {
    var selectedScenario: DemoHomeScenario = .listen
    var selectedMode: DemoHomeMode = .online
    var languages: [DemoLanguageOption] = []
    var sourceLanguage: DemoLanguageOption?
    var targetLanguage: DemoLanguageOption?
    var isLoadingLanguages = false
    var isStartEnabled = false
    var footerText = "正在准备在线语言列表..."
    var offlineFamilyCodes: Set<String> = []   // 离线列表的 base code 集合（小写）
    var isConcurrentSelectable = false          // 语言对是否同时支持在线+离线
}
