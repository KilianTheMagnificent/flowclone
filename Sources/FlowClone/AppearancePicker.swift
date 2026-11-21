import Cocoa
import SwiftUI

/// Settings → Appearance: one compact row per theme and a single live preview of the chosen
/// theme's speaking indicator underneath.
struct AppearancePicker: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var previewRunning = false
    @State private var previewStart = Date.now
    private let store = AppearanceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 4) {
                ForEach(AppTheme.allCases) { choice in
                    ThemeChoiceRow(choice: choice, selected: store.theme == choice) { store.select(choice) }
                }
            }
            // Flat pages have no card inset: hang the row fill into the margin so the marks
            // keep the section's left edge.
            .padding(.horizontal, Theme.flatPanels ? -12 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")
            preview
        }.onDisappear { previewRunning = false }
    }

    /// The selected theme's pill on a page-coloured well, its description, and the sample.
    private var preview: some View {
        let theme = store.theme
        return HStack(alignment: .center, spacing: 16) {
            Group {
                if previewRunning {
                    TimelineView(.animation(minimumInterval:reducedMotion ? 0.25 : 1/60)) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(previewStart)
                        let part = elapsed.truncatingRemainder(dividingBy:9)
                        let phase: IndicatorPreviewPhase = part < 5.5 ? .speaking : part < 7 ? .processing : part < 8 ? .ready : .idle
                        VStack(spacing: 8) {
                            indicator(theme, phase: phase, level: IndicatorPreviewPhase.sampleLevel(at:elapsed), reducedMotion: reducedMotion)
                            Text(phase.label).font(UIStyle.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .accessibilityLabel("Animated speaking indicator preview")
                } else {
                    indicator(theme, phase: .speaking, level: 0, reducedMotion: reducedMotion, still: true)
                        .id(theme)
                        .accessibilityLabel("\(theme.title) speaking indicator")
                }
            }
            .frame(width: 148, height: 84)
            .background(Theme.window, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.divider))
            VStack(alignment: .leading, spacing: 8) {
                Text(theme.title).fontWeight(.semibold)
                Button(previewRunning ? "Stop preview" : "Preview speaking indicator") {
                    previewStart = .now; previewRunning.toggle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func indicator(_ theme: AppTheme, phase: IndicatorPreviewPhase, level: Float, reducedMotion: Bool, still: Bool = false) -> some View {
        NativeIndicatorPreview(phase:phase,level:level,reducedMotion:reducedMotion,still:still)
            .frame(width:phase == .idle ? theme.idleSize.width : phase == .processing ? theme.processingSize.width : theme.activeSize.width,
                   height:phase == .idle ? theme.idleSize.height : theme.activeSize.height)
    }
}

/// One theme: its mark and name, a strip of its own colours, and a radio mark. The selected
/// row takes the selection fill and an accent ring.
private struct ThemeChoiceRow: View {
    let choice: AppTheme
    let selected: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    var body: some View {
        let palette = colorScheme == .dark ? choice.dark : choice.light
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        Button(action: select) {
            HStack(spacing: 12) {
                ThemeMark(theme: choice).frame(width: 22, height: 22)
                Text(choice.title)
                    .font(choice.serifDisplay || choice.bookSerif ? choice.displayFont(17) : .system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    // Page, selection tint, accent and ink: enough to tell the themes apart.
                    // Settle's accent is its ink, so it shows its grey ramp instead.
                    ForEach(Array([palette.window, palette.selection, choice == .anthropic ? 0xD97757 : choice == .settle ? palette.muted : palette.accent, palette.ink].enumerated()), id: \.offset) { _, rgb in
                        Circle().fill(Color(nsColor: NSColor(rgb: rgb)))
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1))
                            .frame(width: 14, height: 14)
                    }
                }
                .accessibilityHidden(true)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accentText : Theme.fieldStroke)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(minHeight: 38)
            .background(selected ? Theme.selection : hovering ? Theme.rowHover : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(choice.detail)
        .accessibilityLabel("\(choice.title) theme")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(choice.detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

enum IndicatorPreviewPhase: Equatable {
    case speaking, processing, ready, idle
    var label: String { switch self { case .speaking:"Speaking";case .processing:"Processing";case .ready:"Ready";case .idle:"Resting" } }
    static func sampleLevel(at time: Double) -> Float {
        // Simulate Recorder's 150ms packets, including silence between phrases.
        let packetStart = floor(max(0, time) / 0.15) * 0.15
        let total = (0..<9).reduce(0.0) { sum, index in
            let t = (packetStart + Double(index) / 60).truncatingRemainder(dividingBy: 4.5)
            guard t >= 0.55 && t <= 3.5 else { return sum }
            return sum + pow(max(0, sin((t - 0.55) * 7.2)), 0.65) * (0.48 + 0.5 * pow(sin(t * 1.5), 2))
        }
        return Float(total / 9)
    }
}

struct NativeIndicatorPreview: NSViewRepresentable {
    let phase: IndicatorPreviewPhase
    let level: Float
    let reducedMotion: Bool
    /// Settings' resting sample: play a phrase of the sample voice once, then hold that frame.
    var still = false
    final class Coordinator { var phase: IndicatorPreviewPhase? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> PillView { PillView() }
    func updateNSView(_ view:PillView,context:Context) {
        view.reduceMotion = reducedMotion
        if context.coordinator.phase != phase {
            switch phase { case .speaking:view.reset();case .processing:view.beginProcessing(slow:false);case .ready:view.beginReady();case .idle:view.beginIdle() }
            context.coordinator.phase = phase
            if still, phase == .speaking {
                for step in 0..<84 {
                    view.push(IndicatorPreviewPhase.sampleLevel(at: 0.6 + Double(step) / 30))
                    view.tick(deltaTime: 1.0 / 30)
                }
            }
        }
        if !still {
            if phase == .speaking { view.push(level) }
            view.tick()
        }
        view.needsDisplay = true
    }
}
