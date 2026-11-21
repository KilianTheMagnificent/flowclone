// Shared rewrite engine — Apple Foundation Models by default, with an explicit local
// sidecar experiment. Extracted from Polisher.swift so profiles reuse one timeout and
// concurrency contract instead of forking it.
// Verified on this machine (RESEARCH.md §6): the DEFAULT guardrails reject ordinary
// dictation, so .permissiveContentTransformations is mandatory, not an optimisation.
//
// What lives here for the Apple backend and why it must live in ONE place:
//   * `q` — the single serial queue that owns every piece of state below, so the
//     single-flight invariant is a queue invariant, not a convention.
//   * `inFlight` — ONE Apple-generation flag (redteam LOW1). At most one Apple generation
//     runs across ALL profiles; the sidecar enforces its own ready/busy single flight.
//   * ONE stored session slot, tagged with the profile that built it. Never two.
// A second copy of this choreography is how two copies diverge; the callers own only
// their prompt shape and their validator.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum FM {
    /// Everything a caller varies. The prompt text itself is built by the caller and
    /// handed to `run` — this type carries only what the SESSION and the call need.
    struct Profile: Sendable {
        let name: String                 // log prefix: "polish" / "prompt"
        /// User-facing one-liner for the degrade notification. Not derivable from `name`
        /// (the shipped Polish string is "Polish needs …", a second profile may read
        /// "Prompt mode needs …"), and it must stay byte-identical to what shipped.
        let notice: String
        let instructions: String
        let prewarmPrefix: String        // fixed user-turn prefix, prewarmed
        let timeout: TimeInterval
        let temperature: Double
        let maxResponseTokens: Int?
        let validate: @Sendable (String, String) -> String?   // (out, input) -> reject reason
    }

    // MARK: - State (all of it confined to State.queue)

    /// A reference container makes the queue ownership explicit to Swift's concurrency
    /// checker. No mutable global is exposed; every property below is touched only while
    /// executing on `queue`.
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.andre.flowclone.fm")
        var model: Any?                    // SystemLanguageModel (macOS 26+ only)
        /// The ONE stored session, and the profile name that built it. There is deliberately
        /// no per-profile storage: a session carries its profile's instructions, so the tag
        /// is what makes reuse safe, and a mismatch discards rather than accumulates.
        var stored: Any?                   // LanguageModelSession, prewarmed
        var storedProfile: String?
        var checked = false
        var checkedAt: DispatchTime?
        var usable = false
        /// true while a generation is running (including a timed-out one still in flight).
        var inFlight = false
        /// A prewarm requested while a generation was in flight.
        var deferred: Profile?
        var announced = Set<String>()
        var notified = Set<String>()
        var why = ""
        var testHoldInFlight = false
    }

    private static let state = State()
    private static var q: DispatchQueue { state.queue }

    // MARK: - Test hooks (guarded like Polisher.testInert; untouched on normal launches)

    /// Simulates a generation in flight on `q` without running one, so a deterministic
    /// suite can prove that `prepare()` defers instead of constructing a session.
    /// Clear it before calling `testDrainDeferred()`, or the drain will re-defer.
    static var testHoldInFlight: Bool {
        get { q.sync { state.testHoldInFlight } }
        set { q.sync { state.testHoldInFlight = newValue } }
    }
    /// Runs the real completion-handler prewarm routine — the only path that clears
    /// `inFlight` and honours the deferred slot.
    static func testDrainDeferred() { q.sync { finish(nil) } }
    /// Tag of the single stored session, for assertions. nil = the slot is empty.
    static var debugStoredProfileName: String? { q.sync { state.storedProfile } }

    /// Every "is a generation running" decision reads this, so the test hold is
    /// indistinguishable from a real in-flight task to the logic under test.
    private static var busy: Bool { state.inFlight || state.testHoldInFlight }

    // MARK: - Availability + prewarmed session

    /// Fire-and-forget warmup: at launch when the mode already uses this profile, and on
    /// every switch to it from either control surface (see `Mode.set`). The explicitly
    /// configured local backend owns its own process warmup; when it is disabled this is
    /// byte-for-byte the existing Apple queue path.
    static func prepare(_ p: Profile) {
        #if DEBUG
        if Sidecar.isEnabled {
            Sidecar.warm()
            return
        }
        #endif
        q.async { _ = arm(p) }
    }

    /// Called from the session queue before routing an utterance to the LLM. An enabled
    /// sidecar is an alternative backend, not an Apple precondition: ready means its warmup
    /// handshake completed. Cold/warming/failed returns false promptly and takes Clean.
    static func ready(_ p: Profile) -> Bool {
        #if DEBUG
        if Sidecar.isEnabled {
            Sidecar.warm()
            let readiness = Sidecar.readiness
            if readiness == .ready { return true }
            // Same contract as the Apple path: the user is told once that this mode fell
            // back to Clean. Without it a dead sidecar degrades silently for the rest of
            // the process and Polish/Prompt look broken rather than unavailable.
            if shouldDegrade(for: readiness) {
                q.sync {
                    state.why = "the local sidecar is \(Sidecar.readinessDescription)"
                    degrade(p)
                }
            }
            return false
        }
        #endif
        return q.sync { arm(p) }
    }

    /// `degrade` fires once per profile per process, so it must be spent on the state the
    /// sidecar cannot leave. Cold, warming and busy all end by themselves — the utterance
    /// takes Clean quietly, exactly as before — while `.failed` is the permanent one the
    /// user needs to hear about. Announcing a warmup would also consume the single shot and
    /// leave a later crash silent.
    static func shouldDegrade(for readiness: Sidecar.Readiness) -> Bool { readiness == .failed }

    /// `prepare` and `ready` for an optional pass (the spoken-repair review): a model that
    /// is unavailable or busy just means the pass is skipped, so nothing is logged as a
    /// degrade and nobody is notified. The sidecar experiment is never used for it.
    static func prepareQuietly(_ p: Profile) {
        #if DEBUG
        guard !Sidecar.isEnabled else { return }
        #endif
        q.async { if ensure() { prewarm(p) } }
    }

    static func readyQuietly(_ p: Profile) -> Bool {
        #if DEBUG
        guard !Sidecar.isEnabled else { return false }
        #endif
        return q.sync {
            guard ensure(), !busy else { return false }
            prewarm(p)
            return true
        }
    }

    /// Availability (once, profile-independent) + a prewarmed session for `p`.
    private static func arm(_ p: Profile) -> Bool {   // on q
        guard ensure() else { degrade(p); return false }
        if prewarm(p), state.announced.insert(p.name).inserted {
            log("\(p.name): Foundation Models available, session prewarmed")
        }
        return true
    }

    private static func ensure() -> Bool {          // on q
        // Apple Intelligence assets/settings can change during a long-running session.
        // Poll on use at most once per 30s, never replace a model during generation.
        if state.checked, busy || state.checkedAt.map({ ms($0, .now()) < 30_000 }) == true {
            return state.usable
        }
        state.checked = true
        state.checkedAt = .now()
        guard #available(macOS 26.0, *) else {
            state.why = "this macOS has no Foundation Models"
            return false
        }
        let m = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if case .unavailable(let w) = m.availability {
            state.why = "Apple Foundation Models unavailable (\(w))"
            state.usable = false
            state.model = nil
            state.stored = nil
            state.storedProfile = nil
            return false
        }
        if !state.usable {
            state.notified.removeAll()
            state.announced.removeAll()
        }
        state.model = m
        state.usable = true
        return true
    }

    private static func degrade(_ p: Profile) {     // on q
        guard state.notified.insert(p.name).inserted else { return }
        log("\(p.name) UNAVAILABLE — \(state.why); falling back to Clean")
        notifyUser(p.notice)
    }

    /// Puts a session for `p` in the single slot. Returns true when the slot now holds
    /// one. Never constructs while a generation is in flight — that request is parked in
    /// `deferred` and honoured by `finish`, which is the only place `inFlight` clears.
    @discardableResult
    private static func prewarm(_ p: Profile) -> Bool {   // on q
        guard state.usable else { return false }
        if busy { state.deferred = p; return false }
        if state.stored != nil, state.storedProfile == p.name { return true }
        guard #available(macOS 26.0, *),
              let m = state.model as? SystemLanguageModel else { return false }
        state.stored = warmSession(m, p) // a differently-tagged session is discarded: one slot
        state.storedProfile = p.name
        return true
    }

    @available(macOS 26.0, *)
    private static func warmSession(_ m: SystemLanguageModel, _ p: Profile) -> LanguageModelSession {
        let s = LanguageModelSession(model: m, instructions: p.instructions)
        s.prewarm(promptPrefix: Prompt(p.prewarmPrefix))   // a fixed prefix — prewarm it too
        return s
    }

    /// Sessions accumulate context, so each utterance consumes one and the next is
    /// prewarmed straight after. A tag mismatch means the stored session carries another
    /// profile's instructions: discard it and build cold — never prewarm mid-run.
    @available(macOS 26.0, *)
    private static func takeSession(_ p: Profile) -> LanguageModelSession? {   // on q
        if busy { return nil }   // redteam LOW1: never open a second concurrent session
        let matched = state.storedProfile == p.name
        let warm = state.stored as? LanguageModelSession
        state.stored = nil       // consumed on a match, discarded on a mismatch
        state.storedProfile = nil
        if matched, let warm { return warm }
        guard let m = state.model as? SystemLanguageModel else { return nil }
        return LanguageModelSession(model: m, instructions: p.instructions)   // prewarm lost, still correct
    }

    /// The single run-completion routine — the ONLY place `inFlight` clears. Prewarms the
    /// deferred profile if one was parked, else re-prewarms the profile that just ran
    /// (today's semantics: back-to-back utterances stay on a warm session).
    private static func finish(_ ran: Profile?) {   // on q
        state.inFlight = false
        let next = state.deferred ?? ran
        state.deferred = nil
        if let next { prewarm(next) }
    }

    // MARK: - The call

    private final class Once: @unchecked Sendable { var done = false }
    final class Slot: @unchecked Sendable { var text: String?; var ms = 0.0 }

    /// Calls back exactly once: the model's text, or nil when the caller should paste its
    /// Clean fallback (error, refusal, garbage, or the profile's timeout).
    static func run(_ p: Profile, input: String, promptText: String,
                    done: @escaping @Sendable (String?, Double) -> Void) {
        let t0 = DispatchTime.now()
        let once = Once()
        let settle: @Sendable (String?) -> Void = { r in
            q.async {
                guard !once.done else { return }
                once.done = true
                log(String(format: "REWRITE_METRIC profile=%@ total_ms=%.1f outcome=%@ input_chars=%d output_chars=%d",
                           p.name, ms(t0, .now()), r == nil ? "clean_fallback" : "accepted", input.count, r?.count ?? 0))
                done(r, ms(t0, .now()))
            }
        }
        // EXPERIMENT (2026-08-28): route to the explicitly configured local MLX sidecar.
        // Off unless `sidecarModel` is set, so the Apple path below is untouched on every
        // normal launch. `Sidecar.run` never spawns or waits for warmup: if it is not ready
        // this worker returns nil promptly. `settle` retains this function's exactly-once
        // contract, and a sidecar failure never opens Apple FM as a hidden second attempt.
        #if DEBUG
        if Sidecar.isEnabled {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Sidecar.run(instructions: p.instructions, prompt: promptText,
                                    temperature: p.temperature,
                                    maxTokens: p.maxResponseTokens ?? 500,
                                    timeout: p.timeout)
                guard let r else { settle(nil); return }
                let out = sanitize(r.text, input: input)
                if let reason = p.validate(out, input) {
                    log("\(p.name) [sidecar] REJECTED (\(reason)): \(logTranscriptsEnabled() ? String(out.prefix(120)) : "\(out.count) chars")")
                    settle(nil)
                } else {
                    log(String(format: "%@ [sidecar] ok %.0fms", p.name, r.ms))
                    settle(out)
                }
            }
            return
        }
        #endif
        guard #available(macOS 26.0, *) else { settle(nil); return }
        q.async {
            guard let s = takeSession(p) else {
                log("\(p.name): no session (model unavailable or one already in flight)")
                settle(nil)
                return
            }
            state.inFlight = true // block a second concurrent session until this ends
            // Only the profiles that set a token cap pay for the extra option, so the
            // shipped Polish call site still constructs GenerationOptions(temperature:).
            let options = p.maxResponseTokens.map {
                GenerationOptions(temperature: p.temperature, maximumResponseTokens: $0)
            } ?? GenerationOptions(temperature: p.temperature)
            let task = Task {
                do {
                    let r = try await s.respond(to: promptText, options: options)
                    let out = sanitize(r.content, input: input)
                    if let reason = p.validate(out, input) {
                        // redteam H1: rejected model output is transcript-derived content.
                        log("\(p.name) REJECTED (\(reason)): \(logTranscriptsEnabled() ? String(out.prefix(120)) : "\(out.count) chars")")
                        settle(nil)
                    } else {
                        settle(out)
                    }
                } catch let e as LanguageModelSession.GenerationError {
                    log("\(p.name) FAILED: \(name(e))")
                    settle(nil)
                } catch {
                    let detail = String(describing: error)
                    let kind = String(reflecting: type(of: error))
                    log("\(p.name) FAILED: \(diagnosticErrorSummary(type: kind, detail: detail))")
                    settle(nil)
                }
                q.async { finish(p) }   // redteam LOW1: cleared when the task actually finishes
            }
            q.asyncAfter(deadline: .now() + p.timeout) {
                guard !once.done else { return }
                log("\(p.name) TIMEOUT after \(Int(p.timeout))s — using the Clean fallback")
                task.cancel()
                settle(nil)
                // redteam LOW1: do NOT clear inFlight here — the abandoned task may still be
                // generating; it clears the flag itself. Until then the next utterance falls
                // back to Clean instead of opening a second concurrent session.
            }
        }
    }

    @available(macOS 26.0, *)
    static func name(_ e: LanguageModelSession.GenerationError) -> String {
        switch e {
        case .exceededContextWindowSize: return "exceededContextWindowSize"
        case .assetsUnavailable: return "assetsUnavailable"
        case .guardrailViolation: return "guardrailViolation"
        case .unsupportedGuide: return "unsupportedGuide"
        case .unsupportedLanguageOrLocale: return "unsupportedLanguageOrLocale"
        case .decodingFailure: return "decodingFailure"
        case .rateLimited: return "rateLimited"
        case .concurrentRequests: return "concurrentRequests"
        case .refusal: return "refusal"
        @unknown default: return "unknownGenerationError"
        }
    }

    // MARK: - Output sanity

    /// The five phrases every profile treats as a refusal — one list, because three
    /// validators drifting apart is how a backstop rots. A phrase the SPEAKER used ("tell
    /// the team I cannot make the standup") may be their own dictation faithfully retyped,
    /// but its mere presence in the input is not a blanket exemption: a model refusal can
    /// otherwise collapse the whole dictation down to that shared phrase.
    private static let refusalPhrases = ["i cannot", "i can't", "i'm sorry", "as an ai",
                                         "i am unable"]

    static func refusalPhrase(in output: String, input: String) -> String? {
        let low = output.lowercased(), source = input.lowercased()
        let present = refusalPhrases.filter { low.contains($0) }
        guard !present.isEmpty else { return nil }

        // A phrase the speaker never used is unambiguously model-authored.
        if let introduced = present.first(where: { !source.contains($0) }) {
            return introduced
        }

        // For a speaker-owned phrase, require the output to retain at least two thirds of
        // the source word occurrences. This still admits ordinary cleanup around a faithful
        // retype (including the historical "tell them" fixture), while rejecting a short
        // refusal-shaped excerpt whose every word happens to occur in the source.
        let sourceWords = wordsForRefusalCheck(input)
        var remaining = Dictionary(sourceWords.map { ($0, 1) }, uniquingKeysWith: +)
        var retained = 0
        for word in wordsForRefusalCheck(output) {
            guard let count = remaining[word], count > 0 else { continue }
            retained += 1
            remaining[word] = count - 1
        }
        return retained * 3 >= sourceWords.count * 2 ? nil : present[0]
    }

    private static func wordsForRefusalCheck(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Curly forms included: the model may straighten what the speaker dictated.
    private static let quoteMarks: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    /// A model that wraps its whole answer in quotation marks is quoting itself, and the
    /// marks are noise. When the INPUT was itself a quoted phrase they are the speaker's own
    /// punctuation, and stripping them silently deletes content — so `input` decides.
    static func sanitize(_ s: String, input: String) -> String {
        var t = s.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "",
                                       options: .regularExpression)
        t = t.filter { !"\u{200B}\u{200C}\u{200D}\u{FEFF}".contains($0) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 1, t.hasPrefix("\""), t.hasSuffix("\""), !isQuoted(input) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func isQuoted(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 1, let first = t.first, let last = t.last else { return false }
        return quoteMarks.contains(first) && quoteMarks.contains(last)
    }
}
