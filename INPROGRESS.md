# Arbor — In-Progress Work

*Work currently in active implementation.* For shipped features see [FEATURES.md](FEATURES.md). For committed-but-not-yet-started work see [PLANNED.md](PLANNED.md). For earlier-stage brainstorming and inbox items, see `.arbor/roadmap/`.

---

## Current State (July 2026)

Formal implementation items in `.arbor/roadmap/3-in-progress/`:

- **Security Sentinel agent** — Phase 1 built + validated (found and drove out 5 real fail-open authz bugs); Phase 2 underway (FindingStore lifecycle + whole-tree detectors — the signed-field detector already found and closed an unsigned-field gap). See `3-in-progress/security-sentinel-agent.md`. Follow-on build plans (dynamic probing, self-remediation, probe tool catalog) are committed in `2-planned/`.

- **Preprocessor pipeline unification** — canonical map + integration/intent-routing plan consolidating the built-but-dormant 4-phase preprocessor with the 8-stage vision and its K1–K5 security-keystone sections. See `3-in-progress/preprocessor-pipeline-unification.md`.

- **Agentic safety eval harness** — Ring 1 eval work for agent safety behaviors. See `3-in-progress/agentic-safety-eval-harness.md`.

- **LLM → DOT compilation evaluation** — completed with strong results (0.87–0.96 quality across 20 models); feeds the DOT signing/stdlib work. See `3-in-progress/llm-dot-compilation-evaluation.md`.

## Active design & research (July 2026 review pass)

A concentrated architecture-review pass produced fresh design docs now sitting in `1-brainstorming/` (several ready to promote to `2-planned/`):

- **DOT signing + adapt-node policy** — decision recorded (`.arbor/decisions/2026-07-04-dot-signing-and-adapt-node-policy.md`); implementation committed in `2-planned/dot-signing-and-verification.md`. Establishes engine-path signature verification (fail-closed), per-signer keys, immutable-with-revocation artifacts, and staged self-modification (generate → validate → invoke) replacing in-place structural adapt.

- **Self-improvement loop** — closing the "agent learns over time" gap by adopting Hermes's post-turn learning loop (skill creation/curation + memory nudges) onto Arbor's governance (learned skills earn signed promotion, not immediate trust). See `1-brainstorming/self-improvement-loop.md`.

- **Memory system review** — identified the P0 gap that recalled memories never reach the turn prompt (only heartbeats), plus the "structured substrate, flat-text interface" memory-page direction and adoption ideas (composite retrieval scoring, temporal validity, write-time reconciliation). See `1-brainstorming/memory-system-review-2026-07-04.md`.

- **Heartbeat cognitive-modes review** — mode selection is a stateless cond with degenerate dynamics (busy agent never reflects, idle agent ruminates); recommends mode-as-FSM with dwell, event triggers, a no-LLM bare mode, and adaptive cadence. See `1-brainstorming/heartbeat-cognitive-modes-review.md`.

- **TUI UX design** — user stories + mockups for the terminal client (transcript-as-UI, gate denials and earned-autonomy made legible). See `1-brainstorming/arbor-tui-ux-design.md`. Scaffold live-validated 2026-06-22.

- **DOT migration benchmarks** — performance gates for converting subsystems to DOT pipelines. See `2-planned/dot-migration-benchmarks.md`.

- **Homelab cluster / trust zones** — consolidated around trust-zone segmentation (one Erlang mesh = one trust zone; edge/devices as gateway clients, never mesh peers), with the arbor9 DMZ design ready to apply.

- **Trust-tier deprecation** — moving from scalar tiers to granular per-task/per-tool trust policies; `earned-trust-feedback-loop.md` is the committed rebuild.

- **Arbor v2 minimal-core / 1.0 packaging** — the minimal core + foundational plugins reframed as the 1.0 release plan (three-ring cut over 26 apps, four+ security gates). See `1-brainstorming/arbor-v2-minimal-core*.md`.

This remains a part-time founder period; energy favors design/positioning that informs *what to build* before committing to *building* it, with targeted implementation on the security-sentinel and preprocessor tracks.

---

*Last updated: 2026-07-04*
