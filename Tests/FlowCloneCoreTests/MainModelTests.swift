import XCTest
@testable import FlowCloneCore

final class MainModelTests: XCTestCase {
    /// 2026-09-21: an off-screen main window was re-laid out on every dictation (100–470 ms
    /// of main thread each) until one pass never returned. Hidden windows defer the render.
    @MainActor func testHistoryChangeDefersRenderWhileWindowOffScreen() {
        @MainActor final class Screen { var on = false }
        let screen = Screen()
        let model = MainModel(isOnScreen: { screen.on })
        History.onChange?()
        XCTAssertEqual(model.historyVersion, 0, "no re-render while off screen")
        model.refreshIfStale()
        XCTAssertEqual(model.historyVersion, 0, "still off screen")
        screen.on = true
        model.refreshIfStale()
        XCTAssertEqual(model.historyVersion, 1, "one re-render once back on screen")
        model.refreshIfStale()
        XCTAssertEqual(model.historyVersion, 1, "a deferred change is applied once")
        History.onChange?()
        XCTAssertEqual(model.historyVersion, 2, "on-screen changes render immediately")
    }
}
