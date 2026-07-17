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
                                     chunkId: chunkId(from: result))
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
        if let bubble = result.extraData["bubble_id"] as? String, bubble.isEmpty == false { return bubble }
        if let bubble = result.extraData["bubbleId"] as? String, bubble.isEmpty == false { return bubble }
        return "sid_\(result.sessionId)"
    }

    private static func lane(from result: TmkResult<String>) -> DemoConversationLane {
        if let ch = (result.extraData["channel"] as? String)?.lowercased(), ch == DemoConversationLane.right.rawValue {
            return .right
        }
        return .left
    }

    private static func chunkId(from result: TmkResult<String>) -> String? {
        if let chunkId = result.extraData["chunk_id"] as? String, chunkId.isEmpty == false { return chunkId }
        if let chunkId = result.extraData["chunkId"] as? String, chunkId.isEmpty == false { return chunkId }
        if let chunkId = result.extraData["chunk_id"] as? Int { return String(chunkId) }
        if let chunkId = result.extraData["chunkId"] as? Int { return String(chunkId) }
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
        return containsMeaningfulContent(text)
    }

    private static func containsMeaningfulContent(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) {
                continue
            }
            if CharacterSet.symbols.contains(scalar) {
                continue
            }
            return true
        }
        return false
    }
}

final class DemoConversationBubbleAssembler {
    private struct SessionSegment {
        var text: String
        var isFinal: Bool
    }

    private struct BubbleAggregate {
        var sourceLangCode: String
        var targetLangCode: String
        var sourceSessionOrder: [Int] = []
        var translatedSessionOrder: [Int] = []
        var sourceBySession: [Int: SessionSegment] = [:]
        var translatedBySession: [Int: SessionSegment] = [:]
        var sourceSessionAlias: [Int: Int] = [:]
        var translatedSessionAlias: [Int: Int] = [:]
        var sourceChunkAlias: [String: Int] = [:]
        var translatedChunkAlias: [String: Int] = [:]
        /// effectiveSessionId -> 贡献它的原始服务端 session_id 集合（用于按 session 着色）。
        var sourceRawIdsByEffective: [Int: Set<Int>] = [:]
        var translatedRawIdsByEffective: [Int: Set<Int>] = [:]
        /// effectiveSessionId -> 贡献它的原始服务端 chunk_id 集合（用于按 chunk 着色）。
        var sourceRawChunkByEffective: [Int: Set<String>] = [:]
        var translatedRawChunkByEffective: [Int: Set<String>] = [:]
        var latestSessionId: Int = 0
        /// 气泡内第一条 ASR final 句子的 offset(纳秒)。
        var bOffset: Int64? = nil
        /// 气泡内最后一条 ASR final 句子的 (offset+duration)(纳秒)。
        var bLastEnd: Int64? = nil
    }

    private var aggregates: [String: BubbleAggregate] = [:]
    private var activeBubbleIdByLane: [DemoConversationLane: String] = [:]
    private var endedBubbleIds = Set<String>()

    func reset() {
        aggregates.removeAll()
        activeBubbleIdByLane.removeAll()
        endedBubbleIds.removeAll()
    }

    func consume(_ event: DemoConversationEvent) -> [DemoConversationBubbleSnapshot] {
        let key = DemoConversationBubbleAssembler.rowKey(bubbleId: event.bubbleId, lane: event.lane)
        var snapshots: [DemoConversationBubbleSnapshot] = []

        if let previousBubbleId = activeBubbleIdByLane[event.lane],
           previousBubbleId != event.bubbleId {
            let previousKey = DemoConversationBubbleAssembler.rowKey(bubbleId: previousBubbleId, lane: event.lane)
            if let previousAggregate = aggregates[previousKey],
               let previousSnapshot = makeSnapshot(bubbleId: previousBubbleId,
                                                   lane: event.lane,
                                                   aggregate: previousAggregate,
                                                   isActiveBubble: false) {
                snapshots.append(previousSnapshot)
            }
        }

        activeBubbleIdByLane[event.lane] = event.bubbleId
        var aggregate = aggregates[key] ?? BubbleAggregate(sourceLangCode: event.sourceLangCode,
                                                           targetLangCode: event.targetLangCode)
        aggregate.latestSessionId = max(aggregate.latestSessionId, event.sessionId)
        // 语言标签在气泡创建时即冻结,不随后续事件覆盖:
        // 切换语言后,正在进行的旧气泡应保留其原始源/目标语言(译文文本仍是旧语言),
        // 新气泡才使用新语言。覆盖会导致旧气泡标签错误地跟随全局语言(见 1v1 语言切换 bug)。

        switch event.stage {
        case .asr:
            update(segmentText: event.text,
                   isFinal: event.isFinal,
                   sessionId: event.sessionId,
                   chunkId: event.chunkId,
                   sessionOrder: &aggregate.sourceSessionOrder,
                   segments: &aggregate.sourceBySession,
                   sessionAliases: &aggregate.sourceSessionAlias,
                   chunkAliases: &aggregate.sourceChunkAlias,
                   rawIdsByEffective: &aggregate.sourceRawIdsByEffective,
                   rawChunkByEffective: &aggregate.sourceRawChunkByEffective)
        case .mt:
            update(segmentText: event.text,
                   isFinal: event.isFinal,
                   sessionId: event.sessionId,
                   chunkId: event.chunkId,
                   sessionOrder: &aggregate.translatedSessionOrder,
                   segments: &aggregate.translatedBySession,
                   sessionAliases: &aggregate.translatedSessionAlias,
                   chunkAliases: &aggregate.translatedChunkAlias,
                   rawIdsByEffective: &aggregate.translatedRawIdsByEffective,
                   rawChunkByEffective: &aggregate.translatedRawChunkByEffective)
        case .tts:
            break
        }

        // 聚合 b_offset/b_duration：仅统计 ASR 且 final 的句子。
        // b_offset = 第一条 final 句子的 offset;b_duration = 最后一条 final 句子的 (offset+duration) − b_offset。
        if event.stage == .asr, event.isFinal, let off = event.offset {
            if aggregate.bOffset == nil { aggregate.bOffset = off }
            if let dur = event.duration { aggregate.bLastEnd = off + dur }
        }

        aggregates[key] = aggregate
        if let currentSnapshot = makeSnapshot(bubbleId: event.bubbleId,
                                              lane: event.lane,
                                              aggregate: aggregate,
                                              isActiveBubble: true) {
            snapshots.append(currentSnapshot)
        }
        return snapshots
    }

