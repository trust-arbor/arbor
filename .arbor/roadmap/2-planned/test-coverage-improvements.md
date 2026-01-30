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
| arbor_persistence | ~52% | ~63% | Partial improvement |
| arbor_signals | ~60% | ~85% | ✓ Significant improvement |
| arbor_shell | 69% | 86% | Below threshold (kill feature incomplete) |
| arbor_actions | 86% | 90% | ✓ Above threshold |
| arbor_common | 50% | 95% | ✓ Above threshold (Mix tasks excluded) |

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

1. **arbor_consensus** - Blocked: ExCoveralls configured but not installed
2. **arbor_trust** - Blocked: ExCoveralls configured but not installed
3. **arbor_historian** - Blocked: ExCoveralls configured but not installed
4. **arbor_shell** - 86%, needs kill feature fix for port tracking
5. **arbor_persistence** - ~63%, needs QueryableStore improvements

### ExCoveralls Blocker

6 libraries have `test_coverage: [tool: ExCoveralls]` in mix.exs but ExCoveralls isn't a dependency. This prevents standard `--cover` from working. Options:
- Add ExCoveralls as a dep (adds hackney dependency chain)
- Remove ExCoveralls config and use built-in cover (simpler)

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
