// Typed spelling edits are monitored locally after a confirmed paste. Stable, conservative
// candidates are saved automatically when autoLearn is enabled, with inspectable rules and Undo.
import Cocoa
import Foundation

enum AutoLearn {
    struct PasteRecord {
        let target: PasteTarget
        let insertion: PasteTarget.ConfirmedInsertion
        let text: String
        let date: Date
        /// Context vocabulary is deliberately ephemeral. A user reversing one of those
        /// substitutions must never turn it into a permanent, app-global correction.
        let hadContextRewrite: Bool
        /// When a cloud/on-device model edited the pasted text, post-paste corrections route
        /// to manual suggestions rather than silently auto-saving global rules.
        let hadModelEdit: Bool

        init(
            target: PasteTarget,
            insertion: PasteTarget.ConfirmedInsertion,
            text: String,
            date: Date,
            hadContextRewrite: Bool,
            hadModelEdit: Bool = false
        ) {
            self.target = target
            self.insertion = insertion
            self.text = text
            self.date = date
            self.hadContextRewrite = hadContextRewrite
            self.hadModelEdit = hadModelEdit
        }
    }

    private final class UndoState: @unchecked Sendable {
        private let lock = NSLock()
        private var token: PersonalizationUndoToken?

        var available: Bool {
            lock.lock()
            defer { lock.unlock() }
            return token != nil
        }

        func remember(_ newToken: PersonalizationUndoToken) {
            lock.lock()
            token = newToken
            lock.unlock()
        }

