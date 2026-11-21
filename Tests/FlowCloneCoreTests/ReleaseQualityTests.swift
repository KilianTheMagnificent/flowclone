import XCTest
@testable import FlowCloneCore

final class ReleaseQualityTests: XCTestCase {
    func testMeaningChangesFallBackInBothModes() {
        let cases = [
            ("Do not send the contract to Alice before Friday.", "Send the contract to Alice before Friday."),
            ("Send Alice 15 dollars on Friday.", "Send Alice 50 dollars on Friday."),
            ("Send the contract to Alice and the finance team on Friday. Include the revised budget and ask Bob to approve the figures.", "Send the contract to Alice and the finance team on Friday."),
            ("Do not deploy the patch. Email the team.", "Deploy the patch. Do not email the team."),
            ("Send the contract to Alice tomorrow.", "Send the contract to Sarah tomorrow.")
        ]
        for (input, output) in cases {
            XCTAssertNotNil(Polisher.reject(output, input), input)
            XCTAssertNotNil(Prompter.reject(output, input), input)
        }
    }

    func testFaithfulRewritesAndExplicitNumericRepairSurvive() {
        let cases = [
            ("Do not send the contract to Alice before Friday.", "Don't send the contract to Alice before Friday."),
            ("Let's do coffee at 2 p.m. actually make that 3 p.m.", "Let's do coffee at 3 p.m."),
            ("So um I was thinking we could we could maybe try the new approach.", "I was thinking we could maybe try the new approach."),
            ("Send the complete contract to Alice on Friday.", "Send the complete contract to Alice on Friday.")
        ]
        for (input, output) in cases { XCTAssertNil(Polisher.reject(output, input), input) }
        XCTAssertFalse(Polisher.eligible(String(repeating: "a", count: 1801)))
        XCTAssertNil(Prompter.reject("Summarize the report in 5 bullet points.", "Summarize the report in five bullet points."))
        XCTAssertNil(Prompter.reject("Use the existing parser rather than writing a new one.", "Use the existing parser rather than writing a new one."))
        XCTAssertNil(Prompter.reject(
            "Write a firm but polite email to my landlord asking for the return of my security deposit.",
            "um so I need like an email to my landlord about getting the deposit back make it firm but you know polite"))
        XCTAssertNil(Prompter.reject(
            "Include the summary at the top if possible, preserve the numbers, and ensure they are included.",
            "put the summary at the top if you can, no big deal either way, but the numbers definitely need to be in there"))
    }

    func testAppliedSpokenCorrectionsSurviveTheValidator() {
        let cases = [
            ("Send the contract to Alice, I mean Sarah, by Friday.", "Send the contract to Sarah by Friday."),
            ("Let's meet on Thursday, I mean Friday.", "Let's meet on Friday."),
            ("Can we do the call at 2 p.m., I mean at 3 p.m.?", "Can we do the call at 3 p.m.?"),
            ("Use the blue theme for the dashboard. Scratch that, keep the grey theme for the dashboard.", "Use the grey theme for the dashboard."),
            ("Use the blue theme for the dashboard. Scratch that, keep the grey theme for the dashboard.", "Keep the grey theme for the dashboard."),
            ("Add a retry button, no wait, a cancel button next to the field.", "Add a cancel button next to the field."),
            ("Move the meeting to Monday. Never mind, leave it on Wednesday.", "Move the meeting to Wednesday."),
            ("Tell Mark the build is green and we can ship on Thursday, I mean Friday, after the review, and ask him to update the changelog before then.",
             "Tell Mark the build is green and we can ship on Friday after the review, and ask him to update the changelog before then."),
            ("Also improve the copy button, it doesn't actually tell you if you've copied anything.", "Also improve the copy button, it doesn't tell you if you've copied anything."),
            ("Tell the team the deploy is done. I mean, the whole thing went smoothly.", "Tell the team the deploy is done. The whole thing went smoothly.")
        ]
        for (input, output) in cases { XCTAssertNil(Polisher.reject(output, input), input) }
    }

