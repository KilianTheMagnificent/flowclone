import XCTest
@testable import FlowCloneCore

final class PermissionsTests: XCTestCase {
    func testSettingsURLTargetsThePrivacyPane() {
        XCTAssertEqual(Permissions.settingsURL(pane: "Privacy_Microphone")?.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @MainActor
    func testGrantOrderAndPanes() {
        XCTAssertEqual(Permissions.grants.map(\.id),
                       ["Microphone", "Accessibility", "Input Monitoring", "Hotkey verified"])
        XCTAssertEqual(Permissions.grants.map(\.pane),
                       ["Privacy_Microphone", "Privacy_Accessibility", "Privacy_ListenEvent", nil])
    }
}
