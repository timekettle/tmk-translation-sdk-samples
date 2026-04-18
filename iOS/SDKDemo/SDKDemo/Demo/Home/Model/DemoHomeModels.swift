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

enum DemoHomeMode: String, CaseIterable {
    case online
    case offline
    case auto
    case mix

    var title: String {
        switch self {
        case .online:
            return "在线翻译"
        case .offline:
            return "离线翻译"
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
        case .auto:
            return "AUTO"
        case .mix:
            return "MIX"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .online, .offline:
            return true
        case .auto, .mix:
            return false
        }
    }

    var source: TmkSupportedLanguagesSource? {
        switch self {
        case .online:
            return .online
        case .offline:
            return .offline
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

struct DemoHomeViewState: Equatable {
    var selectedScenario: DemoHomeScenario = .listen
    var selectedMode: DemoHomeMode = .online
    var languages: [DemoLanguageOption] = []
    var sourceLanguage: DemoLanguageOption?
    var targetLanguage: DemoLanguageOption?
    var isLoadingLanguages = false
    var isStartEnabled = false
    var footerText = "正在准备在线语言列表..."
}
