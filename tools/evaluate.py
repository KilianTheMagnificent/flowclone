#!/usr/bin/env python3
"""Score local JSONL references and model results; standard library only, no network."""
import argparse
import json
import math
import re
from pathlib import Path


def words(text):
    # Ignore sentence punctuation, but keep technical suffixes, decimal points,
    # identifiers and operators. Stripping all non-word characters made C++ and C#
    # indistinguishable and incorrectly reported perfect required-term retention.
    return re.findall(r"\w+(?:[.'’:/-]\w+)*(?:[+#]+)?|[+@#&%=<>*/\\^|~$-]+",
                      text.casefold().replace("’", "'"))


def edit_distance(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i, word in enumerate(reference, 1):
        new = [i]
        for j, candidate in enumerate(hypothesis, 1):
            new.append(min(new[-1] + 1, row[j] + 1, row[j - 1] + (word != candidate)))
        row = new
    return row[-1]


def read_rows(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    result = {row["id"]: row for row in rows}
    if len(result) != len(rows) or not rows:
        raise ValueError("IDs must be unique and the dataset nonempty")
    return result


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def score(references, results):
    if references.keys() != results.keys():
        raise ValueError("Reference/result IDs differ; partial runs cannot pass")
    groups = {}
    rows = []
    for key, ref in references.items():
        got = results[key]
        source = words(ref["reference"])
        raw = words(got["raw"])
        output = " " + " ".join(words(got["final"])) + " "
        # Each required unit supplies acceptable phrasings. This is a transparent
        # lexical check, not a claim to judge meaning or replace blind human review.
        required = ref.get("required", {})
        missing = [label for label, aliases in required.items()
                   if not any(words(alias) and " " + " ".join(words(alias)) + " " in output
                              for alias in aliases)]
        edits = edit_distance(source, raw)
        row = {"id": key, "word_errors": edits, "reference_words": len(source),
               "missing_required": missing, "required_count": len(required),
               "fallback": bool(got.get("fallback")), "gate_passed": got.get("gate_passed", True)}
        for stage in ("cleaned", "final"):
            if stage in got:
                row[stage + "_word_errors"] = edit_distance(source, words(got[stage]))
        rows.append(row)
        cohort = "/".join([got.get("asr_model", "unknown"), got.get("fluidaudio", "unknown"),
                           got.get("mode", "unknown"), ref.get("cohort", "unspecified"),
                           got.get("exec_sha256", "unknown-build")])
        group = groups.setdefault(cohort, {"rows": [], "latencies": []})
        group["rows"].append(row)
        if "total_ms" in got:
            latency = float(got["total_ms"])
            if not math.isfinite(latency) or latency < 0:
                raise ValueError("Latency must be finite and nonnegative")
            group["latencies"].append(latency)
    summary = {}
    for cohort, group in groups.items():
        rs = group["rows"]
        count = len(rs)
        total_words = sum(r["reference_words"] for r in rs)
        total_required = sum(r["required_count"] for r in rs)
        summary[cohort] = {
            "count": count,
            "asr_wer": sum(r["word_errors"] for r in rs) / total_words if total_words else None,
            "required_retention": 1 - sum(len(r["missing_required"]) for r in rs) / total_required if total_required else None,
            "fallback_rate": sum(r["fallback"] for r in rs) / count,
            "gated_count": sum(not r["gate_passed"] for r in rs),
            "text_p50_ms": percentile(group["latencies"], .50),
            "text_p95_ms": percentile(group["latencies"], .95),
        }
        for stage in ("cleaned", "final"):
            measured = [r for r in rs if stage + "_word_errors" in r]
            denominator = sum(r["reference_words"] for r in measured)
            summary[cohort][stage + "_wer"] = (
                sum(r[stage + "_word_errors"] for r in measured) / denominator
                if denominator else None)
    return {"schema": 2, "summary": summary, "rows": rows,
            "limits": "Symbol-aware WER is reported separately for ASR, Clean and final text. Legitimate rewrites can increase WER. Required units are lexical checks. Latency excludes microphone and paste. Human meaning/quality review remains required."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("references")
    parser.add_argument("results")
    args = parser.parse_args()
    print(json.dumps(score(read_rows(args.references), read_rows(args.results)), indent=2))
