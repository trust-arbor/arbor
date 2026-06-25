#!/usr/bin/env python3
"""
Convert the complexity corpus into promptfoo tests (task: preprocessor.complexity).

Input (place in ./_import/ — NOT committed, contains real usage content):
  - effort_tier_seeded.jsonl   145 prompts with a `label`
    (SIMPLE | MULTI_STEP | NON_ACTIONABLE)

Output:
  - dataset.jsonl              promptfoo JSONL tests (gitignored — derived from
                               real usage content; regenerate locally)

⚠️  TRUTH QUALITY: the `label` field is **granite4.1:3b-seeded** (`llm_seed_v2`),
NOT human-QA'd. The effort_tier review only collected human truth for
`needs_tools`, not complexity. So `dataset.jsonl` accuracy is *provisional*:
- Ranking models by agreement with it is CIRCULAR for granite (it generated the
  labels) and measures agreement-with-granite for everyone else — NOT correctness.
- Use it for **distribution / collapse detection** (a model that collapses to
  all-SIMPLE is useless even at high "accuracy" on a SIMPLE-heavy corpus) and for
  rough agreement, NOT for authoritative model ranking.
- The trustworthy ranking signal is the committed `sanity.jsonl` (12 curated,
  unambiguous, human-labeled prompts). A model that fails those is disqualified.
- For authoritative corpus ranking, do a human-QA pass on the 145 labels (as
  needs_tools got) or a multi-strong-model consensus re-seed, then set
  truth_source accordingly.

Usage: python3 convert_corpus.py
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).parent
SEEDED = HERE / "_import" / "effort_tier_seeded.jsonl"
OUT = HERE / "dataset.jsonl"

LABELS = ("SIMPLE", "MULTI_STEP", "NON_ACTIONABLE")

ASSERT_JS = (
    r'((output.match(/"label"\s*:\s*"(SIMPLE|MULTI_STEP|NON_ACTIONABLE)"/i)||[])[1]||'
    r"'').toUpperCase() === '{expected}'"
)


def main():
    if not SEEDED.exists():
        sys.exit(
            "Missing _import/effort_tier_seeded.jsonl. Copy the corpus first:\n"
            f"  cp -r ~/.claude/arbor-personal/eval_corpus {HERE}/_import"
        )

    records = [json.loads(l) for l in SEEDED.open()]
    counts = {l: 0 for l in LABELS}
    skipped = 0

    with OUT.open("w") as f:
        for rec in records:
            label = (rec.get("label") or "").upper()
            if label not in LABELS:
                skipped += 1
                continue
            counts[label] += 1
            test = {
                "description": f"{rec['id']} (label={label} — PROVISIONAL granite-seed)",
                "vars": {"message": rec["content"]},
                "assert": [{"type": "javascript", "value": ASSERT_JS.format(expected=label)}],
                "metadata": {
                    "id": rec["id"],
                    "complexity_label": label,
                    "truth_source": "granite_seed_v2 (PROVISIONAL — not human-QA'd)",
                },
            }
            f.write(json.dumps(test) + "\n")

    print(f"Wrote {sum(counts.values())} tests to {OUT.name} "
          f"({', '.join(f'{k}={v}' for k, v in counts.items())}; skipped {skipped})")
    print("dataset.jsonl is gitignored (real usage content + PROVISIONAL labels) — do not commit.")
    print("Authoritative ranking = sanity.jsonl + collapse check; corpus accuracy is provisional.")


if __name__ == "__main__":
    main()
