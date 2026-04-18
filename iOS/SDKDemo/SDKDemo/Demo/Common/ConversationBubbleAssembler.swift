import Foundation
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
}

struct DemoConversationBubbleSnapshot {
    let bubbleId: String
    let sessionId: Int
    let lane: DemoConversationLane
    let sourceLangCode: String
    let targetLangCode: String
    let sourceText: String
    let translatedText: String
}

enum DemoConversationEventAdapter {
    static func makeRecognizedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        let text = normalized(result.data)
        guard text.isEmpty == false || isFinal else { return nil }
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: result.sessionId,
                                     lane: lane(from: result),
                                     stage: .asr,
                                     isFinal: isFinal,
                                     text: text,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode)
    }

    static func makeTranslatedEvent(from result: TmkResult<String>, isFinal: Bool) -> DemoConversationEvent? {
        let text = normalized(result.data)
        guard text.isEmpty == false || isFinal else { return nil }
        return DemoConversationEvent(bubbleId: bubbleId(from: result),
                                     sessionId: result.sessionId,
                                     lane: lane(from: result),
                                     stage: .mt,
                                     isFinal: isFinal,
                                     text: text,
                                     sourceLangCode: result.srcCode,
                                     targetLangCode: result.dstCode)
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
                                     targetLangCode: result.dstCode)
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

    private static func normalized(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        var latestSessionId: Int = 0
    }

    private var aggregates: [String: BubbleAggregate] = [:]

    func reset() {
        aggregates.removeAll()
    }

    func consume(_ event: DemoConversationEvent) -> DemoConversationBubbleSnapshot? {
        let key = DemoConversationBubbleAssembler.rowKey(bubbleId: event.bubbleId, lane: event.lane)
        var aggregate = aggregates[key] ?? BubbleAggregate(sourceLangCode: event.sourceLangCode,
                                                           targetLangCode: event.targetLangCode)
        aggregate.latestSessionId = max(aggregate.latestSessionId, event.sessionId)
        aggregate.sourceLangCode = event.sourceLangCode
        aggregate.targetLangCode = event.targetLangCode

        switch event.stage {
        case .asr:
            update(segmentText: event.text,
                   isFinal: event.isFinal,
                   sessionId: event.sessionId,
                   sessionOrder: &aggregate.sourceSessionOrder,
                   segments: &aggregate.sourceBySession,
                   sessionAliases: &aggregate.sourceSessionAlias)
        case .mt:
            update(segmentText: event.text,
                   isFinal: event.isFinal,
                   sessionId: event.sessionId,
                   sessionOrder: &aggregate.translatedSessionOrder,
                   segments: &aggregate.translatedBySession,
                   sessionAliases: &aggregate.translatedSessionAlias)
        case .tts:
            break
        }

        aggregates[key] = aggregate
        let sourceText = composeText(order: aggregate.sourceSessionOrder, segments: aggregate.sourceBySession)
        let translatedText = composeText(order: aggregate.translatedSessionOrder, segments: aggregate.translatedBySession)
        if sourceText.isEmpty && translatedText.isEmpty {
            return nil
        }
        return DemoConversationBubbleSnapshot(bubbleId: event.bubbleId,
                                              sessionId: aggregate.latestSessionId,
                                              lane: event.lane,
                                              sourceLangCode: aggregate.sourceLangCode,
                                              targetLangCode: aggregate.targetLangCode,
                                              sourceText: sourceText,
                                              translatedText: translatedText)
    }

    static func rowKey(bubbleId: String, lane: DemoConversationLane) -> String {
        "\(bubbleId)_\(lane.rawValue)"
    }

    private func update(segmentText: String?,
                        isFinal: Bool,
                        sessionId: Int,
                        sessionOrder: inout [Int],
                        segments: inout [Int: SessionSegment],
                        sessionAliases: inout [Int: Int]) {
        let text = (segmentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && isFinal == false { return }
        let effectiveSessionId = sessionAliases[sessionId] ?? sessionId
        if sessionOrder.contains(effectiveSessionId) == false {
            sessionOrder.append(effectiveSessionId)
        }
        let old = segments[effectiveSessionId]
        if let old, old.isFinal, text.isEmpty == false, isIncrementalTransition(old: old.text, new: text) == false {
            let newSessionId = nextSyntheticSessionId(segments)
            sessionOrder.append(newSessionId)
            segments[newSessionId] = SessionSegment(text: text, isFinal: isFinal)
            sessionAliases[sessionId] = newSessionId
            return
        }
        let mergedText = resolveIncrementalText(old: old?.text ?? "", new: text)
        let finalValue = (old?.isFinal ?? false) || isFinal
        segments[effectiveSessionId] = SessionSegment(text: mergedText, isFinal: finalValue)
        sessionAliases[sessionId] = effectiveSessionId
    }

    private func composeText(order: [Int], segments: [Int: SessionSegment]) -> String {
        var orderedTexts: [String] = []
        var latestIsFinal = true
        for sessionId in order {
            guard let segment = segments[sessionId] else { continue }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return latestIsFinal ? merged : appendEllipsisIfNeeded(merged)
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
