import XCTest
@testable import SDKDemo
import TmkTranslationSDK

final class OneToOneSameLanguagePolicyTests: XCTestCase {
    func testOfflineSameLanguageIsAllowedOnlyForRecognize() {
        XCTAssertTrue(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "zh-CN",
            target: "zh-CN",
            roomScenario: .recognize
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "zh-CN",
            target: "zh-CN",
            roomScenario: .toText
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "zh-CN",
            target: "zh-CN",
            roomScenario: .toSpeech
        ))
    }

    func testOfflineEquivalentLocaleVariantsAreSameLanguage() {
        XCTAssertTrue(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "en-US",
            target: "en",
            roomScenario: .recognize
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "en-US",
            target: "en",
            roomScenario: .toText
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOfflineAllowed(
            source: "en_US",
            target: "en",
            roomScenario: .toText
        ))
    }

    func testOnlineDifferentLocaleCodesRemainAllowedOutsideRecognize() {
        XCTAssertTrue(OneToOneSameLanguagePolicy.isOnlineAllowed(
            source: "en-US",
            target: "en",
            roomScenario: .toText
        ))
    }

    func testRecognizeScenarioCanQueueSameLanguageChange() {
        XCTAssertTrue(OneToOneSameLanguagePolicy.canQueueOfflineLanguageChange(
            source: "en",
            target: "en",
            pendingRoomScenario: .recognize
        ))
    }

    func testSameOnlineLanguageIsSelectableWhenRecognizeIsPending() {
        XCTAssertTrue(OneToOneSameLanguagePolicy.isOnlineLanguageSelectable(
            source: "en-US",
            target: "en-US",
            currentRoomScenario: .toSpeech,
            pendingRoomScenario: .recognize
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOnlineLanguageSelectable(
            source: "en-US",
            target: "en-US",
            currentRoomScenario: .toSpeech,
            pendingRoomScenario: .toText
        ))
        XCTAssertFalse(OneToOneSameLanguagePolicy.isOnlineLanguageSelectable(
            source: "en-US",
            target: "en-US",
            currentRoomScenario: .toSpeech,
            pendingRoomScenario: nil
        ))
    }
}
