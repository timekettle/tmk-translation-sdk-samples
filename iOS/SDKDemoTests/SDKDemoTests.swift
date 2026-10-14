import XCTest
import UIKit
import TmkTranslationSDK
@testable import SDKDemo

@MainActor
final class SDKDemoTests: XCTestCase {
    @MainActor
    func testOnlineBubbleEndKeepsNilReasonAcrossBothLanesAndLateResults() async throws {
        let assembler = DemoConversationBubbleAssembler()
        for lane in [DemoConversationLane.left, .right] {
            _ = assembler.consume(.init(bubbleId: "online", sessionId: 1, lane: lane,
                stage: .asr, isFinal: true, text: "source", sourceLangCode: "zh", targetLangCode: "en"))
        }
        let ended = assembler.markBubbleEnded(bubbleId: "online")
        XCTAssertEqual(ended.count, 2)
        XCTAssertTrue(ended.allSatisfy(\.isBubbleEnded))
        XCTAssertTrue(ended.allSatisfy { $0.bubbleEndReason == nil })
        let late = try XCTUnwrap(assembler.consume(.init(bubbleId: "online", sessionId: 1, lane: .left,
            stage: .mt, isFinal: true, text: "translated", sourceLangCode: "zh", targetLangCode: "en")).last)
        XCTAssertTrue(late.isBubbleEnded)
        XCTAssertNil(late.bubbleEndReason)
    }

    @MainActor
    func testOnlineListenNilReasonUsesOriginalGreenEndBorder() async throws {
        let cell = NowListeningBubbleCell(style: .default, reuseIdentifier: nil)
        let row = NowListeningRowViewData(sessionId: 1, bubbleId: "online", sourceLangCode: "zh",
            targetLangCode: "en", sourceText: "source", translatedText: "translated", isBubbleEnded: true)
        cell.configure(row: row, roomNo: "room", scenario: "listen", mode: "online",
            configuredSampleRate: 16000, configuredChannels: 1, captureSampleRate: 16000,
            captureChannels: 1, playbackChannels: 1)
        let border = try XCTUnwrap(cell.contentView.subviews.first).layer
        XCTAssertEqual(border.borderWidth, 1)
        XCTAssertEqual(border.borderColor, UIColor.systemGreen.cgColor)
    }

    @MainActor
    func testOnlineOneToOneNilReasonUsesOriginalLaneEndBorders() async throws {
        for isRight in [false, true] {
            let cell = OneToOneBubbleCell(style: .default, reuseIdentifier: nil)
            cell.configure(metaText: "online", sourceLangCode: "zh", sourceText: "source", sourceSegments: [],
                targetLangCode: "en", translatedText: "translated", translatedSegments: [],
                isRightBubble: isRight, isBubbleEnded: true, bubbleEndReason: nil)
            let border = try XCTUnwrap(cell.contentView.subviews.first).layer
            XCTAssertEqual(border.borderWidth, 1)
            XCTAssertEqual(border.borderColor, (isRight ? UIColor.systemBlue : UIColor.systemGreen).cgColor)
        }
    }

    @MainActor
    func testOfflineBubbleEndReasonColorsRemainUnchanged() async throws {
        let cases: [(String, UIColor)] = [("length", .systemYellow), ("error", .systemRed),
            ("natural", .systemGreen), ("native_final", .systemGreen), ("empty_final", .systemGreen),
            ("stop", .systemPurple), ("other", .systemPurple), (" ", .systemPurple)]
        for (reason, color) in cases {
            let assembler = DemoConversationBubbleAssembler(translationAssemblyMode: .offlineCumulative)
            _ = assembler.consume(.init(bubbleId: "offline", sessionId: 1, lane: .left,
                stage: .asr, isFinal: true, text: "source", sourceLangCode: "zh", targetLangCode: "en"))
            let snapshot = try XCTUnwrap(assembler.markBubbleEnded(bubbleId: "offline", reason: reason).first)
            let cell = NowListeningBubbleCell(style: .default, reuseIdentifier: nil)
            let row = NowListeningRowViewData(sessionId: 1, bubbleId: "offline", sourceLangCode: "zh",
                targetLangCode: "en", sourceText: "source", translatedText: "translated",
                isBubbleEnded: snapshot.isBubbleEnded, bubbleEndReason: snapshot.bubbleEndReason)
            cell.configure(row: row, roomNo: "", scenario: "listen", mode: "offline",
                configuredSampleRate: 16000, configuredChannels: 1, captureSampleRate: 16000,
                captureChannels: 1, playbackChannels: 1)
            XCTAssertEqual(try XCTUnwrap(cell.contentView.subviews.first).layer.borderColor, color.cgColor, reason)
            for isRight in [false, true] {
                let pairCell = OneToOneBubbleCell(style: .default, reuseIdentifier: nil)
                pairCell.configure(metaText: "offline", sourceLangCode: "zh", sourceText: "source", sourceSegments: [],
                    targetLangCode: "en", translatedText: "translated", translatedSegments: [],
                    isRightBubble: isRight, isBubbleEnded: true, bubbleEndReason: snapshot.bubbleEndReason)
                let expected = isRight && color == .systemGreen ? UIColor.systemBlue : color
                XCTAssertEqual(try XCTUnwrap(pairCell.contentView.subviews.first).layer.borderColor, expected.cgColor, reason)
            }
        }
    }

