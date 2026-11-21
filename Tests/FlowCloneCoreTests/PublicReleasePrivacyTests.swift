import os
import XCTest
@testable import FlowCloneCore

/// The choices that keep a stranger's words on their own Mac must hold on every path.
final class PublicReleasePrivacyTests: XCTestCase {
    func testBuiltInModelKeepsPromptModeDictationOffTheCloud() {
        XCTAssertTrue(Pipeline.promptCloudAllowed(hadContextRewrite: false, hasSnippets: false, setting: .auto))
        XCTAssertFalse(Pipeline.promptCloudAllowed(hadContextRewrite: false, hasSnippets: false, setting: .onDevice),
                       "Built-in model means no dictation is sent, in Prompt mode as well as Clean")
        // The Smart corrections switch is about the second look in Clean mode, not Prompt mode.
        XCTAssertTrue(Pipeline.promptCloudAllowed(hadContextRewrite: false, hasSnippets: false, setting: .off))
        for setting in RepairReviewer.Setting.allCases {
            XCTAssertFalse(Pipeline.promptCloudAllowed(hadContextRewrite: true, hasSnippets: false, setting: setting))
            XCTAssertFalse(Pipeline.promptCloudAllowed(hadContextRewrite: false, hasSnippets: true, setting: setting))
        }
    }

    func testBuiltInModelNeverSendsAPromptRewriteEvenWithAKeySaved() async {
        let allowCloud = Pipeline.promptCloudAllowed(hadContextRewrite: false, hasSnippets: false, setting: .onDevice)
        let asked = OSAllocatedUnfairLock(initialState: false)
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Prompter.RewriteOutcome, Never>) in
            _ = Prompter.promptify(
                "please draft a short note to the team about friday", allowCloud: allowCloud,
                apiKey: "sk-ant-test-key-01234567890123456789", allowOnDeviceFallback: false,
                transport: { _, _ in
                    asked.withLock { $0 = true }
                    return AnthropicClient.Response(text: "should never be asked", reason: "ok", status: 200, data: nil)
                },
                done: { continuation.resume(returning: $0) })
        }
        XCTAssertNil(outcome.text)
        XCTAssertFalse(asked.withLock { $0 }, "No request may be built for Anthropic")

        // The same call with the cloud allowed does ask, so the check above is not vacuous.
        let cloud = await withCheckedContinuation { (continuation: CheckedContinuation<Prompter.RewriteOutcome, Never>) in
            _ = Prompter.promptify(
                "please draft a short note to the team about friday", allowCloud: true,
                apiKey: "sk-ant-test-key-01234567890123456789", allowOnDeviceFallback: false,
                transport: { _, _ in
                    asked.withLock { $0 = true }
                    return AnthropicClient.Response(text: "Please draft a short note to the team about Friday.",
                                                    reason: "ok", status: 200, data: nil)
                },
                done: { continuation.resume(returning: $0) })
        }
        XCTAssertTrue(asked.withLock { $0 })
        XCTAssertNotNil(cloud.text)
    }
}
