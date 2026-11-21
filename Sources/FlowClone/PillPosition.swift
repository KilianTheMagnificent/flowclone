import Cocoa

/// The capsule's bottom-center, relative to its display's usable area. Keeping the
/// anchor separate from the animated window frame prevents drift as the pill morphs.
struct PillPosition: Codable, Equatable {
    struct Placement {
        let frame: NSRect
        var pillCenterX: CGFloat? = nil
        var transcriptAbove = true
    }
    static let preferenceKey = "pillPosition"

    /// Auto-hide does not update NSScreen.visibleFrame during the Dock animation.
    /// Use its actual, bottom-attached bounds when available; side Docks and Docks
    /// on other displays must not lift this pill.
    static func defaultAnchor(screenFrame: NSRect, visibleFrame: NSRect,
                              dockFrame: NSRect?) -> NSPoint {
        var bottom = max(screenFrame.minY + 12, visibleFrame.minY + 4)
        if let dockFrame, isBottomDock(dockFrame, on: screenFrame) {
            bottom = max(bottom, dockFrame.maxY + 4)
        }
        return NSPoint(x: visibleFrame.midX, y: bottom)
    }

    static func isBottomDock(_ dock: NSRect, on screen: NSRect) -> Bool {
        // The Dock's AXList floats above the screen edge when fully revealed
        // (10pt on the measured system). Requiring it to touch the edge accepts
        // the slide-in, then incorrectly treats the settled Dock as hidden.
        dock.width > dock.height && dock.height > 0 && dock.height < screen.height / 2
            && dock.minY <= screen.minY + dock.height && dock.maxY > screen.minY
            && dock.maxX > screen.minX && dock.minX < screen.maxX
    }
    let displayID: String
    let x: CGFloat
    let y: CGFloat

    init(anchor: NSPoint, displayID: String, visibleFrame: NSRect) {
        self.displayID = displayID
        x = min(1, max(0, (anchor.x - visibleFrame.minX) / max(1, visibleFrame.width)))
        y = min(1, max(0, (anchor.y - visibleFrame.minY) / max(1, visibleFrame.height)))
    }

    func anchor(in visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: visibleFrame.minX + x * visibleFrame.width,
                y: visibleFrame.minY + y * visibleFrame.height)
    }

    /// Keep the entire overlay reachable, including live text near a display edge.
    static func frame(size: NSSize, anchor: NSPoint, visibleFrame: NSRect) -> NSRect {
        let x = min(max(visibleFrame.minX, anchor.x - size.width / 2),
                    max(visibleFrame.minX, visibleFrame.maxX - size.width))
        let y = min(max(visibleFrame.minY, anchor.y),
                    max(visibleFrame.minY, visibleFrame.maxY - size.height))
        // Normalized preferences can round-trip 204 as 203.99999999999997.
        // AppKit floors that to 203, making the pill walk down on state changes.
        return NSRect(x: (x * 2).rounded() / 2, y: y.rounded(), width: size.width, height: size.height)
    }

    /// At an edge, shift the text box sideways or below the capsule instead of
    /// displacing the capsule each time a partial transcript arrives.
    static func placement(size: NSSize, pillSize: NSSize, anchor: NSPoint,
                          visibleFrame: NSRect, gap: CGFloat) -> Placement {
        let pill = frame(size: pillSize, anchor: anchor, visibleFrame: visibleFrame)
        guard size.height > pillSize.height else { return Placement(frame: pill) }
        let textSize = NSSize(width: size.width, height: size.height - pillSize.height - gap)
        let above = pill.maxY + gap + textSize.height <= visibleFrame.maxY
            || pill.minY - gap - textSize.height < visibleFrame.minY
        let text = frame(size: textSize,
                         anchor: NSPoint(x: pill.midX, y: above ? pill.maxY + gap : pill.minY - gap - textSize.height),
                         visibleFrame: visibleFrame)
        let panel = pill.union(text)
        return Placement(frame: panel, pillCenterX: pill.midX - panel.minX, transcriptAbove: above)
    }

    static func load(from defaults: UserDefaults) -> PillPosition? {
        guard let data = defaults.data(forKey: preferenceKey),
              let position = try? JSONDecoder().decode(Self.self, from: data),
              !position.displayID.isEmpty, position.x.isFinite, position.y.isFinite,
              (0...1).contains(position.x), (0...1).contains(position.y) else { return nil }
        return position
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: preferenceKey)
    }

    @MainActor
    static func displayID(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return screen.localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
