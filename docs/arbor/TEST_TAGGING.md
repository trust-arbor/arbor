# Test Tagging Strategy

Guidelines for consistent test tagging across the Arbor codebase.

## Tags Reference

### Speed

| Tag | When to use |
|-----|-------------|
| `:fast` | Unit tests that complete in < 100ms. Use `@moduletag :fast` for test files that are entirely fast. |
| `:slow` | Tests that take > 1 second (network timeouts, large computations). Use `@tag :slow` on individual tests. |

### Isolation Level

| Tag | When to use |
|-----|-------------|
| (none) | Pure unit tests with no external dependencies |
| `:integration` | Tests that cross app boundaries or require external resources |
| `:behavioral` | End-to-end behavioral tests using `BehavioralCase`. See below. |

### External Dependencies

| Tag | When to use |
|-----|-------------|
| `:database` | Requires PostgreSQL (or pgvector) |
| `:external` | Requires external services or CLI binaries (e.g., Claude CLI) |
| `:llm` | Makes cloud LLM API calls (costs money, rate-limited). **Excluded by default in all apps.** |
| `:llm_local` | Requires a local LLM server (LM Studio, Ollama). Free but needs setup. **Excluded by default in all apps.** |

### Decision Guide: `:llm` vs `:llm_local` vs `:external`

| Scenario | Tag |
|----------|-----|
| Calls OpenAI, Anthropic, Gemini, or any cloud API | `:llm` |
| Calls Ollama or LM Studio on localhost | `:llm_local` |
| Calls a non-LLM external service (HTTP API, CLI tool) | `:external` |
| Mock/stub LLM that doesn't make real calls | No tag needed |

## Common Patterns

```elixir
# Pure unit test (most common)
defmodule MyModuleTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  # ...
end

# Database integration test
defmodule MyRepoTest do
  use ExUnit.Case, async: false
  @moduletag :database
  # ...
end

# Cloud LLM test (costs money)
defmodule MyLLMTest do
  use ExUnit.Case, async: false
  @moduletag :llm
  # ...
end

# Local LLM test (needs Ollama/LM Studio running)
defmodule MyLocalLLMTest do
  use ExUnit.Case, async: false
  @moduletag :llm_local
  # ...
end

# Behavioral test (using BehavioralCase)
defmodule MyBehavioralTest do
  use Arbor.Test.BehavioralCase, async: false
  @moduletag :behavioral
  # ...
end

# End-to-end memory test (behavioral + LLM)
defmodule MemoryE2ETest do
  use Arbor.Test.BehavioralCase, async: false
  @moduletag :behavioral
  @moduletag :llm
  # ...
end
```

## Test Helper Configuration

Every app's `test/test_helper.exs` **must** exclude `:llm` and `:llm_local`:

```elixir
# Minimal (apps with no other exclusions)
ExUnit.start(exclude: [:llm, :llm_local])

# With existing exclusions (add to the list)
ExUnit.start(exclude: [:skip, :integration, :external, :llm, :llm_local])

# With ExUnit.configure (arbor_memory pattern)
ExUnit.configure(exclude: [:database, :llm, :llm_local])
ExUnit.start()
```

## Running Tests

```bash
# Default — runs unit tests, excludes LLM/database/integration
mix test

# Fast unit tests only
mix test.fast

# Include cloud LLM tests (requires API keys, costs money)
mix test --include llm

# Include local LLM tests (requires Ollama/LM Studio)
mix test --include llm_local

# Include database tests
mix test --include database

# Run everything (all tags included)
mix test.all

# Run only behavioral tests
mix test --only behavioral

# Run a specific LLM test file
mix test apps/arbor_agent/test/behavioral/memory_e2e_test.exs --include llm
```

## Behavioral Tests

Behavioral tests use `Arbor.Test.BehavioralCase` which starts the full process tree
(5 apps in dependency order). They test cross-boundary integration.

- Tag with `@moduletag :behavioral`
- Always `async: false` (shared process state)
- If they call real LLMs, also tag with `:llm` or `:llm_local`
- Run with `mix test --only behavioral`

Available assertion helpers from `Arbor.Test.LLMAssertions`:
- `assert_llm_response/1` — validates response struct shape
- `assert_has_text/1` — confirms non-empty text field

## Guidelines

1. **Default to `:fast`** - Most tests should be fast unit tests
2. **Use `async: true`** when possible - Only use `async: false` for tests with shared state
3. **Tag at module level** when all tests share characteristics
4. **Tag individual tests** when only some tests have special requirements
5. **Always tag LLM tests** - Never leave a cloud LLM test untagged; it will run on every `mix test`
6. **Document setup** - If a tag requires setup (DB, API keys, Ollama), document it in the test file's `@moduledoc`
