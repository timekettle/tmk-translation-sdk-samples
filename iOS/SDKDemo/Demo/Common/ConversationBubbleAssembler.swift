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

    init(bubbleId: String,
         sessionId: Int,
         lane: DemoConversationLane,
         stage: DemoConversationStage,
         isFinal: Bool,
         text: String?,
         sourceLangCode: String,
         targetLangCode: String,
         chunkId: String? = nil,
         translationSegmentText: String? = nil,
         sourceSegmentText: String? = nil,
         sentenceState: String? = nil,
         offset: Int64? = nil,
         duration: Int64? = nil) {
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
}

struct DemoConversationBubbleSnapshot {
    let bubbleId: String
    let sessionId: Int
    let lane: DemoConversationLane
    let sourceLangCode: String
    let targetLangCode: String
    let sourceText: String
    let translatedText: String
    /// 源语言按 session 切分的展示片段；离线场景可忽略。
    let sourceSegments: [DemoConversationDisplaySegment]
    /// 目标语言按 session 切分的展示片段；离线场景可忽略。
    let translatedSegments: [DemoConversationDisplaySegment]
    /// 是否已收到服务端 bubble_end 信号，仅用于展示结束态，不阻止后续内容更新。
    let isBubbleEnded: Bool
    /// 气泡内第一条 ASR final 句子的 offset(纳秒);无则为 nil。
    let bOffset: Int64?
    /// 气泡时长(纳秒) = 最后一条 ASR final 句子的 (offset+duration) − bOffset;无则为 nil。
    let bDuration: Int64?
}

enum DemoConversationEventAdapter {
    static func makeRecognizedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        let text = normalized(result.data)
        guard isDisplayable(text, isFinal: isFinal) else { return nil }
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: result.sessionId,
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
                                     duration: int64Value(result.extraData["duration"]))
    }

    static func makeTranslatedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        let text = normalized(result.data)
        guard isDisplayable(text, isFinal: isFinal) else { return nil }
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: result.sessionId,
                                     lane: lane(from: result),
                                     stage: .mt,
                                     isFinal: isFinal,
                                     text: text,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode,
                                     chunkId: chunkId(from: result),
                                     translationSegmentText: stringValue(result.extraData["sentence_translation"]))
    }

    static func makeAudioEvent(from result: TmkResult<String>) -> DemoConversationEvent? {
        let isFinal = (result.extraData["event_kind"] as? String) == "final" || result.isLast
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: result.sessionId,
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
        return stringValue(result.bubbleId) ?? "sid_\(result.sessionId)"
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

    private static func isDisplayable(_ text: String, isFinal: Bool) -> Bool {
        if text.isEmpty {
            return isFinal
        }
        return true
    }
}

/// 离线本句结果：稳定正文只追加，当前句只替换；不用文本内容判断句子身份。
struct OfflineSentenceTextState {
    private(set) var stableText = ""
    private(set) var partialText = ""
    private var partialID: Int?
    private var lastStableID: Int?

    mutating func update(text: String, id: String?, isFinal: Bool) {
        guard let id, let value = Int(id) else { return }
        if let lastStableID, value <= lastStableID { return }
        if let partialID, value < partialID { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !text.isEmpty {
                if !stableText.isEmpty { stableText += " " }
                stableText += text
            }
            lastStableID = value
            partialText = ""
            partialID = nil
        } else {
            partialID = value
            partialText = text
        }
    }

    func displayText(active: Bool) -> String {
        guard !partialText.isEmpty else { return stableText }
        let text = stableText.isEmpty ? partialText : stableText + " " + partialText
        return active ? text + "..." : text
    }
}

final class DemoConversationBubbleAssembler {
    /// 单个气泡保留的服务端 session 别名上限；超出后只影响已过期 partial 的高亮映射，不影响文本或 final 语义。
    private static let maxSessionAliasesPerBubble = 64

    private struct SessionSegment {
        var text: String
        var isFinal: Bool
    }