    @MainActor
    func testSourceRendererDoesNotInsertCharactersBetweenRawFragments() async {
        let fragments = [" \t他说……", "\n然后离开。\u{00a0}"].map {
            DemoConversationDisplaySegment(text: $0, rawSessionIds: [], rawChunkIds: [])
        }
        let rendered = DemoConversationSegmentRenderer.makeBubbleText(metaText: "meta", sourceLangCode: "zh",
            sourceSegments: fragments, sourceFallbackText: "", targetLangCode: "en",
            translatedSegments: [], translatedFallbackText: "", font: .systemFont(ofSize: 14)).string
        XCTAssertTrue(rendered.contains("源语言(zh)： \t他说……\n然后离开。\u{00a0}\n目标语言(en)："))
    }

    func testOfflineCallbackLogExposesSentenceIdentityAndTextForBothStages() async {
        let result = TmkResult(sessionId: 179021822898000,
                               data: "你好，\n世界",
                               srcCode: "zh-CN",
                               dstCode: "en-US",
                               isLast: true,
                               extraData: ["channel": "1", "chunk_id": "12", "sentence_state": "stable"])

        for (stage, callback) in [("ASR", "onRecognized"), ("MT", "onTranslate")] {
            let line = DemoTmkResultLogFormatter.makeOfflineCallbackLine(scene: "OfflineListen",
                                                                          stage: stage,
                                                                          result: result,
                                                                          isFinal: true)
            XCTAssertTrue(line.contains("callback=\(callback)"))
            XCTAssertTrue(line.contains("sessionId=179021822898000"))
            XCTAssertTrue(line.contains("chunkId=12"))
            XCTAssertTrue(line.contains("sentence_state=stable"))
            XCTAssertTrue(line.contains("isFinal=true"))
            XCTAssertTrue(line.contains("text=\"你好，\\n世界\""))
            XCTAssertFalse(line.contains("\n"), "一条回调必须留在同一日志行")
        }
    }

    @MainActor
    func testOnlineOneToOneBubbleAssemblerComposesFinalMTAndCurrentChunk() async {
        let assembler = DemoConversationBubbleAssembler()

        let firstFinal = DemoConversationEvent(bubbleId: "bubble-1",
                                               sessionId: 1001,
                                               lane: .right,
                                               stage: .mt,
                                               isFinal: true,
                                               text: "hello",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US",
                                               chunkId: "1")
        let firstSnapshots = assembler.consume(firstFinal)
        XCTAssertEqual(firstSnapshots.last?.translatedText, "hello")

        let secondPartial = DemoConversationEvent(bubbleId: "bubble-1",
                                                 sessionId: 1001,
                                                 lane: .right,
                                                 stage: .mt,
                                                 isFinal: false,
                                                 text: "world",
                                                 sourceLangCode: "zh-CN",
                                                 targetLangCode: "en-US",
                                                 chunkId: "2")
        let secondSnapshots = assembler.consume(secondPartial)

        XCTAssertEqual(secondSnapshots.last?.translatedText, "hello world...")
    }

    @MainActor
    func testBubbleAssemblerUpdatesCurrentMTChunkByChunkId() async {
        let assembler = DemoConversationBubbleAssembler()
        let firstPartial = DemoConversationEvent(bubbleId: "bubble-1",
                                                 sessionId: 1001,
                                                 lane: .right,
                                                 stage: .mt,
                                                 isFinal: false,
                                                 text: "hel",
                                                 sourceLangCode: "zh-CN",
                                                 targetLangCode: "en-US",
                                                 chunkId: "chunk-1")
        let secondPartial = DemoConversationEvent(bubbleId: "bubble-1",
                                                  sessionId: 1001,
                                                  lane: .right,
                                                  stage: .mt,
                                                  isFinal: false,
                                                  text: "hello",
                                                  sourceLangCode: "zh-CN",
                                                  targetLangCode: "en-US",
                                                  chunkId: "chunk-1")

        _ = assembler.consume(firstPartial)
        let snapshots = assembler.consume(secondPartial)

        XCTAssertEqual(snapshots.last?.translatedText, "hello...")
    }

    @MainActor
    func testBubbleAssemblerEmptyMTFinalPreservesPartialText() async {
        let assembler = DemoConversationBubbleAssembler()
        let partial = DemoConversationEvent(bubbleId: "bubble-1",
                                            sessionId: 1001,
                                            lane: .right,
                                            stage: .mt,
                                            isFinal: false,
                                            text: "hello",
                                            sourceLangCode: "zh-CN",
                                            targetLangCode: "en-US",
                                            chunkId: "chunk-1")
        let final = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1001,
                                          lane: .right,
                                          stage: .mt,
                                          isFinal: true,
                                          text: "",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "chunk-1")

