//
//  SDKDemoTests.swift
//  SDKDemoTests
//
//  Created by xiongjinhui on 2026/3/26.
//

import XCTest
@testable import SDKDemo
import TmkTranslationSDK

final class SDKDemoTests: XCTestCase {

    func testDiagnosisConfigUsesTraceAudioOnlyAndNilRootDirectory() {
        let config = DemoSettingsConfig(
            diagnosisEnabled: true,
            diagnosisLevel: .trace,
            diagnosisAudioCaptureEnabled: true,
            consoleLogEnabled: false,
            networkEnvironment: .test,
            customNetworkBaseURLEnabled: false,
            customNetworkBaseURL: DemoSettingsConfig.rayneoNetworkBaseURL,
            customOfflineModelBaseURLEnabled: false,
            offlineModelBaseURL: "",
            sensitiveWordRedactionEnabled: true,
            mockEngineEnabled: false,
            schemaVersion: DemoSettingsConfig.default.schemaVersion
        )

        let globalConfig = DemoSDKConfigurationFactory.makeGlobalConfig(from: config)

        XCTAssertEqual(globalConfig.diagnosisConfig.level, .trace)
        XCTAssertTrue(globalConfig.diagnosisConfig.audioCaptureEnabled)
        XCTAssertNil(globalConfig.diagnosisConfig.rootDirectory)
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
