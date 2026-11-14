# Changelog

## Unreleased

### Changed

**DEFAULT CHANGE (taint labeling):** `Arbor.Actions.File.Read` and
`File.Search` now label content `:untrusted` when the canonical
(symlink-resolved) path sits outside every configured
`trusted_file_roots`. Previously only a path-string heuristic (`/tmp`,
secrets, downloads) applied, so ordinary out-of-root file, web-adjacent,
and tool reads entered context unlabeled and were treated as trusted
input.

- Empty `trusted_file_roots` is fail-closed: every file read is outside
  the roots and is labeled `:untrusted`.
- In-root reads still assert no provenance (`nil`) rather than laundering
  the bytes to `:trusted`.
- The heuristic still raises taint for foreign/shared/sensitive path
  fragments even when those files sit inside a trusted root.

**Explicit opt-out:**

```elixir
config :arbor_actions, taint_file_reads_outside_trusted_roots: false
```

That restores the heuristic-only labeling. Operators who want in-repo
reads to stay unlabeled must also set `trusted_file_roots` to the
canonical workspace/repo paths.
