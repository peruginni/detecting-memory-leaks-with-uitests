//
//  MyAppUITests.swift
//  MyAppUITests
//
//  Created for the sample project.
//

import XCTest

final class MyAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRepeatedFlowForInstrumentsAndXctrace() {
        let app = XCUIApplication()
        app.launch()

        // Give xctrace time to attach to the app launched by this test.
        Thread.sleep(forTimeInterval: 3)

        for iteration in 1...3 {
            app.openDetailScreen(iteration: iteration)
            app.closeDetailScreen(iteration: iteration)
        }

        // Give the Leaks instrument time to inspect the final state.
        Thread.sleep(forTimeInterval: 5)
    }

    @MainActor
    func testRepeatedFlowWithXCTestMemoryDiagnostics() {
        let app = XCUIApplication()
        let options = XCTMeasureOptions()
        // On our Xcode 26.6 device run, even 0 invoked the flow twice.
        options.iterationCount = 0
        options.invocationOptions = [.manuallyStart]

        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            app.launch()

            startMeasuring()

            for iteration in 1...3 {
                app.openDetailScreen(iteration: iteration)
                app.closeDetailScreen(iteration: iteration)
            }
        }
    }
}


@MainActor
private extension XCUIApplication {
    var elementWaitTimeout: TimeInterval { 10 }

    func openDetailScreen(
        iteration: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let openButton = buttons["open-detail-screen"]
        XCTAssertTrue(
            openButton.waitForExistence(timeout: elementWaitTimeout),
            "Open button did not appear on iteration \(iteration)",
            file: file,
            line: line
        )
        openButton.tap()
    }

    func closeDetailScreen(
        iteration: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let closeButton = buttons["close-detail-screen"]
        XCTAssertTrue(
            closeButton.waitForExistence(timeout: elementWaitTimeout),
            "Close button did not appear on iteration \(iteration)",
            file: file,
            line: line
        )
        closeButton.tap()
        XCTAssertTrue(
            closeButton.waitForNonExistence(timeout: elementWaitTimeout),
            "Leaking screen did not close on iteration \(iteration)",
            file: file,
            line: line
        )
    }
}
