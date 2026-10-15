import Foundation
import UIKit
import TmkTranslationSDK

enum DemoConversationStage {
    case asr
    case mt
    case tts
}

enum DemoConversationLane: String {
    case left
    case right
}

/// 译文在气泡内的组装方式。
/// 在线流按服务端 chunk 分段；离线 Pipeline 已在 `mergedTranslatedText` 中提供 utterance 累计译文，
/// 不能再将每次回调当作独立 chunk 做重叠合并。
enum DemoConversationTranslationAssemblyMode {
    case chunked
    case offlineCumulative
}

struct DemoConversationEvent {
    let bubbleId: String
    let sessionId: Int
    let lane: DemoConversationLane
    let stage: DemoConversationStage
    let isFinal: Bool
    let text: String?
    let sourceLangCode: String
    let targetLangCode: String
    let chunkId: String?
    /// 离线 MT 当前断句的译文；`text` 仍保持兼容的累计快照。
    let translationSegmentText: String?
    let sourceSegmentText: String?
    let sentenceState: String?
    /// ASR 句子的 offset(纳秒)；仅 ASR final 句子携带,MT/TTS 为 nil。
    let offset: Int64?
    /// ASR 句子的 duration(纳秒)；仅 ASR final 句子携带,MT/TTS 为 nil。
    let duration: Int64?
    /// 显式撤回临时译文；缺失时空终态仅关闭原段。
    let isTextRetracted: Bool
    /// 原始文字回调完成态，仅控制字重，不参与既有文本聚合判断。
    let displayIsFinal: Bool

    /// 旧适配器会过滤的空 partial 只传递字重，不能创建或更新正文。
    var isDisplayOnly: Bool { stage != .tts && !isFinal && (text ?? "").isEmpty }

    init(bubbleId: String,
         sessionId: Int,
         lane: DemoConversationLane,
         stage: DemoConversationStage,
         isFinal: Bool,
         displayIsFinal: Bool? = nil,
         text: String?,
         sourceLangCode: String,
         targetLangCode: String,
         chunkId: String? = nil,
         translationSegmentText: String? = nil,
         sourceSegmentText: String? = nil,
         sentenceState: String? = nil,
         offset: Int64? = nil,
         duration: Int64? = nil,
         isTextRetracted: Bool = false) {
        self.bubbleId = bubbleId
        self.sessionId = sessionId
        self.lane = lane
        self.stage = stage
        self.isFinal = isFinal
        self.text = text
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.chunkId = chunkId
        self.translationSegmentText = translationSegmentText
        self.sourceSegmentText = sourceSegmentText
        self.sentenceState = sentenceState
        self.offset = offset
        self.duration = duration
        self.isTextRetracted = isTextRetracted
        self.displayIsFinal = displayIsFinal ?? isFinal
    }
}

/// 气泡内按 session 切分的展示片段。
///
/// 用于「按 session_id / chunk_id 命中着色」的诉求：每个 session（含合并别名）
/// 产出一段独立文字，记录贡献它的原始 session_id 与 chunk_id，由上层根据
/// `online_tts_state` 决定 `isHighlighted`。
struct DemoConversationDisplaySegment: Equatable {
    /// 该段的展示文字（已做单段省略号处理）。
    let text: String
    /// 贡献该段的原始服务端 session_id 集合（含别名合并）。
    let rawSessionIds: Set<Int>
    /// 贡献该段的原始服务端 chunk_id 集合（译文按 chunk 命中时使用）。
    let rawChunkIds: Set<String>
    /// 是否高亮（蓝色），由 ViewModel 写入。
    var isHighlighted: Bool = false
    /// 文字字重与文本锁定、TTS 高亮分别保存，避免由 sentence_state 推导字体。
    var isFinal: Bool = false
    /// 累计快照拆成样式范围时正文已包含分隔符；普通句片段沿用一个空格。
    var separator: String = " "
}

struct DemoConversationBubbleSnapshot {
    let bubbleId: String
    let sessionId: Int
    let lane: DemoConversationLane
    let sourceLangCode: String
    let targetLangCode: String
    let sourceText: String
    let translatedText: String
    /// 原文按既有 session/chunk 切分的展示片段，携带独立字重标记。
    let sourceSegments: [DemoConversationDisplaySegment]
    /// 译文按既有 chunk 切分的展示片段，携带独立字重标记。
    let translatedSegments: [DemoConversationDisplaySegment]
    /// 是否已收到服务端 bubble_end 信号，仅用于展示结束态，不阻止后续内容更新。
    let isBubbleEnded: Bool
    /// BubbleEnd 的测试结束原因；未知值已由 SDK 投影为 other。
    let bubbleEndReason: String?
    /// 气泡内第一条 ASR final 句子的 offset(纳秒);无则为 nil。
    let bOffset: Int64?
    /// 气泡时长(纳秒) = 最后一条 ASR final 句子的 (offset+duration) − bOffset;无则为 nil。
    let bDuration: Int64?
}

