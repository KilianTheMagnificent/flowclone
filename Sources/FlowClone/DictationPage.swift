import Cocoa
import SwiftUI

struct DictationHistorySummary: Equatable {
    var speakingSeconds: Double
    var wordsPerMinute: Int?
    var streakDays: Int
    var topApps: [(id: String, name: String, count: Int)]

    static func == (lhs: DictationHistorySummary, rhs: DictationHistorySummary) -> Bool {
        lhs.speakingSeconds == rhs.speakingSeconds
            && lhs.wordsPerMinute == rhs.wordsPerMinute
            && lhs.streakDays == rhs.streakDays
            && lhs.topApps.count == rhs.topApps.count
            && zip(lhs.topApps, rhs.topApps).allSatisfy { a, b in
                a.id == b.id && a.name == b.name && a.count == b.count
            }
    }
}

@MainActor
enum DictationHistorySummaryCache {
    private struct CacheKey: Equatable {
        var version: Int
        var dayStart: Date
        var seededSeconds: Double
        var count: Int
    }

    private static var cachedKey: CacheKey?
    private static var cachedValue: DictationHistorySummary?
    private(set) static var computeCount = 0

    static func current(today: Date = Date(), calendar: Calendar = .current) -> DictationHistorySummary {
        let items = History.items
        let seeded = TranscriptionStats.totalSeconds(in: History.defaults)
        let key = CacheKey(
            version: History.version,
            dayStart: calendar.startOfDay(for: today),
            seededSeconds: seeded,
            count: items.count
        )
        if cachedKey == key, let cachedValue {
            return cachedValue
        }
        let computed = compute(items: items, seededSeconds: seeded, today: today, calendar: calendar)
        cachedKey = key
        cachedValue = computed
        computeCount += 1
        return computed
    }

    /// Single O(N) pass over `items` computing speaking time, WPM, streak days, and top target apps.
    static func compute(
        items: [History.Item],
        seededSeconds: Double,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> DictationHistorySummary {
        var historySeconds = 0.0
        var timedSeconds = 0.0
        var timedWords = 0
        var days = Set<Date>()
        var appCounts: [String: Int] = [:]

        for item in items {
            if item.seconds.isFinite && item.seconds > 0 {
                historySeconds += item.seconds
                timedSeconds += item.seconds
                timedWords += item.words
            }
            days.insert(calendar.startOfDay(for: item.date))
            if let app = item.targetApp, !app.isEmpty {
                appCounts[app, default: 0] += 1
            }
        }

        let speakingSeconds = max(seededSeconds, historySeconds)
        let wordsPerMinute: Int? = timedSeconds > 0
            ? Int((Double(timedWords) / timedSeconds * 60).rounded())
            : nil

        var streak = 0
        var day = calendar.startOfDay(for: today)
        if days.contains(day) || (calendar.date(byAdding: .day, value: -1, to: day).map { days.contains($0) } ?? false) {
            if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
                day = yesterday
            }
            while days.contains(day) {
                streak += 1
                guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
                day = previous
            }
        }

        let topApps = appCounts
            .sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            .prefix(6)
            .map { (id: $0.key, name: InstalledApp.name($0.key), count: $0.value) }

        return DictationHistorySummary(
            speakingSeconds: speakingSeconds,
            wordsPerMinute: wordsPerMinute,
            streakDays: streak,
            topApps: topApps
        )
    }
}

struct DictationPage: View {
    @Bindable var model: MainModel
    @State private var query = ""
    @State private var selectedApp: String?

    private var items: [History.Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty || selectedApp != nil else { return History.items }
        return History.items.filter { item in
            if let selectedApp, item.targetApp != selectedApp { return false }
            guard !q.isEmpty else { return true }
            return item.final.localizedCaseInsensitiveContains(q) || item.raw.localizedCaseInsensitiveContains(q)
        }
    }

