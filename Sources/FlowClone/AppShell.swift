// The window frame shared by every theme: a title rail carrying the cleanup-mode switch and
// the status, a sidebar panel, and a page panel. Themes change materials, not structure:
// colours and radii come from the tokens, and Anthropic (`flatPanels`) drops the frames so
// the page is one sheet of paper. Classic (`sidebarOnGround`, `pageBleeds`) leaves the sidebar
// on the window ground and lays one page over the rest of the window. Sans themes name the page
// in a head band; serif themes and Classic set the title inside the page instead (`PageHeader`).
import Cocoa
import Combine
import SwiftUI

struct AppShell<Detail: View>: View {
    @Bindable var model: MainModel
    @ViewBuilder var detail: Detail

    var body: some View {
        let flat = Theme.flatPanels, bleed = Theme.current.pageBleeds
        VStack(spacing: 6) {
            // The window's transparent titlebar is 32pt; the rail shares it so its
            // contents centre on the traffic lights.
            ShellRail().frame(height: 32)
            HStack(spacing: flat ? 0 : 10) {
                ShellSidebar(model: model).frame(width: Theme.sidebarWidth)
                let page = VStack(spacing: 0) {
                    if !Theme.titlesInPage { ShellPageHead(page: model.page) }
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if bleed {
                    // Drawn behind the page rather than clipping it: a clip to this one-corner
                    // shape masks the page, and the mask redraws some SF Symbols in white.
                    // The page's own margins keep content clear of the corner.
                    page.background {
                        ZStack {
                            UnevenRoundedRectangle(topLeadingRadius: PageEdge.radius).fill(Theme.panel)
                            PageEdge().stroke(Theme.divider)
                        }
                    }
                } else {
                    page.background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: flat ? 0 : Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(flat ? .clear : Theme.divider))
                }
            }
            .padding(flat ? [] : bleed ? [.leading] : [.horizontal, .bottom], 10)
        }
        .background(alignment: .leading) {
            // Flat Anthropic runs its sidebar the full window height, under the rail, like Claude's.
            if flat {
                Theme.sidebar.frame(width: Theme.sidebarWidth)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 0.5) }
            }
        }
        .background(Theme.window)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct ShellRail: View {
    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ThemeMark(theme: Theme.current).frame(width: 18, height: 18)
                Text("FlowClone")
                    .font(Theme.current.bookSerif ? Theme.serif(16, weight: .bold)
                          : Theme.usesSystemType ? .system(size: 15, weight: .semibold) : Theme.serif(17))
                    .foregroundStyle(Theme.ink)
                Spacer()
                ShellStatus()
                Button { ActionPalette.shared.show() } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(InterfaceIconButtonStyle())
                    .help("All actions").accessibilityLabel("All actions")
            }
            .padding(.leading, 80).padding(.trailing, 10)
            ShellModeSwitch()
        }
        // SwiftUI receives clicks under the transparent titlebar, so the empty rail has to move the window itself.
        .background { Color.clear.contentShape(Rectangle()).modifier(WindowDrag()) }
    }
}

private struct WindowDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.gesture(WindowDragGesture()) } else { content }
    }
}

/// The cleanup-mode switch, in every theme's title rail.
private struct ShellModeSwitch: View {
    @State private var selected = Mode.current

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { mode in
                let on = selected == mode
                Button {
                    if mode != Mode.current { Mode.set(mode) }
                    selected = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 12).frame(height: 22)
                        .background(on ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Theme.divider : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.explanation)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cleanup mode")
        .onAppear { syncMode() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            guard MainWindow.shared.isOnScreen else { return }
            syncMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            if MainWindow.shared.isOnScreen { syncMode() }
        }
    }

    private func syncMode() {
        let current = Mode.current
        if selected != current { selected = current }
    }
}

/// Model and capture state, quietly: a warning never competes with a green "Ready".
private struct ShellStatus: View {
    @Bindable private var workspace = DictationWorkspace.shared
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 9).frame(height: 22)
        .accessibilityElement(children: .ignore).accessibilityLabel("Status: \(status.label)")
    }
    private var status: (label: String, color: Color) {
        if workspace.recording { return ("Listening", Color(nsColor: Theme.adaptive(InterfaceColors.wave))) }
        if workspace.processing { return ("Processing", Theme.accent) }
        if workspace.modelReady { return ("Ready to dictate", Theme.success) }
        switch SpeechModelState.shared.status {
        case .failed: return ("Speech model not available", FeedbackKind.warning.color)
        case .downloading(let done, let total): return ("Downloading model \(done)/\(total)", Theme.muted)
        default: return ("Loading model", Theme.muted)
        }
    }
}

private actor SidebarBadgeCounter {
    static let shared = SidebarBadgeCounter()

    private var cachedStamps: [Date?]?
    private var cachedDictionary: Int?
    private var cachedSnippets: Int?

    func currentCounts() -> [MainWindow.Page: Int] {
        let store = PersonalizationStore.shared
        let stamps: [Date?] = [
            store.modificationDate(for: .dictionary),
            store.modificationDate(for: .correction),
            store.modificationDate(for: .snippet)
        ]
        if cachedStamps != stamps {
            func count(_ kinds: [PersonalizationKind]) -> Int? {
                let sizes = kinds.compactMap { try? store.snapshot($0).entries.count }
                return sizes.isEmpty ? nil : sizes.reduce(0, +)
            }
            cachedDictionary = count([.dictionary, .correction])
            cachedSnippets = count([.snippet])
            cachedStamps = stamps
        }
        var result: [MainWindow.Page: Int] = [.transforms: TransformPresets.loadNamed().count]
        if let cachedDictionary { result[.dictionary] = cachedDictionary }
        if let cachedSnippets { result[.snippets] = cachedSnippets }
        return result
    }
}