    func testCorrectionCueDoesNotLicenseUnrelatedLoss() {
        let cases = [
            ("Actually, send the contract to Alice and cc Mark and Priya on Thursday.", "Send the contract on Thursday."),
            ("Use the blue theme. Scratch that, keep the grey theme and also email Mark the invoice number 4471 today.", "Keep the grey theme."),
            ("It doesn't actually tell you if you've copied anything.", "It tells you if you've copied anything.")
        ]
        for (input, output) in cases { XCTAssertNotNil(Polisher.reject(output, input), input) }
    }

    func testShortWordPassesButSilenceAndClickDoNot() {
        let speech = (0..<2400).map { Float(sin(Double($0) * 0.15)) * 0.02 }
        XCTAssertTrue(SpeechGate.containsSpeech(speech))
        XCTAssertFalse(SpeechGate.containsSpeech(Array(repeating: 0, count: 2400)))
        var click = Array(repeating: Float(0), count: 2400)
        click.replaceSubrange(800..<1120, with: Array(repeating: Float(0.2), count: 320))
        XCTAssertFalse(SpeechGate.containsSpeech(click))
    }

    func testSuggestionsAreProvisionalBoundedAndExpire() {
        let pending = CorrectionSuggestions()
        let now = Date(timeIntervalSince1970: 1000)
        pending.propose(wrong: "send", right: "spend", app: "test", now: now)
        let first = pending.current(now: now).first!
        XCTAssertEqual(first.wrong, "send")
        pending.propose(wrong: "send", right: "sent", app: "test", now: now)
        XCTAssertNil(pending.remove(first.id), "a stale approval cannot accept superseded evidence")
        XCTAssertEqual(pending.current(now: now).count, 1)
        for i in 0..<30 { pending.propose(wrong: "word\(i)", right: "fixed", app: "test", now: now) }
        XCTAssertEqual(pending.current(now: now).count, 20)
        XCTAssertTrue(pending.current(now: now.addingTimeInterval(601)).isEmpty)
    }
}

@MainActor
final class DecodeSchedulerTests: XCTestCase {
    private func waitForQueue(_ scheduler: DecodeScheduler, count: Int) async {
        for _ in 0..<1000 {
            if await scheduler.queuedCount == count { return }
            await Task.yield()
        }
        XCTFail("scheduler did not reach expected queue size")
    }

    func testFinalDisplacesQueuedSpeculationWithoutOverlappingActiveDecode() async {
        let scheduler = DecodeScheduler()
        let acquired = await scheduler.acquire(.preview)
        XCTAssertTrue(acquired)
        let speculation = Task { await scheduler.acquire(.speculation) }
        await waitForQueue(scheduler, count: 1)
        let final = Task { await scheduler.acquire(.final) }
        let displaced = await speculation.value
        XCTAssertFalse(displaced)
        await waitForQueue(scheduler, count: 1)
        let background = await scheduler.acquire(.speculation)
        XCTAssertFalse(background)
        await scheduler.release()
        let granted = await final.value
        XCTAssertTrue(granted)
        await scheduler.release()
    }

    func testCancelledWaiterDoesNotLeakPermit() async {
        let scheduler = DecodeScheduler()
        _ = await scheduler.acquire(.final)
        let queued = Task { await scheduler.acquire(.speculation) }
        await waitForQueue(scheduler, count: 1)
        queued.cancel()
        let granted = await queued.value
        XCTAssertFalse(granted)
        await scheduler.release()
        let next = await scheduler.acquire(.final)
        XCTAssertTrue(next)
        await scheduler.release()
    }

    func testPreviewSkipsBusyDecoderAndNeverQueuesBehindSpeculation() async {
        let scheduler = DecodeScheduler()
        _ = await scheduler.acquire(.speculation)
        let skipped = await scheduler.acquire(.preview)
        let queued = await scheduler.queuedCount
        XCTAssertFalse(skipped)
        XCTAssertEqual(queued, 0)
        await scheduler.release()
        let final = await scheduler.acquire(.final)
        XCTAssertTrue(final, "No deferred preview may start ahead of key-up ASR")
        let skippedDuringFinal = await scheduler.acquire(.preview)
        XCTAssertFalse(skippedDuringFinal)
        await scheduler.release()
        let fresh = await scheduler.acquire(.preview)
        XCTAssertTrue(fresh, "Preview resumes when the decoder becomes idle")
        await scheduler.release()
    }
}