    private func sections(for items: [History.Item]) -> [(title: String, items: [History.Item])] {
        var out: [(String, [History.Item])] = []
        // Group on the day itself, so `sectionTitle` (and its formatting) runs once per
        // section instead of once per row.
        var currentDay: Date?
        let calendar = Calendar.current
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if day == currentDay { out[out.count - 1].1.append(item) }
            else {
                currentDay = day
                out.append((History.sectionTitle(for: item.date), [item]))
            }
        }
        return out
    }

    /// "Welcome back, Andre" from the account's full name; "Welcome back" when unknown.
    /// Anthropic's home greets like Claude does: by the time of day, in serif.
    nonisolated static func timeGreeting(fullName: String, date: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    nonisolated static func greeting(fullName: String) -> String {
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Welcome back" : "Welcome back, \(first)"
    }

    /// Below this page height (a window under ~700pt) the serif hero collapses to one line and
    /// the capture bar takes its compact form, so several dictations stay in view.
    static let compactHeroHeight: CGFloat = 650

    var body: some View {
        let _ = model.historyVersion
        let summary = DictationHistorySummaryCache.current()
        let items = items
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The mode lives in the shell rail; the shortcut in the welcome and the capture hint.
                    let short = proxy.size.height < Self.compactHeroHeight
                    let journal = Theme.current.journalHome
                    if Theme.current == .anthropic {
                        // Claude's home: a centred serif greeting over one white composer, then a
                        // quiet line of totals — nothing competes with the place to start.
                        VStack(spacing: short ? 14 : 22) {
                            ComposerGreeting(compact: short)
                            CaptureBar(compact: short).frame(maxWidth: 672)
                            StatsRow(model: model, summary: summary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, short ? 4 : 36)
                    } else if journal {
                        // Classic's journal: the greeting and the totals, then straight to the words.
                        JournalWelcome()
                        StatsRow(model: model, summary: summary).padding(.top, short ? 20 : 30)
                    } else {
                        if Theme.usesSystemType { CompactWelcome() } else { ThemedDictationWelcome(compact: short) }
                        StatsRow(model: model, summary: summary).padding(.top, 14)
                        CaptureBar(compact: short).padding(.top, 18)
                    }
                    HStack(alignment: .center, spacing: 16) {
                        SectionHeader("Your dictations", count: History.items.count)
                        Spacer(minLength: 16)
                        SearchField(prompt: "Search dictations", text: $query).frame(maxWidth: journal ? 220 : 260)
                    }
                    .padding(.top, journal ? (short ? 30 : 46) : 28)
                    if !summary.topApps.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                AppFilterChip(title: "All", isSelected: selectedApp == nil) {
                                    selectedApp = nil
                                }
                                ForEach(summary.topApps, id: \.id) { app in
                                    AppFilterChip(title: app.name, isSelected: selectedApp == app.id) {
                                        selectedApp = (selectedApp == app.id) ? nil : app.id
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .padding(.top, 10)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Filter dictations by app")
                    }
                    if items.isEmpty {
                        let filtered = !query.isEmpty || selectedApp != nil
                        if filtered {
                            EmptyState(symbol: "magnifyingglass",
                                       title: "No matching dictations",
                                       actionTitle: "Clear filters") {
                                query = ""; selectedApp = nil
                            }.frame(minHeight: 200)
                        } else {
                            EmptyState(symbol: "waveform", title: "No dictations yet")
                                .frame(minHeight: 200)
                        }
                    }
                    ForEach(sections(for: items), id: \.title) { section in
                        HistorySection(title: section.title, items: section.items).padding(.top, journal ? 26 : 18)
                    }
                }
                .frame(maxWidth: Theme.current == .anthropic ? 760 : .infinity)
                .frame(maxWidth: .infinity)
                .pageColumn()
            }
        }
    }
}

