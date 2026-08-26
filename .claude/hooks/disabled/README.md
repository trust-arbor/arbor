# Disabled hooks — the `claude.*` telemetry feed (parked 2026-08-06)

These ten scripts are the **write side** of a harness→Arbor telemetry feed.
They are intact and working. They are parked here, not deleted, and they are
deliberately **not** registered in `.claude/settings.json`.

## What they are

Each POSTs a Claude Code lifecycle event to
`$ARBOR_GATEWAY/api/signals/claude/<type>`:

| Script | Claude Code event | Endpoint |
|---|---|---|
| `signal_session_start.sh` | SessionStart | `claude/session_start` |
| `signal_session_end.sh` | SessionEnd | `claude/session_end` |
| `signal_user_prompt.sh` | UserPromptSubmit | `claude/user_prompt` |
| `signal_pre_tool_use.sh` | PreToolUse | `claude/pre_tool_use` |
| `signal_tool_used.sh` | PostToolUse | `claude/tool_used` |
| `signal_permission_request.sh` | (permission prompt) | `claude/permission_request` |
| `signal_notification.sh` | Notification | `claude/notification` |
| `signal_idle.sh` | (idle) | `claude/idle` |
| `signal_subagent_stop.sh` | SubagentStop | `claude/subagent_stop` |
| `signal_pre_compact.sh` | PreCompact | `claude/pre_compact` |

The receiving end is **built and live**:
`apps/arbor_gateway/lib/arbor/gateway/signals/router.ex` mounts `/api/signals`,
allowlists these ten types via `SafeAtom.to_allowed/2`, and emits
`Arbor.Signals.emit(:claude, type, payload)`.

## Why they are parked

**Nothing in the umbrella subscribes to `claude.*`** (verified by grep,
2026-08-06). Registering them would wire a producer with no reader — the exact
failure mode documented in
`.arbor/roadmap/2-planned/earned-trust-feedback-loop.md`, where
`award_trust_points` had no live callers, decay ran anyway, and nothing read the
score for a decision. An orphaned metric that only accumulates is worse than no
metric. It would also add a `curl` to every single tool call for no benefit.

Deleting them is also wrong: this is the natural feed for the usage-telemetry
sidecar and the trace-to-dataset path
(`.arbor/roadmap/0-inbox/continuous-evaluation-to-standing-gates.md`), and the
allowlisted endpoint already exists.

They were discovered orphaned during the 2026-08-06 self-improvement-systems
audit — tracked, executable, and documented as "the Body's sensory layer",
registered in no settings file, firing on nothing since 2026-01.

## To re-enable

Do these together, never the producer alone:

0. Give the scripts a credential. Since `15e3d4966` (2026-02-07) every `/api/*`
   route on the gateway requires signed-request or JWT auth; an unauthenticated
   `curl` gets `401 Missing API key`. This is exactly how the old
   `arbor_bridge_authorize.sh` PreToolUse hook silently died — it read the 401
   body as "no decision" and passed every tool call through for months
   (found and removed 2026-08-26). Route these through `mix arbor.signer`-style
   signing or a scoped API key, and make a non-2xx response *visible*.

1. Build a consumer that subscribes to `claude.*` and does something a human
   can observe.
2. Add `--max-time 2` to every `curl` here. They currently have no timeout; a
   hung gateway would stall every tool call.
3. Move the scripts back to `.claude/hooks/` and register them under the
   matching hook events in `.claude/settings.json`.

`signal_send.sh` is **not** part of this feed — it is a `signal-cli` messenger
utility invoked by hand, and it stays in `.claude/hooks/`.