    private struct BubbleAggregate {
        var sourceLangCode: String
        var targetLangCode: String
        var sentenceSource = OfflineSentenceTextState()
        var sentenceTranslation = OfflineSentenceTextState()
        var usesSentenceSource = false
        var usesSentenceTranslation = false
        var sourceSessionOrder: [Int] = []
        var translatedSessionOrder: [Int] = []
        var sourceBySession: [Int: SessionSegment] = [:]
        var translatedBySession: [Int: SessionSegment] = [:]
        var sourceSessionAlias: [Int: Int] = [:]
        var translatedSessionAlias: [Int: Int] = [:]
        var sourceSessionAliasOrder: [Int] = []
        var translatedSessionAliasOrder: [Int] = []
        var sourceChunkAlias: [String: Int] = [:]
        var translatedChunkAlias: [String: Int] = [:]
        /// 同一气泡内未携带 chunkId 的 ASR partial 可能轮换 sessionId；始终覆盖该活动分段。
        var activeSourcePartialSegmentID: Int?
        /// effectiveSessionId -> 贡献它的原始服务端 session_id 集合（用于按 session 着色）。
        var sourceRawIdsByEffective: [Int: Set<Int>] = [:]
        var translatedRawIdsByEffective: [Int: Set<Int>] = [:]
        /// effectiveSessionId -> 贡献它的原始服务端 chunk_id 集合（用于按 chunk 着色）。
        var sourceRawChunkByEffective: [Int: Set<String>] = [:]
        var translatedRawChunkByEffective: [Int: Set<String>] = [:]
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
        var latestSessionId: Int = 0
        /// 气泡内第一条 ASR final 句子的 offset(纳秒)。
        var bOffset: Int64? = nil
        /// 气泡内最后一条 ASR final 句子的 (offset+duration)(纳秒)。
        var bLastEnd: Int64? = nil
        /// 内容版本号:每次 consume 改动本 aggregate 时自增,作为快照缓存的失效依据。
        /// composeText/composeSegments 含 O(文本长度²) 的 LCS/overlap,新闻联播等超长句
        /// (单气泡累积 500+ 字)下单次成本高。缓存后:内容未变的历史气泡(切换/markBubbleEnded
        /// 遍历时)直接复用上次结果,只对本轮真正变更的活跃气泡重算,避免长跑随文本长度平方放大
        /// 的 CPU 占用(设备发烫根因)。
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
        aggregate.latestSessionId = max(aggregate.latestSessionId, event.sessionId)
        // 语言标签在气泡创建时即冻结,不随后续事件覆盖:
        // 切换语言后,正在进行的旧气泡应保留其原始源/目标语言(译文文本仍是旧语言),
        // 新气泡才使用新语言。覆盖会导致旧气泡标签错误地跟随全局语言(见 1v1 语言切换 bug)。

