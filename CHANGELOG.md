# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Security

**DEFAULT CHANGE (2026-10-29, Exposure Check item AB):** Arbor no longer
launches Codex in the adapter's built-in `agent` mode
(`approvalsReviewer: auto_review`). The default Codex `mode_id` is now
`"read-only"`, which maps to `approvalPolicy: on-request` and
`approvalsReviewer: user`. Every Codex approval request (commands, file
writes, network) is routed to `Arbor.AI.AcpSession.Handler` and decided
by Arbor's capability and trust system. Codex's own AI reviewer and
auto-approve stay off. Arbor's decision is final. If Arbor security is
unreachable, the request is denied.

`agent` and `agent-full-access` are refused unless the caller sets the
explicit opt-out:

- adapter option: `allow_builtin_approval_reviewer: true`
- application env: `config :arbor_ai, :codex_allow_builtin_approval_reviewer, true`
