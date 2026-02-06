# Arbor Demo Fallback Plan

What to do when things go wrong during the conference demo.

---

## Quick Reference Table

| Failure | Symptom | Recovery |
|---------|---------|----------|
| API timeout | Diagnose stage stuck >15s | Automatic switch to Ollama. Say "Switching to local model..." |
| Monitor not detecting | Detect stage stuck | `Arbor.Demo.force_detect()` in IEx |
| Council hung | Review stage stuck >20s | `Arbor.Demo.Scenarios.run(:successful_heal)` to reset and retry |
| Hot-load fails | Fix stage shows error | "Even failure is instructive—the rollback worked" |
| Total catastrophe | Dashboard unresponsive | Switch to slides with screenshots |

---

## Detailed Recovery Procedures

### 1. API Timeout (LLM Diagnosis Stuck)

**Symptom:** Diagnose stage shows "Analyzing..." for more than 15 seconds.

**Automatic Recovery:**
The system should automatically switch to Ollama (local LLM) after 5 seconds.
If fallback is enabled, you'll see a signal `ai.fallback_activated` in the logs.

**Manual Recovery:**
```elixir
# Check fallback status
Arbor.AI.Fallback.status()

# Force Ollama directly
Arbor.AI.Fallback.generate_via_ollama("Analyze this anomaly", model: "llama3")

# If Ollama isn't running
System.cmd("ollama", ["serve"], into: IO.stream())
```

**Talking Point:**
> "Conference WiFi is always fun. The system just switched to a local model—
> this is why we built offline fallback."

---

### 2. Monitor Not Detecting

**Symptom:** Fault injected but Detect stage doesn't highlight.

**Causes:**
- Monitor not running
- Poll interval too long
- Fault didn't inject properly

**Recovery:**
```elixir
# Check if fault is active
Arbor.Demo.active_faults()

# Force detection signal
Arbor.Demo.force_detect()

# Or emit the signal manually
Arbor.Signals.emit(:monitor, :anomaly_detected, %{
  type: :message_queue_flood,
  severity: :high,
  timestamp: System.system_time(:millisecond)
})
```

---

### 3. Council Review Stuck

**Symptom:** Review stage shows evaluator names but no votes appear.

**Causes:**
- Evaluator timeout
- LLM evaluator waiting on API
- Configuration issue

**Recovery:**
```elixir
# Check council status
Arbor.Consensus.Coordinator.status()

# Skip and show recorded demo
# (pre-record a successful run as backup)

# Or reset and retry with fast timing
Arbor.Demo.clear_all()
Arbor.Demo.Orchestrator.reset()
Arbor.Demo.Timing.set(:fast)
Arbor.Demo.Scenarios.run(:successful_heal, verbose: true)
```

**Talking Point:**
> "The council is taking its time—security reviews shouldn't be rushed.
> Let me show you what happens next..."
> *(switch to pre-recorded video if needed)*

---

### 4. Hot-Load Failure

**Symptom:** Fix stage shows error, verification fails.

**This is actually okay!** The fix being rejected by the BEAM is a safety feature.

**Talking Point:**
> "The hot-load failed—that's actually the safety system working.
> The proposed code change was syntactically valid but the BEAM
> rejected it at load time. Watch the automatic rollback."

**Recovery:**
```elixir
# Show the rollback happened
Arbor.Demo.Orchestrator.pipeline_stage()  # Should show :fix_failed

# Clear and try a different fault
Arbor.Demo.clear_all()
Arbor.Demo.inject_fault(:process_leak)  # This one usually succeeds
```

---

### 5. Dashboard Unresponsive

**Symptom:** Dashboard doesn't load or stops updating.

**Recovery Options:**

1. **Refresh browser** — Sometimes WebSocket disconnects

2. **Restart dashboard:**
   ```elixir
   # In IEx
   Supervisor.restart_child(Arbor.Dashboard.Supervisor, Arbor.Dashboard.Endpoint)
   ```

3. **Run from terminal instead:**
   ```elixir
   # Full rehearsal with console output
   Arbor.Demo.Scenarios.rehearsal(verbose: true)
   ```

4. **Switch to slides** — Have screenshots of each pipeline stage ready

---

### 6. Total System Failure

**Symptom:** IEx crashes, nothing responds.

**Recovery:**

1. **Restart IEx:**
   ```bash
   cd apps/arbor_demo
   iex -S mix
   ```

2. **Start minimal system:**
   ```elixir
   Arbor.Demo.Application.start(:normal, [])
   ```

3. **If all else fails:**
   - Switch to pre-recorded video
   - Show slides with architecture diagrams
   - Walk through the code manually

---

## Pre-Conference Testing Checklist

Run this 30 minutes before the talk:

```elixir
# 1. Check all systems
Arbor.Demo.Scenarios.rehearsal(verbose: true)

# 2. Verify Ollama fallback
Arbor.AI.Fallback.status()
Arbor.AI.Fallback.generate_via_ollama("test", model: "llama3")

# 3. Test timing modes
Arbor.Demo.Timing.set(:fast)
Arbor.Demo.Scenarios.run(:successful_heal)

Arbor.Demo.Timing.set(:normal)
Arbor.Demo.Scenarios.run(:rejected_fix)

# 4. Clear state
Arbor.Demo.clear_all()
Arbor.Demo.Orchestrator.reset()
```

---

## Video Backup

Record a successful demo run before the conference:

```bash
# macOS
# Use QuickTime or OBS to screen record

# Save to: ~/Desktop/arbor-demo-backup.mp4
```

**Video should show:**
1. Starting state (empty pipeline)
2. Successful heal (message_queue_flood)
3. Rejection (supervisor_crash)
4. Final state

---

## Emergency Contact

If something catastrophic happens and you need help:

1. Check the Arbor Discord/Slack
2. The system logs are at `~/.arbor/logs/`
3. Signal logs at `~/.arbor/logs/signal_chat/`

---

## Mindset

Remember:
- Demos fail. It's part of live coding.
- The audience is sympathetic—they've all been there.
- A graceful recovery is more impressive than perfection.
- "The demo gods are fickle" is always a valid excuse.

The worst case is also a learning moment:
> "This is why we build fallback systems. Let me show you how the
> recovery works..."
