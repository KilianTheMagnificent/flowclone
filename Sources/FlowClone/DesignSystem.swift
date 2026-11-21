import Cocoa
import SwiftUI

/// Shared roles for the native window; the recording overlay keeps its compact geometry.
enum UIStyle {
    static let pageInset: CGFloat = 28
    @MainActor static var radius: CGFloat { Theme.radius }
    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)
}

enum FeedbackKind {
    case success, warning, error, information
    var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        case .information: "info.circle"
        }
    }
    /// Each theme's own success/danger roles (≥4.5:1 on every surface); system colours
    /// return under Increase Contrast.
    @MainActor var color: Color {
        let themed = !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return switch self {
        case .success: themed ? Theme.success : Color(nsColor: .systemGreen)
        case .warning: themed ? Color(nsColor: Theme.adaptive((0x8A5A00, 0xF2C064))) : Color(nsColor: .systemOrange)
        case .error: themed ? Theme.danger : Color(nsColor: .systemRed)
        case .information: Theme.muted
        }
    }
}

struct Feedback: View {
    let text: String
    var kind: FeedbackKind = .information
    var body: some View {
        Label { Text(text).foregroundStyle(.primary).textSelection(.enabled) } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
        .font(UIStyle.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .modifier(SearchFieldChrome())
    }
}

/// Classic's search is a soft pill tinted from the page; the other themes keep the bordered field.
private struct SearchFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.current.bookSerif {
            content.padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.wash, in: Capsule())
        } else {
            content.padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.fieldStroke))
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 14) {
            if Theme.current == .anthropic {
                BrushTileIllustration().frame(width: 160, height: 120)
            } else {
                Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
            }
            Text(title).font(Theme.sectionFont)
            if let detail, !detail.isEmpty {
                Text(detail).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let actionTitle, !actionTitle.isEmpty, let action {
                Button(actionTitle, action: action).prominent()
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Mode {
    var explanation: String {
        switch self {
        case .raw: "Exact transcript, without cleanup."
        case .clean: "Removes fillers, fixes punctuation and dictionary sound-alikes, and keeps short clean dictations instant."
        case .prompt: "Structures what you say into an AI prompt (uses Claude when a key is saved, or Apple's built-in model offline)."
        }
    }
}

extension PersonalizationKind {
    var singular: String {
        switch self { case .dictionary: "term"; case .correction: "correction"; case .snippet: "snippet" }
    }
    var example: String {
        switch self {
        case .dictionary: "Add names and specialist vocabulary, such as FlowClone."
        case .correction: "Replace a recurring mishearing, such as flow clone → FlowClone."
        case .snippet: "Expand a spoken phrase, such as my sign off, into a reusable message."
        }
    }
}

/// A themed hairline in either orientation; a bare Divider keeps AppKit's cool grey on warm paper.
struct Hairline: View {
    var body: some View { Divider().overlay(Theme.stroke) }
}

// MARK: - Shared controls (every theme; colours and radii come from the tokens)

/// One button family for all themes. `primary` is the page's main action; `secondary` is
/// outlined; `destructive` keeps the outline and uses the danger role for its label.
struct ThemedButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, kind: kind)
    }
}

private struct ThemedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: ThemedButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        let radius = Theme.controlRadius, primary = kind == .primary
        let destructive = configuration.role == .destructive
        configuration.label
            .font(UIStyle.body.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, Theme.buttonPadding).frame(minHeight: Theme.buttonHeight)
            .foregroundStyle(primary ? Theme.onPrimary : destructive ? Theme.danger : Theme.ink)
            .background(primary ? Theme.primary : Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).fill(Theme.ink.opacity(configuration.isPressed ? 0.12 : hovering ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(primary ? .clear : Theme.buttonStroke))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .opacity(enabled ? 1 : 0.45)
            // A small press, eased out (Anthropic's .165/.84/.44/1 curve); still under Reduce Motion.
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .timingCurve(0.165, 0.84, 0.44, 1, duration: 0.15), value: configuration.isPressed)
            .onHover { hovering = $0 && enabled }
    }
}

/// Kept for existing call sites: the editorial and Interface buttons now share `ThemedButtonStyle`.
typealias PaperButtonStyle = ThemedButtonStyle
extension ThemedButtonStyle {
    init(prominent: Bool) { self.init(kind: prominent ? .primary : .secondary) }
}

