import XCTest
@testable import FlowCloneCore

final class AutoLearnSelfCheckTests: XCTestCase {
    func testCorrectionFixtures() {
        let cases: [(name: String, pasted: String, field: String, want: [(String, String)])] = [
            ("single fix", "Meet with Andre tomorrow", "Meet with André tomorrow",
             [("Andre", "André")]),
            ("case fix", "send it to flowclone", "send it to FlowClone",
             [("flowclone", "FlowClone")]),
            ("rewrite", "the quick brown fox", "an entirely different sentence", []),
            ("append", "the quick brown fox", "the quick brown fox and more words after", []),
            ("two fixes", "Meet with Andre about Kubernets tomorrow",
             "Meet with André about Kubernetes tomorrow",
             [("Andre", "André"), ("Kubernets", "Kubernetes")]),
            ("short words", "I sent it to him", "I sent it an him", []),
            // redteam M5: a grammatical suffix edit is not a spelling fix — don't learn it.
            ("suffix edit", "the server is ready", "the servers is ready", []),
            ("tense edit", "we walk to the office", "we walked to the office", []),
            // 2026-08-04 "like -> live": a terminal buffer shares a few common words with
            // any paste, so vanished words got paired with random same-first-letter output.
            ("terminal buffer", "please make the pill appear like before",
             "make: nothing to do\nlive log stream started\nthe pill widget loaded before main\nps aux grep flow",
             []),
            ("unrelated same-app field", "please make the pill appear like before",
             "make the pill live before", []),
        ]
        for c in cases {
            let got = AutoLearn.findCorrections(pasted: c.pasted, field: c.field)
            XCTAssertEqual(got.count, c.want.count, c.name)
            XCTAssertFalse(zip(got, c.want).contains {
                $0.wrong != $1.0 || $0.right != $1.1
            }, c.name)
        }
    }

    func testCorrectionProvenanceAndDuplicateFixtures() {
        XCTAssertFalse(AutoLearn.mayLearn(hadContextRewrite: true))

        let repeated = AutoLearn.unambiguousCorrections([
            (wrong: "flowclone", right: "FlowClone"),
            (wrong: "FLOWCLONE", right: "FlowClone"),
        ])
        XCTAssertEqual(repeated?.count, 1)
        XCTAssertEqual(repeated?.first?.wrong, "flowclone")
        XCTAssertEqual(repeated?.first?.right, "FlowClone")

        let divergent = AutoLearn.unambiguousCorrections([
            (wrong: "foo", right: "fob"),
            (wrong: "FOO", right: "far"),
        ])
        XCTAssertNil(divergent)
    }
}
