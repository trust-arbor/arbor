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
  | `Compile` | Run `mix compile` (optionally with warnings-as-errors) |
  | `Test` | Run `mix test` (optionally with paths/args) |
  | `Quality` | Run `mix quality` (format-check + credo) |
  | `Format` | Run `mix format` (write or check-only) |

  ## Examples

      {:ok, result} = Arbor.Actions.Mix.Test.run(%{path: "/path/to/project"}, %{})
      result.exit_code  # => 0
      result.passed    # => true

      {:ok, result} = Arbor.Actions.Mix.Quality.run(%{path: "/path/to/project"}, %{})
      result.passed    # => false (format issues found)
  """

  alias Arbor.Shell
  alias Arbor.Common.SafePath

  @compile_feedback_text_limit 2_000
  @excerpt_omission_marker "\n...[omitted]...\n"

  @doc false
  def mix_timeout, do: 300_000
  @doc false
  def mix_sandbox, do: :basic

  @doc false
  def compile_feedback_text_limit, do: @compile_feedback_text_limit

  @doc false
  def compile_feedback(%{exit_code: exit_code, stdout: stdout, stderr: stderr}) do
    stdout = stdout || ""
    stderr = stderr || ""

    %{
      "exit_code" => exit_code,
      "passed" => exit_code == 0,
      "stdout_excerpt" => bounded_excerpt(stdout),
      "stderr_excerpt" => bounded_excerpt(stderr),
      "stdout_truncated" => String.length(stdout) > @compile_feedback_text_limit,
      "stderr_truncated" => String.length(stderr) > @compile_feedback_text_limit,
      "stdout_sha256" => sha256(stdout),
      "stderr_sha256" => sha256(stderr)
    }
  end

  defp bounded_excerpt(text) do
    if String.length(text) <= @compile_feedback_text_limit do
      text
    else
      available = @compile_feedback_text_limit - String.length(@excerpt_omission_marker)
      head_length = div(available, 2)
      tail_length = available - head_length

      String.slice(text, 0, head_length) <>
        @excerpt_omission_marker <>
        String.slice(text, -tail_length, tail_length)
    end
  end

  defp sha256(output) do
    :crypto.hash(:sha256, output) |> Base.encode16(case: :lower)
  end

  # ── Shared command runner ─────────────────────────────────────────

  @doc false
  def run_mix(path, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, mix_timeout())
    executable = mix_executable(path)

    shared_env =
      shared_host_mix_env(path,
        share_build_path: Keyword.get(opts, :share_build_path, true)
      )

    # A project's preferred_envs can override Mix's built-in test default.
    # Explicit caller isolation still wins, including MIX_ENV overrides used
    # by the security-regression runner.
    env =
      shared_env
      |> Map.merge(default_mix_env(args))
      |> Map.merge(Keyword.get(opts, :env, %{}))

    # argv-safe: absolute worktree paths can contain spaces; never join into a
    # single shell string. Sandbox policy still sees basename "mix" + args.
    shell_opts = [
      cwd: path,
      timeout: timeout,
      sandbox: mix_sandbox(),
      env: env
    ]

    case Shell.execute_direct(executable, args, shell_opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp default_mix_env(["test" | _args]), do: %{"MIX_ENV" => "test"}
  defp default_mix_env(_args), do: %{}

  @doc false
  # Point temporary worktrees at the main checkout's deps and, by default,
  # _build so ordinary validation does not require a fresh setup in every
  # worktree. Security-sensitive callers disable build sharing and provide an
  # isolated MIX_BUILD_PATH explicitly.
  def shared_host_mix_env(path, opts \\ [])

  def shared_host_mix_env(path, opts) when is_binary(path) and is_list(opts) do
    case main_checkout_root(path) do
      {:ok, main} ->
        main = Path.expand(main)
        work = Path.expand(path)

        if main != work do
          env = maybe_put_env_dir(%{}, "MIX_DEPS_PATH", Path.join(main, "deps"))

          if Keyword.get(opts, :share_build_path, true) do
            maybe_put_env_dir(env, "MIX_BUILD_PATH", Path.join(main, "_build"))
          else
            env
          end
        else
          %{}
        end

      :error ->
        %{}
    end
  end

  def shared_host_mix_env(_path, _opts), do: %{}

  defp maybe_put_env_dir(env, key, path) do
    if File.dir?(path), do: Map.put(env, key, path), else: env
  end

  defp main_checkout_root(path) do
    case Arbor.Actions.Git.execute(path, ["rev-parse", "--show-toplevel"]) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        top = String.trim(output)

        # For linked worktrees, prefer the common main worktree (the one that
        # owns the shared .git directory and typically has deps/_build).
        case Arbor.Actions.Git.execute(path, ["worktree", "list", "--porcelain"]) do
          {:ok, %{exit_code: 0, stdout: list}} ->
            case first_worktree_path(list) do
              main when is_binary(main) and main != "" -> {:ok, main}
              _ -> {:ok, top}
            end

          _ ->
            {:ok, top}
        end

      _ ->
        :error
    end
  end

  defp first_worktree_path(porcelain) do
    porcelain
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "worktree " <> path -> path
      _ -> nil
    end)
  end

  defp mix_executable(path) do
    _ = path
    # Project-local wrappers are candidate-controlled code. The Shell resolver
    # binds `mix` to the operator's startup-pinned executable identity instead.
    "mix"
  end

  defmodule Compile do
    @moduledoc """
    Run `mix compile`.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Project root |
    | `warnings_as_errors` | boolean | no | Pass `--warnings-as-errors` |
    | `timeout` | integer | no | Command timeout in ms (default 5 min) |
    """

    use Jido.Action,
      name: "mix_compile",
      description: "Run `mix compile` in a project directory",
      category: "mix",
      tags: ["mix", "compile", "elixir"],
      schema: [
        path: [type: :string, required: true, doc: "Project root path"],
        warnings_as_errors: [
          type: :boolean,
          default: false,
          doc: "Treat compiler warnings as errors"
        ],
        timeout: [type: :non_neg_integer, doc: "Command timeout in ms"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Mix, as: MixAction

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        warnings_as_errors: :control,
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
          feedback = MixAction.compile_feedback(result)

          output = %{
            path: path,
            exit_code: result.exit_code,
            passed: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr,
            feedback: feedback,
            feedback_json: Jason.encode!(feedback)
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix compile failed to execute: #{reason}"}
      end
    end

    defp build_args(params) do
      args = ["compile"]

      if params[:warnings_as_errors] do
        args ++ ["--warnings-as-errors"]
      else
        args
      end
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
    - `passed` — boolean derived from exit_code (no `?` suffix so this
      can be used directly in DOT edge conditions like
      `context.exec.<node>.passed=true`)
    - `stdout` — captured stdout
    - `stderr` — captured stderr
    - `feedback` — JSON-clean bounded output excerpts, truncation flags,
      and full-output SHA-256 hashes
    - `feedback_json` — JSON serialization of `feedback`
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

      opts = if params[:timeout], do: [timeout: params[:timeout]], else: []

      with {:ok, args} <- build_args(path, params),
           {:ok, result} <- MixAction.run_mix(path, args, opts) do
        feedback = MixAction.compile_feedback(result)

        output = %{
          path: path,
          exit_code: result.exit_code,
          passed: result.exit_code == 0,
          stdout: result.stdout,
          stderr: result.stderr,
          feedback: feedback,
          feedback_json: Jason.encode!(feedback)
        }

        Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
        {:ok, output}
      else
        {:error, {:invalid_test_path, _path} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test rejected invalid test_paths: #{inspect(reason)}"}

        {:error, {:invalid_test_tag, _tag} = reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test rejected invalid tag: #{inspect(reason)}"}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "mix test failed to execute: #{reason}"}
      end
    end

    defp build_args(path, params) do
      with :ok <- validate_tag(params[:tags]),
           {:ok, test_paths} <- validate_test_paths(path, params[:test_paths]) do
        args = ["test"]
        args = if params[:tags], do: args ++ ["--only", params[:tags]], else: args
        args = if params[:seed], do: args ++ ["--seed", to_string(params[:seed])], else: args

        if test_paths == [] do
          {:ok, args}
        else
          {:ok, args ++ ["--" | test_paths]}
        end
      end
    end

    defp validate_tag(nil), do: :ok

    defp validate_tag(tag) when is_binary(tag) do
      if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_.-]*\z/, tag),
        do: :ok,
        else: {:error, {:invalid_test_tag, tag}}
    end

    defp validate_tag(tag), do: {:error, {:invalid_test_tag, tag}}

    defp validate_test_paths(_root, nil), do: {:ok, []}
    defp validate_test_paths(_root, []), do: {:ok, []}

    defp validate_test_paths(root, paths) when is_list(paths) do
      Enum.reduce_while(paths, {:ok, []}, fn test_path, {:ok, accepted} ->
        case validate_test_path(root, test_path) do
          :ok -> {:cont, {:ok, [test_path | accepted]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
        error -> error
      end
    end

    defp validate_test_paths(_root, paths), do: {:error, {:invalid_test_path, paths}}

    defp validate_test_path(root, test_path) when is_binary(test_path) do
      path_without_line = Regex.replace(~r/:\d+\z/, test_path, "")
      expanded_root = Path.expand(root)
      expanded = Path.expand(path_without_line, expanded_root)

      valid_shape? =
        Regex.match?(
          ~r/\A(?:apps\/[A-Za-z0-9_.-]+\/)?test(?:\/[A-Za-z0-9_.()&+@ -]+)*(?::\d+)?\z/,
          test_path
        )

      contained? = canonical_test_path?(expanded_root, expanded)

      if valid_shape? and contained? and File.exists?(expanded) do
        :ok
      else
        {:error, {:invalid_test_path, test_path}}
      end
    end

    defp validate_test_path(_root, test_path), do: {:error, {:invalid_test_path, test_path}}

    defp canonical_test_path?(root, path) do
      with {:ok, canonical_root} <- SafePath.resolve_real(root),
           {:ok, canonical_path} <- SafePath.resolve_real(path) do
        canonical_path == canonical_root or
          String.starts_with?(canonical_path, canonical_root <> "/")
      else
        _ -> false
      end
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
    - `passed` — boolean derived from exit_code
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
            passed: result.exit_code == 0,
            stdout: result.stdout,
            stderr: result.stderr
          }

          Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
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
    | `files` | list | no | Existing project-relative files (no options or globs) |

    ## Returns

    - `path` — project path
    - `exit_code` — exit code (0 = clean / formatted, non-zero = drift in check_only mode)
    - `passed` — boolean derived from the formatter exit status
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
        files: [
          type: {:list, :string},
          doc: "Existing project-relative files (no options or globs)"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Common.SafePath
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
    def run(%{} = params, _context) do
      with {:ok, path, args} <- build_invocation(params) do
        Actions.emit_started(__MODULE__, params)

        case MixAction.run_mix(path, args) do
          {:ok, result} ->
            output = %{
              path: path,
              exit_code: result.exit_code,
              passed: result.exit_code == 0,
              stdout: result.stdout,
              stderr: result.stderr
            }

            Actions.emit_completed(__MODULE__, %{path: path, passed: output.passed})
            {:ok, output}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "mix format failed to execute: #{reason}"}
        end
      else
        {:error, reason} ->
          {:error, "mix format rejected invalid invocation: #{inspect(reason)}"}
      end
    end

    def run(_params, _context),
      do: {:error, "mix format rejected invalid invocation: :invalid_format_params"}

    defp build_invocation(params) do
      with :ok <- validate_option_keys(params),
           {:ok, path} <- validate_root(params[:path]),
           {:ok, check_only} <- validate_check_only(Map.get(params, :check_only, false)),
           {:ok, files} <- validate_files(path, Map.get(params, :files)) do
        options = if check_only, do: ["--check-formatted"], else: []
        file_args = if files == [], do: [], else: ["--" | files]
        {:ok, path, ["format"] ++ options ++ file_args}
      end
    end

    defp validate_option_keys(params) do
      if Enum.all?(Map.keys(params), &(&1 in [:path, :check_only, :files])),
        do: :ok,
        else: {:error, :unsupported_format_option}
    end

    defp validate_root(path) when is_binary(path) and path != "" do
      case SafePath.resolve_real(path) do
        {:ok, canonical} ->
          if File.dir?(canonical), do: {:ok, canonical}, else: {:error, :invalid_format_root}

        _other ->
          {:error, :invalid_format_root}
      end
    end

    defp validate_root(_path), do: {:error, :invalid_format_root}

    defp validate_check_only(value) when is_boolean(value), do: {:ok, value}
    defp validate_check_only(_value), do: {:error, :invalid_check_only}

    defp validate_files(_root, nil), do: {:ok, []}
    defp validate_files(_root, []), do: {:ok, []}

    defp validate_files(root, files) when is_list(files) do
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, accepted} ->
        case validate_file(root, file) do
          :ok -> {:cont, {:ok, [file | accepted]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
        error -> error
      end
    end

    defp validate_files(_root, _files), do: {:error, :invalid_format_files}

    defp validate_file(root, file) when is_binary(file) do
      components = Path.split(file)

      valid_shape? =
        file != "" and byte_size(file) <= 4_096 and String.valid?(file) and
          not String.contains?(file, [<<0>>, "\n", "\r", "\\"]) and
          not Regex.match?(~r/[\x00-\x1F\x7F]/u, file) and
          not String.starts_with?(file, "-") and Path.type(file) == :relative and
          Enum.all?(components, &(&1 not in ["", ".", ".."])) and
          Regex.match?(~r/\A[A-Za-z0-9_.()&+@ -]+(?:\/[A-Za-z0-9_.()&+@ -]+)*\z/, file)

      candidate = Path.expand(file, root)

      with true <- valid_shape?,
           {:ok, canonical} <- SafePath.resolve_real(candidate),
           true <- canonical == root or String.starts_with?(canonical, root <> "/"),
           true <- File.regular?(canonical) do
        :ok
      else
        _other -> {:error, {:invalid_format_file, file}}
      end
    end

    defp validate_file(_root, file), do: {:error, {:invalid_format_file, file}}
  end
end
