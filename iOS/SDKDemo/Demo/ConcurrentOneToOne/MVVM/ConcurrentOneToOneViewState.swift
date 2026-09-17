//
//  ConcurrentOneToOneViewState.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/17.
//

import Foundation

struct ConcurrentOneToOneViewState {
    var onlineStatus = "准备中"
    var offlineStatus = "准备中"
    var modelStatus = "校验中"
    var modelTotalProgressText = ""
    var modelTotalProgress = 0.0
    var isModelDownloading = false
    var needsModelDownload = false
    var onlineCanRetry = false
    var offlineCanRetry = false
    var canStart = false
    var isRunning = false
    var bubbleRetentionLimit = 20
    var rows: [ConcurrentConversationMapper.Row] = []
}