        switch event.stage {
        case .asr:
            if translationAssemblyMode == .offlineCumulative, let text = event.sourceSegmentText {
                aggregate.usesSentenceSource = true
                if event.sentenceState != "end" {
                    aggregate.sentenceSource.update(text: text, id: event.chunkId,
                                                    isFinal: event.sentenceState == "stable")
                }
            } else {
                update(segmentText: event.text,
                       isFinal: event.isFinal,
                       sessionId: event.sessionId,
                       chunkId: event.chunkId,
                       coalesceUnchunkedPartials: true,
                       activePartialSegmentID: &aggregate.activeSourcePartialSegmentID,
                       sessionOrder: &aggregate.sourceSessionOrder,
                       segments: &aggregate.sourceBySession,
                       sessionAliases: &aggregate.sourceSessionAlias,
                       sessionAliasOrder: &aggregate.sourceSessionAliasOrder,
                       chunkAliases: &aggregate.sourceChunkAlias,
                       rawIdsByEffective: &aggregate.sourceRawIdsByEffective,
                       rawChunkByEffective: &aggregate.sourceRawChunkByEffective)
            }
        case .mt:
            if translationAssemblyMode == .offlineCumulative, let text = event.translationSegmentText {
                aggregate.usesSentenceTranslation = true
                aggregate.sentenceTranslation.update(text: text, id: event.chunkId, isFinal: event.isFinal)
            } else if translationAssemblyMode == .offlineCumulative {
                updateOfflineCumulativeTranslation(event, aggregate: &aggregate)
            } else {
                var ignoredActivePartialSegmentID: Int?
                update(segmentText: event.text,
                       isFinal: event.isFinal,
                       sessionId: event.sessionId,
                       chunkId: event.chunkId,
                       coalesceUnchunkedPartials: false,
                       activePartialSegmentID: &ignoredActivePartialSegmentID,
                       sessionOrder: &aggregate.translatedSessionOrder,
                       segments: &aggregate.translatedBySession,
                       sessionAliases: &aggregate.translatedSessionAlias,
                       sessionAliasOrder: &aggregate.translatedSessionAliasOrder,
                       chunkAliases: &aggregate.translatedChunkAlias,
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

    func markBubbleEnded(bubbleId: String) -> [DemoConversationBubbleSnapshot] {
        let normalized = bubbleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return [] }
        endedBubbleIds.insert(normalized)
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

    /// 取本 aggregate 的组装结果:contentVersion 与 isActiveBubble 均命中缓存则直接复用,
    /// 否则重算 composeText/composeSegments(含 O(n²) LCS/overlap)并写回缓存。
    /// 使"全量气泡 × O(n²)/次"降为"仅变更气泡重算",消除长跑随文本长度平方放大的 CPU 占用。
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
                                     isActiveBubble: isActiveBubble)
        let translatedText: String
        let sourceSegments = aggregate.usesSentenceSource ? [] : composeSegments(order: aggregate.sourceSessionOrder,
                                             segments: aggregate.sourceBySession,
                                             rawIds: aggregate.sourceRawIdsByEffective,
                                             rawChunks: aggregate.sourceRawChunkByEffective,
                                             isActiveBubble: isActiveBubble)
        let translatedSegments: [DemoConversationDisplaySegment]
        if aggregate.usesSentenceTranslation {
            translatedText = aggregate.sentenceTranslation.displayText(active: isActiveBubble)
            translatedSegments = []
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
                                              bOffset: aggregate.bOffset,
                                              bDuration: bDuration)
    }

    private func update(segmentText: String?,
                        isFinal: Bool,
                        sessionId: Int,
                        chunkId: String?,
                        coalesceUnchunkedPartials: Bool,
                        activePartialSegmentID: inout Int?,
                        sessionOrder: inout [Int],
                        segments: inout [Int: SessionSegment],
                        sessionAliases: inout [Int: Int],
                        sessionAliasOrder: inout [Int],
                        chunkAliases: inout [String: Int],
                        rawIdsByEffective: inout [Int: Set<Int>],
                        rawChunkByEffective: inout [Int: Set<String>]) {
        let text = (segmentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && isFinal == false { return }
        let normalizedChunk = normalizedChunkId(chunkId)
        let effectiveSessionId: Int
        if let chunkKey = normalizedChunk {
            if let aliasedSessionId = chunkAliases[chunkKey] {
                effectiveSessionId = aliasedSessionId
            } else {
                let newSessionId = nextSyntheticSessionId(segments)
                chunkAliases[chunkKey] = newSessionId
                effectiveSessionId = newSessionId
            }
        } else if coalesceUnchunkedPartials,
                  let activeSegmentID = activePartialSegmentID,
                  segments[activeSegmentID]?.isFinal == false {
            effectiveSessionId = activeSegmentID
        } else {
            effectiveSessionId = sessionAliases[sessionId] ?? sessionId
        }
        if sessionOrder.contains(effectiveSessionId) == false {
            sessionOrder.append(effectiveSessionId)
        }
        let old = segments[effectiveSessionId]
        if let old, old.isFinal, text.isEmpty == false, isIncrementalTransition(old: old.text, new: text) == false {
            let newSessionId = nextSyntheticSessionId(segments)
            sessionOrder.append(newSessionId)
            segments[newSessionId] = SessionSegment(text: text, isFinal: isFinal)
            setSessionAlias(sessionId,
                            effectiveSessionId: newSessionId,
                            aliases: &sessionAliases,
                            aliasOrder: &sessionAliasOrder)
            updateRawSessionIDs(sessionId,
                                effectiveSessionId: newSessionId,
                                coalesceUnchunkedPartials: coalesceUnchunkedPartials,
                                normalizedChunk: normalizedChunk,
                                storage: &rawIdsByEffective)
            if let normalizedChunk { rawChunkByEffective[newSessionId, default: []].insert(normalizedChunk) }
            if coalesceUnchunkedPartials, normalizedChunk == nil {
                activePartialSegmentID = isFinal ? nil : newSessionId
            }
            return
        }
        let mergedText = resolveIncrementalText(old: old?.text ?? "", new: text)
        let finalValue = (old?.isFinal ?? false) || isFinal
        segments[effectiveSessionId] = SessionSegment(text: mergedText, isFinal: finalValue)
        setSessionAlias(sessionId,
                        effectiveSessionId: effectiveSessionId,
                        aliases: &sessionAliases,
                        aliasOrder: &sessionAliasOrder)
        updateRawSessionIDs(sessionId,
                            effectiveSessionId: effectiveSessionId,
                            coalesceUnchunkedPartials: coalesceUnchunkedPartials,
                            normalizedChunk: normalizedChunk,
                            storage: &rawIdsByEffective)
        if let normalizedChunk { rawChunkByEffective[effectiveSessionId, default: []].insert(normalizedChunk) }
        if coalesceUnchunkedPartials, normalizedChunk == nil {
            activePartialSegmentID = finalValue ? nil : effectiveSessionId
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
        return (text,
                [DemoConversationDisplaySegment(text: text,
                                                rawSessionIds: aggregate.offlineTranslatedSessionIds,
                                                rawChunkIds: aggregate.offlineTranslatedChunkIds)])
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

    /// 更新服务端 session 到展示分段的别名，并以固定窗口限制长跑 partial 的历史引用。
    private func setSessionAlias(_ sessionId: Int,
                                 effectiveSessionId: Int,
                                 aliases: inout [Int: Int],
                                 aliasOrder: inout [Int]) {
        if aliases[sessionId] == nil {
            aliasOrder.append(sessionId)
        }
        aliases[sessionId] = effectiveSessionId
        while aliasOrder.count > Self.maxSessionAliasesPerBubble {
            let expiredSessionId = aliasOrder.removeFirst()
            aliases.removeValue(forKey: expiredSessionId)
        }
    }

    /// 无 chunkId 的 ASR partial 仅需当前 session 用于高亮；保留历史 ID 会造成单气泡内存线性增长。
    private func updateRawSessionIDs(_ sessionId: Int,
                                     effectiveSessionId: Int,
                                     coalesceUnchunkedPartials: Bool,
                                     normalizedChunk: String?,
                                     storage: inout [Int: Set<Int>]) {
        if coalesceUnchunkedPartials, normalizedChunk == nil {
            storage[effectiveSessionId] = [sessionId]
        } else {
            storage[effectiveSessionId, default: []].insert(sessionId)
        }
    }

    private func normalizedChunkId(_ chunkId: String?) -> String? {
        let normalized = (chunkId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// 按 session 顺序产出独立展示片段（不做跨 session 合并去重），用于按 session/chunk 着色。
    private func composeSegments(order: [Int],
                                 segments: [Int: SessionSegment],
                                 rawIds: [Int: Set<Int>],
                                 rawChunks: [Int: Set<String>],
                                 isActiveBubble: Bool) -> [DemoConversationDisplaySegment] {
        var result: [DemoConversationDisplaySegment] = []
        var latestIsFinal = true
        for sessionId in order {
            guard let segment = segments[sessionId] else { continue }
            let normalized = normalizedDisplayText(segment.text, isFinal: segment.isFinal)
            guard normalized.isEmpty == false else { continue }
            result.append(DemoConversationDisplaySegment(text: normalized,
                                                         rawSessionIds: rawIds[sessionId] ?? [sessionId],
                                                         rawChunkIds: rawChunks[sessionId] ?? []))
            latestIsFinal = segment.isFinal
        }
        guard result.isEmpty == false else { return [] }
        // 活跃气泡的最后一段若未 final，补省略号，与 composeText 行为保持一致。
        if latestIsFinal == false && isActiveBubble {
            let lastIndex = result.count - 1
            result[lastIndex] = withText(result[lastIndex], appendEllipsisIfNeeded(result[lastIndex].text))
        }
        return result
    }

    private func withText(_ segment: DemoConversationDisplaySegment, _ text: String) -> DemoConversationDisplaySegment {
        DemoConversationDisplaySegment(text: text,
                                       rawSessionIds: segment.rawSessionIds,
                                       rawChunkIds: segment.rawChunkIds,
                                       isHighlighted: segment.isHighlighted)
    }

    private func composeText(order: [Int], segments: [Int: SessionSegment], isActiveBubble: Bool) -> String {
        var orderedTexts: [String] = []
        var latestIsFinal = true
        for sessionId in order {
            guard let segment = segments[sessionId] else { continue }
            let text = normalizedDisplayText(segment.text, isFinal: segment.isFinal)
            guard text.isEmpty == false else { continue }
            orderedTexts.append(text)
            latestIsFinal = segment.isFinal
        }
        guard orderedTexts.isEmpty == false else { return "" }
        var merged = orderedTexts[0]
        if orderedTexts.count > 1 {
            for idx in 1..<orderedTexts.count {
                merged = mergeCumulativeText(merged, orderedTexts[idx])
            }
        }
        if latestIsFinal || isActiveBubble == false {
            return removeTrailingEllipsis(merged)
        }
        return appendEllipsisIfNeeded(merged)
    }

    private func resolveIncrementalText(old: String, new: String) -> String {
        let lhs = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rhs.isEmpty == false else { return lhs }
        guard lhs.isEmpty == false else { return rhs }
        if shouldPreferRightInUpdate(lhs: lhs, rhs: rhs) { return rhs }
        if shouldPreferLeftInUpdate(lhs: lhs, rhs: rhs) { return lhs }
        return rhs
    }

    private func mergeCumulativeText(_ lhsRaw: String, _ rhsRaw: String) -> String {
        let lhs = lhsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = rhsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lhs.isEmpty == false else { return rhs }
        guard rhs.isEmpty == false else { return lhs }
        if shouldPreferRightInMerge(lhs: lhs, rhs: rhs) { return rhs }
        if shouldPreferLeftInMerge(lhs: lhs, rhs: rhs) { return lhs }
        let overlap = longestOverlap(lhs, rhs)
        if overlap > 0 {
            let start = rhs.index(rhs.startIndex, offsetBy: overlap)
            return lhs + rhs[start...]
        }
        let similarity = normalizedSimilarity(lhs, rhs)
        if similarity >= 0.78 {
            return rhs.count >= lhs.count ? rhs : lhs
        }
        return lhs + " " + rhs
    }

    private func longestOverlap(_ lhs: String, _ rhs: String) -> Int {
        // 逐位比较取代 lhs[...] == rhs[...] 的 Substring 相等,不分配子串。
        // 与原实现同阶但常数与内存分配大幅降低,对齐 Android(regionMatches);
        // 新闻联播超长句下 mergeCumulativeText 高频调用,子串分配是发烫的次要来源。
        let a = Array(lhs)
        let b = Array(rhs)
        let maxCount = min(a.count, b.count)
        guard maxCount > 0 else { return 0 }
        for k in stride(from: maxCount, through: 1, by: -1) {
            var matched = true
            let lhsOffset = a.count - k
            var i = 0
            while i < k {
                if a[lhsOffset + i] != b[i] {
                    matched = false
                    break
                }
                i += 1
            }
            if matched { return k }
        }
        return 0
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

    private func isIncrementalTransition(old: String, new: String) -> Bool {
        let lhs = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lhs.isEmpty == false, rhs.isEmpty == false else { return false }
        if shouldPreferRightInUpdate(lhs: lhs, rhs: rhs) { return true }
        if shouldPreferLeftInUpdate(lhs: lhs, rhs: rhs) { return true }
        if normalizedSimilarity(lhs, rhs) >= 0.70 { return true }
        return false
    }

    private func nextSyntheticSessionId(_ segments: [Int: SessionSegment]) -> Int {
        var id = -1
        while segments[id] != nil {
            id -= 1
        }
        return id
    }

    private func shouldPreferRightInUpdate(lhs: String, rhs: String) -> Bool {
        if lhs == rhs { return true }
        if rhs.hasPrefix(lhs) || rhs.contains(lhs) { return true }
        let lhsKey = normalizeCompareKey(lhs)
        let rhsKey = normalizeCompareKey(rhs)
        if lhsKey.isEmpty || rhsKey.isEmpty { return false }
        if rhsKey == lhsKey { return true }
        if rhsKey.hasPrefix(lhsKey) || rhsKey.contains(lhsKey) { return true }
        if normalizedSimilarity(lhs, rhs) >= 0.88 && rhs.count >= lhs.count { return true }
        return false
    }

    private func shouldPreferLeftInUpdate(lhs: String, rhs: String) -> Bool {
        if lhs.hasPrefix(rhs) || lhs.contains(rhs) { return true }
        let lhsKey = normalizeCompareKey(lhs)
        let rhsKey = normalizeCompareKey(rhs)
        if lhsKey.isEmpty || rhsKey.isEmpty { return false }
        if lhsKey.hasPrefix(rhsKey) || lhsKey.contains(rhsKey) { return true }
        if normalizedSimilarity(lhs, rhs) >= 0.88 && lhs.count > rhs.count { return true }
        return false
    }

    private func shouldPreferRightInMerge(lhs: String, rhs: String) -> Bool {
        if lhs == rhs { return false }
        if rhs.hasPrefix(lhs) || rhs.contains(lhs) { return true }
        let lhsKey = normalizeCompareKey(lhs)
        let rhsKey = normalizeCompareKey(rhs)
        if lhsKey.isEmpty || rhsKey.isEmpty { return false }
        if rhsKey == lhsKey { return rhs.count >= lhs.count }
        if rhsKey.hasPrefix(lhsKey) || rhsKey.contains(lhsKey) { return true }
        return false
    }

    private func shouldPreferLeftInMerge(lhs: String, rhs: String) -> Bool {
        if lhs.hasPrefix(rhs) || lhs.contains(rhs) { return true }
        let lhsKey = normalizeCompareKey(lhs)
        let rhsKey = normalizeCompareKey(rhs)
        if lhsKey.isEmpty || rhsKey.isEmpty { return false }
        if lhsKey == rhsKey { return lhs.count > rhs.count }
        if lhsKey.hasPrefix(rhsKey) || lhsKey.contains(rhsKey) { return true }
        return false
    }

    private func normalizeCompareKey(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if CharacterSet.punctuationCharacters.contains(scalar) { return false }
            if CharacterSet.symbols.contains(scalar) { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private func normalizedSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsKey = normalizeCompareKey(lhs)
        let rhsKey = normalizeCompareKey(rhs)
        guard lhsKey.isEmpty == false, rhsKey.isEmpty == false else { return 0 }
        let common = longestCommonSubstringLength(lhsKey, rhsKey)
        let denominator = max(lhsKey.count, rhsKey.count)
        guard denominator > 0 else { return 0 }
        return Double(common) / Double(denominator)
    }

    private func longestCommonSubstringLength(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard a.isEmpty == false, b.isEmpty == false else { return 0 }
        // 一维滚动数组:空间 O(min) 而非二维 O(a×b)。
        // 新闻联播超长句(500+ 字)下,二维 DP 每次分配 ~25 万个 Int 的嵌套数组,
        // partial 高频重算是设备发烫根因之一(bug 7056277420)。dp[j] 表示以 a[i-1]、b[j-1]
        // 结尾的最长公共子串长度;按 j 从大到小更新,diagUpLeft 保存上一行 dp[j-1](左上角)。
        let inner = b.count
        var dp = Array(repeating: 0, count: inner + 1)
        var best = 0
        var i = 1
        while i <= a.count {
            var diagUpLeft = 0 // dp[i-1][j-1]
            var j = 1
            while j <= inner {
                let temp = dp[j] // 保存 dp[i-1][j],作为下一列的左上角
                if a[i - 1] == b[j - 1] {
                    dp[j] = diagUpLeft + 1
                    if dp[j] > best { best = dp[j] }
                } else {
                    dp[j] = 0
                }
                diagUpLeft = temp
                j += 1
            }
            i += 1
        }
        return best
    }
}

/// 把气泡的 meta 行 + 源语言/目标语言分段文本渲染为带颜色的富文本。
///
/// 仅 `online_tts_state` 命中的 session 片段（`isHighlighted`）显示为蓝色，其余为默认色；
/// meta 行使用次要色。两个在线场景（收听 / 一对一）共用。
enum DemoConversationSegmentRenderer {
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
                   segments: sourceSegments, fallbackText: sourceFallbackText, font: font)
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
                                   font: UIFont) {
        result.append(NSAttributedString(string: label,
                                         attributes: [.font: font, .foregroundColor: UIColor.label]))
        let nonEmpty = segments.filter { $0.text.isEmpty == false }
        // 离线等场景未提供分段时，回退到整段纯文本（默认色），保持既有展示。
        guard nonEmpty.isEmpty == false else {
            let display = fallbackText.isEmpty ? "..." : fallbackText
            result.append(NSAttributedString(string: display,
                                             attributes: [.font: font, .foregroundColor: UIColor.label]))
            return
        }
        for (index, segment) in nonEmpty.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " ",
                                                 attributes: [.font: font, .foregroundColor: UIColor.label]))
            }
            let color: UIColor = segment.isHighlighted ? .systemBlue : .label
            result.append(NSAttributedString(string: segment.text,
                                             attributes: [.font: font, .foregroundColor: color]))
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
