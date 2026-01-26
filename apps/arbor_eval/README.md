# ArborEval

Code quality evaluation framework for Elixir projects.

Provides static analysis checks for:
- **Idiomatic Elixir patterns** - detects common anti-patterns
- **PII detection** - finds hardcoded paths, emails, secrets
- **Documentation coverage** - ensures modules and functions are documented
- **AI-readable naming** - checks for verbose, self-documenting names

## Installation

Add to your dependencies:

```elixir
{:arbor_eval, "~> 0.1.0"}
```

## Usage

### Check a file

```elixir
{:ok, results} = ArborEval.check_file("lib/my_module.ex")
```

### Check code directly

```elixir
code = """
defmodule MyModule do
  def foo(x) do
    if x != nil, do: x
  end
end
"""

{:ok, results} = ArborEval.check_code(code)
```

### Run specific checks

```elixir
{:ok, results} = ArborEval.run_all(
  [ArborEval.Checks.ElixirIdioms, ArborEval.Checks.Documentation],
  code: code
)
```

### Use a suite for comprehensive checking

```elixir
{:ok, result} = ArborEval.Suites.LibraryConstruction.check_directory("apps/my_lib/lib/")
```

## Available Checks

### ElixirIdioms

Detects common anti-patterns:
- Defensive nil checks (`if x != nil`)
- Nested if/else chains
- `Enum.map |> Enum.filter` (inefficient ordering)
- try/rescue for control flow
- GenServer.call without timeout
- Missing @spec on public functions

### PIIDetection

Finds potential PII:
- Hardcoded user paths (`/Users/name/`, `/home/name/`)
- Email addresses
- Phone numbers
- API keys and secrets
- IP addresses

Use `# arbor:allow pii` comments to allowlist intentional patterns.

### Documentation

Ensures documentation coverage:
- @moduledoc on modules
- @doc on public functions
- Configurable minimum doc length
- Correctly handles multi-clause functions

### NamingConventions

Checks for AI-readable naming:
- Module names shouldn't expose implementation (e.g., `HordeSupervisor`)
- Function names should be descriptive
- Flags non-standard abbreviations

## Suites

### LibraryConstruction

Comprehensive suite for new libraries:

```elixir
# Standard mode (reasonable defaults)
{:ok, result} = ArborEval.Suites.LibraryConstruction.check_directory("lib/")

# Strict mode for new code
{:ok, result} = ArborEval.Suites.LibraryConstruction.check_directory("lib/",
  strictness: :strict,
  fail_on: :warning
)
```

## Creating Custom Checks

```elixir
defmodule MyCheck do
  use ArborEval,
    name: "my_check",
    category: :code_quality,
    description: "My custom check"

  @impl ArborEval
  def run(%{ast: ast} = _context) do
    violations = analyze(ast)

    %{
      passed: Enum.empty?(violations),
      violations: violations,
      suggestions: []
    }
  end
end
```

## License

MIT