private struct ShellSidebar: View {
    @Bindable var model: MainModel
    @State private var counts: [MainWindow.Page: Int] = [:]
    @State private var lastPage: MainWindow.Page?
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "v\(info["CFBundleShortVersionString"] as? String ?? "0.3") · \(info["CFBundleVersion"] as? String ?? "local")"
    }

    var body: some View {
        let _ = model.historyVersion
        let framed = !Theme.flatPanels && !Theme.current.sidebarOnGround
        VStack(alignment: .leading, spacing: 2) {
            label("Dictate")
            row(.dictation, count: History.items.count)
            row(.draft)
            row(.meetings)
            label("Personalize").padding(.top, 14)
            row(.dictionary, count: counts[.dictionary])
            row(.snippets, count: counts[.snippets])
            row(.transforms, count: counts[.transforms])
            Spacer(minLength: 12)
            ShellSidebarRow(page: .help, selection: $model.page) {
                Image(systemName: MainWindow.Page.help.icon).frame(width: 18)
                    .foregroundStyle(model.page == .help ? (Theme.flatPanels ? Theme.ink : Theme.accentText) : Theme.muted)
                Text("Help")
            }
            ShellSidebarRow(page: .settings, selection: $model.page, height: 42) {
                Image(systemName: MainWindow.Page.settings.icon).frame(width: 18)
                    .foregroundStyle(model.page == .settings ? (Theme.flatPanels ? Theme.ink : Theme.accentText) : Theme.muted)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                    Text(version).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit()
                }
                Spacer()
                Text("⌘,").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 10))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(framed ? Theme.sidebar : .clear, in: RoundedRectangle(cornerRadius: framed ? Theme.radius : 0))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(framed ? Theme.divider : .clear))
        // Personalization lives in files; recount off the main actor only on initial appear or after editing them.
        .task(id: model.page) {
            let personalizationPages: Set<MainWindow.Page> = [.dictionary, .snippets, .transforms]
            let shouldRefresh = counts.isEmpty
                || personalizationPages.contains(model.page)
                || (lastPage.map(personalizationPages.contains) ?? false)
            lastPage = model.page
            guard shouldRefresh else { return }
            let updated = await SidebarBadgeCounter.shared.currentCounts()
            if counts != updated { counts = updated }
        }
    }

    private func label(_ text: String) -> some View {
        let flat = Theme.flatPanels
        // Classic names its groups like a book's contents: the serif in italic, sentence case.
        let caption = Theme.current.bookSerif
            ? Text(text).font(Theme.serif(14, italic: true))
            : Text(flat ? text : text.uppercased()).font(.system(size: flat ? 12 : 11, weight: .semibold)).tracking(flat ? 0 : 0.6)
        return caption
            .foregroundStyle(Theme.muted).padding(.horizontal, 10).padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ page: MainWindow.Page, count: Int? = nil) -> some View {
        ShellSidebarRow(page: page, selection: $model.page) {
            Image(systemName: page.icon).frame(width: 18)
                .foregroundStyle(model.page == page ? (Theme.flatPanels ? Theme.ink : Theme.accentText) : Theme.muted)
            Text(page.title)
            Spacer()
            if let count { Text(History.compact(count)).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit() }
        }
    }
}

private struct ShellSidebarRow<Label: View>: View {
    let page: MainWindow.Page
    @Binding var selection: MainWindow.Page
    var height: CGFloat = 34
    @ViewBuilder var label: Label
    @State private var hovering = false
    @FocusState private var focused: Bool

    /// Soft Seal carries its seal's diagonal corners into the selected row.
    private var rowShape: AnyShape {
        Theme.current == .softSeal
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 6, bottomTrailingRadius: 14, topTrailingRadius: 6))
            : AnyShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    var body: some View {
        let selected = selection == page
        Button { selection = page } label: {
            HStack(spacing: 10) { label }
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.ink)
                .symbolRenderingMode(.monochrome)
                .imageScale(.medium)
                .tint(selected ? Theme.accentText : Theme.muted)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(selected ? Theme.selection : hovering ? Theme.rowHover : .clear, in: rowShape)
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .onHover { hovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Sans themes name the page in a quiet band at the top of the page panel.
private struct ShellPageHead: View {
    let page: MainWindow.Page
    var body: some View {
        HStack {
            Text(page.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Theme.ink.opacity(0.03))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

/// Classic's page edge: a hairline down the left side and across the top, joined by the page's
/// one rounded corner, where the page meets the sidebar and the title rail.
struct PageEdge: Shape {
    static let radius: CGFloat = 18
    func path(in rect: CGRect) -> Path {
        let r = Self.radius, x = rect.minX + 0.5, y = rect.minY + 0.5
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: x, y: y + r))
        path.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x + r, y: y), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}
