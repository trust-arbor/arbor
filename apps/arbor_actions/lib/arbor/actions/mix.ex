defmodule Arbor.Actions.Mix do
  @moduledoc """
  Elixir `mix` task operations as Jido actions.

  Each action wraps a specific `mix` task (`test`, `quality`, `format`) as a
  capability-distinct operation rather than letting agents reach for raw
  `Shell.Execute`. The win is granularity: an agent granted
  `arbor://action/mix/test` can run tests but cannot run `mix deps.update`,
  whereas raw shell access would conflate them.

  All actions execute through `Arbor.Shell` with `:basic` sandboxing and
  emit `Arbor.Signals` events for observability.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Test` | Run `mix test` (optionally with paths/args) |
  | `Quality` | Run `mix quality` (format-check + credo) |
  | `Format` | Run `mix format` (write or check-only) |

  ## Examples

      {:ok, result} = Arbor.Actions.Mix.Test.run(%{path: "/path/to/project"}, %{})
      result.exit_code  # => 0
      result.passed?    # => true

      {:ok, result} = Arbor.Actions.Mix.Quality.run(%{path: "/path/to/project"}, %{})
      result.passed?    # => false (format issues found)
  """

  alias Arbor.Shell

  @doc false
  def mix_timeout, do: 300_000
  @doc false
  def mix_sandbox, do: :basic

  # ── Shared command runner ─────────────────────────────────────────

  @doc false
  def run_mix(path, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    command = Enum.join(["mix" | args], " ")

    case Shell.execute(command, cwd: path, timeout: timeout, sandbox: mix_sandbox()) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defmodule Test do
    @moduledoc """
    Run `mix test`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `test_paths` | list | no | Specific test files/dirs to run |
    | `tags` | string | no | `--only` tag filter (e.g. `"fast"`) |
    | `seed` | integer | no | Test seed for deterministic ordering |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |

    ## Returns

    - `path` — project path
    - `exit_code` — `mix test` exit code (0 = success)
    - `passed?` — boolean derived from exit_code
    - `stdout` — captured stdout
    - `stderr` — captured stderr
    """

    use Jido.Action,
      name: "mix_test",
      description: "Run `mix test` in a project directory",
      category: "mix",
      tags: ["mix", "test", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        test_paths: [type: {:list, :string}, doc: "Specific test paths to run"],
        tags: [type: :string, doc: "Tag filter for --only"],
        seed: [type: :non_neg_integer, doc: "Test seed"],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        test_paths: {:control, requires: [:path_traversal]},
        tags: {:control, requires: [:command_injection]},
        seed: :data,
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      args = build_args(params)
      opts = if params[:timeout], do: [timeout: params[:timeout]], else: []

      case MixAction.run_mix(path, args, opts) do
        {:ok, result} ->
          output = %{
            path: path,
            exit_code: result.exit_code,
            passed?: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed?: output.passed?})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test failed to execute: #{reason}"}
      end
    end

    defp build_args(params) do
      args = ["test"]
      args = if params[:tags], do: args ++ ["--only", params[:tags]], else: args
      args = if params[:seed], do: args ++ ["--seed", to_string(params[:seed])], else: args
      args = if params[:test_paths], do: args ++ params[:test_paths], else: args
      args
    end
  end

  defmodule Quality do
    @moduledoc """
    Run `mix quality` (the Arbor-wide format-check + credo --strict alias
    defined in the umbrella's mix.exs).

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |

    ## Returns

    - `path` — project path
    - `exit_code` — `mix quality` exit code (0 = passed all checks)
    - `passed?` — boolean derived from exit_code
    - `stdout` / `stderr` — captured output
    """

    use Jido.Action,
      name: "mix_quality",
      description: "Run `mix quality` (format-check + credo)",
      category: "mix",
      tags: ["mix", "quality", "lint", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        timeout: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      opts = if params[:timeout], do: [timeout: params[:timeout]], else: []

      case MixAction.run_mix(path, ["quality"], opts) do
        {:ok, result} ->
          output = %{
            path: path,
            exit_code: result.exit_code,
            passed?: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed?: output.passed?})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix quality failed to execute: #{reason}"}
      end
    end
  end

  defmodule Format do
    @moduledoc """
    Run `mix format`. Default mode rewrites files; `check_only: true` runs
    `mix format --check-formatted` and reports drift without writing.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `check_only` | boolean | no | `--check-formatted` mode (default false) |
    | `files` | list | no | Specific files/globs to format |

    ## Returns

    - `path` — project path
    - `exit_code` — exit code (0 = clean / formatted, non-zero = drift in check_only mode)
    - `passed?` — boolean (always true in write mode unless mix itself failed)
    - `stdout` / `stderr` — captured output
    """

    use Jido.Action,
      name: "mix_format",
      description: "Run `mix format` (write or check-only)",
      category: "mix",
      tags: ["mix", "format", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        check_only: [type: :boolean, default: false, doc: "Check-only mode"],
        files: [type: {:list, :string}, doc: "Specific files/globs"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        check_only: :control,
        files: {:control, requires: [:path_traversal]}
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      args = build_args(params)

      case MixAction.run_mix(path, args) do
        {:ok, result} ->
          output = %{
            path: path,
            exit_code: result.exit_code,
            passed?: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed?: output.passed?})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix format failed to execute: #{reason}"}
      end
    end

    defp build_args(params) do
      args = ["format"]
      args = if params[:check_only], do: args ++ ["--check-formatted"], else: args
      args = if params[:files], do: args ++ params[:files], else: args
      args
    end
  end
end