extension View {
    /// The page's primary action, in every theme.
    @MainActor func prominent() -> some View { buttonStyle(ThemedButtonStyle(kind: .primary)) }
    /// Outlined buttons, checkboxes and fields for everything inside.
    @MainActor func themedButtons() -> some View {
        buttonStyle(ThemedButtonStyle()).textFieldStyle(ThemedTextFieldStyle()).toggleStyle(ThemedCheckboxStyle())
    }
    /// A long paragraph's measure (~75 characters at 14pt).
    func proseWidth() -> some View { frame(maxWidth: 620, alignment: .leading) }
    /// A page's content inset. Classic sets one 680pt column with book margins on its page;
    /// the other themes fill the page inside the standard inset.
    @MainActor @ViewBuilder func pageColumn() -> some View {
        if Theme.current.pageBleeds {
            frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 48, leading: 64, bottom: 48, trailing: 64))
        } else {
            padding(UIStyle.pageInset)
        }
    }
    /// The field treatment for multi-line editors (TextEditor, hosted NSTextView).
    /// Anthropic draws large editors like Claude's composer — a white card on a hairline with a
    /// faint lift — rather than the 3:1 input edge single-line fields keep. Classic's Draft asks
    /// for the same sheet (`composer: true`).
    @MainActor func themedEditor(composer asked: Bool = false) -> some View {
        let composer = Theme.flatPanels || asked
        let shape = RoundedRectangle(cornerRadius: composer ? 14 : Theme.controlRadius, style: .continuous)
        // The lift belongs to the card alone; a shadow on the whole view also shades the area
        // around the hosted text view inside the card.
        return scrollContentBackground(.hidden)
            .padding(composer ? 12 : 8)
            .background { shape.fill(Theme.field).shadow(color: .black.opacity(composer ? 0.035 : 0), radius: 10, y: 4) }
            .overlay(shape.stroke(composer ? Theme.divider : Theme.fieldStroke, lineWidth: composer ? 0.75 : 1))
    }
}

/// Single-line fields: the field fill, a ≥3:1 edge, and an accent ring while focused.
@MainActor
struct ThemedTextFieldStyle: @preconcurrency TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View { FieldChrome(field: configuration) }
}

private struct FieldChrome<Field: View>: View {
    let field: Field
    @FocusState private var focused: Bool
    var body: some View {
        field.textFieldStyle(.plain).focused($focused)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .stroke(focused ? Theme.accent : Theme.fieldStroke, lineWidth: focused ? 2 : 1))
    }
}

/// Checkbox with a visible (≥3:1) box when off and the primary fill when on.
struct ThemedCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(configuration.isOn ? Theme.primary : Theme.field)
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(configuration.isOn ? Color.clear : Theme.fieldStroke, lineWidth: 1.2)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onPrimary)
                    }
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                configuration.label.foregroundStyle(Theme.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A compact segmented control in the theme's own materials (NSSegmentedControl keeps
/// AppKit's grey in every theme).
struct ThemedSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String = ""
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius - 2))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius - 2).stroke(on ? Theme.divider : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A pop-up choice drawn as a themed secondary button with a chevron (AppKit's pop-up keeps
/// its grey bezel in every theme). The open menu stays native; a check marks the selection.
struct ThemedMenuPicker<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var width: CGFloat? = nil
    var body: some View {
        let current = options.first { $0.value == selection }?.title ?? ""
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.value } label: {
                    if option.value == selection { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(current).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .frame(width: width.map { $0 - 24 }, alignment: .leading)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ThemedButtonStyle())
        .fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(current)
    }
}

/// Every dialog: one title scale, the raised surface, content, and a right-aligned footer
/// whose last button is the primary action.
struct SheetFrame<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 560
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.sheetTitleFont).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 8) { Spacer(); footer }
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .background(Theme.surface)
        .font(UIStyle.body)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .themedButtons()
    }
}

/// The one section heading style: title plus an optional muted count.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    init(_ title: String, count: Int? = nil) { self.title = title; self.count = count }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.sectionFont)
            if let count { Text(History.compact(count)).font(UIStyle.caption).foregroundStyle(Theme.muted).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Delivery state as a badge only when it needs attention; confirmed and ready stay quiet.
struct DeliveryBadge: View {
    let state: DeliveryState
    var body: some View {
        switch state {
        case .unverified: badge("exclamationmark.triangle", "Insertion unverified — check the app before pasting again", .warning)
        case .notInserted: badge("xmark.circle", "Not inserted — copy it from here", .error)
        case .learned: badge("checkmark.circle", state.label, .success)
        case .draft: badge("square.and.pencil", state.label, .information)
        case .ready, .confirmed: EmptyView()
        }
    }
    private func badge(_ symbol: String, _ text: String, _ kind: FeedbackKind) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol) }
            .font(UIStyle.caption.weight(.medium))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(kind.color.opacity(0.1), in: Capsule())
            .accessibilityLabel(text)
    }
}
