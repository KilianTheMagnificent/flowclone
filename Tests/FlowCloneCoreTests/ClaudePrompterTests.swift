import Foundation
import XCTest
@testable import FlowCloneCore

final class ClaudePrompterTests: XCTestCase {
    func testClaudeEligibilityLifts1800CharCapAndSkipsSlashCommands() {
        let longPrompt = String(repeating: "Please include the Q4 revenue breakdown and check the latency charts. ", count: 40)
        XCTAssertGreaterThan(longPrompt.count, 1800)
        XCTAssertFalse(Prompter.eligible(longPrompt))
        XCTAssertTrue(Prompter.claudeEligible(longPrompt))
        XCTAssertTrue(Prompter.eligible(longPrompt, apiKey: "sk-ant-test-key-00000000", allowCloud: true))
        XCTAssertFalse(Prompter.eligible(longPrompt, apiKey: "sk-ant-test-key-00000000", allowCloud: false))
        XCTAssertFalse(Prompter.claudeEligible("/compact"))

        let overLimit = String(repeating: "a", count: Prompter.claudeCharLimit + 1)
        XCTAssertFalse(Prompter.claudeEligible(overLimit))
    }

    func testClaudePlanSelectsHaikuForSimpleShortAndSonnetForLongOrCued() {
        let shortSimple = Prompter.claudePlan(for: "um can you make me a packing list for the weekend trip")
        XCTAssertEqual(shortSimple.model, AnthropicClient.fastModel)
        XCTAssertEqual(shortSimple.backend, .claudeHaiku)

        let cued = Prompter.claudePlan(for: "schedule the demo for Thursday actually make that Friday")
        XCTAssertEqual(cued.model, AnthropicClient.preferredModel)
        XCTAssertEqual(cued.backend, .claudeSonnet)

        let long = Prompter.claudePlan(for: String(repeating: "explain the architecture tradeoffs in detail ", count: 10))
        XCTAssertEqual(long.model, AnthropicClient.preferredModel)
        XCTAssertEqual(long.backend, .claudeSonnet)
        XCTAssertGreaterThan(long.maxTokens, 500)
    }

    func testClaudeSystemBlocksUse1hCacheAndExceedMinimumTokens() {
        XCTAssertGreaterThan(Prompter.claudeSystemPrompt.count, 2_200)
        let blocks = Prompter.claudeSystemBlocks(dictionaryTerms: ["FlowClone", "FluidAudio"])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].cacheTTL, "1h")
        XCTAssertEqual(blocks[1].cacheTTL, "1h")
    }

    func testClaudeRewriteSucceedsAndValidatesOutput() async {
        let input = "um so I need like an email to my landlord about getting the deposit back make it firm but polite"
        let expected = "Write a firm but polite email to my landlord asking for the return of my security deposit."
        let outcome = await Prompter.claudeRewrite(
            input,
            apiKey: "sk-ant-test-key-00000000",
            dictionaryTerms: ["FlowClone"],
            transport: { request, key in
                XCTAssertEqual(key, "sk-ant-test-key-00000000")
                XCTAssertEqual(request.model, AnthropicClient.fastModel)
                XCTAssertEqual(request.systemBlocks.count, 2)
                return AnthropicClient.Response(text: expected, reason: "ok", status: 200, data: nil)
            }
        )
        XCTAssertEqual(outcome.text, expected)
        XCTAssertEqual(outcome.backend, .claudeHaiku)
    }

    func testClaudeRewriteRejectsArtifactPreambleAndConstraintDrops() async {
        let input = "um draft an email to my landlord asking for my $1200 security deposit back, keep it firm but polite"

        let badReplies = [
            "Dear Landlord,\nPlease return my deposit.\nSincerely, Andre",
            "Here is your rewritten prompt: Write an email to my landlord.",
            "<transcript>Write an email to my landlord.</transcript>",
            "I'm sorry, I cannot assist with that request.",
            "Write an email to my landlord asking for my $500 security deposit back.",
        ]
        for bad in badReplies {
            let outcome = await Prompter.claudeRewrite(
                input,
                apiKey: "sk-ant-test-key-00000000",
                transport: { _, _ in
                    AnthropicClient.Response(text: bad, reason: "ok", status: 200, data: nil)
                }
            )
            XCTAssertNil(outcome.text, "Expected rejection for bad reply: \(bad)")
        }
    }

    func testPromptifyFallsBackCleanlyWhenCloudDisabledOrErrors() {
        let done1 = expectation(description: "no key fallback")
        Prompter.promptify(
            "can you summarize this report",
            allowCloud: false,
            apiKey: "sk-ant-test-key-00000000",
            allowOnDeviceFallback: false
        ) { outcome in
            XCTAssertNil(outcome.text)
            XCTAssertEqual(outcome.backend, .cleanFallback)
            done1.fulfill()
        }

        let done2 = expectation(description: "network error fallback")
        Prompter.promptify(
            "can you summarize this report",
            allowCloud: true,
            apiKey: "sk-ant-test-key-00000000",
            allowOnDeviceFallback: false,
            transport: { _, _ in
                AnthropicClient.Response(text: nil, reason: "network--1001", status: 0, data: nil)
            }
        ) { outcome in
            XCTAssertNil(outcome.text)
            XCTAssertEqual(outcome.backend, .cleanFallback)
            done2.fulfill()
        }

        wait(for: [done1, done2], timeout: 2)
    }
}
