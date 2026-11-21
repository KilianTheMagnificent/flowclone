import Cocoa

/// A receipt is issued only after the destination itself confirms the insertion. It is
/// memory-only, and expires on a later insertion or any observed document change.
@MainActor
final class LastInsertionController {
    static let shared = LastInsertionController()
    private struct Receipt: Sendable {
        let id: UUID
        let target: PasteTarget
        let insertion: PasteTarget.ConfirmedInsertion
        let text: String
        let snapshot: PasteTarget.LearningSnapshot
    }
    private var receipt: Receipt?
    private var generation = UUID()
    private var busy = false

    func record(id: UUID, target: PasteTarget, insertion: PasteTarget.ConfirmedInsertion, text: String) {
        generation = id; receipt = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = target.learningSnapshot(at: insertion)
            DispatchQueue.main.async {
                guard self.generation == id, let snapshot,
                      snapshot.text.hasPrefix(text) else { return }
                self.receipt = Receipt(id: id, target: target, insertion: insertion, text: text, snapshot: snapshot)
            }
        }
    }
    func invalidate() { generation = UUID(); receipt = nil }
    func edit() { use(undo: false) }
    func undo() { use(undo: true) }

    private func use(undo: Bool) {
        guard !busy, !DictationWorkspace.shared.recording, !DictationWorkspace.shared.processing else { return }
        guard let receipt else {
            notifyUser("No verified last dictation is available. Open History to copy or edit it.")
            return
        }
        guard !undo || receipt.insertion.replacedText != nil else {
            fallback(receipt, "The original selection was not readable, so Undo is unavailable.")
            return
        }
        busy = true
        AutoLearn.monitor.stop()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let now = receipt.target.learningSnapshot(at: receipt.insertion),
                  Self.matches(receipt.snapshot, now),
                  let selection = receipt.target.insertedTextTarget(receipt.insertion, text: receipt.text),
                  selection.select(receipt.insertion.range),
                  selection.revalidateSelection(expected: receipt.text, range: receipt.insertion.range),
                  let afterSelect = receipt.target.learningSnapshot(at: receipt.insertion),
                  Self.matches(receipt.snapshot, afterSelect) else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.fallback(receipt, "The app, field, or text changed. The dictation is available in Draft.")
                }
                return
            }
            if undo {
                let result = selection.replace(expected: receipt.text, at: receipt.insertion.range,
                                               with: receipt.insertion.replacedText!)
                DispatchQueue.main.async {
                    self.busy = false; self.invalidate()
                    switch result {
                    case .verified:
                        notifyUser("Last dictation undone.")
                    case .failed, .ambiguous:
                        self.fallback(receipt, "Undo could not be confirmed. Check the original app before changing it again.")
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.busy = false; self.invalidate()
                    TransformController.shared.beginCaptured(selection)
                }
            }
        }
    }
    nonisolated static func matches(_ before: PasteTarget.LearningSnapshot,
                                    _ after: PasteTarget.LearningSnapshot) -> Bool {
        before.characterCount == after.characterCount && before.prefix == after.prefix && before.text == after.text
    }
    private func fallback(_ receipt: Receipt, _ message: String) {
        invalidate()
        DictationWorkspace.shared.recover(receipt.text, id: receipt.id, state: .notInserted)
        DictationWorkspace.shared.status = message
        notifyUser(message)
    }
}
