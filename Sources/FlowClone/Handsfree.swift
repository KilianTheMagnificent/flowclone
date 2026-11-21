#if DEBUG
import AppKit

/// Hands-free agent driver, switched on by `handsfree start native` (HANDSFREE=1).
/// `install()` makes the app unable to reach the owner: it never activates, never orders a
/// window on screen, keeps status items hidden, cannot open URLs or apps, runs no modal
/// panels, plays no speech or sounds, and writes a private pasteboard instead of the owner's clipboard. `start()` then
/// serves tree/press/type/key/shot/action requests from files in the session directory,
/// performed in-process on the hidden windows. Global hotkeys, event taps, synthetic CGEvents,
/// microphone and screen capture are plain C APIs the app itself must skip when `enabled`.
@MainActor
enum Handsfree {
  static let session: URL? = {
    let env = ProcessInfo.processInfo.environment
    guard env["HANDSFREE"] == "1", let profile = env["HANDSFREE_PROFILE"] else { return nil }
    return URL(fileURLWithPath: profile).deletingLastPathComponent()
  }()
  static var enabled: Bool { session != nil }
  /// A throwaway directory for the app's own state (defaults suite, stores, logs).
  static var profile: URL? { session?.appendingPathComponent("profile") }
  /// App-specific seams: `handsfree action <name> [json]` calls these (fixtures, flows the
  /// real OS would trigger such as a global hotkey).
  static var actions: [String: @MainActor ([String: Any]) throws -> Any] = [:]

