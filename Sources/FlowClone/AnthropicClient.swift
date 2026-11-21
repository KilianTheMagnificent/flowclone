// Shared Anthropic Messages API client for FlowClone (dictation Smart Cleanup, Prompt mode,
// and Meeting Notes). Uses direct URLSession over HTTP/2 with connection pooling, hotkey-down
// pre-warming, and 1-hour prompt caching — zero external SDK dependencies.
import Foundation

struct AnthropicSystemBlock: Sendable, Equatable {
    let text: String
    /// Optional Anthropic prompt-cache TTL (`"1h"` or `"5m"`). `nil` disables caching on this block.
    let cacheTTL: String?

    init(_ text: String, cacheTTL: String? = nil) {
        self.text = text
        self.cacheTTL = cacheTTL
    }
}

struct AnthropicMessageRequest: Sendable, Equatable {
    let model: String
    let systemBlocks: [AnthropicSystemBlock]
    let userMessage: String
    let maxTokens: Int
    let effort: String?
    let timeout: TimeInterval
    let userAgent: String
    let acceptMaxTokensStop: Bool

    init(
        model: String,
        systemBlocks: [AnthropicSystemBlock],
        userMessage: String,
        maxTokens: Int,
        effort: String? = "low",
        timeout: TimeInterval,
        userAgent: String,
        acceptMaxTokensStop: Bool = false
    ) {
        self.model = model
        self.systemBlocks = systemBlocks
        self.userMessage = userMessage
        self.maxTokens = maxTokens
        self.effort = effort
        self.timeout = timeout
        self.userAgent = userAgent
        self.acceptMaxTokensStop = acceptMaxTokensStop
    }
}

enum AnthropicClient {
    static let apiVersion = "2026-10-21"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let prewarmEndpoint = URL(string: "https://api.anthropic.com/")!
    static let preferredModel = "claude-sonnet-5-5"
    static let fastModel = "claude-haiku-5-5"

