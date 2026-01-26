# ArborEval

Code quality evaluation framework for Elixir projects.

## Features

- **Idiomatic Pattern Checks** - Detects common anti-patterns and suggests improvements
- **PII Detection** - Finds hardcoded secrets, emails, phone numbers, credit cards, SSNs
- **Documentation Coverage** - Ensures public functions have `@doc` and modules have `@moduledoc`
- **Naming Conventions** - Checks for AI-readable naming patterns
- **Library Construction Suite** - Comprehensive quality suite for Elixir libraries

## Installation

```elixir
def deps do
  [
    {:arbor_eval, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Check a single file
{:ok, results} = ArborEval.check_file("lib/my_module.ex")

# Check a directory
{:ok, results} = ArborEval.Suites.LibraryConstruction.check_directory("lib/")

# Check code directly
code = """
defmodule MyModule do
  @doc "Does something"
  def foo, do: :bar
end
"""
{:ok, results} = ArborEval.check_code(code)
```

## Available Checks

| Check | Description |
|-------|-------------|
| `ArborEval.Checks.ElixirIdioms` | Idiomatic Elixir patterns |
| `ArborEval.Checks.PIIDetection` | Secrets, PII, hardcoded paths |
| `ArborEval.Checks.Documentation` | @doc and @moduledoc coverage |
| `ArborEval.Checks.NamingConventions` | AI-readable naming patterns |

## PII Detection

Detects patterns based on [Microsoft Presidio](https://microsoft.github.io/presidio/) and [Bearer CLI](https://github.com/Bearer/bearer):

- Credit card numbers (with Luhn validation)
- US Social Security Numbers
- API keys (OpenAI, GitHub, AWS, Google, Stripe, Slack)
- Email addresses
- Phone numbers
- Hardcoded user paths
- JWT tokens
- Private keys

### Allowlist

Mark intentional patterns with comments:

```elixir
# arbor:allow pii
@test_email "test@example.com"
```

## Library Construction Suite

Run comprehensive checks on a library:

```elixir
{:ok, result} = ArborEval.Suites.LibraryConstruction.check_directory("lib/")

IO.puts("Files: #{result.files_checked}")
IO.puts("Passed: #{result.passed}")
IO.puts("Errors: #{result.summary.errors}")
IO.puts("Warnings: #{result.summary.warnings}")
```

## Writing Custom Checks

```elixir
defmodule MyCheck do
  use ArborEval,
    name: "my_check",
    category: :custom,
    description: "My custom check"

  @impl ArborEval
  def run(%{code: code, ast: ast}) do
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
