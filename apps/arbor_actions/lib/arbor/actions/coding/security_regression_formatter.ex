defmodule Arbor.Actions.Coding.SecurityRegression.Formatter do
  @moduledoc """
  Produces the trusted ExUnit runner/formatter loaded into each isolated test VM.

  The child process writes one Erlang external-term artifact only after receiving
  `suite_finished`. The parent validates that artifact against an exact schema;
  human-oriented CLI output is never used as proof.

  ## Level A boundary

  This harness is **not** a hostile-runtime proof channel. Candidate code shares
  the BEAM with the generated formatter; the artifact path is owner-selected and
  supplied as the first `System.argv()` entry after `--`. Do not claim T4 /
  hostile-runtime integrity from this Level A evidence path.
  """

  alias Arbor.Actions.Coding.SecurityRegression.Core

  @doc """
  Render a self-contained runner.

  The artifact path is **not** embedded: the owner passes the host (or guest)
  path as the first argument after `--`, followed by selected relative tests.

  ## `mix run` argv contract

  Owner argv is always:

      mix run --no-start <runner.exs> -- <result.etf> <tests...>

  `Mix.Tasks.Run` places everything after the script file into `System.argv/0`,
  which **includes the leading `--` separator**. The script strips that
  separator once, stores the owner-issued result path in formatter-owned state
  **before** `Mix.Task.run/2`, and never rereads `System.argv/0` at
  `suite_finished` — Mix may replace argv with the selected test paths, which
  would otherwise overwrite a reviewed test file and falsely trip
  source-identity / workspace-fingerprint checks.

  The generated `Mix.Task.run("test", ...)` flags are validator-owned. They
  always include `--include test` so helper `ExUnit.start(exclude: ...)` cannot
  drop already exact-selected tests. Callers cannot supply include/exclude/only.
  """
  @spec runner_source(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def runner_source(module_name) when is_binary(module_name) do
    with :ok <- validate_module_name(module_name) do
      {:ok,
       render_runner(
         module_name,
         inspect(Core.artifact_tag()),
         Core.artifact_version()
       )}
    else
      _ -> {:error, :invalid_formatter_configuration}
    end
  end

  def runner_source(_module_name), do: {:error, :invalid_formatter_configuration}

  @doc """
  Fixed Mix test flags prepended to the exact selected paths.

  `--include test` is the generic ExUnit override: every test carries the
  built-in `:test` tag, so include wins over helper exclusions without a
  tag-specific allowlist. Filter arguments are not accepted from callers.
  """
  @spec mix_test_flags(String.t()) :: [String.t()]
  def mix_test_flags(module_name) when is_binary(module_name) do
    [
      "--formatter",
      module_name,
      "--seed",
      "0",
      "--max-cases",
      "1",
      "--max-requires",
      "1",
      "--no-color",
      "--exit-status",
      "2",
      "--include",
      "test"
    ]
  end

  @doc """
  Normalize `mix run` script argv into `{artifact_path, test_paths}`.

  Accepts the exact owner form (leading `"--"` then absolute result path then
  nonempty relative tests) and the already-stripped form for unit fixtures.
  """
  @spec normalize_runner_argv([String.t()]) ::
          {:ok, String.t(), [String.t()]} | {:error, atom()}
  def normalize_runner_argv(argv) when is_list(argv) do
    case strip_leading_separator(argv) do
      [artifact_path | test_paths]
      when is_binary(artifact_path) and artifact_path != "" and test_paths != [] ->
        cond do
          artifact_path == "--" ->
            {:error, :invalid_artifact_path}

          String.starts_with?(artifact_path, "-") ->
            {:error, :option_shaped_artifact_path}

          true ->
            {:ok, artifact_path, test_paths}
        end

      [artifact_path]
      when is_binary(artifact_path) and artifact_path != "" ->
        {:error, :empty_test_paths}

      _other ->
        {:error, :missing_artifact_path}
    end
  end

  def normalize_runner_argv(_), do: {:error, :missing_artifact_path}

  defp strip_leading_separator(["--" | rest]), do: rest
  defp strip_leading_separator(argv) when is_list(argv), do: argv

  defp validate_module_name(module_name) do
    if Regex.match?(~r/\AArborSecurityRegressionFormatter\.M[A-F0-9]{32}\z/, module_name) do
      :ok
    else
      {:error, :invalid_formatter_module}
    end
  end

  defp render_runner(module_name, artifact_tag, artifact_version) do
    """
    defmodule #{module_name} do
      use GenServer

      @artifact_tag #{artifact_tag}
      @artifact_version #{artifact_version}
      @artifact_path_key {__MODULE__, :owner_artifact_path}

      # Capture the owner-issued result path before Mix.Task.run may replace
      # System.argv with the selected test paths.
      # Path checks stay in function bodies — remote calls such as
      # String.starts_with?/2 are not valid Elixir guards (OTP/Elixir 1.19).
      def store_artifact_path!(path) when is_binary(path) do
        if valid_owner_artifact_path?(path) do
          :persistent_term.put(@artifact_path_key, path)
          :ok
        else
          raise "security-regression runner missing artifact path argument"
        end
      end

      def store_artifact_path!(_path) do
        raise "security-regression runner missing artifact path argument"
      end

      def init(_opts) do
        artifact_path =
          case :persistent_term.get(@artifact_path_key, :missing) do
            path when is_binary(path) ->
              if valid_owner_artifact_path?(path) do
                path
              else
                raise "security-regression runner missing stored artifact path"
              end

            _other ->
              raise "security-regression runner missing stored artifact path"
          end

        {:ok,
         %{
           artifact_path: artifact_path,
           excluded: 0,
           executed: 0,
           invalid: 0,
           max_failures_reached: false,
           passed: 0,
           setup_failures: 0,
           skipped: 0,
           suite_completed: false,
           suite_started: false,
           test_failures: 0,
           total: 0
         }}
      end

      def handle_cast({:suite_started, _opts}, state) do
        {:noreply, %{state | suite_started: true}}
      end

      def handle_cast({:test_finished, %ExUnit.Test{state: nil}}, state) do
        {:noreply,
         state
         |> increment(:executed)
         |> increment(:passed)
         |> increment(:total)}
      end

      def handle_cast(
            {:test_finished, %ExUnit.Test{state: {:failed, failures}} = test},
            state
          ) do
        real_failure = Enum.any?(failures, &failure_from_test?(&1, test))
        callback_failure = failures == [] or Enum.any?(failures, &(not failure_from_test?(&1, test)))

        state =
          if real_failure do
            state
            |> increment(:executed)
            |> increment(:test_failures)
            |> increment(:total)
          else
            state
            |> increment(:invalid)
            |> increment(:total)
          end

        state = if callback_failure, do: increment(state, :setup_failures), else: state
        {:noreply, state}
      end

      def handle_cast({:test_finished, %ExUnit.Test{state: {:skipped, _reason}}}, state) do
        {:noreply, state |> increment(:skipped) |> increment(:total)}
      end

      def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _reason}}}, state) do
        {:noreply, state |> increment(:excluded) |> increment(:total)}
      end

      def handle_cast({:test_finished, %ExUnit.Test{state: {:invalid, _reason}}}, state) do
        {:noreply, state |> increment(:invalid) |> increment(:total)}
      end

      def handle_cast({:test_finished, %ExUnit.Test{}}, state) do
        {:noreply,
         state
         |> increment(:invalid)
         |> increment(:setup_failures)
         |> increment(:total)}
      end

      def handle_cast(
            {:module_finished, %ExUnit.TestModule{state: {:failed, _failures}}},
            state
          ) do
        {:noreply, increment(state, :setup_failures)}
      end

      def handle_cast(:max_failures_reached, state) do
        {:noreply, %{state | max_failures_reached: true}}
      end

      def handle_cast({:suite_finished, _times}, state) do
        completed = %{state | suite_completed: true}
        # Counts only in the published artifact — never re-export artifact_path.
        counts = Map.drop(completed, [:artifact_path])
        artifact = {@artifact_tag, @artifact_version, counts}
        bytes = :erlang.term_to_binary(artifact, [:deterministic])

        # Owner path from formatter-owned state only. Never reread System.argv:
        # Mix.Task.run("test", ...) may have replaced argv with selected tests.
        artifact_path = Map.fetch!(state, :artifact_path)
        temporary = artifact_path <> ".tmp"

        File.write!(temporary, bytes, [:binary])
        File.chmod!(temporary, 0o600)
        File.rename!(temporary, artifact_path)

        {:noreply, completed}
      end

      def handle_cast(_event, state), do: {:noreply, state}

      defp valid_owner_artifact_path?(path) when is_binary(path) do
        path != "" and path != "--" and not String.starts_with?(path, "-")
      end

      defp valid_owner_artifact_path?(_path), do: false

      defp increment(state, key), do: Map.update!(state, key, &(&1 + 1))

      defp failure_from_test?({_kind, _reason, stacktrace}, test)
           when is_list(stacktrace) do
        Enum.any?(stacktrace, fn
          {module, function, _arity_or_args, _location} ->
            module == test.module and function == test.name

          {module, function, _arity_or_args} ->
            module == test.module and function == test.name

          _other ->
            false
        end)
      end

      defp failure_from_test?(_failure, _test), do: false

      @mix_task_module_key {__MODULE__, :mix_task_module}
      @schema_project_mix_file #{inspect(Core.schema_project_mix_file())}
      @schema_bootstrap_tasks #{inspect(Core.schema_bootstrap_tasks())}
      @schema_bootstrap_args #{inspect(Core.schema_bootstrap_args())}
      @schema_home_dir #{inspect(Core.schema_home_dir())}

      @doc false
      def configure_mix_task_module(mod) when is_atom(mod) do
        Process.put(@mix_task_module_key, mod)
        :ok
      end

      def schema_project? do
        File.regular?(@schema_project_mix_file)
      end

      def bootstrap_test_schema do
        if schema_project?() do
          prepare_revision_schema()
        else
          :skipped
        end
      end

      def write_bootstrap_failure_artifact! do
        artifact_path = stored_owner_artifact_path!()

        counts = %{
          excluded: 0,
          executed: 0,
          invalid: 0,
          max_failures_reached: false,
          passed: 0,
          setup_failures: 1,
          skipped: 0,
          suite_completed: false,
          suite_started: false,
          test_failures: 0,
          total: 0
        }

        artifact = {@artifact_tag, @artifact_version, counts}
        bytes = :erlang.term_to_binary(artifact, [:deterministic])
        temporary = artifact_path <> ".tmp"
        File.write!(temporary, bytes, [:binary])
        File.chmod!(temporary, 0o600)
        File.rename!(temporary, artifact_path)
        :ok
      end

      def run_selected_tests!(test_paths) do
        mix_task_module().run("test", [
          #{rendered_mix_test_flags(module_name)}
          | test_paths
        ])
      end

      def prepare_schema_and_run_tests!(test_paths) do
        case bootstrap_test_schema() do
          {:error, :schema_bootstrap_failed} = error ->
            write_bootstrap_failure_artifact!()
            error

          :ok ->
            run_selected_tests!(test_paths)
            :ok

          :skipped ->
            run_selected_tests!(test_paths)
            :ok
        end
      end

      defp prepare_revision_schema do
        File.mkdir_p!(Path.expand(@schema_home_dir))
        run_schema_bootstrap_tasks()
      rescue
        _error -> {:error, :schema_bootstrap_failed}
      catch
        _kind, _reason -> {:error, :schema_bootstrap_failed}
      end

      defp run_schema_bootstrap_tasks do
        Enum.reduce_while(@schema_bootstrap_tasks, :ok, fn name, :ok ->
          case run_schema_task(name) do
            :ok -> {:cont, :ok}
            {:error, :schema_bootstrap_failed} = error -> {:halt, error}
          end
        end)
      end

      # In-child Mix.Task.rerun loads this revision's ecto tasks. Ecto Create
      # treats an already-up schema as a normal return; any raise/throw fails
      # closed. Never run Migrator in the host Arbor VM.
      defp run_schema_task(name) do
        mix_task_module().rerun(name, @schema_bootstrap_args)
        :ok
      rescue
        _error -> {:error, :schema_bootstrap_failed}
      catch
        _kind, _reason -> {:error, :schema_bootstrap_failed}
      end

      defp mix_task_module do
        Process.get(@mix_task_module_key, Mix.Task)
      end

      defp stored_owner_artifact_path! do
        case :persistent_term.get(@artifact_path_key, :missing) do
          path when is_binary(path) ->
            if valid_owner_artifact_path?(path) do
              path
            else
              raise "security-regression runner missing stored artifact path"
            end

          _other ->
            raise "security-regression runner missing stored artifact path"
        end
      end
    end

    # Strip Mix.Tasks.Run's retained `--` once. Store the owner result path in
    # formatter-owned state before Mix.Task.run can mutate System.argv.
    argv =
      case System.argv() do
        ["--" | rest] -> rest
        rest -> rest
      end

    [artifact_path | test_paths] = argv

    if not is_binary(artifact_path) or artifact_path == "" or artifact_path == "--" or
         String.starts_with?(artifact_path, "-") do
      raise "security-regression runner missing artifact path argument"
    end

    if test_paths == [] do
      raise "security-regression runner missing reviewed test paths"
    end

    #{module_name}.store_artifact_path!(artifact_path)

    case #{module_name}.prepare_schema_and_run_tests!(test_paths) do
      :ok -> :ok
      {:error, :schema_bootstrap_failed} -> System.halt(2)
    end
    """
  end

  defp rendered_mix_test_flags(module_name) do
    module_name
    |> mix_test_flags()
    |> Enum.map_join(",\n      ", &inspect/1)
  end
end
