import Cocoa
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum HistoryAudio {
    private static let queue = DispatchQueue(label: "flowclone.history.audio", qos: .utility)
    static var root: URL { History.storeURL.deletingLastPathComponent().appendingPathComponent("history-audio") }
    static var isEnabled: Bool { History.defaults.bool(forKey: "saveHistoryAudio") }
    static func url(_ name: String) -> URL? {
        guard name.hasSuffix(".wav"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        return root.appendingPathComponent(name)
    }
    static func save(_ samples: [Float], name: String) {
        guard let url = url(name) else { return }
        queue.async {
            do { try PrivateFile.write(waveData(samples), to: url) }
            catch { log("History audio could not be saved.") }
        }
    }
    nonisolated static func waveData(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        let count = min(samples.count, Int(Recorder.sampleRate * Recorder.handsFreeMaxSeconds))
        text("RIFF"); u32(UInt32(36 + count * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(UInt32(count * 2))
        for sample in samples.prefix(count) {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            u16(UInt16(bitPattern: Int16(value * 32_767)))
        }
        return data
    }
    static func remove(name: String) {
        guard let url = url(name) else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
    static func prune(keeping names: Set<String>?, now: Date = Date()) {
        let root = root
        let days = History.defaults.object(forKey: "historyAudioRetentionDays") as? Int ?? 7
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "wav" {
                let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if names.map({ !$0.contains(file.lastPathComponent) }) == true || (date ?? .distantPast) < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
    static func flush() { queue.sync {} }
}

struct HistoryRetentionSettings: View {
    @AppStorage("historyRetentionDays") private var textDays = 0
    @AppStorage("saveHistoryAudio") private var audio = false
    @AppStorage("historyAudioRetentionDays") private var audioDays = 7
    var body: some View {
        HStack(spacing: 10) {
            Text("Keep text history").accessibilityHidden(true)
            ThemedMenuPicker(label: "Keep text history",
                             options: [(0, "Until I delete it"), (7, "7 days"), (30, "30 days"), (90, "90 days")],
                             selection: $textDays)
        }.onChange(of: textDays) { _, _ in History.applyRetention() }
        Toggle("Save audio recordings", isOn: $audio)
        if audio {
            HStack(spacing: 10) {
                Text("Keep recordings").accessibilityHidden(true)
                ThemedMenuPicker(label: "Keep recordings", options: [(1, "1 day"), (7, "7 days"), (30, "30 days")], selection: $audioDays)
            }.onChange(of: audioDays) { _, _ in History.applyRetention() }
        }
        HStack(spacing: 8) {
            Button("Export history…") { HistoryExporter.export(History.items) }
            Button("Delete saved recordings", role: .destructive) { HistoryAudio.prune(keeping: []) }
        }
    }
}

@MainActor
enum HistoryExporter {
    static func export(_ items: [History.Item]) {
        let panel = NSSavePanel()
        panel.title = "Export dictation history"
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = "FlowClone-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if url.pathExtension.lowercased() == "json" {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(items)
            } else { data = Data(items.map { "\($0.date.formatted())\n\($0.final)" }.joined(separator: "\n\n").utf8) }
            // The user selected the export directory; don't change its permissions.
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { notifyUser("History export failed. Choose a writable location and try again.") }
    }
}

/// An app's name as the user knows it ("Visual Studio Code"), or its bundle ID when it is
/// not installed here.
@MainActor
enum InstalledApp {
    private static var cache: [String: String] = [:]
    static func name(_ bundleID: String) -> String {
        if let known = cache[bundleID] { return known }
        var name = bundleID
        if !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let display = FileManager.default.displayName(atPath: url.path)
            name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
        }
        cache[bundleID] = name
        return name
    }
}

struct HistoryDetail: View {
    let item: History.Item
    @Environment(\.dismiss) private var dismiss
    @State private var stage = "final"
    @State private var result = ""
    @State private var running = false
    @State private var message = ""
    @State private var sound: NSSound?
    private var text: String {
        switch stage { case "raw": item.raw; case "clean": item.cleaned ?? item.raw; default: item.final }
    }
    /// "Clean", not the stored "clean"; older entries may carry a retired mode's name.
    private var modeTitle: String {
        let raw = item.effectiveMode ?? item.mode
        return Mode(rawValue: raw)?.label ?? raw.capitalized
    }
    /// Mode, app and, when it needs no attention, the delivery outcome in one quiet line;
    /// states that need attention get the badge instead.
    private var summary: String {
        var parts = [modeTitle]
        if let app = item.targetApp, !app.isEmpty { parts.append(InstalledApp.name(app)) }
        if let delivery = item.delivery {
            if delivery == .confirmed || delivery == .ready { parts.append(delivery.label) }
        } else { parts.append("Delivery not recorded") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        SheetFrame(title: "Dictation details", width: 640) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(summary)
                        if let delivery = item.delivery { DeliveryBadge(state: delivery) }
                    }
                    Text([item.model, item.parentID.map { "Rerun of \($0.uuidString.prefix(8))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(UIStyle.caption).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
                ThemedSegmented(options: [("raw", "Raw"), ("clean", "Clean"), ("final", "Final")], selection: $stage, label: "Stage")
                TranscriptWell(text: text, maxHeight: 220)
                HStack(spacing: 8) {
                    Button("Copy stage") { _ = Paster.writeTranscript(text) }
                    Button("Edit in Draft") { DictationWorkspace.shared.append(text); dismiss(); MainWindow.shared.show(.draft) }
                    Button("Export…") { HistoryExporter.export([item]) }
                }
                if let name = item.audioName, let url = HistoryAudio.url(name), FileManager.default.fileExists(atPath: url.path) {
                    HStack(spacing: 8) {
                        Button("Play recording") { sound?.stop(); sound = NSSound(contentsOf: url, byReference: true); sound?.play() }
                        Button("Stop playback") { sound?.stop() }
                        Button("Transcribe again into Draft") {
                            DictationWorkspace.shared.onRetranscribe(item)
                            dismiss(); MainWindow.shared.show(.draft)
                        }.disabled(DictationWorkspace.shared.processing || DictationWorkspace.shared.recording)
                    }
                }
                Hairline()
                HStack(spacing: 8) {
                    Text("Rerun raw transcript")
                    ForEach([Mode.clean, .prompt], id: \.rawValue) { mode in
                        Button(mode.label) { rerun(mode) }.disabled(running)
                    }
                }
                if !message.isEmpty {
                    Text(message).font(UIStyle.caption).foregroundStyle(Theme.muted)
                }
                if !result.isEmpty { TranscriptWell(text: result, maxHeight: 160) }
            }
        } footer: {
            Button("Done") { dismiss() }.prominent().keyboardShortcut(.defaultAction)
        }
        .onDisappear { sound?.stop() }
    }
    /// Transcript text in a well that hugs short text and scrolls past `maxHeight`, so the
    /// dialog sizes to its content instead of reserving a fixed void.
    private struct TranscriptWell: View {
        let text: String
        let maxHeight: CGFloat
        var body: some View {
            CappedHeight(cap: maxHeight) {
                ScrollView {
                    Text(text).font(Theme.writingFont).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.divider))
        }
    }
    /// Takes its content's ideal height, up to `cap`.
    private struct CappedHeight: Layout {
        let cap: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let content = subviews.first else { return .zero }
            let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, cap))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
    private func rerun(_ mode: Mode) {
        running = true; message = "Processing…"
        let canPersist = History.canPersistDerived(from: item.id)
        let raw = item.raw
        DispatchQueue.global(qos: .userInitiated).async {
            let configuration = VocabularySets.shared.configuration(bundleID: item.targetApp)
            let cleaned = Cleaner.cleanWithChanges(raw, configuration: configuration).text
            let complete: @Sendable (String, String) -> Void = { output, effective in
                DispatchQueue.main.async {
                    result = output; running = false; message = "Saved a linked \(effective) result."
                    History.add(raw: raw, final: output, origin: canPersist ? .utterance : .selfTest,
                        mode: mode.rawValue, cleaned: cleaned, effectiveMode: effective,
                        model: effective == "clean" ? "Deterministic cleanup" : "Local rewrite model",
                        delivery: .ready, parentID: item.id)
                }
            }
            let commandLine = SlashCommands.isCommandLine(cleaned)
            if mode == .prompt, !commandLine, Prompter.eligible(cleaned), Prompter.ready() {
                Prompter.promptify(cleaned) { output, _ in complete(output ?? cleaned, output == nil ? "clean" : "prompt") }
            } else { complete(commandLine ? cleaned : SmartFormat.autoList(cleaned), "clean") }
        }
    }
}