enum DemoConversationEventAdapter {
    /// 气泡身份沿用 SDK 的 session 回退；译文仍必须携带句身份才能合并。
    static func makeOfflineRecognizedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        makeRecognizedEvent(from: result, isFinal: isFinal)
    }

    static func makeOfflineTranslatedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        guard chunkId(from: result) != nil else { return nil }
        let isStable = stringValue(result.extraData["sentence_state"])?.lowercased() == "stable"
        return makeTranslatedEvent(from: result, isFinal: isFinal || isStable, displayIsFinal: isFinal)
    }

    static func makeRecognizedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        let text = result.data ?? ""
        // 空 partial 也携带可观察的 final=false；consume 仅更新已存在段的显示元数据。
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: Int(result.sessionID) ?? 0,
                                     lane: lane(from: result),
                                     stage: .asr,
                                     isFinal: isFinal,
                                     text: text,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode,
                                     chunkId: chunkId(from: result),
                                     sourceSegmentText: result.extraData["sentence_source"] as? String,
                                     sentenceState: result.extraData["sentence_state"] as? String,
                                     offset: int64Value(result.extraData["offset"]),
                                     duration: int64Value(result.extraData["duration"]),
                                     isTextRetracted: result.extraData["text_action"] as? String == "retract")
    }

    static func makeTranslatedEvent(from result: TmkResult<String>, isFinal: Bool, displayIsFinal: Bool? = nil) -> DemoConversationEvent? {
        let text = normalized(result.data)
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: Int(result.sessionID) ?? 0,
                                     lane: lane(from: result),
                                     stage: .mt,
                                     isFinal: isFinal,
                                     displayIsFinal: displayIsFinal ?? isFinal,
                                     text: text,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode,
                                     chunkId: chunkId(from: result),
                                     translationSegmentText: result.extraData["sentence_translation"] as? String
                                        ?? stringValue(result.extraData["sentence_translation"]),
                                     isTextRetracted: result.extraData["text_action"] as? String == "retract")
    }

    static func makeAudioEvent(from result: TmkResult<String>) -> DemoConversationEvent? {
        let isFinal = (result.extraData["event_kind"] as? String) == "final" || result.isLast
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: Int(result.sessionID) ?? 0,
                                     lane: lane(from: result),
                                     stage: .tts,
                                     isFinal: isFinal,
                                     text: nil,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode,
                                     chunkId: chunkId(from: result))
    }

    private static func bubbleId(from result: TmkResult<String>) -> String {
        if let bubble = stringValue(result.extraData["bubble_id"]) { return bubble }
        if let bubble = stringValue(result.extraData["bubbleId"]) { return bubble }
        // 在线收听/旧服务结果可能不带显式 bubble_id。SDK 的 TmkResult 会提供
        // sid_<sessionId> 兼容标识；保留该回退，避免把合法 ASR/MT 结果静默丢弃。
        return stringValue(result.bubbleId) ?? "sid_\(result.sessionID)"
    }

    private static func lane(from result: TmkResult<String>) -> DemoConversationLane {
        let channel = stringValue(result.extraData["channel"])?.lowercased()
        if channel == DemoConversationLane.right.rawValue || channel == "2" {
            return .right
        }
        return .left
    }

    private static func chunkId(from result: TmkResult<String>) -> String? {
        if let chunkId = stringValue(result.extraData["chunk_id"]) { return chunkId }
        if let chunkId = stringValue(result.extraData["chunkId"]) { return chunkId }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    /// 从 extraData 中提取 Int64 数值，兼容 Int64 / Int / NSNumber 三种装箱形态。
    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// 离线本句结果：按身份保存各句，暂停句只接受 stable 回填，已稳定句不可改写。
struct OfflineSentenceTextState {
    var preserveSourceText = false
    init(preserveSourceText: Bool = false) { self.preserveSourceText = preserveSourceText }
    private enum SegmentState {
        case activePartial
        case suspendedPartial
        case finalized
    }

    private struct SentenceSegment {
        var text: String
        var state: SegmentState
        var displayIsFinal: Bool
        var rawSessionIds: Set<Int>
    }

    private var sentenceOrder: [String] = []
    private var sentences: [String: SentenceSegment] = [:]
    private var activeSentenceId: String?

    var stableText: String {
        sentenceOrder.compactMap { id in
            guard let sentence = sentences[id], sentence.state == .finalized, !sentence.text.isEmpty else { return nil }
            return sentence.text
        }.joined(separator: preserveSourceText ? "" : " ")
    }

    var partialText: String {
        activeSentenceId.flatMap { sentences[$0]?.text } ?? ""
    }

    mutating func updateDisplayFinal(id: String?, isFinal: Bool) {
        guard let id, var sentence = sentences[id] else { return }
        sentence.displayIsFinal = isFinal
        sentences[id] = sentence
    }

    mutating func update(text: String, id: String?, isFinal: Bool, isTextRetracted: Bool = false,
                         displayIsFinal: Bool? = nil, rawSessionId: Int? = nil) {
        guard let id, !id.isEmpty else { return }
        // 字重反映最新回调，包括空 partial；正文仍按既有状态机过滤或锁定。
        updateDisplayFinal(id: id, isFinal: displayIsFinal ?? isFinal)
        let text = preserveSourceText ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || isFinal else { return }
        let old = sentences[id]
        if old?.state == .finalized || (old?.state == .suspendedPartial && !isFinal) { return }
        // 迟到旧句不暂停较新的当前句；数字身份来自离线递增句号。
        let precedesActive = Int64(id).flatMap { incoming in
            activeSentenceId.flatMap(Int64.init).map { incoming < $0 }
        } ?? false

        if old == nil {
            if !precedesActive, let activeId = activeSentenceId, var active = sentences[activeId], active.state == .activePartial {
                active.state = .suspendedPartial
                sentences[activeId] = active
            }
            if !precedesActive { activeSentenceId = nil }
            sentenceOrder.append(id)
            if sentenceOrder.allSatisfy({ Int64($0) != nil }) { sentenceOrder.sort { Int64($0)! < Int64($1)! } }
        }
        // 空 final 只结束该句，保留已有正文；迟到 final 不结束另一句的 partial。
        // 与离线 SDK 的空白判定一致，仅改变终态保留规则，不改写有效原文字符。
        let isBlank = text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (0x0009...0x000D).contains(value) || value == 0x0020 || value == 0x0085 ||
                value == 0x00A0 || value == 0x1680 || (0x2000...0x200A).contains(value) ||
                value == 0x2028 || value == 0x2029 || value == 0x202F || value == 0x205F ||
                value == 0x3000 || (preserveSourceText && value == 0x200B)
        }
        let finalText = isFinal && isBlank && !isTextRetracted ? old?.text ?? "" : text
        sentences[id] = SentenceSegment(text: finalText, state: isFinal ? .finalized : (precedesActive ? .suspendedPartial : .activePartial),
            displayIsFinal: displayIsFinal ?? isFinal,
            rawSessionIds: (old?.rawSessionIds ?? []).union(rawSessionId.map { [$0] } ?? []))
        if !isFinal && !precedesActive { activeSentenceId = id }
        else if activeSentenceId == id { activeSentenceId = nil }
    }

    func displayText(active: Bool) -> String {
        let text = sentenceOrder.compactMap { id -> String? in
            guard let sentence = sentences[id], !sentence.text.isEmpty else { return nil }
            return sentence.text
        }.joined(separator: preserveSourceText ? "" : " ")
        return !preserveSourceText && active && !partialText.isEmpty ? text + "..." : text
    }

    func displaySegments(active: Bool) -> [DemoConversationDisplaySegment] {
        var result = sentenceOrder.compactMap { id -> DemoConversationDisplaySegment? in
            guard let sentence = sentences[id], !sentence.text.isEmpty else { return nil }
            return DemoConversationDisplaySegment(text: sentence.text, rawSessionIds: sentence.rawSessionIds,
                rawChunkIds: [id], isFinal: sentence.displayIsFinal)
        }
        if !preserveSourceText && active && !partialText.isEmpty, let last = result.popLast() {
            result.append(DemoConversationDisplaySegment(text: last.text + "...", rawSessionIds: last.rawSessionIds,
                rawChunkIds: last.rawChunkIds, isFinal: last.isFinal))
        }
        return result
    }
}

