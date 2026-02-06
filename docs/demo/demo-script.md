# Arbor Self-Healing Demo Script

**Duration:** 60-90 seconds per scenario
**Audience:** BEAM conference attendees
**Setup:** Dashboard visible, terminal ready for fallback commands

---

## Pre-Demo Checklist

- [ ] Ollama installed and running (`ollama serve`)
- [ ] Llama3 model pulled (`ollama pull llama3`)
- [ ] `mix arbor.start` running with dashboard visible
- [ ] Dashboard shows all pipeline stages: Detect → Diagnose → Propose → Review → Fix → Verify
- [ ] Terminal window ready for fallback commands
- [ ] Timing set appropriately: `Arbor.Demo.Timing.set(:normal)`

---

## Scenario 1: Successful Self-Healing (45s)

### Opening (10s)

> "Arbor is a capability-based security system for AI agents.
> Today I'll show you an agent that can heal itself—with governance."

*Point to the dashboard showing the empty pipeline*

### Inject Fault (5s)

*Click "Inject Fault" button next to message_queue_flood*

> "I've just flooded a process's message queue. Watch the pipeline."

### Detection (10s)

*Watch the Detect stage highlight*

> "The Monitor detected the anomaly. See the process count spike?"

*Point to the anomaly indicator*

### Diagnosis (10s)

*Watch the Diagnose stage highlight*

> "Our DebugAgent is analyzing the problem. It's using bounded reasoning—
> it can only run for 5 cycles, so it can't spin forever."

*Point to the cycle counter if visible*

### Proposal (5s)

*Watch the Propose stage highlight*

> "It's proposing a fix. Look at the code diff—it adds a queue limit
> so this can't happen again."

*Point to the diff viewer*

### Council Review (10s)

*Watch the Review stage highlight with evaluator votes streaming in*

> "Three evaluators are reviewing: security, performance, and a rule-based check."

*Point to each vote as it appears*

> "All approved. The fix will be hot-loaded."

### Fix & Verify (5s)

*Watch the Fix and Verify stages complete*

> "Code loaded. Verification passed. The process is healthy again."

*Point to the timing display*

---

## Scenario 2: Rejected Fix (30s)

*Brief pause, then inject second fault*

### Setup

*Click "Inject Fault" on supervisor_crash*

> "Now let's see what happens when a fix is rejected."

### Flow

*Watch the pipeline progress to Review*

> "This time, the agent proposes modifying a protected module.
> Watch what the council does."

### Rejection

*Watch the rejection appear*

> "Rejected. The security evaluator flagged this—the target module
> is in the protected list."

*Point to the rejection reason*

> "This isn't theater. The governance is real. The agent can propose
> anything, but it can only execute what the council approves."

---

## Scenario 3: Second Success (optional, 30s)

*If time permits*

> "Let's try one more—a process leak."

*Click "Inject Fault" on process_leak*

> "Same pipeline: detect, diagnose, propose, review, fix.
> Self-healing with accountability. That's Arbor."

---

## Closing (10s)

> "What you've seen is a BEAM-native AI agent that can:
> - Detect runtime anomalies
> - Diagnose root causes
> - Propose fixes
> - Get council approval
> - Hot-load code changes
> - Verify the fix worked
>
> All with capability-based security and governance.
> Self-healing with accountability. That's Arbor."

---

## Timing Notes

| Phase | Target | Actual |
|-------|--------|--------|
| Opening | 10s | |
| Fault injection | 5s | |
| Detection | 10s | |
| Diagnosis | 10s | |
| Proposal | 5s | |
| Council review | 10s | |
| Fix + Verify | 5s | |
| **Scenario 1 Total** | **55s** | |
| Rejection demo | 30s | |
| **Total with rejection** | **85s** | |

---

## Key Talking Points

1. **Bounded reasoning** — The agent can't spin forever. It has cycle limits.

2. **Governance is real** — The council isn't rubber-stamping. It actually rejects bad proposals.

3. **Hot-loading** — The fix is applied to the running system. No restart needed.

4. **BEAM-native** — This leverages OTP's strengths: supervision trees, hot code loading, process isolation.

5. **Capability-based** — The agent only has access to what it's been granted. No ambient authority.

---

## Backup Commands

If the dashboard isn't responding, you can drive the demo from IEx:

```elixir
# Inject fault
Arbor.Demo.inject_fault(:message_queue_flood)

# Check pipeline stage
Arbor.Demo.Orchestrator.pipeline_stage()

# Force detection (if stuck)
Arbor.Demo.force_detect()

# Run full scenario programmatically
Arbor.Demo.Scenarios.run(:successful_heal, verbose: true)

# Clear and reset
Arbor.Demo.clear_all()
Arbor.Demo.Orchestrator.reset()
```
