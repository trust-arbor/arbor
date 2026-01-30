# Test Coverage Improvements

**Status:** In Progress
**Priority:** Low
**Effort:** Ongoing (pick up anytime)

## Goal

Improve test coverage across libraries, especially for edge cases and error paths.

## Progress (2026-01-30)

| Library | Before | After | Status |
|---------|--------|-------|--------|
| arbor_security | 77% | 91% | ✓ Above threshold (found 2 bugs) |
| arbor_persistence | ~52% | 98% | ✓ Above threshold (Postgres/Ecto excluded) |
| arbor_historian | 65% | 94% | ✓ Above threshold |
| arbor_signals | ~60% | 93% | ✓ Above threshold |
| arbor_shell | 69% | 91% | ✓ Above threshold |
| arbor_actions | 86% | 90% | ✓ Above threshold |
| arbor_common | 50% | 95% | ✓ Above threshold (Mix tasks excluded) |
| arbor_consensus | 66% | 91% | ✓ Above threshold (11 test helpers excluded) |
| arbor_trust | 81% | 91% | ✓ Above threshold (TestHelpers excluded) |
| arbor_checkpoint | 89% | 94% | ✓ Above threshold (test helpers excluded) |
| arbor_contracts | ~19% | ~19% | Behaviours only — low executable code |
| arbor_eval | ~85% | ~85% | Needs Documentation/Idioms checks |

### Bugs Found During Coverage Work

1. **Kernel.grant_capability/1**: MatchError — `CapabilityStore.put/1` returns `{:ok, :stored}` not `:ok`. Function crashed on every call (0% coverage).
2. **FileGuard dead code clause**: Catch-all `defp check_pattern_constraints(_path, %{patterns: patterns})` always returned `:ok`, bypassing all regex enforcement.

## Approach

1. Run coverage report to identify gaps
2. Prioritize critical paths (security, persistence, consensus)
3. Add tests incrementally

## How to Find Gaps

```bash
# Run with coverage per-app
MIX_ENV=test mix test apps/<app>/test --cover
```

## Remaining Priority Order

1. ~~**arbor_consensus**~~ - ✓ Done (66% → 91%)
2. ~~**arbor_trust**~~ - ✓ Done (81% → 91%)
3. ~~**arbor_historian**~~ - ✓ Done (65% → 94%)
4. ~~**arbor_shell**~~ - ✓ Done (86% → 91%)
5. ~~**arbor_persistence**~~ - ✓ Done (54% → 98%)
6. ~~**arbor_checkpoint**~~ - ✓ Done (89% → 94%)
7. **arbor_eval** - 85%, needs Documentation/ElixirIdioms check coverage
8. **arbor_contracts** - 19%, mostly behaviours with no executable code. Consider lower threshold or exclusions.

### ExCoveralls Blocker

6 libraries have `test_coverage: [tool: ExCoveralls]` in mix.exs but ExCoveralls isn't a dependency. This prevents standard `--cover` from working. Options:
- Add ExCoveralls as a dep (adds hackney dependency chain)
- Remove ExCoveralls config and use built-in cover (simpler)

## Test Isolation Issues (from 2026-01-30 audit)

Priority fixes:
1. **arbor_comms** (HIGH): `chat_logger_test.exs` and `message_handler_test.exs` use hardcoded `/tmp/arbor/` paths, forcing `async: false`. Use ActionCase pattern with unique dirs.
2. **arbor_sandbox** (HIGH): `filesystem_test.exs` and `sandbox_test.exs` share `/tmp/arbor_sandbox_test` path. Use unique paths.
3. **arbor_comms** (MEDIUM): `config_test.exs` calls `Application.put_env` without cleanup in `on_exit`.
4. **consensus/historian** (LOW): 4 files use `start_link` instead of `start_supervised!` for named processes.

Model pattern: `apps/arbor_actions/test/support/action_case.ex` (unique temp dirs + on_exit cleanup).

## Test Patterns to Add

- Error cases (invalid input, missing data)
- Boundary conditions (empty lists, nil values)
- Concurrent access (where applicable)
- Recovery scenarios

## Tagging

- Use `@moduletag :fast` for unit tests
- Use `@moduletag :integration` for tests needing full system
- Use `@tag :slow` for performance tests

## Property-Based Testing Exploration

Experiment with StreamData for property-based tests. Good candidates:
- **SafeAtom** - "any string input produces valid output without crashing"
- **SafePath** - "no input can escape the root directory"
- **Capability matching** - "prefix matching is consistent"
- **Event serialization** - "roundtrip encoding/decoding preserves data"

```elixir
# Example property test
property "SafePath.resolve_within never escapes root" do
  check all path <- string(:printable),
            root <- string(:printable, min_length: 1) do
    case SafePath.resolve_within(path, "/tmp/test/#{root}") do
      {:ok, resolved} -> assert String.starts_with?(resolved, "/tmp/test/")
      {:error, _} -> :ok  # Rejection is also safe
    end
  end
end
```

**Autonomy note:** Experiment with this approach, evaluate effectiveness, implement if results are good, document decision in `.arbor/decisions/`.

## Verification

```bash
MIX_ENV=test mix test --only fast
MIX_ENV=test mix test --cover
```
