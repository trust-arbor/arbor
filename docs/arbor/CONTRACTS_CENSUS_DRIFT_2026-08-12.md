# Contracts Census Drift - 2026-08-12

AC-02 requires the executable census to reproduce the dated 2026-08-10
baseline or report every discrepancy without changing the scanner to fit the
old table. The first conforming run at parent commit `7d7a969e6` produced the
following results.

| Tier | 2026-08-10 files / LOC | 2026-08-12 files / LOC | Delta |
| --- | ---: | ---: | ---: |
| A | 21 / 5,116 | 21 / 5,116 | 0 / 0 |
| A2 | 10 / 1,851 | 10 / 1,851 | 0 / 0 |
| B | 7 / 1,078 | 14 / 1,749 | +7 / +671 |
| C | 8 / 1,526 | 10 / 2,249 | +2 / +723 |
| D | 23 / 4,639 | 16 / 3,968 | -7 / -671 |
| Shared | 87 / 19,653 | 86 / 19,164 | -1 / -489 |
| **Total** | **156 / 33,863** | **157 / 34,097** | **+1 / +234** |

## Classification Corrections

The dated table placed seven zero-consumer callback files in Tier D. AC-02's
normative order assigns any non-API file with callbacks to Tier B before it
checks for zero external consumers. These seven files account for the exact
671-LOC transfer from D to B:

| LOC | Path |
| ---: | --- |
| 208 | `lib/arbor/contracts/session/adapter.ex` |
| 123 | `lib/arbor/contracts/healing/anomaly_queue.ex` |
| 110 | `lib/arbor/contracts/comms/question_registry.ex` |
| 67 | `lib/arbor/contracts/handler/computable.ex` |
| 60 | `lib/arbor/contracts/handler/writeable.ex` |
| 57 | `lib/arbor/contracts/handler/composable.ex` |
| 46 | `lib/arbor/contracts/handler/compute_policy.ex` |

The dated table also treated two multi-consumer API facades as shared. AC-02
requires the `api/` check to run first, so these files move to Tier C:

| LOC | Path | External consumers |
| ---: | --- | --- |
| 76 | `lib/arbor/contracts/api/ai.ex` | `arbor_ai`, `arbor_consensus` |
| 647 | `lib/arbor/contracts/api/persistence.ex` | `arbor_persistence`, `arbor_persistence_ecto` |

This is a 723-LOC transfer from Shared to C. Both files remain admissible; the
change corrects their reporting tier.

## Source Drift

Commit `4582ec8de` added
`lib/arbor/contracts/persistence/revision.ex` on 2026-08-11. It has three
external consumers and contributes one shared file and 234 physical LOC.

The shared delta therefore reconciles exactly: 87 old files, minus the two API
facades, plus the new revision contract equals 86; 19,653 old LOC minus 723
plus 234 equals 19,164. The total tree delta is solely the new 234-LOC file.

No AC-02 counting rule was weakened to match the dated baseline. The current
numbers are the accepted executable baseline until contract source or
consumer references change again.