  /// Call before NSApplication finishes launching, ideally first thing in main.
  static func install() {
    guard enabled else { return }
    if let profile {
      try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let noop: @convention(block) (AnyObject) -> Void = { _ in }
    let noopArg: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in }
    let noopBool: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
    let blockedOpen: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, url in log("blocked open \(url.map { "\($0)" } ?? "")"); return true }
    swap(NSApplication.self, "activateIgnoringOtherApps:", noopBool)
    swap(NSApplication.self, "activate", noop)
    swap(NSApplication.self, "activateWithOptions:", noopBool)
    swap(NSApplication.self, "setActivationPolicy:", { (_: AnyObject, _: Int) -> Bool in true } as @convention(block) (AnyObject, Int) -> Bool)
    swap(NSWindow.self, "makeKeyAndOrderFront:", noopArg)
    swap(NSWindow.self, "orderFront:", noopArg)
    swap(NSWindow.self, "orderFrontRegardless", noop)
    swap(NSWindow.self, "setIsVisible:", noopBool)
    typealias Order = @convention(c) (AnyObject, Selector, Int, Int) -> Void
    if let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("orderWindow:relativeTo:")) {
      let original = unsafeBitCast(method_getImplementation(method), to: Order.self)
      let order: @convention(block) (AnyObject, Int, Int) -> Void = { window, place, other in
        if place == NSWindow.OrderingMode.out.rawValue { original(window, NSSelectorFromString("orderWindow:relativeTo:"), place, other) }
      }
      method_setImplementation(method, imp_implementationWithBlock(order))
    }
    typealias SetVisible = @convention(c) (AnyObject, Selector, Bool) -> Void
    if let method = class_getInstanceMethod(NSStatusItem.self, NSSelectorFromString("setVisible:")) {
      let original = unsafeBitCast(method_getImplementation(method), to: SetVisible.self)
      let hide: @convention(block) (AnyObject, Bool) -> Void = { item, _ in original(item, NSSelectorFromString("setVisible:"), false) }
      method_setImplementation(method, imp_implementationWithBlock(hide))
    }
    typealias MakeItem = @convention(c) (AnyObject, Selector, CGFloat) -> NSStatusItem
    if let method = class_getInstanceMethod(NSStatusBar.self, NSSelectorFromString("statusItemWithLength:")) {
      let original = unsafeBitCast(method_getImplementation(method), to: MakeItem.self)
      let make: @convention(block) (AnyObject, CGFloat) -> NSStatusItem = { bar, length in
        let item = original(bar, NSSelectorFromString("statusItemWithLength:"), length)
        item.isVisible = false
        return item
      }
      method_setImplementation(method, imp_implementationWithBlock(make))
    }
    swap(NSWorkspace.self, "openURL:", blockedOpen)
    swap(NSWorkspace.self, "activateFileViewerSelectingURLs:", noopArg)
    let openWith: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> Void = { _, url, _, done in
      log("blocked open \(url.map { "\($0)" } ?? "")")
      if let done { unsafeBitCast(done, to: (@convention(block) (AnyObject?, AnyObject?) -> Void).self)(nil, nil) }
    }
    swap(NSWorkspace.self, "openURL:configuration:completionHandler:", openWith)
    swap(NSWorkspace.self, "openApplicationAtURL:configuration:completionHandler:", openWith)
    // Silent: no speech or sound playback (the owner may be on a call).
    let silentBool: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in log("blocked sound"); return false }
    let silent: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in log("blocked speech") }
    swap(NSSound.self, "play", { (_: AnyObject) -> Bool in log("blocked sound"); return false } as @convention(block) (AnyObject) -> Bool)
    if let speech = NSClassFromString("NSSpeechSynthesizer") { swap(speech, "startSpeakingString:", silentBool) }
    if let speech = NSClassFromString("AVSpeechSynthesizer") { swap(speech, "speakUtterance:", silent) }
    swap(NSAlert.self, "runModal", { (_: AnyObject) -> Int in NSApplication.ModalResponse.alertFirstButtonReturn.rawValue } as @convention(block) (AnyObject) -> Int)
    swap(NSSavePanel.self, "runModal", { (_: AnyObject) -> Int in NSApplication.ModalResponse.cancel.rawValue } as @convention(block) (AnyObject) -> Int)
    // Preferences go to a per-session domain the driver deletes on stop. (The driver also sets
    // CFFIXED_USER_HOME, which moves Application Support, Caches and Logs but not preferences.)
    let defaults = UserDefaults(suiteName: "handsfree.\(session?.lastPathComponent ?? "session")")
    if let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")), let defaults {
      method_setImplementation(method, imp_implementationWithBlock({ (_: AnyObject) in defaults } as @convention(block) (AnyObject) -> UserDefaults))
    }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("handsfree.\(session?.lastPathComponent ?? "session")"))
    if let method = class_getClassMethod(NSPasteboard.self, NSSelectorFromString("generalPasteboard")) {
      method_setImplementation(method, imp_implementationWithBlock({ (_: AnyObject) in pasteboard } as @convention(block) (AnyObject) -> NSPasteboard))
    }
  }

  private static func swap(_ cls: AnyClass, _ selector: String, _ block: Any) {
    guard let method = class_getInstanceMethod(cls, NSSelectorFromString(selector)) else { return }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  nonisolated static func log(_ message: String) { FileHandle.standardError.write(Data("handsfree: \(message)\n".utf8)) }

  static func start() {
    guard let session else { return }
    let inbox = session.appendingPathComponent("inbox"), outbox = session.appendingPathComponent("outbox")
    for dir in [inbox, outbox] {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
      MainActor.assumeIsolated { poll(inbox: inbox, outbox: outbox) }
    }
    // SwiftUI builds its accessibility nodes only once an assistive client talks to the app.
    // Asking our own process from a background thread (the main thread serves the answer)
    // wakes them without moving the pointer or focus; it needs the launching terminal's
    // Accessibility grant, else only AppKit-backed controls are reachable.
    let pid = getpid(), ready = session.appendingPathComponent("native-ready")
    Thread.detachNewThread {
      var role: CFTypeRef?
      AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXRoleAttribute as CFString, &role)
      try? "\(pid) accessibility=\(AXIsProcessTrusted())".write(to: ready, atomically: true, encoding: .utf8)
    }
  }

  private static func poll(inbox: URL, outbox: URL) {
    let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
      var reply: [String: Any]
      do {
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        reply = ["ok": true, "result": try handle(request["cmd"] as? String ?? "", request["args"] as? [String: Any] ?? [:])]
      } catch { reply = ["ok": false, "error": "\(error)"] }
      try? FileManager.default.removeItem(at: file)
      let tmp = outbox.appendingPathComponent(file.lastPathComponent + ".tmp")
      if let data = try? JSONSerialization.data(withJSONObject: reply) {
        try? data.write(to: tmp)
        try? FileManager.default.moveItem(at: tmp, to: outbox.appendingPathComponent(file.lastPathComponent))
      }
    }
  }

  struct Failure: Error, CustomStringConvertible { let description: String }

  private static func handle(_ cmd: String, _ args: [String: Any]) throws -> Any {
    let query = args["query"] as? String
    window = args["window"] as? String
    switch cmd {
    case "tree":
      return windows().map { window in
        var lines = ["window \"\(window.title)\" \(Int(window.frame.width))x\(Int(window.frame.height))\(window.isVisible ? " VISIBLE" : "")"]
        if let root = window.contentView {
          walk(Node(object: root)) { node, depth in lines.append(String(repeating: "  ", count: depth + 1) + describe(node)) }
        }
        return lines.joined(separator: "\n")
      }.joined(separator: "\n")
    case "press":
      guard try find(query).press() else { throw Failure(description: "element does not support press") }
      return "pressed"
    case "type":
      let text = args["text"] as? String ?? ""
      let window = try targetWindow()
      if let query {
        let object = try find(query).object
        guard let view = (object as? NSView) ?? (object as? NSCell)?.controlView, window.makeFirstResponder(view) else {
          throw Failure(description: "cannot focus \(query)")
        }
      }
      guard let editor = window.firstResponder as? NSTextView else { throw Failure(description: "no focused text input") }
      editor.insertText(text, replacementRange: editor.selectedRange())
      return "typed"
    case "key":
      let window = try targetWindow()
      let (code, chars, flags) = try key(args["key"] as? String ?? "")
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
        if let event { window.sendEvent(event) }
      }
      return "pressed"
    case "shot":
      guard let path = args["path"] as? String, let view = try targetWindow().contentView else { throw Failure(description: "no window content") }
      view.layoutSubtreeIfNeeded()
      guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "cannot render") }
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      return path
    case "action":
      guard let name = args["name"] as? String, let action = actions[name] else {
        throw Failure(description: "unknown action; available: \(actions.keys.sorted().joined(separator: ", "))")
      }
      return try action(args["payload"] as? [String: Any] ?? [:])
    default:
      throw Failure(description: "unknown command \(cmd)")
    }
  }

  private static func windows() -> [NSWindow] { NSApp.windows.filter { $0.contentView != nil } }

  /// The window whose title contains `--window`, else the first one.
  private static func targetWindow() throws -> NSWindow {
    let all = windows()
    if let name = window, let match = all.first(where: { $0.title.contains(name) }) { return match }
    guard let first = all.first else { throw Failure(description: "no windows") }
    return first
  }
  private static var window: String?

  /// Accessibility element seen through Objective-C dispatch: SwiftUI's nodes implement the
  /// NSAccessibility methods without formally conforming to the Swift protocol.
  @MainActor private struct Node {
    let object: AnyObject
    var children: [Node] {
      let list: [Any] = (object.accessibilityChildren?() ?? nil) ?? []
      return list.map { Node(object: $0 as AnyObject) }
    }
    var role: String {
      let role: NSAccessibility.Role? = object.accessibilityRole?() ?? nil
      return (role?.rawValue ?? "").replacingOccurrences(of: "AX", with: "")
    }
    var identifier: String {
      let id: String? = object.accessibilityIdentifier?() ?? nil
      return id ?? ""
    }
    var texts: [String] {
      let label: String? = object.accessibilityLabel?() ?? nil
      let title: String? = object.accessibilityTitle?() ?? nil
      let value: Any? = object.accessibilityValue?() ?? nil
      return [label, title, value.map { "\($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
    }
    var summary: String { (texts + (identifier.isEmpty ? [] : ["#" + identifier])).joined(separator: " | ") }
    func press() -> Bool {
      if let control = object as? NSControl { control.performClick(nil); return true }
      return object.accessibilityPerformPress?() ?? false
    }
  }

  private static func walk(_ node: Node, depth: Int = 0, _ visit: (Node, Int) -> Void) {
    let meaningful = !node.summary.isEmpty
    if meaningful { visit(node, depth) }
    for child in node.children { walk(child, depth: meaningful ? depth + 1 : depth, visit) }
  }

  private static func describe(_ node: Node) -> String { "\(node.role) \(node.summary)" }

  /// Matches `#identifier` exactly, otherwise a label/title/value substring; first match wins.
  private static func find(_ query: String?) throws -> Node {
    guard let query, !query.isEmpty, let root = try targetWindow().contentView else { throw Failure(description: "missing query") }
    var found: Node?
    walk(Node(object: root)) { node, _ in
      guard found == nil else { return }
      if query.hasPrefix("#") ? node.identifier == String(query.dropFirst()) : node.texts.contains(where: { $0.contains(query) }) { found = node }
    }
    guard let found else { throw Failure(description: "nothing matches \(query)") }
    return found
  }

  private static func key(_ spec: String) throws -> (UInt16, String, NSEvent.ModifierFlags) {
    var parts = spec.split(separator: "+").map(String.init)
    let name = parts.popLast() ?? ""
    let mods: [String: NSEvent.ModifierFlags] = ["Cmd": .command, "Meta": .command, "Shift": .shift, "Alt": .option, "Ctrl": .control, "Control": .control]
    let flags = try parts.reduce(into: NSEvent.ModifierFlags()) { acc, part in
      guard let flag = mods[part] else { throw Failure(description: "unknown modifier \(part)") }
      acc.insert(flag)
    }
    let named: [String: (UInt16, String)] = ["Enter": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Backspace": (51, "\u{7f}"),
      "Space": (49, " "), "ArrowLeft": (123, "\u{F702}"), "ArrowRight": (124, "\u{F703}"), "ArrowDown": (125, "\u{F701}"), "ArrowUp": (126, "\u{F700}")]
    if let (code, chars) = named[name] { return (code, chars, flags) }
    guard name.count == 1 else { throw Failure(description: "unknown key \(name)") }
    return (0, name.lowercased(), flags)
  }
}
#else
enum Handsfree {
  nonisolated static func log(_: String) {}
}
#endif
