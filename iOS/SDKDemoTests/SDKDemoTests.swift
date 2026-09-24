//
//  SDKDemoTests.swift
//  SDKDemoTests
//
//  Created by xiongjinhui on 2026/3/26.
//

import XCTest
@testable import SDKDemo

final class SDKDemoTests: XCTestCase {

    func testUnchunkedTranslationUsesSessionIdentity() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("draft", sessionId: 7, chunkId: nil, isFinal: false))
        let snapshots = assembler.consume(translationEvent("final", sessionId: 7, chunkId: " ", isFinal: true))

        XCTAssertEqual(snapshots.first?.translatedText, "final")
        XCTAssertEqual(snapshots.first?.translatedSegments.first?.rawSessionIds, Set([7]))
        XCTAssertEqual(snapshots.first?.translatedSegments.first?.rawChunkIds, Set<String>())
    }

    func testUnchunkedAndChunkWithSessionLikeIdRemainSeparate() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("session final", sessionId: 7, chunkId: nil, isFinal: true))
        let snapshots = assembler.consume(
            translationEvent("chunk final", sessionId: 8, chunkId: "session:7", isFinal: true)
        )

        XCTAssertEqual(snapshots.first?.translatedText, "session final chunk final")
        XCTAssertEqual(snapshots.first?.translatedSegments.count, 2)
    }

    func testChunkedFinalReplacesEarlierUnchunkedPartial() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("draft", sessionId: 7, chunkId: nil, isFinal: false))
        let snapshots = assembler.consume(
            translationEvent("final", sessionId: 7, chunkId: "chunk-a", isFinal: true)
        )

        XCTAssertEqual(snapshots.first?.translatedText, "final")
        XCTAssertEqual(snapshots.first?.translatedSegments.count, 1)
        XCTAssertEqual(snapshots.first?.translatedSegments.first?.rawChunkIds, Set(["chunk-a"]))
    }

    func testChunkedCorrectionReplacesUnchunkedFinal() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("first", sessionId: 7, chunkId: nil, isFinal: true))
        let snapshots = assembler.consume(
            translationEvent("corrected", sessionId: 7, chunkId: "chunk-a", isFinal: true)
        )

        XCTAssertEqual(snapshots.first?.translatedText, "corrected")
        XCTAssertEqual(snapshots.first?.translatedSegments.count, 1)
    }

    func testLateUnchunkedPartialDoesNotReopenFinalizedChunk() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("draft", sessionId: 7, chunkId: nil, isFinal: false))
        _ = assembler.consume(translationEvent("final", sessionId: 7, chunkId: "chunk-a", isFinal: true))
        let snapshots = assembler.consume(
            translationEvent("late draft", sessionId: 7, chunkId: nil, isFinal: false)
        )

        XCTAssertEqual(snapshots.first?.translatedText, "final")
        XCTAssertEqual(snapshots.first?.translatedSegments.count, 1)
    }

    func testUnchunkedFinalClosesPromotedChunkPartial() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("draft", sessionId: 7, chunkId: nil, isFinal: false))
        _ = assembler.consume(translationEvent("new draft", sessionId: 7, chunkId: "chunk-a", isFinal: false))
        let snapshots = assembler.consume(
            translationEvent("final", sessionId: 7, chunkId: nil, isFinal: true)
        )

        XCTAssertEqual(snapshots.first?.translatedText, "final")
        XCTAssertEqual(snapshots.first?.translatedSegments.count, 1)
    }

    func testCorrectedFinalReplacesFinalizedTranslation() {
        let assembler = DemoConversationBubbleAssembler()
        _ = assembler.consume(translationEvent("first final", sessionId: 7, chunkId: "chunk-a", isFinal: true))
        let latePartial = assembler.consume(
            translationEvent("late partial", sessionId: 7, chunkId: "chunk-a", isFinal: false)
        )
        let snapshots = assembler.consume(
            translationEvent("corrected final", sessionId: 7, chunkId: "chunk-a", isFinal: true)
        )

        XCTAssertEqual(latePartial.first?.translatedText, "first final")
        XCTAssertEqual(snapshots.first?.translatedText, "corrected final")
    }

    private func translationEvent(_ text: String, sessionId: Int, chunkId: String?, isFinal: Bool) -> DemoConversationEvent {
        DemoConversationEvent(bubbleId: "bubble-1",
                              sessionId: sessionId,
                              lane: .left,
                              stage: .mt,
                              isFinal: isFinal,
                              text: text,
                              sourceLangCode: "en-US",
                              targetLangCode: "zh-CN",
                              chunkId: chunkId)
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
