# Changelog

## Unreleased

### Security

**DEFAULT CHANGE (2026-10-29).** Strict-mode taint now gates send-capable tools
after untrusted or external tool output enters context. This is a fail-closed
behavior change, independent of the still-dark
`config :arbor_security, :egress_gate_enforcing` flag.

- External MCP tool descriptions are flattened (newlines and control characters
  stripped), length-capped, and wrapped in an `UNTRUSTED` label that names the
  originating server before they enter a prompt.
- `Arbor.LLM.ToolLoop` raises `tool_taint` whenever a tool result from an
  untrusted or external source (MCP `mcp.*`, `source: :mcp`/`:external`, or an
  already-untrusted result envelope) enters context.
- `Arbor.AI.generate_text_with_tools/2` forwards `:tools`, `:tool_executor`, and
  taint into ToolLoop. Unlabeled calls are no longer treated as clean.
- The gateway MCP success path keeps the `UNTRUSTED` label instead of stripping
  `ToolBridge.taint_result/3` down to the inner value.
- Send-capable tools (email, HTTP POST, messaging, `comms_send_message`) are
  refused under taint (`CallFailure` `:refused`).

**Explicit opt-out:**

```elixir
config :arbor_llm, :strict_taint_send_gate, false
config :arbor_ai, :allow_untainted_tool_calls, true
```

Per-call opt-out for `generate_text_with_tools/2`: `allow_untainted: true`.