final class DemoConversationBubbleAssembler {
    private enum SegmentState {
        case activePartial
        case suspendedPartial
        case finalized
    }

    private struct SessionSegment {
        var text: String
        var state: SegmentState
        var displayIsFinal: Bool

        var isFinal: Bool {
            state == .finalized
        }
    }

    private struct BubbleAggregate {
        var sourceLangCode: String
        var targetLangCode: String
        var sentenceSource = OfflineSentenceTextState(preserveSourceText: true)
        var sentenceTranslation = OfflineSentenceTextState()
        var usesSentenceSource = false
        var usesSentenceTranslation = false
        var sourceSessionOrder: [String] = []
        var translatedSessionOrder: [String] = []
        var sourceBySession: [String: SessionSegment] = [:]
        var translatedBySession: [String: SessionSegment] = [:]
        /// 每个通道同一时刻仅有一个可持续替换的 partial；新身份到来时旧 partial 暂停。
        var activeSourceSegmentID: String?
        var activeTranslatedSegmentID: String?
        /// segmentId -> 贡献它的原始服务端 session_id 集合（用于按 session 着色）。
        var sourceRawIdsByEffective: [String: Set<Int>] = [:]
        var translatedRawIdsByEffective: [String: Set<Int>] = [:]
        /// segmentId -> 贡献它的原始服务端 chunk_id 集合（用于按 chunk 着色）。
        var sourceRawChunkByEffective: [String: Set<String>] = [:]
        var translatedRawChunkByEffective: [String: Set<String>] = [:]
        /// 离线 MT 的 final 是累计快照；partial 既可能是累计文本，也可能仅是当前句。
        /// 两者分开保存，避免 partial 覆盖已确认前缀，也允许同一 chunk 的 final 修正文本。
        var offlineConfirmedTranslatedText: String = ""
        var offlineLatestFinalChunkId: String?
        /// 最近一个 final 提交前的稳定前缀，供同一 chunk 的 final 修正替换句尾而非整段回滚。
        var offlineLatestFinalBaseText: String = ""
        var offlineProvisionalTranslatedText: String?
        var offlineProvisionalBaseText: String = ""
        var offlineProvisionalChunkId: String?
        var offlineTranslatedSessionIds: Set<Int> = []
        var offlineTranslatedChunkIds: Set<String> = []
        /// 兼容累计译文只保存显示范围，正文仍由原累计算法生成。
        var offlineTranslationDisplaySegments: [DemoConversationDisplaySegment] = []
        var latestSessionId: Int = 0
        /// 气泡内第一条 ASR final 句子的 offset(纳秒)。
        var bOffset: Int64? = nil
        /// 气泡内最后一条 ASR final 句子的 (offset+duration)(纳秒)。
        var bLastEnd: Int64? = nil
        /// 内容版本号:每次 consume 改动本 aggregate 时自增,作为快照缓存的失效依据。
        /// 内容未变的历史气泡(切换/markBubbleEnded 遍历时)直接复用上次结果。
        var contentVersion: Int64 = 0
        /// 上次快照缓存:命中条件为 contentVersion 与 isActiveBubble 均未变。
        var cachedVersion: Int64 = -1
        var cachedIsActive: Bool = false
        var cachedSourceText: String = ""
        var cachedTranslatedText: String = ""
        var cachedSourceSegments: [DemoConversationDisplaySegment] = []
        var cachedTranslatedSegments: [DemoConversationDisplaySegment] = []
    }

    /// 组装结果缓存条目:文本 + 分段一并缓存,供快照复用。
    private struct ComposedResult {
        let sourceText: String
        let translatedText: String
        let sourceSegments: [DemoConversationDisplaySegment]
        let translatedSegments: [DemoConversationDisplaySegment]
    }

    /// aggregate 容量上限。1v1/收听长跑(新闻联播数小时)会持续新建气泡,
    /// aggregates 若不裁剪会单调增长(每个含多份长文本+多个字典),最终 OOM 被系统杀死
    /// (bug 7056277420:5 小时后 iOS demo 退出)。上限对齐 ViewModel 的 maxDisplayedRows。
    static let minimumMaxRows = 10
    static let maximumMaxRows = 500
    private var maxRows: Int
    private let translationAssemblyMode: DemoConversationTranslationAssemblyMode
    private var aggregates: [String: BubbleAggregate] = [:]
    /// aggregates 的插入顺序,用于按"最老优先"裁剪(Dictionary 本身无序)。
    private var aggregateOrder: [String] = []
    private var activeBubbleIdByLane: [DemoConversationLane: String] = [:]
    private var endedBubbleIds = Set<String>()
    private var endedBubbleReasons = [String: String]()

    init(maxRows: Int = 200,
         translationAssemblyMode: DemoConversationTranslationAssemblyMode = .chunked) {
        self.maxRows = max(1, maxRows)
        self.translationAssemblyMode = translationAssemblyMode
    }

    func reset() {
        aggregates.removeAll()
        aggregateOrder.removeAll()
        activeBubbleIdByLane.removeAll()
        endedBubbleIds.removeAll()
        endedBubbleReasons.removeAll()
    }

    /// 运行时更新 Demo 页面保留气泡数；缩小上限时立刻淘汰最早的聚合状态。
    @discardableResult
    func setMaxRows(_ maxRows: Int) -> [DemoConversationBubbleSnapshot] {
        self.maxRows = min(max(maxRows, Self.minimumMaxRows), Self.maximumMaxRows)
        trimIfNeeded()
        return snapshots()
    }

