import Cocoa
import SwiftUI

/// A row's button and menu actions share one result, so every Copy entry point gives the
/// same visible feedback. The writer's result decides success; a click alone never does.
@MainActor
@Observable
final class CopyFeedback {
    enum Result { case idle, copied, failed }
    private(set) var result: Result = .idle
    private(set) var attempt = 0

    func copy(_ text: String, using writer: (String) -> Bool = { Paster.writeTranscript($0) }) {
        attempt &+= 1
        result = writer(text) ? .copied : .failed
    }

    func clear() { result = .idle }
}

struct CopyFeedbackButton: View {
    let feedback: CopyFeedback
    var title = "Copy"
    var subject = "dictation"
    let action: () -> Void

    private var label: String {
        switch feedback.result {
        case .idle: title
        case .copied: "Copied"
        case .failed: "Copy failed"
        }
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: feedback.result == .copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(feedback.result == .copied ? FeedbackKind.success.color
                                 : feedback.result == .failed ? FeedbackKind.error.color : Theme.accentText)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(feedback.result == .idle ? "Copy \(subject)"
                            : feedback.result == .copied ? "Copied \(subject)" : "Copy failed. Try again")
        .help(feedback.result == .failed ? "Could not write to the clipboard. Click to try again."
              : feedback.result == .copied ? "Copied to the clipboard" : "Copy \(subject) to the clipboard")
        .task(id: feedback.attempt) {
            guard feedback.result == .copied else { return }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
            guard !Task.isCancelled else { return }
            feedback.clear()
        }
        .onDisappear { feedback.clear() }
    }
}
