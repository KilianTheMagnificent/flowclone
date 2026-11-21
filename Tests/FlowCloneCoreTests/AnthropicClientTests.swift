import Foundation
import XCTest
@testable import FlowCloneCore

final class AnthropicClientTests: XCTestCase {
    func testBuildRequestBodyIncludesCacheControlAndOmitsRemovedParameters() throws {
        let req = AnthropicMessageRequest(
            model: AnthropicClient.fastModel,
            systemBlocks: [
                AnthropicSystemBlock("Static cleanup instructions", cacheTTL: "1h"),
                AnthropicSystemBlock("Dictionary: FlowClone, FluidAudio", cacheTTL: "5m"),
            ],
            userMessage: "<transcript>\nHello world\n</transcript>",
            maxTokens: 512,
            effort: "low",
            timeout: 2.5,
            userAgent: "dictation-smart-cleanup/1"
        )
        let data = try AnthropicClient.buildRequestBody(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 512)
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "low")

        // Removed parameters on anthropic-version 2026-10-21 must never be emitted.
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["top_p"])
        XCTAssertNil(json["top_k"])

        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        XCTAssertEqual(system.count, 2)
        XCTAssertEqual(system[0]["type"] as? String, "text")
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertEqual((system[0]["cache_control"] as? [String: Any])?["ttl"] as? String, "1h")
        XCTAssertEqual((system[1]["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertNil((system[1]["cache_control"] as? [String: Any])?["ttl"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
    }

    func testURLRequestSetsRequiredHeadersAndTimeout() {
        let req = AnthropicMessageRequest(
            model: AnthropicClient.preferredModel,
            systemBlocks: [AnthropicSystemBlock("System text")],
            userMessage: "Hi",
            maxTokens: 256,
            effort: nil,
            timeout: 4.5,
            userAgent: "test-agent/1"
        )
        let urlReq = AnthropicClient.urlRequest(for: req, apiKey: "sk-ant-test-key-000000")
        XCTAssertEqual(urlReq.url, AnthropicClient.endpoint)
        XCTAssertEqual(urlReq.httpMethod, "POST")
        XCTAssertEqual(urlReq.timeoutInterval, 4.5)
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-key-000000")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(urlReq.value(forHTTPHeaderField: "user-agent"), "test-agent/1")
    }

    func testParseAnswerFiltersThinkingBlocksAndEnforcesStopReason() throws {
        let okPayload = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [
                ["type": "thinking", "thinking": "hidden"],
                ["type": "text", "text": "  Cleaned sentence.  "],
            ],
        ])
        let ok = AnthropicClient.parseAnswer(status: 200, data: okPayload)
        XCTAssertEqual(ok.text, "Cleaned sentence.")
        XCTAssertEqual(ok.reason, "ok")

        let truncatedPayload = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "max_tokens",
            "content": [["type": "text", "text": "Partial summary"]],
        ])
        let rejectTruncated = AnthropicClient.parseAnswer(status: 200, data: truncatedPayload, acceptMaxTokensStop: false)
        XCTAssertNil(rejectTruncated.text)
        XCTAssertEqual(rejectTruncated.reason, "max_tokens")

        let acceptTruncated = AnthropicClient.parseAnswer(status: 200, data: truncatedPayload, acceptMaxTokensStop: true)
        XCTAssertEqual(acceptTruncated.text, "Partial summary")
        XCTAssertEqual(acceptTruncated.reason, "max_tokens")

        let authErr = try JSONSerialization.data(withJSONObject: [
            "error": ["type": "authentication_error", "message": "invalid x-api-key"]
        ])
        let failed = AnthropicClient.parseAnswer(status: 401, data: authErr)
        XCTAssertNil(failed.text)
        XCTAssertEqual(failed.reason, "authentication_error-401")
    }

    func testParseUsageExtractsPromptCacheReadAndCreationTokens() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "Done."]],
            "usage": [
                "input_tokens": 42,
                "output_tokens": 11,
                "cache_creation_input_tokens": 600,
                "cache_read_input_tokens": 1240,
            ],
        ])
        let usage = try XCTUnwrap(AnthropicClient.parseUsage(data: payload))
        XCTAssertEqual(usage.inputTokens, 42)
        XCTAssertEqual(usage.outputTokens, 11)
        XCTAssertEqual(usage.cacheCreationInputTokens, 600)
        XCTAssertEqual(usage.cacheReadInputTokens, 1240)
    }

    func testPrewarmIsNoOpUnderTestHostAccessSuppression() {
        // Under xctest, `suppressHostAccess` is true, so prewarm must never fire network calls.
        XCTAssertFalse(AnthropicClient.prewarmIfConfigured(hasKey: true, force: true))
    }

    func testSendEnforcesHardWallClockTimeout() {
        final class HangingURLProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {}
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: config)
        let req = AnthropicMessageRequest(
            model: AnthropicClient.fastModel,
            systemBlocks: [AnthropicSystemBlock("sys")],
            userMessage: "hi",
            maxTokens: 64,
            timeout: 0.08,
            userAgent: "timeout-test/1"
        )
        let timedOut = expectation(description: "hard wall-clock timeout fires")
        AnthropicClient.send(req, apiKey: "sk-ant-test-key-000000", session: session) { response in
            XCTAssertNil(response.text)
            XCTAssertEqual(response.reason, "timeout")
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1.5)
    }
}