    func consume(_ event: DemoConversationEvent) -> [DemoConversationBubbleSnapshot] {
        let key = DemoConversationBubbleAssembler.rowKey(bubbleId: event.bubbleId, lane: event.lane)
        var snapshots: [DemoConversationBubbleSnapshot] = []

        // 空 partial 保持原正文过滤效果，只刷新已有段的字重，不切换活跃气泡或创建片段。
        if event.isDisplayOnly {
            guard var aggregate = aggregates[key] else { return [] }
            updateDisplayCompletion(event, aggregate: &aggregate)
            aggregate.contentVersion += 1
            let snapshot = makeSnapshot(bubbleId: event.bubbleId, lane: event.lane, aggregate: &aggregate,
                isActiveBubble: activeBubbleIdByLane[event.lane] == event.bubbleId)
            aggregates[key] = aggregate
            return snapshot.map { [$0] } ?? []
        }

        if let previousBubbleId = activeBubbleIdByLane[event.lane],
           previousBubbleId != event.bubbleId {
            let previousKey = DemoConversationBubbleAssembler.rowKey(bubbleId: previousBubbleId, lane: event.lane)
            if var previousAggregate = aggregates[previousKey] {
                let previousSnapshot = makeSnapshot(bubbleId: previousBubbleId,
                                                    lane: event.lane,
                                                    aggregate: &previousAggregate,
                                                    isActiveBubble: false)
                // 写回:makeSnapshot 可能刷新了 previousAggregate 的快照缓存,避免下次重算。
                aggregates[previousKey] = previousAggregate
                if let previousSnapshot {
                    snapshots.append(previousSnapshot)
                }
            }
        }

        activeBubbleIdByLane[event.lane] = event.bubbleId
        let isNewAggregate = aggregates[key] == nil
        var aggregate = aggregates[key] ?? BubbleAggregate(sourceLangCode: event.sourceLangCode,
                                                           targetLangCode: event.targetLangCode)
        // 后续回调可省略 sentence_* 字段；字体仍更新原来实际展示的片段。
        updateDisplayCompletion(event, aggregate: &aggregate)
        aggregate.latestSessionId = max(aggregate.latestSessionId, event.sessionId)
        // 语言标签在气泡创建时即冻结,不随后续事件覆盖:
        // 切换语言后,正在进行的旧气泡应保留其原始源/目标语言(译文文本仍是旧语言),
        // 新气泡才使用新语言。覆盖会导致旧气泡标签错误地跟随全局语言(见 1v1 语言切换 bug)。

        switch event.stage {
        case .asr:
            if translationAssemblyMode == .offlineCumulative, let text = event.sourceSegmentText {
                aggregate.usesSentenceSource = true
                aggregate.sentenceSource.updateDisplayFinal(id: event.chunkId, isFinal: event.displayIsFinal)
                if event.sentenceState != "end" {
                    aggregate.sentenceSource.update(text: text, id: event.chunkId,
                                                    isFinal: event.sentenceState == "stable", isTextRetracted: event.isTextRetracted,
                                                    displayIsFinal: event.displayIsFinal, rawSessionId: event.sessionId)
                }
            } else {
                update(segmentText: event.text,
                       preserveSourceText: true,
                       isTextRetracted: event.isTextRetracted,
                       isFinal: event.isFinal,
                       displayIsFinal: event.displayIsFinal,
                       segmentID: String(event.sessionId),
                       rawSessionID: event.sessionId,
                       rawChunkID: event.chunkId,
                       activeSegmentID: &aggregate.activeSourceSegmentID,
                       sessionOrder: &aggregate.sourceSessionOrder,
                       segments: &aggregate.sourceBySession,
                       rawIdsByEffective: &aggregate.sourceRawIdsByEffective,
                       rawChunkByEffective: &aggregate.sourceRawChunkByEffective)
            }
        case .mt:
            if translationAssemblyMode == .offlineCumulative, let text = event.translationSegmentText {
                aggregate.usesSentenceTranslation = true
                aggregate.sentenceTranslation.update(text: text, id: event.chunkId, isFinal: event.isFinal, isTextRetracted: event.isTextRetracted,
                    displayIsFinal: event.displayIsFinal, rawSessionId: event.sessionId)
            } else if translationAssemblyMode == .offlineCumulative {
                updateOfflineCumulativeTranslation(event, aggregate: &aggregate)
            } else if let chunkID = normalizedChunkId(event.chunkId) {
                update(segmentText: event.text,
                       isTextRetracted: event.isTextRetracted,
                       isFinal: event.isFinal,
                       displayIsFinal: event.displayIsFinal,
                       segmentID: chunkID,
                       rawSessionID: event.sessionId,
                       rawChunkID: chunkID,
                       activeSegmentID: &aggregate.activeTranslatedSegmentID,
                       sessionOrder: &aggregate.translatedSessionOrder,
                       segments: &aggregate.translatedBySession,
                       rawIdsByEffective: &aggregate.translatedRawIdsByEffective,
                       rawChunkByEffective: &aggregate.translatedRawChunkByEffective)
            }
        case .tts:
            break
        }

        // 聚合 b_offset/b_duration：仅统计 ASR 且 final 的句子。
        // b_offset = 第一条 final 句子的 offset;b_duration = 最后一条 final 句子的 (offset+duration) − b_offset。
        if event.stage == .asr, event.isFinal, let off = event.offset {
            if aggregate.bOffset == nil { aggregate.bOffset = off }
            if let dur = event.duration { aggregate.bLastEnd = off + dur }
        }

        // 本 aggregate 内容已变(source/translated/offset 任一),自增版本使其快照缓存失效。
        aggregate.contentVersion &+= 1

        if isNewAggregate {
            aggregateOrder.append(key)
        }
        var currentAggregate = aggregate
        let currentSnapshot = makeSnapshot(bubbleId: event.bubbleId,
                                           lane: event.lane,
                                           aggregate: &currentAggregate,
                                           isActiveBubble: true)
        aggregates[key] = currentAggregate
        if let currentSnapshot {
            snapshots.append(currentSnapshot)
        }
        trimIfNeeded()
        return snapshots
    }

    /// 返回当前聚合器内的完整快照，供 Concurrent 页面在独立 Runtime 间刷新展示列表。
    /// 结果仍由本聚合器自己的 bubble/session/chunk 状态生成，不接受外部 trace 关联。
    func snapshots() -> [DemoConversationBubbleSnapshot] {
        aggregateOrder.compactMap { key in
            guard let lane = DemoConversationBubbleAssembler.lane(fromRowKey: key),
                  var aggregate = aggregates[key] else { return nil }
            let bubbleId = DemoConversationBubbleAssembler.bubbleId(fromRowKey: key)
            let snapshot = makeSnapshot(bubbleId: bubbleId,
                                        lane: lane,
                                        aggregate: &aggregate,
                                        isActiveBubble: activeBubbleIdByLane[lane] == bubbleId)
            // makeSnapshot 可能更新缓存，写回避免下一次快照重复计算。
            aggregates[key] = aggregate
            return snapshot
        }
    }