private struct AppFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accentText : Theme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Theme.selection : Theme.ink.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(isSelected ? Theme.accent.opacity(0.45) : Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One day of dictations: a small group label, then the rows on one surface. Anthropic's flat
/// page keeps only the hairlines.
private struct HistorySection: View {
    let title: String
    let items: [History.Item]
    var body: some View {
        let flat = Theme.flatPanels, journal = Theme.current.journalHome
        let open = flat || journal
        let shape = RoundedRectangle(cornerRadius: Theme.radius)
        VStack(alignment: .leading, spacing: journal ? 0 : 8) {
            // Anthropic keeps sentence case, as Claude's sidebar and lists do; Classic's journal
            // names the day in the serif's italic.
            Group {
                if journal {
                    Text(title.lowercased().capitalized).font(Theme.serif(15, italic: true))
                } else {
                    Text(flat ? title.lowercased().capitalized : title.uppercased())
                        .font(.system(size: flat ? 12 : 11, weight: .semibold)).tracking(flat ? 0 : 0.6)
                }
            }
            .foregroundStyle(Theme.muted)
            .accessibilityAddTraits(.isHeader)
            LazyVStack(spacing: 0) {
                if flat { Hairline() }
                ForEach(items) { item in
                    HistoryRow(item: item)
                    if item.id != items.last?.id { Hairline().padding(.horizontal, open ? 0 : 16) }
                }
            }
            .background(open ? .clear : Theme.surface, in: shape)
            .clipShape(open ? AnyShape(Rectangle().inset(by: -10)) : AnyShape(shape))
            .overlay(shape.stroke(open ? .clear : Theme.divider))
        }
    }
}

/// Totals as one quiet row of value–label pairs, so the history starts high on the page.
struct StatsRow: View {
    @Bindable var model: MainModel
    var summary: DictationHistorySummary? = nil
    var body: some View {
        let _ = model.historyVersion
        let resolved = summary ?? DictationHistorySummaryCache.current()
        let words = History.compact(TranscriptionStats.totalWords)
        let speaking = TranscriptionStats.formatSpeakingTime(resolved.speakingSeconds)
        let pace = resolved.wordsPerMinute.map(String.init) ?? "—"
        let streak = String(resolved.streakDays)
        Group {
            if Theme.current.journalHome {
                // Classic: serif figures over small captions, no rules between them.
                HStack(alignment: .top, spacing: 44) {
                    figure(words, "total words")
                    figure(speaking, "speaking time")
                    figure(pace, "words / min")
                    figure(streak, "day streak")
                }
            } else {
                HStack(spacing: 14) {
                    stat(words, "total words")
                    separator
                    stat(speaking, "speaking time")
                    separator
                    stat(pace, "words / min")
                    separator
                    stat(streak, "day streak")
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(Theme.serif(26)).foregroundStyle(Theme.ink)
            Text(label).font(UIStyle.caption).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
    private var separator: some View {
        Rectangle().fill(Theme.divider).frame(width: 1, height: 14).accessibilityHidden(true)
    }
    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(Theme.usesSystemType ? .system(size: 16, weight: .semibold).monospacedDigit() : Theme.serif(19))
                .foregroundStyle(Theme.ink)
            Text(label).font(UIStyle.caption).foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HistoryRow: View {
    let item: History.Item
    var copyTranscript: (String) -> Bool = { Paster.writeTranscript($0) }
    @State private var copyFeedback = CopyFeedback()
    @State private var hovering = false
    @State private var showRaw = false
    @State private var showDetail = false
    @State private var showTeachCorrection = false
    @State private var expanded = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    private var isLong: Bool { item.final.count > 240 || item.final.filter { $0 == "\n" }.count > 3 }
    var body: some View {
        // Classic's journal leads with the words and keeps the time and actions underneath.
        let journal = Theme.current.journalHome, open = Theme.flatPanels || journal
        VStack(alignment: .leading, spacing: 8) {
            if !journal { details }
            Text(item.final).font(Theme.writingFont).lineSpacing(journal ? 5 : 4)
                .lineLimit(isLong && !expanded ? 4 : nil).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Only states that need attention show; a confirmed insertion stays quiet.
            if let delivery = item.delivery { DeliveryBadge(state: delivery) }
            if isLong {
                Button(expanded ? "Show less" : "Read full dictation") { expanded.toggle() }
                    .buttonStyle(.borderless).font(UIStyle.caption).foregroundStyle(Theme.accentText)
            }
            if journal { details }
        }
        .padding(.horizontal, open ? 0 : 16).padding(.vertical, 14)
        // Rows fill their clipped group; on open pages the hover wash reaches a little past the text.
        .background(hovering ? Theme.rowHover : .clear,
                    in: open ? AnyShape(RoundedRectangle(cornerRadius: Theme.controlRadius).inset(by: -8)) : AnyShape(Rectangle()))
        .contentShape(Rectangle())
        .focusable().focused($focused)
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).inset(by: open ? -8 : 2)
            .stroke(focused ? Theme.accent : .clear, lineWidth: 2))
        .tint(Theme.accentText)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Teach correction…") { showTeachCorrection = true }
            Button("Show raw transcript") { showRaw = true }
            Button("Delete dictation…", role: .destructive) { confirmDelete = true }
        }
        .popover(isPresented: $showRaw, arrowEdge: .bottom) { rawPopover }
        .sheet(isPresented: $showDetail) { HistoryDetail(item: item) }
        .sheet(isPresented: $showTeachCorrection) { TeachCorrectionSheet(item: item) }
        .confirmationDialog("Delete this \(item.words)-word dictation?", isPresented: $confirmDelete) {
            Button("Delete dictation", role: .destructive) { History.remove(id: item.id) }
        }
    }
    /// Time, length and mode, then Copy and the row's menu.
    private var details: some View {
        let appSuffix: String = {
            guard let app = item.targetApp, !app.isEmpty else { return "" }
            return "  ·  \(InstalledApp.name(app))"
        }()
        return HStack(spacing: 8) {
            Text(item.date, format: .dateTime.hour().minute())
            Text("·  \(item.words) words  ·  \(Mode(rawValue: item.mode)?.label ?? item.mode.capitalized)\(appSuffix)")
            Spacer()
            CopyFeedbackButton(feedback: copyFeedback) { copy() }
            Menu {
                Button("Copy") { copy() }
                Button("Teach correction…") { showTeachCorrection = true }
                Button("Show raw transcript") { showRaw = true }
                Button("Details, rerun & export…") { showDetail = true }
                Button("Edit in Draft") { DictationWorkspace.shared.append(item.final); MainWindow.shared.show(.draft) }
                Button("Delete dictation…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Dictation actions")
        }.font(UIStyle.caption).foregroundStyle(Theme.muted)
    }
    private func copy() { copyFeedback.copy(item.final, using: copyTranscript) }
    private var rawPopover: some View {
        RawTranscriptReader(item: item, copyTranscript: copyTranscript) { showRaw = false }
    }
}

private struct TeachCorrectionSheet: View {
    let item: History.Item
    @Environment(\.dismiss) private var dismiss
    @State private var wrong = ""
    @State private var right = ""
    @State private var error = ""

    var body: some View {
        SheetFrame(
            title: "Teach spelling correction",
            width: 500
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dictation text").font(UIStyle.caption).foregroundStyle(Theme.muted)
                Text(item.final)
                    .font(Theme.writingFont)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            }
            TextField("Heard as (e.g. Wisper Flow)", text: $wrong)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("teachCorrectionWrong")
            TextField("Replace with (e.g. FlowClone)", text: $right)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("teachCorrectionRight")
            if !error.isEmpty {
                Feedback(text: error, kind: .error)
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save correction") {
                saveCorrection()
            }
            .prominent()
            .disabled(wrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            if item.words <= 4 {
                wrong = item.final.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func saveCorrection() {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try PersonalizationStore.shared.upsertCorrection(wrong: w, right: r)
            if !handsfreeSession {
                StatusMenu.shared.showLearnedCorrection("\(w) → \(r)")
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RawTranscriptReader: View {
    let item: History.Item
    var copyTranscript: (String) -> Bool = { Paster.writeTranscript($0) }
    let onClose: () -> Void
    @State private var copyFeedback = CopyFeedback()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Raw transcript").font(Theme.sectionFont)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Close raw transcript")
            }
            ScrollView {
                Text(item.raw).font(Theme.writingFont).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }.frame(maxHeight: 320)
            Hairline()
            HStack {
                Text("\(TranscriptionStats.wordCount(in: item.raw)) words · \(String(format: "%.1f", item.seconds))s · \(item.mode.capitalized)")
                    .font(UIStyle.caption).foregroundStyle(Theme.muted)
                Spacer()
                CopyFeedbackButton(feedback: copyFeedback, title: "Copy raw", subject: "raw transcript") {
                    copyFeedback.copy(item.raw, using: copyTranscript)
                }
            }
        }.padding(20).frame(width: 420).tint(Theme.accentText)
    }
}