        _ = assembler.consume(partial)
        XCTAssertEqual(assembler.consume(final).last?.translatedText, "hello")
    }

    @MainActor
    func testBubbleAssemblerFinalizedMTChunkIgnoresLaterEvents() async {
        let assembler = DemoConversationBubbleAssembler()
        let partial = DemoConversationEvent(bubbleId: "bubble-1",
                                            sessionId: 1001,
                                            lane: .right,
                                            stage: .mt,
                                            isFinal: false,
                                            text: "draft",
                                            sourceLangCode: "zh-CN",
                                            targetLangCode: "en-US",
                                            chunkId: "chunk-1")
        let final = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1001,
                                          lane: .right,
                                          stage: .mt,
                                          isFinal: true,
                                          text: "final text",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "chunk-1")
        let correction = DemoConversationEvent(bubbleId: "bubble-1",
                                               sessionId: 1001,
                                               lane: .right,
                                               stage: .mt,
                                               isFinal: true,
                                               text: "must be ignored",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US",
                                               chunkId: "chunk-1")

        _ = assembler.consume(partial)
        XCTAssertEqual(assembler.consume(final).last?.translatedText, "final text")
        XCTAssertEqual(assembler.consume(correction).last?.translatedText, "final text")
    }

    @MainActor
    func testBubbleAssemblerKeepsIdenticalTextFromDifferentMTChunks() async {
        let assembler = DemoConversationBubbleAssembler()
        let first = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1001,
                                          lane: .right,
                                          stage: .mt,
                                          isFinal: true,
                                          text: "same text",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "chunk-1")
        let second = DemoConversationEvent(bubbleId: "bubble-1",
                                           sessionId: 1002,
                                           lane: .right,
                                           stage: .mt,
                                           isFinal: true,
                                           text: "same text",
                                           sourceLangCode: "zh-CN",
                                           targetLangCode: "en-US",
                                           chunkId: "chunk-2")

        _ = assembler.consume(first)
        XCTAssertEqual(assembler.consume(second).last?.translatedText, "same text same text")
    }

    @MainActor
    func testBubbleAssemblerAppendsFinalMTChunkAndMovesToNextChunk() async {
        let assembler = DemoConversationBubbleAssembler()
        let firstFinal = DemoConversationEvent(bubbleId: "bubble-1",
                                               sessionId: 1001,
                                               lane: .right,
                                               stage: .mt,
                                               isFinal: true,
                                               text: "hello",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US",
                                               chunkId: "chunk-1")
        let secondPartial = DemoConversationEvent(bubbleId: "bubble-1",
                                                  sessionId: 1002,
                                                  lane: .right,
                                                  stage: .mt,
                                                  isFinal: false,
                                                  text: "world",
                                                  sourceLangCode: "zh-CN",
                                                  targetLangCode: "en-US",
                                                  chunkId: "chunk-2")
        let secondFinal = DemoConversationEvent(bubbleId: "bubble-1",
                                                sessionId: 1002,
                                                lane: .right,
                                                stage: .mt,
                                                isFinal: true,
                                                text: "world",
                                                sourceLangCode: "zh-CN",
                                                targetLangCode: "en-US",
                                                chunkId: "chunk-2")

        _ = assembler.consume(firstFinal)
        XCTAssertEqual(assembler.consume(secondPartial).last?.translatedText, "hello world...")
        XCTAssertEqual(assembler.consume(secondFinal).last?.translatedText, "hello world")
    }

    @MainActor
    func testOfflineCumulativeTranslationKeepsLatestTextAtBubbleTail() async {
        let assembler = DemoConversationBubbleAssembler(
            translationAssemblyMode: .offlineCumulative
        )
        let firstFinal = DemoConversationEvent(bubbleId: "offline-bubble",
                                               sessionId: 1,
                                               lane: .left,
                                               stage: .mt,
                                               isFinal: true,
                                               text: "First sentence.",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US",
                                               chunkId: "1")
        let currentPartial = DemoConversationEvent(bubbleId: "offline-bubble",
                                                   sessionId: 2,
                                                   lane: .left,
                                                   stage: .mt,
                                                   isFinal: false,
                                                   text: "First sentence. Second sentence.",
                                                   sourceLangCode: "zh-CN",
                                                   targetLangCode: "en-US",
                                                   chunkId: "2")
        let delayedOlderFinal = DemoConversationEvent(bubbleId: "offline-bubble",
                                                      sessionId: 1,
                                                      lane: .left,
                                                      stage: .mt,
                                                      isFinal: true,
                                                      text: "First sentence.",
                                                      sourceLangCode: "zh-CN",
                                                      targetLangCode: "en-US",
                                                      chunkId: "1")

        _ = assembler.consume(firstFinal)
        XCTAssertEqual(assembler.consume(currentPartial).last?.translatedText,
                       "First sentence. Second sentence....")
        XCTAssertEqual(assembler.consume(delayedOlderFinal).last?.translatedText,
                       "First sentence. Second sentence....")
    }

    @MainActor
    func testOfflineAdapterRejectsMissingChunkAndKeepsOnlineFallback() async {
        let missingChunk = TmkResult(sessionId: 1, data: "text", srcCode: "zh", dstCode: "en",
                                     isLast: false, extraData: ["bubble_id": "b"])
        XCTAssertNil(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: missingChunk, isFinal: false))
        XCTAssertNotNil(DemoConversationEventAdapter.makeTranslatedEvent(from: missingChunk, isFinal: false))
        let missingBubble = TmkResult(sessionId: 1, data: "text", srcCode: "zh", dstCode: "en", isLast: false)
        XCTAssertEqual(DemoConversationEventAdapter.makeOfflineRecognizedEvent(from: missingBubble, isFinal: false)?.bubbleId, "sid_1")
        XCTAssertEqual(DemoConversationEventAdapter.makeRecognizedEvent(from: missingBubble, isFinal: false)?.bubbleId, "sid_1")
    }

    @MainActor
    func testOfflineAdapterEmptyStablePreservesAndLocksCurrentSentence() async throws {
        let assembler = DemoConversationBubbleAssembler(translationAssemblyMode: .offlineCumulative)
        let partial = TmkResult(sessionId: 1, data: "draft", srcCode: "zh", dstCode: "en", isLast: false,
                                extraData: ["bubble_id": "b", "chunk_id": "1", "sentence_translation": "draft"])
        let stable = TmkResult(sessionId: 1, data: "", srcCode: "zh", dstCode: "en", isLast: false,
                               extraData: ["bubble_id": "b", "chunk_id": "1", "sentence_translation": "",
                                           "sentence_state": "stable"])
        _ = assembler.consume(try XCTUnwrap(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: partial, isFinal: false)))
        _ = assembler.consume(try XCTUnwrap(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: stable, isFinal: false)))
        _ = assembler.consume(try XCTUnwrap(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: partial, isFinal: false)))
        XCTAssertEqual(assembler.snapshots().last?.translatedText, "draft")
    }

    @MainActor
    func testOfflineAdapterLateStableUpdatesItsChunkAfterBubbleEnd() async throws {
        let assembler = DemoConversationBubbleAssembler(translationAssemblyMode: .offlineCumulative)
        for (id, text, state) in [("1", "A draft", "partial"), ("2", "B draft", "partial")] {
            let result = TmkResult(sessionId: 1, data: text, srcCode: "zh", dstCode: "en", isLast: false,
                                    extraData: ["bubble_id": "b", "chunk_id": id, "sentence_translation": text,
                                                "sentence_state": state])
            _ = assembler.consume(try XCTUnwrap(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: result, isFinal: false)))
        }
        _ = assembler.markBubbleEnded(bubbleId: "b")
        let stable = TmkResult(sessionId: 1, data: "A final", srcCode: "zh", dstCode: "en", isLast: false,
                               extraData: ["bubble_id": "b", "chunk_id": "1", "sentence_translation": "A final",
                                           "sentence_state": "stable"])
        _ = assembler.consume(try XCTUnwrap(DemoConversationEventAdapter.makeOfflineTranslatedEvent(from: stable, isFinal: false)))
        XCTAssertEqual(assembler.snapshots().last?.translatedText, "A final B draft...")
        XCTAssertEqual(assembler.snapshots().last?.isBubbleEnded, true)
    }

    @MainActor
    func testOfflineSentenceStateAcceptsLateStableWithoutReplacingCurrentPartial() async {
        var state = OfflineSentenceTextState()
        state.update(text: "A draft", id: "1", isFinal: false)
        state.update(text: "B draft", id: "2", isFinal: false)
        state.update(text: "A stale", id: "1", isFinal: false)
        XCTAssertEqual(state.displayText(active: true), "A draft B draft...")
        state.update(text: "A final", id: "1", isFinal: true)
        XCTAssertEqual(state.displayText(active: true), "A final B draft...")
        state.update(text: "B final", id: "2", isFinal: true)
        state.update(text: "A duplicate", id: "1", isFinal: true)
        XCTAssertEqual(state.displayText(active: true), "A final B final")
    }

    @MainActor
    func testOfflineSentenceStateEmptyFinalPreservesAndLocksPartial() async {
        var state = OfflineSentenceTextState()
        state.update(text: "draft", id: "1", isFinal: false)
        state.update(text: "", id: "1", isFinal: true)
        state.update(text: "late partial", id: "1", isFinal: false)
        state.update(text: "late final", id: "1", isFinal: true)
        XCTAssertEqual(state.displayText(active: true), "draft")
        XCTAssertTrue(state.partialText.isEmpty)
    }

    @MainActor
    func testOfflineSentenceStateUsesChunkIdentityRatherThanNumericComparison() async {
        var state = OfflineSentenceTextState()
        state.update(text: "A draft", id: "chunk-a", isFinal: false)
        state.update(text: "B draft", id: "chunk-b", isFinal: false)
        state.update(text: "A final", id: "chunk-a", isFinal: true)
        state.update(text: "B final", id: "chunk-b", isFinal: true)
        XCTAssertEqual(state.stableText, "A final B final")
    }

    @MainActor
    func testOfflineViewModelPreservesResultLanguagesAndFallsBackOnlyWhenMissing() async {
        let viewModel = Offline1V1ViewModel()
        let original = DemoConversationEvent(bubbleId: "old", sessionId: 1, lane: .right,
                                             stage: .mt, isFinal: true, text: "old result",
                                             sourceLangCode: "ja", targetLangCode: "de", chunkId: "1")
        let normalized = viewModel.normalizedConversationEvent(from: original, explicitLane: .right)
        XCTAssertEqual(normalized.sourceLangCode, "ja")
        XCTAssertEqual(normalized.targetLangCode, "de")
        let missing = DemoConversationEvent(bubbleId: "new", sessionId: 2, lane: .left,
                                            stage: .asr, isFinal: false, text: "draft",
                                            sourceLangCode: "", targetLangCode: "")
        let fallback = viewModel.normalizedConversationEvent(from: missing, explicitLane: .left)
        XCTAssertEqual(fallback.sourceLangCode, "en")
        XCTAssertEqual(fallback.targetLangCode, "zh")
    }

    @MainActor
    func testOfflineViewModelResolvesNumericChannelBeforeLanguageInference() async {
        let viewModel = Offline1V1ViewModel()
        let result = TmkResult(sessionId: 1, data: "text", srcCode: "ja", dstCode: "de", isLast: false,
                               extraData: ["bubble_id": "b", "channel": NSNumber(value: 2)])
        XCTAssertEqual(viewModel.lane(from: result), .right)
        let left = TmkResult(sessionId: 1, data: "text", srcCode: "ja", dstCode: "de", isLast: false,
                             extraData: ["bubble_id": "b", "channel": " 1 "])
        XCTAssertEqual(viewModel.lane(from: left), .left)
    }

    @MainActor
    func testOfflineSentenceStateReplacesPartialAndPreservesRepeatedSentences() async {
        var state = OfflineSentenceTextState()
        state.update(text: "你好，你叫什么", id: "1", isFinal: false)
        state.update(text: "你好，你叫", id: "1", isFinal: false)
        XCTAssertEqual(state.partialText, "你好，你叫")
        state.update(text: "你好，你叫什么名字。", id: "1", isFinal: true)
        state.update(text: "你来自", id: "2", isFinal: false)
        state.update(text: "你好，你叫什么名字。", id: "1", isFinal: true)
        XCTAssertEqual(state.displayText(active: true), "你好，你叫什么名字。 你来自...")
        state.update(text: "你来自哪里？", id: "2", isFinal: true)
        state.update(text: "你来自哪里？", id: "3", isFinal: true)
        XCTAssertEqual(state.stableText, "你好，你叫什么名字。 你来自哪里？ 你来自哪里？")
    }

    @MainActor
    func testOfflineASRSentenceEventsDoNotAppendUtteranceEndSnapshot() async throws {
        let viewModel = Offline1V1ViewModel()
        let assembler = DemoConversationBubbleAssembler(translationAssemblyMode: .offlineCumulative)
        let updates: [(String, String, String, Bool)] = [
            ("1", "你好，你叫", "partial", false),
            ("1", "你好，你叫什么名字。", "stable", true),
            ("2", "你来自", "partial", false),
            ("2", "你来自哪里？", "stable", true),
            ("3", "你会说中文吗？", "stable", true),
            ("3", "", "end", true)
        ]
        for (id, text, state, final) in updates {
            let result = TmkResult(sessionId: 1, data: "累计全文", srcCode: "zh", dstCode: "en", isLast: final,
                                   extraData: ["bubble_id": "b", "channel": "right", "chunk_id": id,
                                               "sentence_source": text, "sentence_state": state])
            let event = try XCTUnwrap(DemoConversationEventAdapter.makeRecognizedEvent(from: result, isFinal: final))
            _ = assembler.consume(viewModel.normalizedConversationEvent(from: event, explicitLane: .right))
        }
        XCTAssertEqual(assembler.snapshots().last?.sourceText, "你好，你叫什么名字。你来自哪里？你会说中文吗？")
    }

    func testOfflineLongConversationAlwaysKeepsCurrentSentenceAtTail() async {
        var state = OfflineSentenceTextState()
        var expected: [String] = []
        for id in 1...1000 {
            state.update(text: "当前句\(id)的较长草稿", id: String(id), isFinal: false)
            state.update(text: "当前句\(id)", id: String(id), isFinal: false)
            XCTAssertTrue(state.displayText(active: true).hasSuffix("当前句\(id)..."))
            let sentence = "第\(id)句。"
            state.update(text: sentence, id: String(id), isFinal: true)
            state.update(text: "过期草稿", id: String(id), isFinal: false)
            expected.append(sentence)
        }
        XCTAssertEqual(state.stableText, expected.joined(separator: " "))
        XCTAssertTrue(state.partialText.isEmpty)
    }

    @MainActor
    func testOfflineViewModelPreservesSentenceTranslationThroughNormalization() async throws {
        let viewModel = Offline1V1ViewModel()
        let assembler = DemoConversationBubbleAssembler(translationAssemblyMode: .offlineCumulative)
        for (id, current, cumulative) in [(1, "First.", "First."), (2, "Second.", "First.Second.")] {
            let result = TmkResult(sessionId: id, data: cumulative, srcCode: "zh", dstCode: "en",
                                   isLast: true, extraData: ["bubble_id": "b", "channel": "right",
                                                            "chunk_id": String(id), "sentence_translation": current])
            let event = try XCTUnwrap(DemoConversationEventAdapter.makeTranslatedEvent(from: result, isFinal: true))
            let normalized = viewModel.normalizedConversationEvent(from: event, explicitLane: .right)
            XCTAssertEqual(normalized.translationSegmentText, current)
            _ = assembler.consume(normalized)
        }
        XCTAssertEqual(assembler.snapshots().last?.translatedText, "First. Second.")
    }

    func testOfflineCumulativeTranslationAppendsCurrentSentencePartialToConfirmedText() async {
        let assembler = DemoConversationBubbleAssembler(
            translationAssemblyMode: .offlineCumulative
        )

        _ = assembler.consume(event(bubbleId: "offline-bubble",
                                   sessionId: 1,
                                   lane: .left,
                                   stage: .mt,
                                   text: "Good morning",
                                   isFinal: true,
                                   chunkId: "1"))
        let snapshot = assembler.consume(event(bubbleId: "offline-bubble",
                                               sessionId: 2,
                                               lane: .left,
                                               stage: .mt,
                                               text: "See you",
                                               isFinal: false,
                                               chunkId: "2"))

        XCTAssertEqual(snapshot.last?.translatedText, "Good morning See you...")
    }

    func testOfflineCumulativeTranslationFinalCommitsOnlyCurrentSentenceTail() async {
        let assembler = DemoConversationBubbleAssembler(
            translationAssemblyMode: .offlineCumulative
        )

        _ = assembler.consume(DemoConversationEvent(bubbleId: "offline-bubble",
                                                    sessionId: 9,
                                                    lane: .left,
                                                    stage: .mt,
                                                    isFinal: true,
                                                    text: "The established prefix.",
                                                    sourceLangCode: "zh-CN",
                                                    targetLangCode: "en-US",
                                                    chunkId: "9",
                                                    translationSegmentText: "The established prefix."))
        _ = assembler.consume(DemoConversationEvent(bubbleId: "offline-bubble",
                                                    sessionId: 10,
                                                    lane: .left,
                                                    stage: .mt,
                                                    isFinal: false,
                                                    text: "The sentence at the tail",
                                                    sourceLangCode: "zh-CN",
                                                    targetLangCode: "en-US",
                                                    chunkId: "10"))
        let snapshot = assembler.consume(DemoConversationEvent(
            bubbleId: "offline-bubble",
            sessionId: 10,
            lane: .left,
            stage: .mt,
            isFinal: true,
            text: "A revised translation of the established prefix, followed by the sentence at the tail.",
            sourceLangCode: "zh-CN",
            targetLangCode: "en-US",
            chunkId: "10",
            translationSegmentText: "The sentence at the tail."
        ))

        XCTAssertEqual(snapshot.last?.translatedText,
                       "The established prefix. The sentence at the tail.")
    }

    func testOfflineCumulativeTranslationAcceptsShorterFinalCorrectionForSameChunk() async {
        let assembler = DemoConversationBubbleAssembler(
            translationAssemblyMode: .offlineCumulative
        )

        _ = assembler.consume(event(bubbleId: "offline-bubble",
                                   sessionId: 1,
                                   lane: .left,
                                   stage: .mt,
                                   text: "I need two tickets",
                                   isFinal: false,
                                   chunkId: "1"))
        let snapshot = assembler.consume(event(bubbleId: "offline-bubble",
                                               sessionId: 1,
                                               lane: .left,
                                               stage: .mt,
                                               text: "I need two",
                                               isFinal: true,
                                               chunkId: "1"))

        XCTAssertEqual(snapshot.last?.translatedText, "I need two")
    }

    func testOfflineCumulativeTranslationIgnoresOlderFinalChunkAfterNewerFinal() async {
        let assembler = DemoConversationBubbleAssembler(
            translationAssemblyMode: .offlineCumulative
        )

        _ = assembler.consume(event(bubbleId: "offline-bubble",
                                   sessionId: 1,
                                   lane: .left,
                                   stage: .mt,
                                   text: "First sentence.",
                                   isFinal: true,
                                   chunkId: "1"))
        _ = assembler.consume(event(bubbleId: "offline-bubble",
                                   sessionId: 2,
                                   lane: .left,
                                   stage: .mt,
                                   text: "First sentence. Second sentence.",
                                   isFinal: true,
                                   chunkId: "2"))
        let snapshot = assembler.consume(event(bubbleId: "offline-bubble",
                                               sessionId: 1,
                                               lane: .left,
                                               stage: .mt,
                                               text: "First sentence.",
                                               isFinal: true,
                                               chunkId: "1"))

        XCTAssertEqual(snapshot.last?.translatedText, "First sentence. Second sentence.")
    }

    @MainActor
    func testBubbleAssemblerUsesBubbleIdForASRAndMTPairing() async {
        let assembler = DemoConversationBubbleAssembler()
        let asr = DemoConversationEvent(bubbleId: "bubble-1",
                                        sessionId: 1001,
                                        lane: .left,
                                        stage: .asr,
                                        isFinal: true,
                                        text: "你好",
                                        sourceLangCode: "zh-CN",
                                        targetLangCode: "en-US")
        let mt = DemoConversationEvent(bubbleId: "bubble-1",
                                       sessionId: 2001,
                                       lane: .left,
                                       stage: .mt,
                                       isFinal: true,
                                       text: "hello",
                                       sourceLangCode: "zh-CN",
                                       targetLangCode: "en-US",
                                       chunkId: "chunk-1")

        _ = assembler.consume(asr)
        let snapshots = assembler.consume(mt)

        XCTAssertEqual(snapshots.last?.bubbleId, "bubble-1")
        XCTAssertEqual(snapshots.last?.sourceText, "你好")
        XCTAssertEqual(snapshots.last?.translatedText, "hello")
    }

    @MainActor
    func testBubbleAssemblerMarksBubbleEndedButKeepsUpdatingText() async {
        let assembler = DemoConversationBubbleAssembler()
        let first = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1001,
                                          lane: .right,
                                          stage: .mt,
                                          isFinal: true,
                                          text: "hello",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "chunk-1")
        let second = DemoConversationEvent(bubbleId: "bubble-1",
                                           sessionId: 1002,
                                           lane: .right,
                                           stage: .mt,
                                           isFinal: true,
                                           text: "world",
                                           sourceLangCode: "zh-CN",
                                           targetLangCode: "en-US",
                                           chunkId: "chunk-2")

        let initial = assembler.consume(first)
        XCTAssertEqual(initial.last?.translatedText, "hello")
        XCTAssertEqual(initial.last?.isBubbleEnded, false)

        let ended = assembler.markBubbleEnded(bubbleId: "bubble-1")
        XCTAssertEqual(ended.last?.isBubbleEnded, true)

        let updated = assembler.consume(second)
        XCTAssertEqual(updated.last?.translatedText, "hello world")
        XCTAssertEqual(updated.last?.isBubbleEnded, true)
    }

    @MainActor
    func testBubbleAssemblerAggregatesOffsetDurationFromFinalASR() async {
        let assembler = DemoConversationBubbleAssembler()
        let first = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: true,
                                          text: "你好",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "chunk-1",
                                          offset: 16_692_000_000,
                                          duration: 1_600_000_000)
        let second = DemoConversationEvent(bubbleId: "bubble-1",
                                           sessionId: 2,
                                           lane: .left,
                                           stage: .asr,
                                           isFinal: true,
                                           text: "世界",
                                           sourceLangCode: "zh-CN",
                                           targetLangCode: "en-US",
                                           chunkId: "chunk-2",
                                           offset: 20_000_000_000,
                                           duration: 2_000_000_000)

        _ = assembler.consume(first)
        let snapshot = assembler.consume(second).last
        XCTAssertEqual(snapshot?.bOffset, 16_692_000_000)
        // bLastEnd = 20_000_000_000 + 2_000_000_000; bDuration = bLastEnd - bOffset
        XCTAssertEqual(snapshot?.bDuration, 22_000_000_000 - 16_692_000_000)
    }

    @MainActor
    func testBubbleAssemblerIgnoresNonFinalASROffsetForAggregation() async {
        let assembler = DemoConversationBubbleAssembler()
        let mtFinal = DemoConversationEvent(bubbleId: "bubble-2",
                                            sessionId: 1,
                                            lane: .left,
                                            stage: .mt,
                                            isFinal: true,
                                            text: "hi",
                                            sourceLangCode: "zh-CN",
                                            targetLangCode: "en-US",
                                            chunkId: "chunk-1")
        let asrPartial = DemoConversationEvent(bubbleId: "bubble-2",
                                               sessionId: 1,
                                               lane: .left,
                                               stage: .asr,
                                               isFinal: false,
                                               text: "你",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US",
                                               chunkId: "chunk-1",
                                               offset: 5_000_000_000,
                                               duration: 1_000_000_000)
        let asrFinal = DemoConversationEvent(bubbleId: "bubble-2",
                                             sessionId: 1,
                                             lane: .left,
                                             stage: .asr,
                                             isFinal: true,
                                             text: "你好",
                                             sourceLangCode: "zh-CN",
                                             targetLangCode: "en-US",
                                             chunkId: "chunk-1",
                                             offset: 8_000_000_000,
                                             duration: 1_500_000_000)

        _ = assembler.consume(mtFinal)
        _ = assembler.consume(asrPartial)
        let snapshot = assembler.consume(asrFinal).last
        XCTAssertEqual(snapshot?.bOffset, 8_000_000_000)
        XCTAssertEqual(snapshot?.bDuration, 1_500_000_000)
    }

    @MainActor
    func testBubbleAssemblerTrimsOldestAggregatesBeyondMaxRows() async {
        let assembler = DemoConversationBubbleAssembler(maxRows: 3)
        for index in 0..<5 {
            let event = DemoConversationEvent(bubbleId: "bubble-\(index)",
                                              sessionId: 1000 + index,
                                              lane: .left,
                                              stage: .asr,
                                              isFinal: true,
                                              text: "sentence \(index)",
                                              sourceLangCode: "zh-CN",
                                              targetLangCode: "en-US",
                                              chunkId: "c\(index)")
            _ = assembler.consume(event)
        }
        // 用 markBubbleEnded 探测某 bubble 是否仍在 aggregates 中(返回快照即存在)。
        XCTAssertTrue(assembler.markBubbleEnded(bubbleId: "bubble-0").isEmpty, "最老 bubble-0 应已被裁剪")
        XCTAssertTrue(assembler.markBubbleEnded(bubbleId: "bubble-1").isEmpty, "次老 bubble-1 应已被裁剪")
        XCTAssertFalse(assembler.markBubbleEnded(bubbleId: "bubble-4").isEmpty, "最新 bubble-4 应保留")
        XCTAssertFalse(assembler.markBubbleEnded(bubbleId: "bubble-2").isEmpty, "bubble-2 在容量内应保留")
    }

    @MainActor
    func testBubbleAssemblerChangingMaxRowsTrimsOldestImmediately() async {
        let assembler = DemoConversationBubbleAssembler(maxRows: 20)
        for index in 0..<20 {
            _ = assembler.consume(DemoConversationEvent(bubbleId: "bubble-\(index)",
                                                        sessionId: index,
                                                        lane: .left,
                                                        stage: .asr,
                                                        isFinal: true,
                                                        text: "sentence \(index)",
                                                        sourceLangCode: "zh-CN",
                                                        targetLangCode: "en-US",
                                                        chunkId: "c\(index)"))
        }

        let rows = assembler.setMaxRows(10)

        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.bubbleId, "bubble-10")
        XCTAssertEqual(rows.last?.bubbleId, "bubble-19")
        XCTAssertEqual(assembler.setMaxRows(500).count, 10, "增大上限不会恢复已淘汰气泡")
    }

    @MainActor
    func testBubbleAssemblerSnapshotCacheDoesNotAlterOutput() async {
        let assembler = DemoConversationBubbleAssembler()
        let final1 = DemoConversationEvent(bubbleId: "bubble-1",
                                           sessionId: 1,
                                           lane: .left,
                                           stage: .asr,
                                           isFinal: true,
                                           text: "你好世界",
                                           sourceLangCode: "zh-CN",
                                           targetLangCode: "en-US",
                                           chunkId: "1")
        let s1 = assembler.consume(final1)
        XCTAssertEqual(s1.last?.sourceText, "你好世界")

        // 切到另一 bubble 再切回,触发历史气泡以 isActiveBubble=false 走缓存路径。
        let other = DemoConversationEvent(bubbleId: "bubble-2",
                                          sessionId: 2,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: false,
                                          text: "另一句",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "2")
        let s2 = assembler.consume(other)
        // 切换时会补发前一个气泡(bubble-1)的最终快照,其文本应保持不变。
        XCTAssertEqual(s2.first(where: { $0.bubbleId == "bubble-1" })?.sourceText, "你好世界")
        XCTAssertEqual(s2.last?.sourceText, "另一句")
    }

    @MainActor
    func testBubbleAssemblerMergesLongOverlappingPartialsWithoutDuplication() async {
        let assembler = DemoConversationBubbleAssembler()
        let prefix = String(repeating: "跨越语言与文化的边界我们正在", count: 8) // ~112 字
        let first = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: false,
                                          text: prefix,
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "1")
        _ = assembler.consume(first)
        // 同 chunk 的下一 partial 在原文基础上增量增长,应覆盖为最新(不重复)。
        let grown = DemoConversationEvent(bubbleId: "bubble-1",
                                          sessionId: 1,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: true,
                                          text: prefix + "书写新的篇章",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US",
                                          chunkId: "1")
        let snapshots = assembler.consume(grown)
        XCTAssertEqual(snapshots.last?.sourceText, prefix + "书写新的篇章")
    }

    @MainActor
    func testBubbleAssemblerSuspendsASRPartialWhenNewSessionStarts() async {
        let assembler = DemoConversationBubbleAssembler()
        let first = DemoConversationEvent(bubbleId: "asr-bubble",
                                          sessionId: 100,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: false,
                                          text: "第一句初稿",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US")
        let second = DemoConversationEvent(bubbleId: "asr-bubble",
                                           sessionId: 101,
                                           lane: .left,
                                           stage: .asr,
                                           isFinal: false,
                                           text: "第二句初稿",
                                           sourceLangCode: "zh-CN",
                                           targetLangCode: "en-US")

        _ = assembler.consume(first)
        let snapshots = assembler.consume(second)

        XCTAssertEqual(snapshots.last?.sourceSegments.map(\.text), ["第一句初稿", "第二句初稿"])
        XCTAssertEqual(snapshots.last?.sourceText, "第一句初稿第二句初稿")
    }

    @MainActor
    func testBubbleAssemblerShorterASRFinalReplacesPartialThenLocksSegment() async {
        let assembler = DemoConversationBubbleAssembler()
        let partial = DemoConversationEvent(bubbleId: "asr-bubble",
                                            sessionId: 100,
                                            lane: .left,
                                            stage: .asr,
                                            isFinal: false,
                                            text: "平均每天都有超过两百个衍生模型出现。我",
                                            sourceLangCode: "zh-CN",
                                            targetLangCode: "en-US")
        let final = DemoConversationEvent(bubbleId: "asr-bubble",
                                          sessionId: 100,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: true,
                                          text: "平均每天都有超过两百个衍生模型出现。",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US")
        let correction = DemoConversationEvent(bubbleId: "asr-bubble",
                                               sessionId: 100,
                                               lane: .left,
                                               stage: .asr,
                                               isFinal: true,
                                               text: "不应覆盖的 final",
                                               sourceLangCode: "zh-CN",
                                               targetLangCode: "en-US")

        _ = assembler.consume(partial)
        XCTAssertEqual(assembler.consume(final).last?.sourceText, "平均每天都有超过两百个衍生模型出现。")
        XCTAssertEqual(assembler.consume(correction).last?.sourceText, "平均每天都有超过两百个衍生模型出现。")
    }

    @MainActor
    func testBubbleAssemblerEmptyASRFinalPreservesPartialText() async {
        let assembler = DemoConversationBubbleAssembler()
        let partial = DemoConversationEvent(bubbleId: "asr-bubble",
                                            sessionId: 100,
                                            lane: .left,
                                            stage: .asr,
                                            isFinal: false,
                                            text: "正在识别的内容",
                                            sourceLangCode: "zh-CN",
                                            targetLangCode: "en-US")
        let final = DemoConversationEvent(bubbleId: "asr-bubble",
                                          sessionId: 100,
                                          lane: .left,
                                          stage: .asr,
                                          isFinal: true,
                                          text: "",
                                          sourceLangCode: "zh-CN",
                                          targetLangCode: "en-US")

        _ = assembler.consume(partial)
        XCTAssertEqual(assembler.consume(final).last?.sourceText, "正在识别的内容")
    }

    @MainActor
    func testBubbleAssemblerSuspendedASRSessionIgnoresLatePartialButAcceptsFinal() async {
        let assembler = DemoConversationBubbleAssembler()
        let firstPartial = DemoConversationEvent(
            bubbleId: "asr-bubble",
            sessionId: 100,
            lane: .left,
            stage: .asr,
            isFinal: false,
            text: "第一句初稿",
            sourceLangCode: "zh-CN",
            targetLangCode: "en-US"
        )
        let secondPartial = DemoConversationEvent(
            bubbleId: "asr-bubble",
            sessionId: 101,
            lane: .left,
            stage: .asr,
            isFinal: false,
            text: "第二句初稿",
            sourceLangCode: "zh-CN",
            targetLangCode: "en-US"
        )
        let latePartial = DemoConversationEvent(
            bubbleId: "asr-bubble",
            sessionId: 100,
            lane: .left,
            stage: .asr,
            isFinal: false,
            text: "第一句错误回写",
            sourceLangCode: "zh-CN",
            targetLangCode: "en-US"
        )
        let lateFinal = DemoConversationEvent(bubbleId: "asr-bubble",
                                              sessionId: 100,
                                              lane: .left,
                                              stage: .asr,
                                              isFinal: true,
                                              text: "第一句最终",
                                              sourceLangCode: "zh-CN",
                                              targetLangCode: "en-US")

        _ = assembler.consume(firstPartial)
        _ = assembler.consume(secondPartial)
        let afterLatePartial = assembler.consume(latePartial).last
        let afterLateFinal = assembler.consume(lateFinal).last

        XCTAssertEqual(afterLatePartial?.sourceText, "第一句初稿第二句初稿")
        XCTAssertEqual(afterLateFinal?.sourceText, "第一句最终第二句初稿")
    }

    private func event(bubbleId: String,
                       sessionId: Int,
                       lane: DemoConversationLane,
                       stage: DemoConversationStage,
                       text: String,
                       isFinal: Bool = false,
                       chunkId: String? = nil) -> DemoConversationEvent {
        DemoConversationEvent(bubbleId: bubbleId,
                              sessionId: sessionId,
                              lane: lane,
                              stage: stage,
                              isFinal: isFinal,
                              text: text,
                              sourceLangCode: "zh-CN",
                              targetLangCode: "en-US",
                              chunkId: chunkId)
    }
}