        /// Keep the token stable while undo validates and restores its fingerprint. This
        /// prevents a concurrently remembered, newer batch from being cleared by an older
        /// undo attempt.
        func undo() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            guard let token else { return nil }
            do {
                try PersonalizationStore.shared.undo(token)
                self.token = nil
                return .success(())
            } catch {
                self.token = nil
                return .failure(error)
            }
        }
    }

    private static let undoState = UndoState()
    static let suggestions = CorrectionSuggestions(
        storageURL: PersonalizationStore.shared.root.appendingPathComponent("pending-suggestions.json")
    )
    static let monitor = TypedCorrectionMonitor()
    static let didChange = Notification.Name("FlowCloneLearnedCorrectionsChanged")
    static var enabled: Bool { UserDefaults.standard.object(forKey: "autoLearn") as? Bool ?? true }

    /// Resolves the active spell-checker language dynamically instead of hardcoding `"en_US"`.
    static func activeSpellcheckLanguage(checker: NSSpellChecker = .shared) -> String {
        let current = checker.language().trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        return Locale.preferredLanguages.first ?? "en"
    }

    @discardableResult
    static func approveSuggestion(
        _ id: UUID,
        suggestions queue: CorrectionSuggestions = AutoLearn.suggestions,
        store: PersonalizationStore = .shared
    ) throws -> PersonalizationUndoToken? {
        guard let candidate = queue.remove(id) else { return nil }
        let upsert = try store.upsertCorrection(wrong: candidate.wrong, right: candidate.right)
        let undoToken = upsert.undoToken

        // Also seed the canonical right-hand spelling into dictionary.txt when it is a
        // valid dictionary term (up to 6 words, no `->`), without failing if it already exists.
        let dictDraft = PersonalizationDraft(kind: .dictionary, primary: candidate.right, replacement: nil)
        if let validDict = try? PersonalizationStore.validated(dictDraft),
           let dictSnapshot = try? store.snapshot(.dictionary) {
            _ = try? store.add(validDict, expected: dictSnapshot.fingerprint)
        }

        if let undoToken {
            rememberUndo(undoToken)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        return undoToken
    }

    @discardableResult
    static func dismissSuggestion(
        _ id: UUID,
        suggestions queue: CorrectionSuggestions = AutoLearn.suggestions
    ) -> Bool {
        queue.remove(id) != nil
    }

    @MainActor
    static func reviewSuggestion() {
        guard let candidate = suggestions.current().first else { return }
        let alert = suggestionAlert(candidate)
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        if response == .alertSecondButtonReturn {
            _ = dismissSuggestion(candidate.id)
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        do {
            guard try approveSuggestion(candidate.id) != nil else { return }
            StatusMenu.shared.showLearnedCorrection("\(candidate.wrong) → \(candidate.right)")
        } catch {
            notifyUser("Could not save that correction. Try adding it in Dictionary → Corrections.")
        }
    }

    @MainActor
    static func suggestionAlert(_ candidate: CorrectionSuggestions.Item) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Add correction?"
        alert.informativeText = "Suggested from an edit in \(candidate.app). This replacement applies to future dictations in every app."
        let before = NSTextField(wrappingLabelWithString: "Heard as: \(candidate.wrong)")
        let after = NSTextField(wrappingLabelWithString: "Replace with: \(candidate.right)")
        before.font = .systemFont(ofSize: 14); after.font = .systemFont(ofSize: 14, weight: .medium)
        let comparison = NSStackView(views: [before, after])
        comparison.orientation = .vertical; comparison.alignment = .leading; comparison.spacing = 12
        comparison.frame = NSRect(x: 0, y: 0, width: 380, height: 80)
        alert.accessoryView = comparison
        alert.addButton(withTitle: "Add correction")
        alert.addButton(withTitle: "Dismiss suggestion")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static var undoAvailable: Bool {
        undoState.available
    }

    static func rememberUndo(_ token: PersonalizationUndoToken) {
        undoState.remember(token)
    }

    /// Session queue. The store refuses to overwrite a file changed since the batch, so
    /// this can never erase a later manual Personalization edit.
    static func undoLastLearnedBatch() -> Bool {
        guard let result = undoState.undo() else { return false }
        switch result {
        case .success:
            log("auto-learn: last correction batch undone")
            return true
        case .failure:
            log("auto-learn undo refused: personalization file changed")
            return false
        }
    }

    /// PLAN-PROMPT D9: may a paste be recorded for the post-paste typed-over-fix
    /// diff? Only a live utterance qualifies (a repaste or a self-test is not one), and
    /// never in Prompt mode: that diff assumes a word-preserving paste, and edits to a
    /// GENERATED prompt would file junk corrections (the 2026-08-04 class of bug). Pure and
    /// static precisely so `--prompttest` can pin its truth table without a paste harness.
    static func shouldRecord(origin: DictationOrigin, mode: Mode) -> Bool {
        origin.recordsAutoLearn && mode != .prompt
    }

    static func mayLearn(hadContextRewrite: Bool) -> Bool { !hadContextRewrite }

    /// Exact user-facing provenance for a successfully persisted batch. Kept pure so tests
    /// can pin the wording independently of Accessibility and Notification Center.
    static func correctionSummary(
        _ pairs: [(wrong: String, right: String)]
    ) -> String {
        pairs.map { "\($0.wrong) → \($0.right)" }.joined(separator: ", ")
    }

    struct SavedBatch {
        let pairs: [(wrong: String, right: String)]
        let undo: PersonalizationUndoToken
    }

    /// Atomic, non-overwriting persistence shared by the live path and isolated tests.
    /// Invalid or conflicting batches fail closed; exact existing rules are skipped.
    static func saveCorrections(_ pairs: [(wrong: String, right: String)],
                                store: PersonalizationStore) throws -> SavedBatch? {
        guard let unique = unambiguousCorrections(pairs), !unique.isEmpty else { return nil }
        for pair in unique {
            _ = try PersonalizationStore.validated(PersonalizationDraft(
                kind: .correction, primary: pair.wrong, replacement: pair.right))
        }
        let data = Data(unique.map { "\($0.wrong) -> \($0.right)\n" }.joined().utf8)
        let preview = try store.previewImport(data, kind: .correction)
        guard preview.invalidCount == 0, preview.conflictCount == 0, preview.addedCount > 0 else { return nil }
        let fresh = preview.rows.filter { $0.outcome == .addition }.compactMap { row -> (String, String)? in
            guard let right = row.draft.replacement else { return nil }
            return (row.draft.primary, right)
        }
        return SavedBatch(pairs: fresh, undo: try store.apply(preview, replaceConflicts: false))
    }

    /// True when a token has code-identifier shape (digits, symbols/underscores, ALL-CAPS
    /// acronym, or internal camelCase) and should never be single-edit auto-saved via
    /// `NSSpellChecker`.
    static func looksCodeLike(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: { $0.isNumber || "_-./:@$#<>`".contains($0) }) {
            return true
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        for word in words {
            if word.count >= 2 && word.allSatisfy(\.isUppercase) {
                return true
            }
            if word.dropFirst().contains(where: \.isUppercase) {
                return true
            }
        }
        return false
    }

    /// Casing/diacritics with identical word boundaries ("Andre" -> "André", "flowclone" -> "FlowClone")
    /// and explicit multi-word -> PascalCase/camelCase identifier joins ("open code" -> "OpenCode")
    /// are unambiguous. Space-modulo compound/phrasal pairs ("checkout" <-> "check out",
    /// "login" <-> "log in", "setup" <-> "set up"), coding-app edits, and code-like tokens
    /// never silently auto-save on a single edit — they route to `CorrectionSuggestions`.
    static func isAutomaticSpelling(
        _ wrong: String,
        _ right: String,
        bundleID: String? = nil,
        isKnownWord: (String) -> Bool
    ) -> Bool {
        if AppProfiles.isCodingOrAgentApp(bundleID) {
            return false
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let foldedWrongWithSpaces = wrong
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let foldedRightWithSpaces = right
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)

        if foldedWrongWithSpaces == foldedRightWithSpaces {
            return true
        }

        let spacelessWrong = wrong.filter { !$0.isWhitespace }
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let spacelessRight = right.filter { !$0.isWhitespace }
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)

        if spacelessWrong == spacelessRight {
            // Only an explicit multi-word -> mixedCase/PascalCase product join ("open code" -> "OpenCode")
            // is unambiguous; ordinary English compounds ("checkout" <-> "check out",
            // "login" <-> "log in", "setup" <-> "set up") require confirmation.
            let isCompoundIdentifierJoin = wrong.contains(where: \.isWhitespace)
                && !right.contains(where: \.isWhitespace)
                && right.dropFirst().contains(where: \.isUppercase)
            return isCompoundIdentifierJoin
        }

        if looksCodeLike(wrong) || looksCodeLike(right) {
            return false
        }

        let wrongWords = wrong.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !wrongWords.isEmpty else { return false }
        return wrongWords.contains { !isKnownWord($0) }
    }

    @MainActor
    @discardableResult
    static func learn(
        _ pairs: [(wrong: String, right: String)],
        app: String,
        bundleID: String? = nil,
        store: PersonalizationStore = .shared,
        suggestions suggestionQueue: CorrectionSuggestions = AutoLearn.suggestions,
        report: Bool = true,
        allowAutomaticSave: Bool = true
    ) -> SavedBatch? {
        guard enabled, let unique = unambiguousCorrections(pairs),
              let existing = try? store.snapshot(.correction) else { return nil }
        let fresh = unique.filter { pair in
            !existing.entries.contains { $0.primary.lowercased() == pair.wrong.lowercased() }
        }
        let effectiveBundleID = bundleID ?? (AppProfiles.isCodingOrAgentApp(app) ? app : nil)
        let checker = NSSpellChecker.shared
        let language = activeSpellcheckLanguage(checker: checker)
        let automatic = allowAutomaticSave ? fresh.filter { pair in
            isAutomaticSpelling(pair.wrong, pair.right, bundleID: effectiveBundleID) { word in
                if checker.automaticallyIdentifiesLanguages {
                    return checker.checkSpelling(
                        of: word,
                        startingAt: 0,
                        language: nil,
                        wrap: false,
                        inSpellDocumentWithTag: 0,
                        wordCount: nil
                    ).location == NSNotFound
                }
                return checker.checkSpelling(
                    of: word,
                    startingAt: 0,
                    language: language,
                    wrap: false,
                    inSpellDocumentWithTag: 0,
                    wordCount: nil
                ).location == NSNotFound
            }
        } : []
        let review = fresh.filter { pair in !automatic.contains { $0.wrong == pair.wrong } }
        for pair in review { suggestionQueue.propose(wrong: pair.wrong, right: pair.right, app: app) }
        do {
            guard let saved = try saveCorrections(automatic, store: store) else {
                if report, !review.isEmpty { notifyUser("Spelling suggestion available. Open Dictionary to review it.") }
                return nil
            }
            guard report else { return saved }
            rememberUndo(saved.undo)
            StatusMenu.shared.showLearnedCorrection(correctionSummary(saved.pairs))
            NotificationCenter.default.post(name: didChange, object: nil)
            log("auto-learn: saved \(saved.pairs.count) spelling correction(s)")
            notifyUser("Spelling correction learned. Review it in Dictionary → Corrections, or undo it in the FlowClone menu.")
            return saved
        } catch {
            log("auto-learn: save failed; existing corrections preserved")
            if report { notifyUser("Could not save a spelling correction. Try adding it in Dictionary → Corrections.") }
            return nil
        }
    }

    // MARK: - Diff

    /// Word cores only (letters/numbers, case preserved) — the parts() split from Cleaner
    /// without the punctuation bookkeeping, which nothing here needs.
    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Conservative aligned word replacements. Appended prose is ignored; deleted or
    /// reordered words and grammar edits are rejected. Bound token sizes before distance
    /// calculations so a pathological field cannot monopolize the monitor queue.
    static func findCorrections(pasted: String, field: String) -> [(wrong: String, right: String)] {
        guard pasted.utf16.count <= 3_000, field.utf16.count <= 4_096 else { return [] }
        let pastedWords = words(pasted), fieldWords = words(field)
        guard (3...256).contains(pastedWords.count), !fieldWords.isEmpty else { return [] }
        var out: [(wrong: String, right: String)] = []
        var unchanged = 0
        var i = 0, j = 0
        while i < pastedWords.count {
            guard j < fieldWords.count else { return [] }
            let w = pastedWords[i], candidate = fieldWords[j]
            if w == candidate { unchanged += 1; i += 1; j += 1; continue }
            // Name/product word boundaries (open code→OpenCode) are safe only when the
            // concatenated spelling is identical. Never align arbitrary missing words.
            var joined = false
            for count in 2...3 {
                if i + count <= pastedWords.count {
                    let span = Array(pastedWords[i..<(i + count)])
                    let wrong = span.joined(separator: " ")
                    if span.allSatisfy({ (2...60).contains($0.count) }), (4...60).contains(candidate.count),
                       span.joined().lowercased() == candidate.lowercased(), pasted.contains(wrong) {
                        out.append((wrong, candidate)); i += count; j += 1; joined = true; break
                    }
                }
                if j + count <= fieldWords.count {
                    let span = Array(fieldWords[j..<(j + count)])
                    let right = span.joined(separator: " ")
                    if span.allSatisfy({ (2...60).contains($0.count) }), (4...60).contains(w.count),
                       span.joined().lowercased() == w.lowercased(), field.contains(right) {
                        out.append((w, right)); i += 1; j += count; joined = true; break
                    }
                }
            }
            if joined { continue }
            guard (3...60).contains(w.count), (3...60).contains(candidate.count) else { return [] }
            let lw = w.lowercased(), lc = candidate.lowercased()
            let distance = Double(Cleaner.distance(lw, lc)) / Double(max(lw.count, lc.count))
            let sameInitial = candidate.first?.lowercased() == w.first?.lowercased()
            guard distance <= (sameInitial ? 0.4 : 0.25), !isSuffixEdit(w, candidate) else { return [] }
            out.append((w, candidate)); i += 1; j += 1
        }
        // A high unchanged overlap and a small edit count distinguish a corrected paste
        // from a rewrite. Keep the historical two-common-word floor for short utterances.
        guard unchanged >= 2,
              Double(unchanged) / Double(pastedWords.count) >= 0.5,
              (1...3).contains(out.count) else { return [] }
        return out
    }

    /// A global correction has one case-insensitive heard form. Repeated occurrences with
    /// the same edited value collapse to one rule; two different edited values make the
    /// entire batch ambiguous and therefore unlearnable.
    static func unambiguousCorrections(
        _ pairs: [(wrong: String, right: String)]
    ) -> [(wrong: String, right: String)]? {
        var ordered: [(wrong: String, right: String)] = []
        var rightByWrong: [String: String] = [:]
        for pair in pairs {
            let wrongKey = pair.wrong.precomposedStringWithCanonicalMapping.lowercased()
            let right = pair.right.precomposedStringWithCanonicalMapping
            if let existing = rightByWrong[wrongKey] {
                guard existing == right else { return nil }
                continue
            }
            rightByWrong[wrongKey] = right
            ordered.append((pair.wrong, pair.right))
        }
        return ordered
    }

    /// redteam M5: true when the two words differ only by a trailing 1–2 chars (one is the
    /// other plus a suffix), i.e. an inflection rather than a spelling/casing correction.
    private static func isSuffixEdit(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        let (long, short) = la.count >= lb.count ? (la, lb) : (lb, la)
        return (1...2).contains(long.count - short.count) && long.hasPrefix(short)
    }
}