    func markBubbleEnded(bubbleId: String, reason: String? = nil) -> [DemoConversationBubbleSnapshot] {
        let normalized = bubbleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return [] }
        endedBubbleIds.insert(normalized)
        // 在线不分类结束原因；离线调用方显式提供 other 作为缺失原因兜底。
        if let reason {
            let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            endedBubbleReasons[normalized] = normalizedReason.isEmpty ? "other" : normalizedReason
        } else {
            endedBubbleReasons.removeValue(forKey: normalized)
        }
        var snapshots: [DemoConversationBubbleSnapshot] = []
        for lane in [DemoConversationLane.left, .right] {
            let key = DemoConversationBubbleAssembler.rowKey(bubbleId: normalized, lane: lane)
            guard var aggregate = aggregates[key] else { continue }
            let snapshot = makeSnapshot(bubbleId: normalized,
                                        lane: lane,
                                        aggregate: &aggregate,
                                        isActiveBubble: activeBubbleIdByLane[lane] == normalized)
            // 写回:makeSnapshot 可能刷新了快照缓存。
            aggregates[key] = aggregate
            if let snapshot {
                snapshots.append(snapshot)
            }
        }
        return snapshots
    }

    static func rowKey(bubbleId: String, lane: DemoConversationLane) -> String {
        "\(bubbleId)_\(lane.rawValue)"
    }

    /// 取本 aggregate 的组装结果；内容与活跃态未变时直接复用缓存。
    private func resolveComposed(_ aggregate: inout BubbleAggregate, isActiveBubble: Bool) -> ComposedResult {
        if aggregate.cachedVersion == aggregate.contentVersion, aggregate.cachedIsActive == isActiveBubble {
            return ComposedResult(sourceText: aggregate.cachedSourceText,
                                  translatedText: aggregate.cachedTranslatedText,
                                  sourceSegments: aggregate.cachedSourceSegments,
                                  translatedSegments: aggregate.cachedTranslatedSegments)
        }
        let sourceText = aggregate.usesSentenceSource
            ? aggregate.sentenceSource.displayText(active: isActiveBubble)
            : composeText(order: aggregate.sourceSessionOrder,
                                     segments: aggregate.sourceBySession,
                                     isActiveBubble: isActiveBubble, preserveSourceText: true)
        let translatedText: String
        let sourceSegments = aggregate.usesSentenceSource ? aggregate.sentenceSource.displaySegments(active: isActiveBubble) : composeSegments(order: aggregate.sourceSessionOrder,
                                             segments: aggregate.sourceBySession,
                                             rawIds: aggregate.sourceRawIdsByEffective,
                                             rawChunks: aggregate.sourceRawChunkByEffective,
                                             isActiveBubble: isActiveBubble, preserveSourceText: true)
        let translatedSegments: [DemoConversationDisplaySegment]
        if aggregate.usesSentenceTranslation {
            translatedText = aggregate.sentenceTranslation.displayText(active: isActiveBubble)
            translatedSegments = aggregate.sentenceTranslation.displaySegments(active: isActiveBubble)
        } else if translationAssemblyMode == .offlineCumulative {
            let cumulative = composeOfflineCumulativeTranslation(aggregate,
                                                                  isActiveBubble: isActiveBubble)
            translatedText = cumulative.text
            translatedSegments = cumulative.segments
        } else {
            translatedText = composeText(order: aggregate.translatedSessionOrder,
                                         segments: aggregate.translatedBySession,
                                         isActiveBubble: isActiveBubble)
            translatedSegments = composeSegments(order: aggregate.translatedSessionOrder,
                                                 segments: aggregate.translatedBySession,
                                                 rawIds: aggregate.translatedRawIdsByEffective,
                                                 rawChunks: aggregate.translatedRawChunkByEffective,
                                                 isActiveBubble: isActiveBubble)
        }
        aggregate.cachedVersion = aggregate.contentVersion
        aggregate.cachedIsActive = isActiveBubble
        aggregate.cachedSourceText = sourceText
        aggregate.cachedTranslatedText = translatedText
        aggregate.cachedSourceSegments = sourceSegments
        aggregate.cachedTranslatedSegments = translatedSegments
        return ComposedResult(sourceText: sourceText,
                              translatedText: translatedText,
                              sourceSegments: sourceSegments,
                              translatedSegments: translatedSegments)
    }

    /// 裁剪最老的 aggregate,使容量不超过 maxRows。长跑场景防内存无限增长(bug 7056277420 OOM)。
    private func trimIfNeeded() {
        while aggregateOrder.count > maxRows {
            let oldestKey = aggregateOrder.removeFirst()
            aggregates.removeValue(forKey: oldestKey)
            // 同步收敛 endedBubbleIds,避免其随裁剪后仍无限增长。
            let bubbleId = DemoConversationBubbleAssembler.bubbleId(fromRowKey: oldestKey)
            if aggregateOrder.contains(where: { DemoConversationBubbleAssembler.bubbleId(fromRowKey: $0) == bubbleId }) == false {
                endedBubbleIds.remove(bubbleId)
                endedBubbleReasons.removeValue(forKey: bubbleId)
            }
        }
    }

    /// 从 rowKey("<bubbleId>_<lane>") 还原 bubbleId;lane 后缀为 left/right。
    private static func bubbleId(fromRowKey key: String) -> String {
        if key.hasSuffix("_\(DemoConversationLane.left.rawValue)") {
            return String(key.dropLast(DemoConversationLane.left.rawValue.count + 1))
        }
        if key.hasSuffix("_\(DemoConversationLane.right.rawValue)") {
            return String(key.dropLast(DemoConversationLane.right.rawValue.count + 1))
        }
        return key
    }

    private static func lane(fromRowKey key: String) -> DemoConversationLane? {
        if key.hasSuffix("_\(DemoConversationLane.left.rawValue)") { return .left }
        if key.hasSuffix("_\(DemoConversationLane.right.rawValue)") { return .right }
        return nil
    }

    private func makeSnapshot(bubbleId: String,
                              lane: DemoConversationLane,
                              aggregate: inout BubbleAggregate,
                              isActiveBubble: Bool) -> DemoConversationBubbleSnapshot? {
        let composed = resolveComposed(&aggregate, isActiveBubble: isActiveBubble)
        let sourceText = composed.sourceText
        let translatedText = composed.translatedText
        if sourceText.isEmpty && translatedText.isEmpty {
            return nil
        }
        let bDuration = (aggregate.bOffset != nil && aggregate.bLastEnd != nil)
            ? aggregate.bLastEnd! - aggregate.bOffset!
            : nil
        return DemoConversationBubbleSnapshot(bubbleId: bubbleId,
                                              sessionId: aggregate.latestSessionId,
                                              lane: lane,
                                              sourceLangCode: aggregate.sourceLangCode,
                                              targetLangCode: aggregate.targetLangCode,
                                              sourceText: sourceText,
                                              translatedText: translatedText,
                                              sourceSegments: composed.sourceSegments,
                                              translatedSegments: composed.translatedSegments,
                                              isBubbleEnded: endedBubbleIds.contains(bubbleId),
                                              bubbleEndReason: endedBubbleReasons[bubbleId],
                                              bOffset: aggregate.bOffset,
                                              bDuration: bDuration)
    }

    private func update(segmentText: String?,
                        preserveSourceText: Bool = false,
                        isTextRetracted: Bool = false,
                        isFinal: Bool,
                        displayIsFinal: Bool,
                        segmentID: String,
                        rawSessionID: Int,
                        rawChunkID: String?,
                        activeSegmentID: inout String?,
                        sessionOrder: inout [String],
                        segments: inout [String: SessionSegment],
                        rawIdsByEffective: inout [String: Set<Int>],
                        rawChunkByEffective: inout [String: Set<String>]) {
        guard segmentID.isEmpty == false else { return }
        let old = segments[segmentID]
        // 即使旧聚合分支拒绝改写正文，也允许原始回调完成态刷新字体。
        if var displayed = old {
            displayed.displayIsFinal = displayIsFinal
            segments[segmentID] = displayed
        }
        let text = preserveSourceText ? segmentText ?? "" : (segmentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && isFinal == false { return }
        if let old {
            // final 一经接收即不可变；暂停段只能由它自己的 final 确认，不能再被 partial 改写。
            if old.state == .finalized || (old.state == .suspendedPartial && isFinal == false) {
                return
            }
        } else {
            // 新 session/chunk 到来时，原 active partial 暂停。随后若它的 final 迟到，
            // 仍可回写该段，但不会影响当前活跃段。
            if let activeID = activeSegmentID,
               let active = segments[activeID],
               active.state == .activePartial {
                segments[activeID] = SessionSegment(text: active.text, state: .suspendedPartial, displayIsFinal: active.displayIsFinal)
            }
            activeSegmentID = nil
            sessionOrder.append(segmentID)
        }

        // 空 final 只收口当前段，保留已展示的 partial，避免气泡内容被清空。
        let finalText = isFinal && text.isEmpty && !isTextRetracted ? old?.text ?? "" : text
        let nextState: SegmentState = isFinal ? .finalized : .activePartial
        segments[segmentID] = SessionSegment(text: finalText, state: nextState,
            displayIsFinal: displayIsFinal)
        rawIdsByEffective[segmentID, default: []].insert(rawSessionID)
        if let rawChunkID { rawChunkByEffective[segmentID, default: []].insert(rawChunkID) }
        if isFinal {
            if activeSegmentID == segmentID { activeSegmentID = nil }
        } else {
            activeSegmentID = segmentID
        }
    }

    /// 只更新已经存在的显示范围；原文、译文和不同身份之间互不影响。
    private func updateDisplayCompletion(_ event: DemoConversationEvent, aggregate: inout BubbleAggregate) {
        switch event.stage {
        case .asr:
            aggregate.sentenceSource.updateDisplayFinal(id: event.chunkId, isFinal: event.displayIsFinal)
            let id = String(event.sessionId)
            if var segment = aggregate.sourceBySession[id] {
                segment.displayIsFinal = event.displayIsFinal
                aggregate.sourceBySession[id] = segment
            }
        case .mt:
            aggregate.sentenceTranslation.updateDisplayFinal(id: event.chunkId, isFinal: event.displayIsFinal)
            if let id = normalizedChunkId(event.chunkId) {
                if var segment = aggregate.translatedBySession[id] {
                    segment.displayIsFinal = event.displayIsFinal
                    aggregate.translatedBySession[id] = segment
                }
                aggregate.offlineTranslationDisplaySegments = aggregate.offlineTranslationDisplaySegments.map { segment in
                    var copy = segment
                    if copy.rawChunkIds.contains(where: { normalizedChunkId($0) == id }) {
                        copy.isFinal = event.displayIsFinal
                    }
                    return copy
                }
            }
        case .tts:
            break
        }
    }

    /// 离线 MT 的 `text` 是累计快照，`translationSegmentText` 是本句译文。
    /// 以稳定前缀 + 当前句尾部组装，避免新句 final 的重译历史覆盖气泡中部。
    private func updateOfflineCumulativeTranslation(_ event: DemoConversationEvent,
                                                    aggregate: inout BubbleAggregate) {
        let incoming = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard incoming.isEmpty == false else { return }
        let chunkId = normalizedChunkId(event.chunkId)

        if event.isFinal {
            if chunkId == aggregate.offlineLatestFinalChunkId,
               aggregate.offlineProvisionalChunkId != nil { return }
            guard isNotOlderOfflineChunk(chunkId, than: aggregate.offlineLatestFinalChunkId) else { return }
            let base: String
            if chunkId == aggregate.offlineLatestFinalChunkId {
                base = aggregate.offlineLatestFinalBaseText
            } else if chunkId == aggregate.offlineProvisionalChunkId {
                base = aggregate.offlineProvisionalBaseText
            } else {
                base = aggregate.offlineConfirmedTranslatedText
            }
            let sentenceText = (event.translationSegmentText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if sentenceText.isEmpty == false {
                aggregate.offlineConfirmedTranslatedText = appendOfflineTail(base, sentenceText)
            } else if base.isEmpty || incoming.hasPrefix(base) {
                // 兼容未升级 SDK：仅在累计快照确实延续稳定前缀时才采用它。
                aggregate.offlineConfirmedTranslatedText = incoming
            } else if chunkId == aggregate.offlineProvisionalChunkId,
                      let provisional = aggregate.offlineProvisionalTranslatedText {
                aggregate.offlineConfirmedTranslatedText = provisional
            } else {
                // 无句级译文且累计快照改写历史时，宁可只在尾部追加，也不改写已确认文本。
                aggregate.offlineConfirmedTranslatedText = appendOfflineTail(base, incoming)
            }
            aggregate.offlineLatestFinalChunkId = chunkId
            aggregate.offlineLatestFinalBaseText = base
            aggregate.offlineProvisionalTranslatedText = nil
            aggregate.offlineProvisionalBaseText = ""
            aggregate.offlineProvisionalChunkId = nil
        } else {
            // 已确认的 chunk 不接受迟到 partial，避免 final 后回退展示。
            guard isNewerOfflineChunk(chunkId, than: aggregate.offlineLatestFinalChunkId) else { return }
            let base: String
            if chunkId == aggregate.offlineProvisionalChunkId {
                base = aggregate.offlineProvisionalBaseText
            } else {
                base = aggregate.offlineConfirmedTranslatedText
                aggregate.offlineProvisionalBaseText = base
                aggregate.offlineProvisionalChunkId = chunkId
            }
            // partial 仅替换本句的临时尾部，禁止通用重叠合并写入历史中间。
            aggregate.offlineProvisionalTranslatedText = incoming.hasPrefix(base)
                ? incoming
                : appendOfflineTail(base, incoming)
        }

        aggregate.offlineTranslatedSessionIds = [event.sessionId]
        aggregate.offlineTranslatedChunkIds = chunkId.map { [$0] } ?? []
        let body = aggregate.offlineProvisionalTranslatedText ?? aggregate.offlineConfirmedTranslatedText
        let base = event.isFinal ? aggregate.offlineLatestFinalBaseText : aggregate.offlineProvisionalBaseText
        aggregate.offlineTranslationDisplaySegments = cumulativeDisplaySegments(text: body, base: base,
            previous: aggregate.offlineTranslationDisplaySegments, event: event)
    }

    /// 仅把原累计快照拆成样式范围，保留已知前缀的身份与字重；不参与正文生成。
    private func cumulativeDisplaySegments(text: String, base: String,
                                           previous: [DemoConversationDisplaySegment],
                                           event: DemoConversationEvent) -> [DemoConversationDisplaySegment] {
        let canKeepPrefix = text.hasPrefix(base) && previous.map(\.text).joined().hasPrefix(base)
        var remaining = canKeepPrefix ? base.count : 0
        var result: [DemoConversationDisplaySegment] = []
        for segment in previous where remaining > 0 {
            let prefix = String(segment.text.prefix(remaining))
            result.append(withText(segment, prefix))
            remaining -= prefix.count
        }
        let tail = String(text.dropFirst(canKeepPrefix ? base.count : 0))
        if !tail.isEmpty {
            result.append(DemoConversationDisplaySegment(text: tail, rawSessionIds: [event.sessionId],
                rawChunkIds: event.chunkId.map { [$0] } ?? [], isFinal: event.displayIsFinal, separator: ""))
        }
        return result
    }

    private func appendOfflineTail(_ stablePrefix: String, _ tail: String) -> String {
        let prefix = stablePrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.isEmpty == false else { return suffix }
        guard suffix.isEmpty == false else { return prefix }
        if suffix.hasPrefix(prefix) { return suffix }
        if prefix.hasSuffix(suffix) { return prefix }
        return prefix + " " + suffix
    }

    private func composeOfflineCumulativeTranslation(_ aggregate: BubbleAggregate,
                                                     isActiveBubble: Bool)
        -> (text: String, segments: [DemoConversationDisplaySegment]) {
        let rawText = aggregate.offlineProvisionalTranslatedText
            ?? aggregate.offlineConfirmedTranslatedText
        guard rawText.isEmpty == false else { return ("", []) }
        let isFinal = aggregate.offlineProvisionalTranslatedText == nil
        let normalized = normalizedDisplayText(rawText, isFinal: isFinal)
        guard normalized.isEmpty == false else { return ("", []) }
        let text: String
        if isFinal || isActiveBubble == false {
            text = removeTrailingEllipsis(normalized)
        } else {
            text = appendEllipsisIfNeeded(normalized)
        }
        var remaining = text.count
        var segments: [DemoConversationDisplaySegment] = []
        for segment in aggregate.offlineTranslationDisplaySegments where remaining > 0 {
            let body = String(segment.text.prefix(remaining))
            segments.append(withText(segment, body))
            remaining -= body.count
        }
        // 省略号仍由既有正文规则决定；仅让最后一个样式范围覆盖它。
        if remaining > 0, let last = segments.popLast() {
            segments.append(withText(last, last.text + String(text.suffix(remaining))))
        }
        return (text, segments)
    }

    private func isNotOlderOfflineChunk(_ incoming: String?, than current: String?) -> Bool {
        guard let incoming = numericChunkId(incoming), let current = numericChunkId(current) else {
            return true
        }
        return incoming >= current
    }

    private func isNewerOfflineChunk(_ incoming: String?, than current: String?) -> Bool {
        guard let current else { return true }
        guard let incomingNumeric = numericChunkId(incoming), let currentNumeric = numericChunkId(current) else {
            // 非数字 chunk 不具备可靠的全序。相同 ID 视为当前已确认句，其他 ID 只要存在便
            // 交由上游的时序保证；真实 Offline Pipeline 使用递增 sentenceId，因此会走数字分支。
            return incoming != nil && incoming != current
        }
        return incomingNumeric > currentNumeric
    }

    private func numericChunkId(_ chunkId: String?) -> Int64? {
        guard let chunkId else { return nil }
        return Int64(chunkId)
    }

    private func normalizedChunkId(_ chunkId: String?) -> String? {
        let normalized = (chunkId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// 按 session 顺序产出独立展示片段（不做跨 session 合并去重），用于按 session/chunk 着色。
    private func composeSegments(order: [String],
                                 segments: [String: SessionSegment],
                                 rawIds: [String: Set<Int>],
                                 rawChunks: [String: Set<String>],
                                 isActiveBubble: Bool, preserveSourceText: Bool = false) -> [DemoConversationDisplaySegment] {
        var result: [DemoConversationDisplaySegment] = []
        var latestIsFinal = true
        for segmentID in order {
            guard let segment = segments[segmentID] else { continue }
            let normalized = preserveSourceText ? segment.text : normalizedDisplayText(segment.text, isFinal: segment.isFinal)
            guard normalized.isEmpty == false else { continue }
            result.append(DemoConversationDisplaySegment(text: normalized,
                                                         rawSessionIds: rawIds[segmentID] ?? [],
                                                         rawChunkIds: rawChunks[segmentID] ?? [],
                                                         isFinal: segment.displayIsFinal))
            latestIsFinal = segment.isFinal
        }
        guard result.isEmpty == false else { return [] }
        // 活跃气泡的最后一段若未 final，补省略号，与 composeText 行为保持一致。
        if !preserveSourceText && latestIsFinal == false && isActiveBubble {
            let lastIndex = result.count - 1
            result[lastIndex] = withText(result[lastIndex], appendEllipsisIfNeeded(result[lastIndex].text))
        }
        return result
    }

    private func withText(_ segment: DemoConversationDisplaySegment, _ text: String) -> DemoConversationDisplaySegment {
        DemoConversationDisplaySegment(text: text,
                                       rawSessionIds: segment.rawSessionIds,
                                       rawChunkIds: segment.rawChunkIds,
                                       isHighlighted: segment.isHighlighted,
                                       isFinal: segment.isFinal,
                                       separator: segment.separator)
    }

    private func composeText(order: [String], segments: [String: SessionSegment], isActiveBubble: Bool, preserveSourceText: Bool = false) -> String {
        var orderedTexts: [String] = []
        var latestIsFinal = true
        for segmentID in order {
            guard let segment = segments[segmentID] else { continue }
            let text = preserveSourceText ? segment.text : normalizedDisplayText(segment.text, isFinal: segment.isFinal)
            guard text.isEmpty == false else { continue }
            orderedTexts.append(text)
            latestIsFinal = segment.isFinal
        }
        guard orderedTexts.isEmpty == false else { return "" }
        let merged = orderedTexts.joined(separator: preserveSourceText ? "" : " ")
        if preserveSourceText { return merged }
        if latestIsFinal || isActiveBubble == false {
            return removeTrailingEllipsis(merged)
        }
        return appendEllipsisIfNeeded(merged)
    }

    private func appendEllipsisIfNeeded(_ text: String) -> String {
        if text.hasSuffix("...") || text.hasSuffix("…") { return text }
        return text + "..."
    }

    private func normalizedDisplayText(_ text: String, isFinal: Bool) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinal else { return normalized }
        return removeTrailingEllipsis(normalized)
    }

    private func removeTrailingEllipsis(_ text: String) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("...") || normalized.hasSuffix("…") {
            if normalized.hasSuffix("...") {
                normalized.removeLast(3)
            } else {
                normalized.removeLast()
            }
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

}

/// 把气泡的 meta 行 + 源语言/目标语言分段文本渲染为带颜色的富文本。
///
/// 仅 `online_tts_state` 命中的 session 片段（`isHighlighted`）显示为蓝色，其余为默认色；
/// meta 行使用次要色。在线、离线与并行 Demo 共用分段字重规则。
enum DemoConversationSegmentRenderer {
    static func makeConcurrentText(sourceSegments: [DemoConversationDisplaySegment], sourceFallbackText: String,
                                   translatedSegments: [DemoConversationDisplaySegment], translatedFallbackText: String,
                                   font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendLine(to: result, label: "ASR：", segments: sourceSegments,
                   fallbackText: sourceFallbackText, font: font, preserveSourceText: true)
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        appendLine(to: result, label: "MT：", segments: translatedSegments,
                   fallbackText: translatedFallbackText, font: font, emptyFallbackText: "")
        return result
    }

    static func makeBubbleText(metaText: String,
                               sourceLangCode: String,
                               sourceSegments: [DemoConversationDisplaySegment],
                               sourceFallbackText: String,
                               targetLangCode: String,
                               translatedSegments: [DemoConversationDisplaySegment],
                               translatedFallbackText: String,
                               font: UIFont,
                               timeRangeText: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: metaText,
                                         attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        result.append(NSAttributedString(string: "\n\n",
                                         attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        appendLine(to: result, label: "源语言(\(sourceLangCode))：",
                   segments: sourceSegments, fallbackText: sourceFallbackText, font: font, preserveSourceText: true)
        result.append(NSAttributedString(string: "\n",
                                         attributes: [.font: font, .foregroundColor: UIColor.label]))
        appendLine(to: result, label: "目标语言(\(targetLangCode))：",
                   segments: translatedSegments, fallbackText: translatedFallbackText, font: font)
        // bubbleEnd 后单独一行醒目展示气泡时间段(纳秒),与源/译文和 meta 明显区分。
        if let timeRangeText, timeRangeText.isEmpty == false {
            result.append(NSAttributedString(string: "\n",
                                             attributes: [.font: font, .foregroundColor: UIColor.label]))
            let emphasisFont = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            result.append(NSAttributedString(string: timeRangeText,
                                             attributes: [.font: emphasisFont, .foregroundColor: UIColor.systemOrange]))
        }
        return result
    }

    private static func appendLine(to result: NSMutableAttributedString,
                                   label: String,
                                   segments: [DemoConversationDisplaySegment],
                                   fallbackText: String,
                                   font: UIFont,
                                   preserveSourceText: Bool = false,
                                   emptyFallbackText: String = "...") {
        result.append(NSAttributedString(string: label,
                                         attributes: [.font: font, .foregroundColor: UIColor.label]))
        let nonEmpty = segments.filter { $0.text.isEmpty == false }
        // 离线等场景未提供分段时，回退到整段纯文本（默认色），保持既有展示。
        guard nonEmpty.isEmpty == false else {
            let display = preserveSourceText ? fallbackText : (fallbackText.isEmpty ? emptyFallbackText : fallbackText)
            result.append(NSAttributedString(string: display,
                                             attributes: [.font: font, .foregroundColor: UIColor.label]))
            return
        }
        for (index, segment) in nonEmpty.enumerated() {
            if index > 0 && !preserveSourceText {
                result.append(NSAttributedString(string: segment.separator,
                                                 attributes: [.font: font, .foregroundColor: UIColor.label]))
            }
            let color: UIColor = segment.isHighlighted ? .systemBlue : .label
            let segmentFont = UIFont.systemFont(ofSize: font.pointSize, weight: segment.isFinal ? .bold : .regular)
            result.append(NSAttributedString(string: segment.text,
                                             attributes: [.font: segmentFont, .foregroundColor: color]))
        }
    }
}

/// 生成气泡时间段的单行展示文本,供在线收听 / 一对一两个 cell 共用。
///
/// 仅当气泡收到 bubbleEnd 且已聚合出 offset 时展示 `⏱ offset=…s duration=…s`;
/// 时间由纳秒换算为秒,保留 3 位小数(到毫秒)。否则返回 nil(不占行)。
/// 离线场景无服务端 offset,bOffset 恒为 nil → 永不显示(需求:离线不管)。
enum DemoBubbleTimeRangeFormatter {
    static func text(isBubbleEnded: Bool, bOffset: Int64?, bDuration: Int64?) -> String? {
        guard isBubbleEnded, let bOffset else { return nil }
        let offsetSec = secondsText(fromNanos: bOffset)
        let durationSec = secondsText(fromNanos: bDuration ?? 0)
        return "⏱ offset=\(offsetSec)s duration=\(durationSec)s"
    }

    /// 纳秒 → 秒,保留 3 位小数(到毫秒)。
    private static func secondsText(fromNanos nanos: Int64) -> String {
        String(format: "%.3f", Double(nanos) / 1_000_000_000.0)
    }
}
