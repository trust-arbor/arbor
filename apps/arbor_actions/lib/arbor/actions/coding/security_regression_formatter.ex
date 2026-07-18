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

      def init(_opts) do
        {:ok,
         %{
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
        artifact = {@artifact_tag, @artifact_version, completed}
        bytes = :erlang.term_to_binary(artifact, [:deterministic])

        [artifact_path | _tests] = System.argv()

        if not is_binary(artifact_path) or artifact_path == "" do
          raise "security-regression runner missing artifact path argument"
        end

        temporary = artifact_path <> ".tmp"

        File.write!(temporary, bytes, [:binary])
        File.chmod!(temporary, 0o600)
        File.rename!(temporary, artifact_path)

        {:noreply, completed}
      end

      def handle_cast(_event, state), do: {:noreply, state}

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
    end

    [artifact_path | test_paths] = System.argv()

    if not is_binary(artifact_path) or artifact_path == "" do
      raise "security-regression runner missing artifact path argument"
    end

    Mix.Task.run("test", [
      "--formatter",
      #{inspect(module_name)},
      "--seed",
      "0",
      "--max-cases",
      "1",
      "--max-requires",
      "1",
      "--no-color",
      "--exit-status",
      "2"
      | test_paths
    ])
    """
  end
end
