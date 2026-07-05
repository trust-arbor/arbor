# Model Selection Decisions — Living Log

Which model Arbor uses for each **role**, the eval evidence, and the date decided. We re-run these
evals periodically (new model releases, new tasks), so **append a new dated block at the TOP each
round** and update the "Current" table. The dated blocks are the audit trail — never rewrite history,
add a new block.

- **Methodology / footprint:** [`evals/promptfoo/MODELS.md`](promptfoo/MODELS.md)
- **Dated eval-result docs (local, gitignored):** `.arbor/evals/` (e.g. `model-comparison-2026-02-18.md`)
- **Raw eval store:** Postgres `eval_runs` / `eval_results` (query by `task_id`, `model`, `inserted_at`;
  `metadata->>'judge_score'` holds the 0-100 plan-quality score)

---

## Current decisions (as of 2026-07-04)

| Role | Model | Provider | Evidence | Runner-up |
|---|---|---|---|---|
| **Front-door / sensitivity classifier** (decides what data may leave the box) | **gemma-4-e4b** | LM Studio (local) | 100% sensitivity (75/75), ~28s, best small classifier | gemma-4-e2b (93%, smaller) |
| **Local tool-calling agent** | **qwen3.5-4b-mtp** | LM Studio (local) | 13/13 agent tasks + 98% classifier; steadiest small agent | (qwen-2b quants ~90%) |
| **Planner — best overall** | **gpt-5.5** | ChatGPT (OAuth) | 88 ±11 on hard planner tasks | kimi/glm (tied within noise) |
| **Planner — best value (free)** | **kimi-k2.7-code:cloud** or **glm-5.2:cloud** | ollama cloud (FREE) | 84 ±15 / 83 ±13, ~½ the latency, FREE — ≈ frontier | — |
| **Planner — best local** | **gemma-4-31b** | LM Studio (local) | 72 ±16, reliable | NOT qwen-122b (see below) |
| **Eval judge** | **gpt-5.4-mini** | ChatGPT (OAuth) | discriminating 0-100 scoring (gemma-e4b too lenient) | — |
| **Heartbeat (routine)** | **claude-haiku-4.5** | (prior, 2026-02-18) | not re-evaled 2026-07-04 | Sonnet (deep), Opus (reflective) |

---

## 2026-07-04 — small-model battery + frontier planner roster

**Context:** first eval round with subscription-OAuth (ChatGPT/Grok) and ollama-cloud models working,
plus a rebuilt planner eval (0-100 quality score + wall time + hard-task tier + strong judge).

### Decisions & what changed
- **Front-door = gemma-4-e4b (100% sensitivity).** Confirmed after fixing an eval extraction bug that
  had made thinking models (qwen-9b) look "collapsed" — see [[feedback_thinking_models_underscored_by_eval_infra]].
- **Local agent = qwen3.5-4b-mtp (13/13).** Beats the 2b quants and gemma on tool tasks; the head-to-head
  vs gemma-4-e4b confirmed **co-winners by role**: gemma-e4b classifies + is 2-3× faster; qwen-4b is the
  steadier tool-using agent.
- **Planner: free cloud now rivals the paid frontier.** Confirmed repeat-3 (n=12, strong judge): gpt-5.5
  **88**, kimi-k2.7-code **84**, glm-5.2 **83** — a statistical tie (±11-15). The two free ollama-cloud
  models are ≈ frontier at a quarter the latency. grok-4 80 (fastest, 44s). minimax-m3 77.
- **⚠ qwen3.5-122b DETHRONED as "best local planner."** Prior belief was it was the best local planner
  (beaten only by kimi cloud). Repeat-3 shows it **last at 60 with huge variance (±37)** — unreliable,
  likely the MTP hidden-reasoning-eats-content failure mode. **gemma-4-31b (72) is now the local pick.**
  Revisit qwen-122b only after its variance is understood.
- **qwen3-coder:480b and deepseek-v4-pro** emit a hallucinated "Plan mode" preamble instead of planning
  (coding models, not planners) — excluded from the planner role.

### Eval infrastructure changes this round (affect reproducibility)
- Judge now emits `SCORE: 0-100` (commit `7eedd6b5`); hard planner tier added (`planner-hard-db-shard`,
  `planner-hard-incident`); run_id made restart-collision-proof.
- **Known limitation:** the single OAuth judge serializes under concurrent eval load — future harness
  should parallelize judging (spread across providers or a local judge pool).

### Caveats
- Planner top cluster (gpt-5.5 / kimi / glm ≈ 83-88) is within the noise band — "top tier," not a precise
  ordering. Judge (gpt-5.4-mini) same-family-favors gpt-5.5 slightly.
- Free ollama-cloud model availability/tags change; re-check the catalog each round (`ollama` /api/tags).