    func markBubbleEnded(bubbleId: String) -> [DemoConversationBubbleSnapshot] {
        let normalized = bubbleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return [] }
        endedBubbleIds.insert(normalized)
        var snapshots: [DemoConversationBubbleSnapshot] = []
        for lane in [DemoConversationLane.left, .right] {
            let key = DemoConversationBubbleAssembler.rowKey(bubbleId: normalized, lane: lane)
            guard let aggregate = aggregates[key],
                  let snapshot = makeSnapshot(bubbleId: normalized,
                                              lane: lane,
                                              aggregate: aggregate,
                                              isActiveBubble: activeBubbleIdByLane[lane] == normalized) else {
                continue
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    static func rowKey(bubbleId: String, lane: DemoConversationLane) -> String {
        "\(bubbleId)_\(lane.rawValue)"
    }

    private func makeSnapshot(bubbleId: String,
                              lane: DemoConversationLane,
                              aggregate: BubbleAggregate,
                              isActiveBubble: Bool) -> DemoConversationBubbleSnapshot? {
        let sourceText = composeText(order: aggregate.sourceSessionOrder,
                                     segments: aggregate.sourceBySession,
                                     isActiveBubble: isActiveBubble)
        let translatedText = composeText(order: aggregate.translatedSessionOrder,
                                         segments: aggregate.translatedBySession,
                                         isActiveBubble: isActiveBubble)
        if sourceText.isEmpty && translatedText.isEmpty {
            return nil
        }
        let sourceSegments = composeSegments(order: aggregate.sourceSessionOrder,
                                             segments: aggregate.sourceBySession,
                                             rawIds: aggregate.sourceRawIdsByEffective,
                                             rawChunks: aggregate.sourceRawChunkByEffective,
                                             isActiveBubble: isActiveBubble)
        let translatedSegments = composeSegments(order: aggregate.translatedSessionOrder,
                                                 segments: aggregate.translatedBySession,
                                                 rawIds: aggregate.translatedRawIdsByEffective,
                                                 rawChunks: aggregate.translatedRawChunkByEffective,
                                                 isActiveBubble: isActiveBubble)
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
                                              sourceSegments: sourceSegments,
                                              translatedSegments: translatedSegments,
                                              isBubbleEnded: endedBubbleIds.contains(bubbleId),
                                              bOffset: aggregate.bOffset,
                                              bDuration: bDuration)
    }

    private func update(segmentText: String?,
                        isFinal: Bool,
                        sessionId: Int,
                        chunkId: String?,
                        sessionOrder: inout [Int],
                        segments: inout [Int: SessionSegment],
                        sessionAliases: inout [Int: Int],
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
            sessionAliases[sessionId] = newSessionId
            rawIdsByEffective[newSessionId, default: []].insert(sessionId)
            if let normalizedChunk { rawChunkByEffective[newSessionId, default: []].insert(normalizedChunk) }
            return
        }
        let mergedText = resolveIncrementalText(old: old?.text ?? "", new: text)
        let finalValue = (old?.isFinal ?? false) || isFinal
        segments[effectiveSessionId] = SessionSegment(text: mergedText, isFinal: finalValue)
        sessionAliases[sessionId] = effectiveSessionId
        rawIdsByEffective[effectiveSessionId, default: []].insert(sessionId)
        if let normalizedChunk { rawChunkByEffective[effectiveSessionId, default: []].insert(normalizedChunk) }
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
        let maxCount = min(lhs.count, rhs.count)
        guard maxCount > 0 else { return 0 }
        for k in stride(from: maxCount, through: 1, by: -1) {
            let lhsStart = lhs.index(lhs.endIndex, offsetBy: -k)
            let rhsEnd = rhs.index(rhs.startIndex, offsetBy: k)
            if lhs[lhsStart...] == rhs[..<rhsEnd] {
                return k
            }
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
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        var best = 0
        var i = 1
        while i <= a.count {
            var j = 1
            while j <= b.count {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                    if dp[i][j] > best { best = dp[i][j] }
                }
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
