# Arbor — Planned Work

*Committed work that hasn't been started yet.* This doc lists items from `.arbor/roadmap/2-planned/` — work that has been designed and committed to, but isn't in active implementation. For shipped features see [FEATURES.md](FEATURES.md). For active development see [INPROGRESS.md](INPROGRESS.md). For earlier-stage brainstorming and inbox items, see `.arbor/roadmap/`.

---

## Items

### Agent Infrastructure Platform
Master vision for Arbor as an external integration hub. Tracks dependency order for incremental delivery — external agent registration → message bridges (Discord, Telegram, Slack) → home assistant integration. Several extracted slices live in `0-inbox/`.
**Priority:** High · **Source:** `.arbor/roadmap/2-planned/agent-infrastructure-platform.md`

### Public Launch Roadmap
Four-stage plan from private development to publicly usable product. Defines Arbor's core differentiators across three tiers (relationship memory, earned autonomy, security architecture) and stages the work needed to harden, polish, and publicly launch.
**Priority:** High · **Source:** `.arbor/roadmap/2-planned/public-launch-roadmap.md`

### Voice Pipeline — Phone Cluster Integration
Voice conversation pipeline between an Android phone (BEAM node) and the Arbor homelab over distributed Erlang. Phone handles STT/TTS locally; Arbor processes through an agent and returns the response. Phone clustering already verified; this is the conversation pipeline on top.
**Priority:** High · **Source:** `.arbor/roadmap/2-planned/voice-pipeline-phone-cluster.md`

### Security Kernel Extraction
Extract `arbor_security` into a standalone Hex library so any Elixir developer can use capability-based agent authorization and cryptographic identity without the full Arbor umbrella. ~15K lines, ~2–3 days of mostly mechanical work.
**Priority:** High (enables platform positioning) · **Source:** `.arbor/roadmap/2-planned/security-kernel-extraction.md`

### User Customization Directory Split
Split project `.arbor/` from user customizations to prevent upgrade conflicts. User-created templates, DOT pipelines, council consultations, and eval results currently mix with Arbor defaults — `git pull` risks loss. Move user content to `~/.arbor/` or similar.
**Priority:** Medium · **Source:** `.arbor/roadmap/2-planned/user-customization-directory-split.md`

### Arbor Blog Agent
Build a collaborative blog writing assistant agent that takes rough ideas to publishable drafts. Handles structure, voice consistency, codebase fact-checking, and the draft-review-publish pipeline while the human retains creative control. Reduces friction between having ideas and publishing.
**Priority:** Medium · **Source:** `.arbor/roadmap/2-planned/arbor-blog-agent.md`

### Documentation Pass
Improve module docs (`@moduledoc`), function docs (`@doc`), type specs (`@spec`), per-library READMEs, and keep CLAUDE.md current. Opportunistic — pick up anytime when touching adjacent code. Priority order: facades first, contracts second, core modules third.
**Priority:** Low (ongoing) · **Source:** `.arbor/roadmap/2-planned/documentation-pass.md`

### Distributed Trust Zones & Agent Migration
Advanced cluster management — classify nodes as compute/edge/DMZ, restrict what agents or data can run where (edge nodes like Android get different policies), and support agent migration across nodes (checkpoint state on source, restore on destination). Builds on completed distributed agent scheduling work.
**Priority:** Low (not blocking; activates as cluster grows) · **Source:** `.arbor/roadmap/2-planned/distributed-trust-zones-and-migration.md`

---

*Last updated: 2026-05-17*
