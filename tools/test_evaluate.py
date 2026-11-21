import unittest
from evaluate import edit_distance, score, words


class EvaluationTests(unittest.TestCase):
    def test_symbols_and_technical_tokens_are_not_erased(self):
        for reference, output in [("C++", "C#"), ("1.5", "15"), ("a <= b", "a >= b"),
                                  ("AT&T", "ATT"), ("foo_bar", "foobar"), ("$20", "20")]:
            with self.subTest(reference=reference):
                report = score({"1": {"reference": reference, "required": {"term": [reference]}}},
                               {"1": {"raw": output, "final": output}})
                self.assertGreater(report["rows"][0]["word_errors"], 0)
                self.assertEqual(report["rows"][0]["missing_required"], ["term"])
        self.assertEqual(words("Hello, world!"), words("hello world."))
        self.assertEqual(words("don't"), words("don’t"))

    def test_builds_and_text_stages_are_scored_separately(self):
        refs = {str(i): {"reference": "Use C++"} for i in range(2)}
        results = {str(i): {"raw": "Use C++", "cleaned": "Use C#", "final": "Use C++",
                            "exec_sha256": str(i)} for i in range(2)}
        report = score(refs, results)
        self.assertEqual(len(report["summary"]), 2)
        for group in report["summary"].values():
            self.assertEqual(group["asr_wer"], 0)
            self.assertEqual(group["cleaned_wer"], .5)
            self.assertEqual(group["final_wer"], 0)

    def test_empty_required_alias_cannot_pass(self):
        report = score({"1": {"reference": "hello", "required": {"term": [""]}}},
                       {"1": {"raw": "hello", "final": "hello"}})
        self.assertEqual(report["rows"][0]["missing_required"], ["term"])

    def test_order_multiplicity_and_omissions_count(self):
        self.assertEqual(edit_distance(["a", "a", "b"], ["a", "b"]), 1)
        self.assertEqual(edit_distance(["a", "b"], ["b", "a"]), 2)
        self.assertEqual(edit_distance([], ["hallucination"]), 1)

    def test_subset_cannot_pass_required_units_and_partial_run_is_refused(self):
        refs = {"1": {"reference": "do not send 15 dollars", "required": {"negative": ["not"], "amount": ["15", "fifteen"]}}}
        results = {"1": {"raw": "do not send 15 dollars", "final": "send 50 dollars", "total_ms": 100}}
        report = score(refs, results)
        self.assertEqual(report["rows"][0]["missing_required"], ["negative", "amount"])
        self.assertEqual(next(iter(report["summary"].values()))["required_retention"], 0)
        with self.assertRaises(ValueError):
            score(refs, {})


if __name__ == "__main__":
    unittest.main()
