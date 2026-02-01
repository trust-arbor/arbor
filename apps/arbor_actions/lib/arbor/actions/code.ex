defmodule Arbor.Actions.Code do
  @moduledoc """
  Code verification operations as Jido actions.

  This module provides Jido-compatible actions for code compilation, testing,
  and hot-loading. These let agents verify fixes before proposing them.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `CompileAndTest` | Compile and run tests in agent worktree (safe) |
  | `HotLoad` | Hot-load a module with auto-rollback (heavily gated) |

  ## Safety Levels

  - **CompileAndTest**: Safe — runs in agent's own worktree, nothing touches the running VM
  - **HotLoad**: Powerful — requires `arbor://code/hot_load/{module}` capability and high trust tier

  ## Examples

      # Safe: compile and test in worktree
      {:ok, result} = Arbor.Actions.Code.CompileAndTest.run(
        %{file: "lib/my_module.ex", test_files: ["test/my_module_test.exs"]},
        %{worktree_path: "/path/to/agent/worktree"}
      )

      # Powerful: hot-load with rollback
      {:ok, result} = Arbor.Actions.Code.HotLoad.run(
        %{
          module: "MyModule",
          source: "defmodule MyModule do ... end",
          verify_fn: "MyModule.health_check/0"
        },
        %{}
      )

  ## Authorization

  - CompileAndTest: `arbor://actions/execute/code.compile_and_test`
  - HotLoad: `arbor://code/hot_load/{module}` (requires Trusted tier or above)
  """

  defmodule CompileAndTest do
    @moduledoc """
    Compile and run tests in the agent's worktree.

    This is the safe verification path — nothing touches the running VM.
    The agent compiles in its own worktree and runs `mix test` there.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `file` | string | yes | Path to the modified file (relative to worktree) |
    | `test_files` | list | no | Test files to run (relative paths) |
    | `compile_only` | boolean | no | Only compile, don't run tests (default: false) |
    | `worktree_path` | string | no | Path to worktree (uses context if not specified) |

    ## Returns

    - `compiled` - Whether compilation succeeded
    - `tests_passed` - Whether all tests passed (nil if compile_only)
    - `test_output` - Test output (if tests were run)
    - `warnings` - List of compilation warnings
    - `errors` - List of compilation errors (if failed)
    """

    use Jido.Action,
      name: "code_compile_and_test",
      description: "Compile and run tests in the agent's worktree",
      category: "code",
      tags: ["code", "compile", "test", "verify"],
      schema: [
        file: [
          type: :string,
          required: true,
          doc: "Path to the modified file (relative to worktree)"
        ],
        test_files: [
          type: {:list, :string},
          default: [],
          doc: "Test files to run (relative paths)"
        ],
        compile_only: [
          type: :boolean,
          default: false,
          doc: "Only compile, don't run tests"
        ],
        worktree_path: [
          type: :string,
          doc: "Path to worktree (uses context if not specified)"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{file: file} = params, context) do
      worktree = params[:worktree_path] || Map.get(context, :worktree_path)

      if is_nil(worktree) do
        {:error, "worktree_path required in params or context"}
      else
        do_run(file, params, worktree)
      end
    end

    defp do_run(file, params, worktree) do
      compile_only = params[:compile_only] || false
      test_files = params[:test_files] || []

      Actions.emit_started(__MODULE__, %{file: file, worktree: worktree})

      # First, compile the project
      compile_result = run_compile(worktree)

      case compile_result do
        {:ok, warnings} ->
          if compile_only do
            result = %{
              compiled: true,
              tests_passed: nil,
              test_output: nil,
              warnings: warnings,
              errors: []
            }

            Actions.emit_completed(__MODULE__, %{compiled: true})
            {:ok, result}
          else
            # Run tests
            run_tests(worktree, test_files, warnings)
          end

        {:error, errors, warnings} ->
          result = %{
            compiled: false,
            tests_passed: nil,
            test_output: nil,
            warnings: warnings,
            errors: errors
          }

          Actions.emit_failed(__MODULE__, "Compilation failed")
          {:ok, result}
      end
    end

    defp run_compile(worktree) do
      case System.cmd("mix", ["compile", "--warnings-as-errors"],
             cd: worktree,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          warnings = extract_warnings(output)
          {:ok, warnings}

        {output, _} ->
          errors = extract_errors(output)
          warnings = extract_warnings(output)
          {:error, errors, warnings}
      end
    end

    defp run_tests(worktree, test_files, warnings) do
      # Build test command
      test_args =
        case test_files do
          [] -> ["test"]
          files -> ["test" | files]
        end

      case System.cmd("mix", test_args, cd: worktree, stderr_to_stdout: true) do
        {output, 0} ->
          result = %{
            compiled: true,
            tests_passed: true,
            test_output: truncate(output, 5000),
            warnings: warnings,
            errors: []
          }

          Actions.emit_completed(__MODULE__, %{compiled: true, tests_passed: true})
          {:ok, result}

        {output, _} ->
          result = %{
            compiled: true,
            tests_passed: false,
            test_output: truncate(output, 5000),
            warnings: warnings,
            errors: []
          }

          Actions.emit_completed(__MODULE__, %{compiled: true, tests_passed: false})
          {:ok, result}
      end
    end

    defp extract_warnings(output) do
      output
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.contains?(&1, "warning:"))
      |> Enum.take(20)
    end

    defp extract_errors(output) do
      output
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&(String.contains?(&1, "error:") or String.contains?(&1, "** (")))
      |> Enum.take(20)
    end

    defp truncate(str, max) when byte_size(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    end

    defp truncate(str, _max), do: str
  end

  defmodule HotLoad do
    @moduledoc """
    Hot-load a module into the running VM with automatic rollback.

    This is a powerful action that requires high trust and specific capabilities.
    It saves the current module beam binary, compiles new source, runs a
    verification function, and rolls back if verification fails.

    ## Security

    - Requires `arbor://code/hot_load/{module}` capability
    - Requires Trusted tier or above
    - Cannot hot-load protected modules (security, persistence, kernel)
    - All attempts are logged to EventLog permanently

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `module` | string | yes | Module name to hot-load |
    | `source` | string | yes | New source code (or path to file) |
    | `verify_fn` | string | no | MFA string to call after loading (e.g., "MyModule.health_check/0") |
    | `rollback_timeout_ms` | integer | no | Auto-rollback timeout (default: 30000) |

    ## Returns

    - `loaded` - Whether the module was loaded
    - `verification_passed` - Whether verify_fn succeeded
    - `rolled_back` - Whether rollback occurred
    - `output` - Any output from compilation or verification
    """

    use Jido.Action,
      name: "code_hot_load",
      description: "Hot-load a module with automatic rollback on failure",
      category: "code",
      tags: ["code", "hot_load", "dangerous", "rollback"],
      schema: [
        module: [
          type: :string,
          required: true,
          doc: "Module name to hot-load (e.g., 'MyApp.SomeModule')"
        ],
        source: [
          type: :string,
          required: true,
          doc: "New source code string or path to source file"
        ],
        verify_fn: [
          type: :string,
          doc: "MFA to call after loading (e.g., 'MyModule.health_check/0')"
        ],
        rollback_timeout_ms: [
          type: :integer,
          default: 30_000,
          doc: "Auto-rollback timeout in milliseconds"
        ]
      ]

    alias Arbor.Actions

    # Modules that cannot be hot-loaded under any circumstances
    @protected_modules [
      Arbor.Security,
      Arbor.Security.Kernel,
      Arbor.Security.CapabilityStore,
      Arbor.Persistence,
      Arbor.Persistence.EventLog,
      Arbor.Contracts
    ]

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(%{module: module_str, source: source} = params, _context) do
      verify_fn = params[:verify_fn]
      timeout = params[:rollback_timeout_ms] || 30_000

      Actions.emit_started(__MODULE__, %{module: module_str})

      with {:ok, module} <- parse_module(module_str),
           :ok <- check_not_protected(module),
           {:ok, original_binary} <- save_original(module),
           {:ok, compiled_module} <- compile_source(source) do
        # Load the new module
        {:ok, result} = load_module(compiled_module, verify_fn, timeout, original_binary)

        Actions.emit_completed(__MODULE__, %{
          module: module_str,
          loaded: result.loaded,
          verification_passed: result.verification_passed,
          rolled_back: result.rolled_back
        })

        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, format_error(reason)}
      end
    end

    defp parse_module(module_str) when is_binary(module_str) do
      module_str = if String.starts_with?(module_str, "Elixir."), do: module_str, else: "Elixir.#{module_str}"

      try do
        {:ok, String.to_existing_atom(module_str)}
      rescue
        ArgumentError ->
          # Module doesn't exist yet, that's fine for new modules
          {:ok, String.to_atom(module_str)}
      end
    end

    defp check_not_protected(module) do
      if module in @protected_modules do
        {:error, {:protected_module, module}}
      else
        :ok
      end
    end

    defp save_original(module) do
      case :code.get_object_code(module) do
        {^module, binary, _filename} ->
          {:ok, binary}

        :error ->
          # Module doesn't exist yet - that's okay for new modules
          {:ok, nil}
      end
    end

    defp compile_source(source) do
      # Check if source is a file path
      source_code =
        if File.exists?(source) do
          File.read!(source)
        else
          source
        end

      try do
        case Code.compile_string(source_code) do
          [{module, _binary}] -> {:ok, module}
          [{module, _binary} | _] -> {:ok, module}
          [] -> {:error, :no_module_compiled}
        end
      rescue
        e ->
          {:error, {:compile_error, Exception.message(e)}}
      end
    end

    defp load_module(module, verify_fn, timeout, original_binary) do
      # The module is already loaded by Code.compile_string
      # Now run verification if provided
      if verify_fn do
        task =
          Task.async(fn ->
            run_verification(module, verify_fn)
          end)

        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, :ok} ->
            {:ok,
             %{
               loaded: true,
               verification_passed: true,
               rolled_back: false,
               output: "Module loaded and verified"
             }}

          {:ok, {:error, reason}} ->
            # Verification failed, rollback
            restore_original(module, original_binary)

            {:ok,
             %{
               loaded: true,
               verification_passed: false,
               rolled_back: true,
               output: "Verification failed: #{inspect(reason)}"
             }}

          nil ->
            # Timeout, rollback
            restore_original(module, original_binary)

            {:ok,
             %{
               loaded: true,
               verification_passed: false,
               rolled_back: true,
               output: "Verification timed out after #{timeout}ms"
             }}
        end
      else
        {:ok,
         %{
           loaded: true,
           verification_passed: nil,
           rolled_back: false,
           output: "Module loaded (no verification)"
         }}
      end
    end

    defp run_verification(_module, verify_fn_str) do
      # Parse MFA string like "MyModule.health_check/0"
      case parse_mfa(verify_fn_str) do
        {:ok, {m, f, a}} ->
          try do
            result = apply(m, f, a)

            case result do
              :ok -> :ok
              true -> :ok
              {:ok, _} -> :ok
              false -> {:error, :verification_returned_false}
              {:error, reason} -> {:error, reason}
              _ -> :ok
            end
          rescue
            e -> {:error, Exception.message(e)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp parse_mfa(mfa_str) do
      # Parse "Module.function/arity" format
      case Regex.run(~r/^(.+)\.([^.\/]+)\/(\d+)$/, mfa_str) do
        [_, module_str, func_str, arity_str] ->
          module_str = if String.starts_with?(module_str, "Elixir."), do: module_str, else: "Elixir.#{module_str}"

          try do
            module = String.to_existing_atom(module_str)
            func = String.to_existing_atom(func_str)
            arity = String.to_integer(arity_str)

            if arity == 0 do
              {:ok, {module, func, []}}
            else
              {:error, "Verification function must have arity 0"}
            end
          rescue
            ArgumentError -> {:error, "Unknown module or function: #{mfa_str}"}
          end

        _ ->
          {:error, "Invalid MFA format. Use 'Module.function/0'"}
      end
    end

    defp restore_original(module, nil) do
      # Module didn't exist before, purge it
      :code.purge(module)
      :code.delete(module)
      :ok
    end

    defp restore_original(module, binary) do
      # Restore the original binary
      case :code.load_binary(module, ~c"#{module}", binary) do
        {:module, ^module} -> :ok
        {:error, reason} -> {:error, {:rollback_failed, reason}}
      end
    end

    defp format_error({:protected_module, module}) do
      "Cannot hot-load protected module: #{inspect(module)}"
    end

    defp format_error({:compile_error, msg}), do: "Compilation error: #{msg}"
    defp format_error(reason), do: "Hot-load failed: #{inspect(reason)}"
  end
end
