defmodule Arbor.Shell.AppleContainerUnitRecoveryCore do
  @moduledoc """
  Pure CRC recovery reducer for durable Apple Container unit intents.

  After a crash or owner loss, a reconciler must force-stop, force-delete, and
  positively prove exact absence of a reserved unit name before completing the
  journal intent. This core decides that recovery state machine and returns
  fixed argv effects as data — a later imperative shell interprets them.

  All functions are pure: no File/IO, GenServer, Port, System time, randomness,
  Application config, Logger, process messaging, or cross-library facades.
  Absence classification reuses `AppleContainerUnitCore.classify_exact_absence/2`.
  """

  alias Arbor.Shell.AppleContainerUnitCore

  @runtime_executable "/usr/local/bin/container"
  @unit_name_prefix "arbor-v1-"
  @unit_name_hex_bytes 32
  @unit_name_re ~r/\Aarbor-v1-[0-9a-f]{32}\z/

  @max_cleanup_diagnostics 16
  @max_cleanup_rounds 10_000

  @cleanup_retry_initial_ms 50
  @cleanup_retry_max_ms 2_000

  @logical_state_keys [
    :unit_name,
    :argv,
    :stage,
    :cleanup_step,
    :cleanup_round,
    :cleanup_retry_ms,
    :cleanup_diagnostics,
    :terminal
  ]

  @logical_argv_keys [:force_stop, :delete, :verify_absent]

  @type phase :: :force_stop | :delete | :verify_absent

  @type effect ::
          {:run, phase(), [String.t()]}
          | {:retry_after, non_neg_integer(), {:run, phase(), [String.t()]}}
          | {:terminal, :reconciled}

  @type state :: %{
          unit_name: String.t(),
          argv: %{
            force_stop: [String.t()],
            delete: [String.t()],
            verify_absent: [String.t()]
          },
          stage: :cleanup | :terminal,
          cleanup_step: :force_stop | :delete | :verify_absent | nil,
          cleanup_round: non_neg_integer(),
          cleanup_retry_ms: pos_integer(),
          cleanup_diagnostics: [atom()],
          terminal: :reconciled | nil
        }

  @doc """
  Construct recovery state for a reserved durable unit name.

  Admits only `arbor-v1-` plus exactly 32 lowercase hex digits. Emits the first
  fixed force-stop effect.
  """
  @spec new(term()) :: {:ok, state(), [effect()]} | {:error, term()}
  def new(unit_name) when is_binary(unit_name) do
    with {:ok, name} <- validate_unit_name(unit_name) do
      argv = fixed_argv(name)

      state = %{
        unit_name: name,
        argv: argv,
        stage: :cleanup,
        cleanup_step: :force_stop,
        cleanup_round: 1,
        cleanup_retry_ms: @cleanup_retry_initial_ms,
        cleanup_diagnostics: [],
        terminal: nil
      }

      {:ok, state, [{:run, :force_stop, argv.force_stop}]}
    end
  rescue
    _ -> {:error, :invalid_unit_name}
  end

  def new(_), do: {:error, :invalid_unit_name}

  @doc """
  Apply an exact phase command result to recovery state.

  Force-stop and delete are best-effort and always advance once the result is a
  map. Verification uses `UnitCore.classify_exact_absence/2`; only `:absent`
  emits `{:terminal, :reconciled}`. Presence and every verification error retry
  force-stop with a deterministic exponential delay (50ms, cap 2000ms) and no
  terminal failure budget.
  """
  @spec apply_result(state(), phase(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_result(%{stage: :terminal} = state, _phase, _result) do
    _ = state
    {:error, :recovery_already_terminal}
  end

  def apply_result(state, phase, result) when is_map(state) and is_atom(phase) do
    with :ok <- require_state(state),
         :ok <- expect_phase(state, phase) do
      reduce(state, phase, result)
    end
  rescue
    _ -> {:error, :invalid_command_result}
  end

  def apply_result(_state, _phase, _result), do: {:error, :invalid_command_result}

  @doc """
  JSON-clean recovery view. Never includes command stdout or shell text.
  """
  @spec show(term()) :: map() | {:error, :invalid_recovery_state}
  def show(state) do
    with :ok <- require_state(state) do
      %{
        "unit_name" => state.unit_name,
        "stage" => Atom.to_string(state.stage),
        "cleanup_step" =>
          if(is_atom(state.cleanup_step) and not is_nil(state.cleanup_step),
            do: Atom.to_string(state.cleanup_step),
            else: nil
          ),
        "cleanup_round" => state.cleanup_round,
        "cleanup_retry_ms" => state.cleanup_retry_ms,
        "cleanup_diagnostics" => Enum.map(state.cleanup_diagnostics, &Atom.to_string/1),
        "terminal" => show_terminal(state.terminal)
      }
    end
  end

  # --- Construction -----------------------------------------------------------

  defp fixed_argv(name) do
    %{
      force_stop: force_stop_argv(name),
      delete: delete_argv(name),
      verify_absent: verify_absent_argv()
    }
  end

  defp force_stop_argv(name),
    do: [@runtime_executable, "kill", "--signal", "KILL", name]

  defp delete_argv(name),
    do: [@runtime_executable, "delete", "--force", name]

  defp verify_absent_argv,
    do: [@runtime_executable, "list", "--all", "--format", "json"]

  defp validate_unit_name(name) when is_binary(name) do
    cond do
      not String.valid?(name) ->
        {:error, :invalid_unit_name}

      byte_size(name) != byte_size(@unit_name_prefix) + @unit_name_hex_bytes ->
        {:error, :invalid_unit_name}

      not String.starts_with?(name, @unit_name_prefix) ->
        {:error, :invalid_unit_name}

      not Regex.match?(@unit_name_re, name) ->
        {:error, :invalid_unit_name}

      true ->
        {:ok, name}
    end
  end

  defp validate_unit_name(_), do: {:error, :invalid_unit_name}

  # --- State admission --------------------------------------------------------

  defp require_state(
         %{
           unit_name: unit_name,
           argv: argv,
           stage: stage,
           cleanup_step: cleanup_step,
           cleanup_round: cleanup_round,
           cleanup_retry_ms: cleanup_retry_ms,
           cleanup_diagnostics: cleanup_diagnostics,
           terminal: terminal
         } = state
       )
       when is_binary(unit_name) and is_map(argv) and is_integer(cleanup_round) and
              is_integer(cleanup_retry_ms) and is_list(cleanup_diagnostics) do
    with true <- exact_keys?(state, @logical_state_keys),
         true <- exact_keys?(argv, @logical_argv_keys),
         {:ok, ^unit_name} <- validate_unit_name(unit_name),
         true <- argv == fixed_argv(unit_name),
         true <- stage in [:cleanup, :terminal],
         true <- cleanup_step in [:force_stop, :delete, :verify_absent, nil],
         true <- cleanup_round >= 0 and cleanup_round <= @max_cleanup_rounds,
         true <-
           cleanup_retry_ms >= @cleanup_retry_initial_ms and
             cleanup_retry_ms <= @cleanup_retry_max_ms,
         true <- Enum.all?(cleanup_diagnostics, &is_atom/1),
         true <- length(cleanup_diagnostics) <= @max_cleanup_diagnostics,
         true <- valid_stage_shape?(stage, cleanup_step, terminal) do
      :ok
    else
      _ -> {:error, :invalid_recovery_state}
    end
  end

  defp require_state(_), do: {:error, :invalid_recovery_state}

  defp exact_keys?(map, logical_keys) when is_map(map) do
    Map.keys(map) |> MapSet.new() |> MapSet.equal?(MapSet.new(logical_keys))
  end

  defp exact_keys?(_, _), do: false

  defp valid_stage_shape?(:cleanup, step, nil)
       when step in [:force_stop, :delete, :verify_absent],
       do: true

  defp valid_stage_shape?(:terminal, nil, :reconciled), do: true
  defp valid_stage_shape?(_, _, _), do: false

  # --- Phase expectation ------------------------------------------------------

  defp expect_phase(%{stage: :cleanup, cleanup_step: :force_stop}, :force_stop), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :delete}, :delete), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :verify_absent}, :verify_absent), do: :ok
  defp expect_phase(_state, _phase), do: {:error, :unexpected_phase}

  # --- Reduce -----------------------------------------------------------------

  defp reduce(%{stage: :cleanup, cleanup_step: :force_stop} = state, :force_stop, result)
       when is_map(result) do
    state =
      state
      |> record_cleanup_diag(:force_stop, result)
      |> Map.put(:cleanup_step, :delete)

    {:ok, state, [{:run, :delete, state.argv.delete}]}
  end

  defp reduce(%{stage: :cleanup, cleanup_step: :delete} = state, :delete, result)
       when is_map(result) do
    state =
      state
      |> record_cleanup_diag(:delete, result)
      |> Map.put(:cleanup_step, :verify_absent)

    {:ok, state, [{:run, :verify_absent, state.argv.verify_absent}]}
  end

  defp reduce(%{stage: :cleanup, cleanup_step: :verify_absent} = state, :verify_absent, result) do
    case AppleContainerUnitCore.classify_exact_absence(state.unit_name, result) do
      :absent ->
        terminal = :reconciled

        state = %{
          state
          | stage: :terminal,
            cleanup_step: nil,
            terminal: terminal
        }

        {:ok, state, [{:terminal, terminal}]}

      :present ->
        loop_cleanup(state, :unit_still_present)

      {:error, reason} ->
        loop_cleanup(state, normalize_verify_diag(reason))
    end
  end

  defp reduce(_state, :force_stop, _result), do: {:error, :invalid_command_result}
  defp reduce(_state, :delete, _result), do: {:error, :invalid_command_result}
  defp reduce(_state, _phase, _result), do: {:error, :unexpected_phase}

  defp loop_cleanup(state, diag) do
    delay = state.cleanup_retry_ms
    next_delay = min(delay * 2, @cleanup_retry_max_ms)
    round = min(state.cleanup_round + 1, @max_cleanup_rounds)

    state =
      state
      |> record_diag(diag)
      |> Map.put(:cleanup_round, round)
      |> Map.put(:cleanup_step, :force_stop)
      |> Map.put(:cleanup_retry_ms, next_delay)

    {:ok, state, [{:retry_after, delay, {:run, :force_stop, state.argv.force_stop}}]}
  end

  defp normalize_verify_diag(reason) when is_atom(reason), do: reason
  defp normalize_verify_diag(_reason), do: :verify_absent_error

  # --- Diagnostics ------------------------------------------------------------

  defp record_cleanup_diag(state, step, result) when is_map(result) do
    class =
      cond do
        flag_true?(result, :cancelled) ->
          :cancelled

        flag_true?(result, :timed_out) ->
          :timeout

        flag_true?(result, :output_limit_exceeded) or flag_true?(result, :output_truncated) ->
          :output_limit

        flag_true?(result, :containment_failure) ->
          :containment_failure

        nonzero_exit?(result) ->
          :failed

        true ->
          :ok
      end

    record_diag(state, cleanup_diag_atom(step, class))
  end

  defp flag_true?(result, key) when is_atom(key) do
    Map.get(result, key) == true or Map.get(result, Atom.to_string(key)) == true
  end

  defp nonzero_exit?(result) do
    code =
      case Map.fetch(result, :exit_code) do
        {:ok, value} -> value
        :error -> Map.get(result, "exit_code")
      end

    is_integer(code) and code != 0
  end

  defp cleanup_diag_atom(:force_stop, :ok), do: :force_stop_ok
  defp cleanup_diag_atom(:force_stop, :failed), do: :force_stop_failed
  defp cleanup_diag_atom(:force_stop, :timeout), do: :force_stop_timeout
  defp cleanup_diag_atom(:force_stop, :cancelled), do: :force_stop_cancelled
  defp cleanup_diag_atom(:force_stop, :output_limit), do: :force_stop_output_limit

  defp cleanup_diag_atom(:force_stop, :containment_failure),
    do: :force_stop_containment_failure

  defp cleanup_diag_atom(:delete, :ok), do: :delete_ok
  defp cleanup_diag_atom(:delete, :failed), do: :delete_failed
  defp cleanup_diag_atom(:delete, :timeout), do: :delete_timeout
  defp cleanup_diag_atom(:delete, :cancelled), do: :delete_cancelled
  defp cleanup_diag_atom(:delete, :output_limit), do: :delete_output_limit
  defp cleanup_diag_atom(:delete, :containment_failure), do: :delete_containment_failure
  defp cleanup_diag_atom(_step, _class), do: :cleanup_step_other

  defp record_diag(state, diag) when is_atom(diag) do
    diagnostics =
      [diag | state.cleanup_diagnostics]
      |> Enum.take(@max_cleanup_diagnostics)

    %{state | cleanup_diagnostics: diagnostics}
  end

  defp show_terminal(nil), do: nil
  defp show_terminal(:reconciled), do: "reconciled"
end
