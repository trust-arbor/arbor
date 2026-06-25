#!/usr/bin/env python3
"""
Convert the needs_tools corpus + Hysun's QA truth labels into promptfoo tests.

Inputs (place in ./_import/ — NOT committed, contains real usage content):
  - needs_tools_dual_seeded.jsonl   145 prompts with model predictions
  - needs_tools_dual_review.md      QA review: `id: X` `[truth: true|false]` lines

Output:
  - dataset.jsonl                   promptfoo JSONL tests (gitignored — derived
                                    from real usage content; regenerate locally)

The original corpus is real Hysun usage (may contain internal hostnames/IPs/
project details). Arbor is a public repo: neither _import/ nor dataset.jsonl
may be committed. The committed, shareable subset is sanity.jsonl (16 curated
prompts from the 2026-05-26 model sweep).

Usage: python3 convert_corpus.py
"""

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent
SEEDED = HERE / "_import" / "needs_tools_dual_seeded.jsonl"
REVIEW = HERE / "_import" / "needs_tools_dual_review.md"
OUT = HERE / "dataset.jsonl"

TRUTH_RE = re.compile(r"`id:\s*(\w+)`\s*`\[truth:\s*(true|false|\?)\]`", re.IGNORECASE)

# Robust extraction: JSON parse if possible, else regex. Handles models that
# wrap JSON in prose. (Reasoning models that emit into reasoning_content with
# empty content will fail — that is correct behavior for this gate: an empty
# answer is a wrong answer. See README.)
ASSERT_JS = (
    r'((output.match(/"needs_tools"\s*:\s*(true|false)/i)||[])[1]||'
    r"'').toLowerCase() === '{expected}'"
)


def main():
    if not SEEDED.exists() or not REVIEW.exists():
        sys.exit(
            "Missing _import/ inputs. Copy the corpus first:\n"
            "  cp -r ~/.claude/arbor-personal/eval_corpus "
            f"{HERE}/_import"
        )

    truth = {}
    for line in REVIEW.open():
        m = TRUTH_RE.search(line)
        if m and m.group(2).lower() in ("true", "false"):
            truth[m.group(1)] = m.group(2).lower() == "true"

    records = [json.loads(l) for l in SEEDED.open()]
    missing = [r["id"] for r in records if r["id"] not in truth]
    if missing:
        sys.exit(f"{len(missing)} records lack truth labels: {missing[:5]}...")

    n_true = 0
    with OUT.open("w") as f:
        for rec in records:
            expected = truth[rec["id"]]
            n_true += expected
            test = {
                "description": f"{rec['id']} (truth={expected}, complexity={rec.get('label')})",
                "vars": {"message": rec["content"]},
                "assert": [
                    {
                        "type": "javascript",
                        "value": ASSERT_JS.format(expected=str(expected).lower()),
                    }
                ],
                "metadata": {
                    "id": rec["id"],
                    "needs_tools_truth": expected,
                    "complexity_label": rec.get("label"),
                    "truth_source": "hysun_qa_review_2026-05-26",
                    # FN/FP analysis: a failed assert where truth=true is a
                    # false NEGATIVE (the dangerous direction).
                },
            }
            f.write(json.dumps(test) + "\n")

    print(f"Wrote {len(records)} tests to {OUT.name} ({n_true} truth=true, "
          f"{len(records) - n_true} truth=false)")
    print("dataset.jsonl is gitignored (derived from real usage content) — do not commit.")


if __name__ == "__main__":
    main()
