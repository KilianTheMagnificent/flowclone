// Home-page pieces shared by every theme: the compact welcome (sans themes), keycaps, and the
// one capture bar used on Dictation and Draft. The window frame they sit in is AppShell.swift.
import Cocoa
import SwiftUI

/// The sans themes' greeting: one 22pt line, one muted line and the shortcut keycaps. Serif
/// themes use `ThemedDictationWelcome` instead.
struct CompactWelcome: View {
    var body: some View {
        let dictate = ShortcutStore.shared.bindings.filter { $0.action == .dictate }.map(\.title)
        VStack(alignment: .leading, spacing: 4) {
            Text(DictationPage.greeting(fullName: NSFullUserName()))
                .font(.system(size: 22, weight: .semibold)).tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 16) {
                if dictate.isEmpty { Text("No dictation shortcut assigned") }
                else { keys(dictate, "hold to dictate, double-tap for hands-free") }
                keys(["esc"], "cancel hands-free")
            }
            .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keys(_ caps: [String], _ what: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                if index > 0 { Text("or") }
                Keycap(text: cap)
            }
            Text(what).padding(.leading, 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(caps.joined(separator: " or ")): \(what)")
    }
}

/// Kept for the theme-preview renders, which still name the Interface original.
typealias InterfaceWelcome = CompactWelcome

/// Classic's greeting: the page title in the book serif and one quiet line. Dictation starts
/// from the shortcut, so the journal home carries no shortcut hints or capture button.
struct JournalWelcome: View {
    var body: some View {
        Text(DictationPage.greeting(fullName: NSFullUserName()))
            .font(Theme.pageFont).tracking(-0.3)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 18)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.divider))
    }
}

/// The one capture control, on Dictation and (compact) on Draft. The whole composer-styled
/// bar is the button: clicking anywhere on it dictates into Draft. Recording swaps in Finish
/// and Cancel; processing shows progress. "All actions" stays a separate trailing button.
struct CaptureBar: View {
    var compact = false
    @Bindable private var workspace = DictationWorkspace.shared
    @State private var hovering = false

    private var disc: CGFloat { compact ? 26 : 34 }
    private var titleFont: Font { .system(size: compact ? 14 : 15, weight: .medium) }
    private var hint: String? {
        if !workspace.modelReady && !workspace.processing {
            let model = SpeechModelState.shared.status
            return model == .loading ? "Preparing speech model…" : model.shortLabel
        }
        return nil
    }

    var body: some View {
        let recording = workspace.recording
        let canStart = !workspace.processing && workspace.modelReady
        // A compact bar keeps a rectangle's corners even in Soft Seal (20pt would make it a capsule).
        // Anthropic draws Claude's composer: 20pt continuous corners, a faint lift, a hairline.
        let composer = Theme.current == .anthropic
        let shape = RoundedRectangle(cornerRadius: composer ? (compact ? 14 : 20) : compact ? min(Theme.radius, 12) : Theme.radius,
                                     style: .continuous)
        HStack(spacing: 8) {
            if recording { recordingRow } else {
                Button { workspace.perform(.draft) } label: { startLabel(canStart: canStart) }
                    .buttonStyle(CaptureSurfaceStyle())
                    .disabled(!canStart)
                    .onHover { hovering = $0 }
                    .help("Dictate into Draft")
                    .accessibilityLabel(workspace.processing ? "Processing" : "Dictate into Draft")
                    .accessibilityHint(hint ?? "")
                Button { ActionPalette.shared.show() } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(InterfaceIconButtonStyle(boxed: true))
                    .help("All actions").accessibilityLabel("All actions")
                    .padding(.trailing, compact ? 7 : 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: shape)
        .shadow(color: .black.opacity(composer ? (hovering ? 0.075 : 0.035) : 0), radius: 10, y: 4)
        .overlay(shape.stroke(recording ? Theme.accent : hovering && canStart ? Theme.fieldStroke : Theme.divider,
                              lineWidth: recording ? 1.5 : composer ? 0.75 : 1))
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func startLabel(canStart: Bool) -> some View {
        HStack(spacing: compact ? 10 : 12) {
            ZStack {
                if workspace.processing {
                    Circle().fill(Theme.selection)
                    ProgressView().controlSize(.small)
                } else if Theme.current == .anthropic {
                    // Claude's one clay control: a small rounded square carrying a white glyph.
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: Theme.brand))
                    Image(systemName: "mic.fill").font(.system(size: compact ? 11 : 13, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Circle().fill(Theme.primary)
                    Image(systemName: "mic.fill").font(.system(size: compact ? 11 : 14, weight: .semibold))
                        .foregroundStyle(Theme.onPrimary)
                }
            }
            .frame(width: Theme.current == .anthropic ? disc - 4 : disc, height: Theme.current == .anthropic ? disc - 4 : disc)
            .opacity(canStart || workspace.processing ? 1 : 0.45)
            let title = Text(workspace.processing ? "Processing…" : "Dictate into Draft")
                .font(titleFont).foregroundStyle(workspace.processing ? Theme.muted : Theme.ink)
            let note = hint.map { Text($0).font(UIStyle.caption).foregroundStyle(Theme.muted) }
            if compact || workspace.processing {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    if !workspace.processing, let note { note }
                }
                .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 1) { title; if let note { note } }
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, compact ? 7 : 11).padding(.vertical, compact ? 7 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var recordingRow: some View {
        HStack(spacing: compact ? 10 : 12) {
            ZStack {
                Circle().fill(Theme.selection)
                Image(systemName: "waveform").font(.system(size: compact ? 11 : 14, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
            }
            .frame(width: disc, height: disc)
            .accessibilityHidden(true)
            Text("Recording · \(workspace.captureLabel)").font(titleFont).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") { workspace.onCancel() }
            Button("Finish") { workspace.onStop() }.prominent()
        }
        .padding(compact ? 7 : 11)
    }
}

/// Press feedback for the capture bar; its hover edge is drawn by the bar itself.
private struct CaptureSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct InterfaceIconButtonStyle: ButtonStyle {
    var boxed = false
    func makeBody(configuration: Configuration) -> some View {
        IconBody(label: configuration.label, pressed: configuration.isPressed, boxed: boxed)
    }

    private struct IconBody: View {
        let label: Configuration.Label
        let pressed: Bool
        let boxed: Bool
        @State private var hovering = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
            label
                .font(.system(size: 13))
                .foregroundStyle(hovering ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 28)
                .background(pressed ? Theme.selection : hovering ? Theme.ink.opacity(0.08) : boxed ? Theme.ink.opacity(0.04) : .clear,
                            in: shape)
                // A boxed button keeps a visible edge (the secondary button's outline).
                .overlay(shape.stroke(boxed ? Theme.fieldStroke.opacity(0.55) : .clear))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}