    struct Usage: Sendable, Equatable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationInputTokens: Int
        let cacheReadInputTokens: Int
    }

    struct Response: Sendable {
        let text: String?
        let reason: String
        let status: Int
        let data: Data?
        let usage: Usage?

        init(text: String?, reason: String, status: Int, data: Data?, usage: Usage? = nil) {
            self.text = text
            self.reason = reason
            self.status = status
            self.data = data
            self.usage = usage
        }
    }

    /// Persistent HTTP/2 connection pool shared across dictation, Prompt mode, and meetings.
    /// Ephemeral configuration keeps cookies and disk caches disabled while preserving live TLS sockets.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    private final class PrewarmThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var lastAttempt: DispatchTime?
        let minIntervalSeconds: Double = 30

        func shouldPrewarm(now: DispatchTime = .now()) -> Bool {
            lock.withLock {
                if let lastAttempt {
                    let elapsed = Double(now.uptimeNanoseconds &- lastAttempt.uptimeNanoseconds) / 1e9
                    if elapsed < minIntervalSeconds { return false }
                }
                lastAttempt = now
                return true
            }
        }

        func resetForTest() {
            lock.withLock { lastAttempt = nil }
        }
    }

    private static let prewarmThrottle = PrewarmThrottle()

    /// Asynchronously warms the TCP/TLS/HTTP2 socket to `api.anthropic.com` while the user speaks
    /// (on hotkey-down), trimming cold-handshake latency off the post-release critical path.
    /// Safe no-op under tests (`suppressHostAccess`), when no key is saved, or within 30s of the last warm.
    @discardableResult
    static func prewarmIfConfigured(
        hasKey: Bool? = nil,
        session: URLSession = sharedSession,
        force: Bool = false
    ) -> Bool {
        guard !suppressHostAccess else { return false }
        let keyAvailable = hasKey ?? (ClaudeKey.current != nil)
        guard keyAvailable else { return false }
        guard force || prewarmThrottle.shouldPrewarm() else { return false }
        var req = URLRequest(url: prewarmEndpoint, timeoutInterval: 3.0)
        req.httpMethod = "HEAD"
        req.setValue("dictation-prewarm/1", forHTTPHeaderField: "user-agent")
        let task = session.dataTask(with: req) { _, _, _ in }
        task.resume()
        return true
    }

    #if DEBUG
    static func resetPrewarmThrottleForTest() {
        prewarmThrottle.resetForTest()
    }
    #endif

    /// Builds the JSON payload for `POST /v1/messages` (`anthropic-version: 2026-10-21`).
    /// Never emits removed fields (`temperature`, `top_p`, `top_k`, or assistant prefill).
    static func buildRequestBody(_ request: AnthropicMessageRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "messages": [["role": "user", "content": request.userMessage]],
        ]
        if let effort = request.effort, !effort.isEmpty {
            body["output_config"] = ["effort": effort]
        }
        let nonEmptyBlocks = request.systemBlocks.filter { !$0.text.isEmpty }
        if !nonEmptyBlocks.isEmpty {
            if nonEmptyBlocks.count == 1, nonEmptyBlocks[0].cacheTTL == nil {
                body["system"] = nonEmptyBlocks[0].text
            } else {
                body["system"] = nonEmptyBlocks.map { block -> [String: Any] in
                    var dict: [String: Any] = [
                        "type": "text",
                        "text": block.text,
                    ]
                    if let ttl = block.cacheTTL, !ttl.isEmpty {
                        if ttl == "5m" {
                            dict["cache_control"] = ["type": "ephemeral"]
                        } else {
                            dict["cache_control"] = ["type": "ephemeral", "ttl": ttl]
                        }
                    }
                    return dict
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func urlRequest(for request: AnthropicMessageRequest, apiKey: String) -> URLRequest {
        var urlReq = URLRequest(url: endpoint, timeoutInterval: request.timeout)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "content-type")
        urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlReq.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlReq.setValue(request.userAgent, forHTTPHeaderField: "user-agent")
        urlReq.httpBody = try? buildRequestBody(request)
        return urlReq
    }

    /// Extracts token usage (including prompt-cache reads/writes) from an Anthropic response payload.
    static func parseUsage(from object: [String: Any]) -> Usage? {
        guard let usage = object["usage"] as? [String: Any] else { return nil }
        return Usage(
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheCreationInputTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
            cacheReadInputTokens: usage["cache_read_input_tokens"] as? Int ?? 0
        )
    }

    static func parseUsage(data: Data) -> Usage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseUsage(from: object)
    }

    /// Extracts visible text blocks (skipping thinking blocks) and returns a log-safe reason.
    static func parseAnswer(
        status: Int,
        data: Data,
        acceptMaxTokensStop: Bool = false
    ) -> (text: String?, reason: String) {
        let parsed = parseResponse(status: status, data: data, acceptMaxTokensStop: acceptMaxTokensStop)
        return (parsed.text, parsed.reason)
    }

    private static func parseResponse(
        status: Int,
        data: Data,
        acceptMaxTokensStop: Bool
    ) -> (text: String?, reason: String, usage: Usage?) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let usage = object.flatMap(parseUsage(from:))
        guard status == 200, let object else {
            let kind = ((object?["error"] as? [String: Any])?["type"] as? String) ?? "http"
            return (nil, "\(kind)-\(status)", usage)
        }
        let stopReason = object["stop_reason"] as? String
        let stopOK = stopReason == "end_turn" || (acceptMaxTokensStop && stopReason == "max_tokens")
        guard stopOK else {
            return (nil, stopReason ?? "no-stop-reason", usage)
        }
        let text = ((object["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "empty", usage) }
        let okReason = stopReason == "max_tokens" ? "max_tokens" : "ok"
        return (text, okReason, usage)
    }

    /// Callback-based request returning an immediate cancellation closure (for concurrent model racing).
    /// Enforces a hard wall-clock deadline (`request.timeout`) in addition to URLRequest idle timeout
    /// so trickling connections can never stall dictation past its budget.
    @discardableResult
    static func send(
        _ request: AnthropicMessageRequest,
        apiKey: String,
        session: URLSession = sharedSession,
        done: @escaping @Sendable (Response) -> Void
    ) -> (@Sendable () -> Void) {
        final class DeliveryGate: @unchecked Sendable {
            private let lock = NSLock()
            private var settled = false
            private var timer: DispatchWorkItem?
            func setTimer(_ item: DispatchWorkItem) {
                lock.withLock {
                    if settled { item.cancel() } else { timer = item }
                }
            }
            func finish(_ block: () -> Void) {
                let shouldRun = lock.withLock { () -> Bool in
                    guard !settled else { return false }
                    settled = true
                    timer?.cancel()
                    timer = nil
                    return true
                }
                if shouldRun { block() }
            }
            func cancelTimerOnly() {
                lock.withLock {
                    timer?.cancel()
                    timer = nil
                }
            }
        }

        let gate = DeliveryGate()
        let urlReq = urlRequest(for: request, apiKey: apiKey)
        let acceptMaxTokens = request.acceptMaxTokensStop
        let modelName = request.model
        let userAgent = request.userAgent
        let task = session.dataTask(with: urlReq) { data, response, error in
            gate.finish {
                guard let data, let http = response as? HTTPURLResponse else {
                    let why = (error as? URLError).map { "network-\($0.code.rawValue)" } ?? "network"
                    done(Response(text: nil, reason: why, status: 0, data: nil, usage: nil))
                    return
                }
                let parsed = parseResponse(status: http.statusCode, data: data, acceptMaxTokensStop: acceptMaxTokens)
                if let usage = parsed.usage {
                    log("anthropic: model=\(modelName) agent=\(userAgent) in=\(usage.inputTokens) out=\(usage.outputTokens) cache_read=\(usage.cacheReadInputTokens) cache_create=\(usage.cacheCreationInputTokens)")
                }
                done(Response(text: parsed.text, reason: parsed.reason, status: http.statusCode, data: data, usage: parsed.usage))
            }
        }
        if request.timeout > 0 {
            let deadline = DispatchWorkItem {
                task.cancel()
                gate.finish {
                    done(Response(text: nil, reason: "timeout", status: 0, data: nil))
                }
            }
            gate.setTimer(deadline)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + request.timeout, execute: deadline)
        }
        task.resume()
        return {
            gate.cancelTimerOnly()
            task.cancel()
        }
    }

    /// Async/await request with cooperative Swift Task cancellation.
    static func send(
        _ request: AnthropicMessageRequest,
        apiKey: String,
        session: URLSession = sharedSession
    ) async -> Response {
        final class CancelBox: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelAction: (@Sendable () -> Void)?
            private var cancelled = false
            func store(_ action: @escaping @Sendable () -> Void) {
                let immediate = lock.withLock { () -> Bool in
                    if cancelled { return true }
                    cancelAction = action
                    return false
                }
                if immediate { action() }
            }
            func cancel() {
                let action = lock.withLock { () -> (@Sendable () -> Void)? in
                    cancelled = true
                    defer { cancelAction = nil }
                    return cancelAction
                }
                action?()
            }
        }
        let box = CancelBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancel = send(request, apiKey: apiKey, session: session) { response in
                    continuation.resume(returning: response)
                }
                box.store(cancel)
            }
        } onCancel: {
            box.cancel()
        }
    }
}
