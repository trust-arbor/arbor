# Test Tagging Strategy

Guidelines for consistent test tagging across the Arbor codebase.

## Tag Dimensions

Tests are categorized along three dimensions:

### 1. Speed (affects CI parallelization)

| Tag | When to use |
|-----|-------------|
| `:fast` | Unit tests that complete in < 100ms. Use `@moduletag :fast` for test files that are entirely fast. |
| `:slow` | Tests that take > 1 second (LLM calls, network timeouts, etc.). Use `@tag :slow` on individual tests. |

### 2. Isolation Level

| Tag | When to use |
|-----|-------------|
| (none) | Pure unit tests with no external dependencies |
| `:integration` | Tests that cross module boundaries or require external resources |

### 3. External Dependencies

| Tag | When to use |
|-----|-------------|
| `:database` | Requires PostgreSQL or other database |
| `:external` | Calls external HTTP APIs (non-LLM) |
| `:llm` | Makes LLM API calls (paid, rate-limited) |

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
  @moduletag :integration
  @moduletag :database
  # ...
end

# External API integration
defmodule MyClientTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :external
  # ...
end

# LLM-based test (expensive, slow)
defmodule MyLLMTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :llm

  @tag :slow
  test "generates response" do
    # ...
  end
end

# Mixed file with one slow test
defmodule MixedTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  test "fast unit test" do
    # ...
  end

  @tag :slow
  @tag :external
  test "calls external service" do
    # ...
  end
end
```

## Test Helper Configuration

Each app's `test/test_helper.exs` should exclude tags that require setup:

```elixir
# Exclude tests that need external resources by default
ExUnit.start(exclude: [:database, :llm, :external])
```

For apps where most tests are fast units:
```elixir
ExUnit.start(exclude: [:skip])
```

## Running Tests

```bash
# Run all fast tests (default)
mix test

# Run only fast unit tests
mix test --only fast

# Include database tests (requires DB setup)
mix test --include database

# Include LLM tests (requires API keys, costs money)
mix test --include llm

# Run everything
mix test --include database --include llm --include external

# Exclude slow tests for quick feedback
mix test --exclude slow
```

## Mix Aliases

The umbrella defines these aliases:

```elixir
# mix test.fast - Run only fast unit tests
# mix test.all  - Run everything including external deps
```

## Guidelines

1. **Default to `:fast`** - Most tests should be fast unit tests
2. **Use `async: true`** when possible - Only use `async: false` for tests with shared state
3. **Tag at module level** when all tests share characteristics
4. **Tag individual tests** when only some tests have special requirements
5. **Combine tags** - A database test is both `:integration` and `:database`
6. **Document setup** - If a tag requires setup (DB, API keys), document it in the test file's `@moduledoc`
