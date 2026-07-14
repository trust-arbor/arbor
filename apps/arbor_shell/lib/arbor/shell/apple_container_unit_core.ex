defmodule Arbor.Shell.AppleContainerUnitCore do
  @moduledoc """
  Pure Apple Container unit lifecycle reducer (Construct-Reduce-Convert).

  Decides preflight → create → start → enforcing cleanup transitions and
  returns effects as plain data for a later imperative shell. Performs no IO,
  process execution, time, randomness, config, or GenServer calls.

  A successful terminal primary result is forbidden until positive proof that
  the exact named unit is absent from a successful `container list --all
  --format json` (matching `configuration.id`). A failing inspect-style command
  is never treated as absence. After create is attempted, every outcome enters
  cleanup (force-stop → force-delete → verify_absent), looping until absence is
  proven or the shell stops applying results.
  """

  alias Arbor.Shell.AppleContainerPlanCore

  @max_list_json_bytes 262_144
  @max_list_entries 256
  @max_id_bytes 256
  @max_cleanup_diagnostics 16
  @max_cleanup_rounds 10_000

  @logical_result_keys [
    :exit_code,
    :stdout,
    :timed_out,
    :cancelled,
    :output_limit_exceeded,
    :output_truncated,
    :containment_failure
  ]
  @allowed_result_keys MapSet.new(
                         @logical_result_keys ++
                           Enum.map(@logical_result_keys, &Atom.to_string/1)
                       )

  @type phase ::
          :verify_absent
          | :create
          | :start
          | :force_stop
          | :delete

  @type effect ::
          {:run, phase(), [String.t()]}
          | {:terminal, map()}

  @type primary_outcome :: %{
          status: :ok | :error | :cancelled,
          reason: atom() | nil,
          phase: phase() | :preflight | :cleanup | nil,
          exit_code: non_neg_integer() | nil
        }

  @type state :: %{
          unit_name: String.t(),
          argv: AppleContainerPlanCore.argv_plans(),
          stage: :preflight | :create | :start | :cleanup | :terminal,
          cleanup_step: :force_stop | :delete | :verify_absent | nil,
          create_attempted: boolean(),
          primary: primary_outcome() | nil,
          cleanup_round: non_neg_integer(),
          cleanup_diagnostics: [atom()],
          terminal: map() | nil
        }

  @doc """
  Construct preflight lifecycle state from a validated PlanCore plan.

  Emits a single preflight `verify_absent` (list) effect.
  """
  @spec new(term()) :: {:ok, state(), [effect()]} | {:error, term()}
  def new(plan) when is_map(plan) do
    with :ok <- validate_plan(plan) do
      state = %{
        unit_name: plan.unit_name,
        argv: plan.argv,
        stage: :preflight,
        cleanup_step: nil,
        create_attempted: false,
        primary: nil,
        cleanup_round: 0,
        cleanup_diagnostics: [],
        terminal: nil
      }

      {:ok, state, [{:run, :verify_absent, plan.argv.verify_absent}]}
    end
  rescue
    _ -> {:error, :invalid_plan}
  end

  def new(_), do: {:error, :invalid_plan}

  @doc """
  Apply an exact phase command result to lifecycle state.

  `phase` must match the pending effect. Returns updated state plus effects
  (next run and/or terminal).
  """
  @spec apply_result(state(), phase(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_result(%{stage: :terminal} = _state, _phase, _result) do
    {:error, :lifecycle_already_terminal}
  end

  def apply_result(state, phase, result) when is_map(state) and is_atom(phase) do
    with :ok <- expect_phase(state, phase),
         {:ok, normalized} <- normalize_result(result) do
      reduce(state, phase, normalized)
    end
  rescue
    _ -> {:error, :invalid_command_result}
  end

  def apply_result(_state, _phase, _result), do: {:error, :invalid_command_result}

  @doc """
  Request cancellation.

  Before create is attempted, terminates as cancelled. At or after create
  (including while create/start is pending), enters enforcing cleanup without
  emitting a terminal primary success.
  """
  @spec cancel(state()) :: {:ok, state(), [effect()]} | {:error, term()}
  def cancel(%{stage: :terminal} = _state), do: {:error, :lifecycle_already_terminal}

  def cancel(state) when is_map(state) do
    cond do
      state.stage == :preflight and state.create_attempted == false ->
        primary = %{
          status: :cancelled,
          reason: :preflight_cancelled,
          phase: :preflight,
          exit_code: nil
        }

        terminal = finalize_primary(primary)
        state = %{state | stage: :terminal, terminal: terminal, primary: primary}
        {:ok, state, [{:terminal, terminal}]}

      state.stage in [:create, :start, :cleanup] or state.create_attempted ->
        primary =
          state.primary ||
            %{
              status: :cancelled,
              reason: :cancelled,
              phase: stage_phase(state),
              exit_code: nil
            }

        enter_cleanup(%{state | primary: primary}, :cancel)

      true ->
        primary = %{
          status: :cancelled,
          reason: :cancelled,
          phase: stage_phase(state),
          exit_code: nil
        }

        terminal = finalize_primary(primary)
        state = %{state | stage: :terminal, terminal: terminal, primary: primary}
        {:ok, state, [{:terminal, terminal}]}
    end
  rescue
    _ -> {:error, :invalid_state}
  end

  def cancel(_), do: {:error, :invalid_state}

  @doc """
  JSON-clean lifecycle view. Never includes setup/cleanup stdout.
  """
  @spec show(state()) :: map()
  def show(state) when is_map(state) do
    %{
      "unit_name" => state.unit_name,
      "stage" => Atom.to_string(state.stage),
      "cleanup_step" =>
        if(is_atom(state.cleanup_step), do: Atom.to_string(state.cleanup_step), else: nil),
      "create_attempted" => state.create_attempted == true,
      "cleanup_round" => state.cleanup_round,
      "cleanup_diagnostics" => Enum.map(state.cleanup_diagnostics, &Atom.to_string/1),
      "primary" => show_primary(state.primary),
      "terminal" => show_terminal(state.terminal)
    }
  end

  # --- Plan validation -------------------------------------------------------

  defp validate_plan(plan) do
    with :ok <- require_binary(plan[:unit_name] || plan["unit_name"], :invalid_unit_name),
         {:ok, argv} <- fetch_argv(plan),
         :ok <- require_argv_key(argv, :create),
         :ok <- require_argv_key(argv, :start),
         :ok <- require_argv_key(argv, :force_stop),
         :ok <- require_argv_key(argv, :delete),
         :ok <- require_argv_key(argv, :verify_absent),
         :ok <- validate_lifecycle(plan) do
      :ok
    end
  end

  defp fetch_argv(plan) do
    case plan[:argv] || plan["argv"] do
      argv when is_map(argv) -> {:ok, argv}
      _ -> {:error, :invalid_plan_argv}
    end
  end

  defp require_argv_key(argv, key) do
    value = Map.get(argv, key) || Map.get(argv, Atom.to_string(key))

    if is_list(value) and Enum.all?(value, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_plan_argv, key}}
    end
  end

  defp validate_lifecycle(plan) do
    lifecycle = plan[:lifecycle] || plan["lifecycle"]

    case lifecycle do
      %{
        preflight_order: [:verify_absent],
        start_order: [:create, :start],
        terminal_order: [:force_stop, :delete, :verify_absent]
      } ->
        :ok

      %{
        "preflight_order" => ["verify_absent"],
        "start_order" => ["create", "start"],
        "terminal_order" => ["force_stop", "delete", "verify_absent"]
      } ->
        :ok

      %{start_order: [:create, :start], terminal_order: [:force_stop, :delete, :verify_absent]} =
          life
      when not is_map_key(life, :preflight_order) ->
        # Accept plans that only lack preflight_order if argv.verify_absent is list-shaped
        # is not enough — require preflight_order for this core.
        {:error, :missing_preflight_order}

      _other ->
        {:error, :invalid_plan_lifecycle}
    end
  end

  defp require_binary(value, _ok) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, err), do: {:error, err}

  # --- Phase expectation -----------------------------------------------------

  defp expect_phase(%{stage: :preflight}, :verify_absent), do: :ok
  defp expect_phase(%{stage: :create}, :create), do: :ok
  defp expect_phase(%{stage: :start}, :start), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :force_stop}, :force_stop), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :delete}, :delete), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :verify_absent}, :verify_absent), do: :ok
  defp expect_phase(_state, _phase), do: {:error, :unexpected_phase}

  defp stage_phase(%{stage: :preflight}), do: :preflight
  defp stage_phase(%{stage: :create}), do: :create
  defp stage_phase(%{stage: :start}), do: :start
  defp stage_phase(%{stage: :cleanup}), do: :cleanup
  defp stage_phase(_), do: nil

  # --- Result normalization --------------------------------------------------

  defp normalize_result(result) when is_map(result) do
    with :ok <- validate_result_keys(result),
         {:ok, exit_code} <- fetch_exit_code(result),
         {:ok, stdout} <- fetch_stdout(result),
         timed_out <- truthy?(result, :timed_out),
         cancelled <- truthy?(result, :cancelled),
         output_limit <-
           truthy?(result, :output_limit_exceeded) or truthy?(result, :output_truncated),
         containment <- truthy?(result, :containment_failure) do
      {:ok,
       %{
         exit_code: exit_code,
         stdout: stdout,
         timed_out: timed_out,
         cancelled: cancelled,
         output_limit_exceeded: output_limit,
         containment_failure: containment
       }}
    end
  end

  defp normalize_result(_), do: {:error, :invalid_command_result}

  defp validate_result_keys(result) do
    keys = Map.keys(result)

    if Enum.all?(keys, &MapSet.member?(@allowed_result_keys, &1)) do
      :ok
    else
      {:error, :unsupported_result_keys}
    end
  end

  defp fetch_exit_code(result) do
    case get_field(result, :exit_code) do
      code when is_integer(code) and code >= 0 and code <= 0xFFFF ->
        {:ok, code}

      nil ->
        {:error, :missing_exit_code}

      _ ->
        {:error, :invalid_exit_code}
    end
  end

  defp fetch_stdout(result) do
    case get_field(result, :stdout) do
      nil ->
        {:ok, ""}

      out when is_binary(out) ->
        if byte_size(out) > @max_list_json_bytes do
          {:error, :stdout_too_long}
        else
          {:ok, out}
        end

      _ ->
        {:error, :invalid_stdout}
    end
  end

  defp truthy?(map, key) do
    case get_field(map, key) do
      true -> true
      _ -> false
    end
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # --- Reduce ----------------------------------------------------------------

  defp reduce(%{stage: :preflight} = state, :verify_absent, result) do
    case classify_list_absence(result, state.unit_name) do
      :absent ->
        state = %{state | stage: :create, create_attempted: true}
        {:ok, state, [{:run, :create, state.argv.create}]}

      :present ->
        primary = %{
          status: :error,
          reason: :unit_name_collision,
          phase: :preflight,
          exit_code: 0
        }

        terminal = finalize_primary(primary)
        state = %{state | stage: :terminal, terminal: terminal, primary: primary}
        {:ok, state, [{:terminal, terminal}]}

      {:error, reason} ->
        primary = %{
          status: :error,
          reason: reason,
          phase: :preflight,
          exit_code: result.exit_code
        }

        terminal = finalize_primary(primary)
        state = %{state | stage: :terminal, terminal: terminal, primary: primary}
        {:ok, state, [{:terminal, terminal}]}
    end
  end

  defp reduce(%{stage: :create} = state, :create, result) do
    cond do
      result.cancelled ->
        primary = primary_from_flags(result, :create, :cancelled)
        enter_cleanup(%{state | primary: primary}, :create_cancelled)

      unclean_flags?(result) or result.exit_code != 0 ->
        primary = primary_from_flags(result, :create, :create_failed)
        enter_cleanup(%{state | primary: primary}, :create_failed)

      true ->
        state = %{state | stage: :start}
        {:ok, state, [{:run, :start, state.argv.start}]}
    end
  end

  defp reduce(%{stage: :start} = state, :start, result) do
    primary =
      cond do
        result.cancelled ->
          primary_from_flags(result, :start, :cancelled)

        result.timed_out ->
          primary_from_flags(result, :start, :start_timeout)

        result.output_limit_exceeded ->
          primary_from_flags(result, :start, :start_output_limit)

        result.containment_failure ->
          primary_from_flags(result, :start, :start_containment_failure)

        result.exit_code != 0 ->
          primary_from_flags(result, :start, :start_failed)

        true ->
          %{status: :ok, reason: nil, phase: :start, exit_code: 0}
      end

    enter_cleanup(%{state | primary: primary}, :start_complete)
  end

  defp reduce(%{stage: :cleanup, cleanup_step: :force_stop} = state, :force_stop, result) do
    state = record_cleanup_diag(state, :force_stop, result)
    state = %{state | cleanup_step: :delete}
    {:ok, state, [{:run, :delete, state.argv.delete}]}
  end

  defp reduce(%{stage: :cleanup, cleanup_step: :delete} = state, :delete, result) do
    state = record_cleanup_diag(state, :delete, result)
    state = %{state | cleanup_step: :verify_absent}
    {:ok, state, [{:run, :verify_absent, state.argv.verify_absent}]}
  end

  defp reduce(%{stage: :cleanup, cleanup_step: :verify_absent} = state, :verify_absent, result) do
    case classify_list_absence(result, state.unit_name) do
      :absent ->
        terminal = finalize_primary(state.primary)
        state = %{state | stage: :terminal, cleanup_step: nil, terminal: terminal}
        {:ok, state, [{:terminal, terminal}]}

      :present ->
        loop_cleanup(state, :unit_still_present)

      {:error, reason} ->
        loop_cleanup(state, reason)
    end
  end

  defp reduce(_state, _phase, _result), do: {:error, :unexpected_phase}

  defp unclean_flags?(result) do
    result.timed_out or result.output_limit_exceeded or result.containment_failure
  end

  defp primary_from_flags(result, phase, default_reason) do
    reason =
      cond do
        result.cancelled -> :cancelled
        result.timed_out -> :timeout
        result.output_limit_exceeded -> :output_limit
        result.containment_failure -> :containment_failure
        true -> default_reason
      end

    status = if reason == :cancelled, do: :cancelled, else: :error

    %{
      status: status,
      reason: reason,
      phase: phase,
      exit_code: result.exit_code
    }
  end

  defp enter_cleanup(state, _why) do
    round = min(state.cleanup_round + 1, @max_cleanup_rounds)

    state = %{
      state
      | stage: :cleanup,
        cleanup_step: :force_stop,
        cleanup_round: round
    }

    {:ok, state, [{:run, :force_stop, state.argv.force_stop}]}
  end

  defp loop_cleanup(state, diag) do
    state =
      state
      |> record_diag(diag)
      |> Map.update!(:cleanup_round, &min(&1 + 1, @max_cleanup_rounds))
      |> Map.put(:cleanup_step, :force_stop)

    {:ok, state, [{:run, :force_stop, state.argv.force_stop}]}
  end

  defp record_cleanup_diag(state, step, result) do
    class =
      cond do
        result.cancelled -> :cancelled
        result.timed_out -> :timeout
        result.output_limit_exceeded -> :output_limit
        result.containment_failure -> :containment_failure
        result.exit_code != 0 -> :failed
        true -> :ok
      end

    record_diag(state, cleanup_diag_atom(step, class))
  end

  defp cleanup_diag_atom(:force_stop, :ok), do: :force_stop_ok
  defp cleanup_diag_atom(:force_stop, :failed), do: :force_stop_failed
  defp cleanup_diag_atom(:force_stop, :timeout), do: :force_stop_timeout
  defp cleanup_diag_atom(:force_stop, :cancelled), do: :force_stop_cancelled
  defp cleanup_diag_atom(:force_stop, :output_limit), do: :force_stop_output_limit
  defp cleanup_diag_atom(:force_stop, :containment_failure), do: :force_stop_containment_failure
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

  defp finalize_primary(nil) do
    %{
      "status" => "error",
      "reason" => "missing_primary_outcome",
      "phase" => nil,
      "exit_code" => nil
    }
  end

  defp finalize_primary(%{status: :ok} = primary) do
    %{
      "status" => "ok",
      "reason" => nil,
      "phase" => phase_string(primary.phase),
      "exit_code" => primary.exit_code
    }
  end

  defp finalize_primary(primary) do
    %{
      "status" => Atom.to_string(primary.status),
      "reason" => if(is_atom(primary.reason), do: Atom.to_string(primary.reason), else: nil),
      "phase" => phase_string(primary.phase),
      "exit_code" => primary.exit_code
    }
  end

  defp phase_string(nil), do: nil
  defp phase_string(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_string(_), do: nil

  # --- List absence proof ----------------------------------------------------

  # Positive absence: exit 0, no unclean flags, bounded JSON list, every entry
  # has nonblank bounded configuration.id, exact unit name not present.
  defp classify_list_absence(result, unit_name) do
    cond do
      result.cancelled ->
        {:error, :list_cancelled}

      result.timed_out ->
        {:error, :list_timeout}

      result.output_limit_exceeded ->
        {:error, :list_output_limit}

      result.containment_failure ->
        {:error, :list_containment_failure}

      result.exit_code != 0 ->
        {:error, :list_nonzero_exit}

      true ->
        parse_list_for_unit(result.stdout, unit_name)
    end
  end

  defp parse_list_for_unit(stdout, unit_name) when is_binary(stdout) do
    with :ok <- bounded_stdout(stdout),
         :ok <- require_valid_utf8(stdout),
         {:ok, decoded} <- decode_json(stdout),
         {:ok, entries} <- require_list(decoded),
         :ok <- require_entry_bound(entries),
         {:ok, ids} <- extract_ids(entries) do
      if unit_name in ids do
        :present
      else
        :absent
      end
    end
  end

  defp bounded_stdout(stdout) do
    if byte_size(stdout) <= @max_list_json_bytes, do: :ok, else: {:error, :list_too_large}
  end

  defp require_valid_utf8(bin) do
    if String.valid?(bin), do: :ok, else: {:error, :list_invalid_utf8}
  end

  defp decode_json(stdout) do
    case Jason.decode(stdout) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, :list_invalid_json}
    end
  end

  defp require_list(list) when is_list(list), do: {:ok, list}
  defp require_list(_), do: {:error, :list_not_array}

  defp require_entry_bound(entries) do
    if length(entries) <= @max_list_entries, do: :ok, else: {:error, :list_too_many_entries}
  end

  defp extract_ids(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case extract_configuration_id(entry) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp extract_configuration_id(entry) when is_map(entry) do
    config = Map.get(entry, "configuration") || Map.get(entry, :configuration)

    case config do
      config when is_map(config) ->
        id = Map.get(config, "id") || Map.get(config, :id)
        validate_id(id)

      _ ->
        {:error, :list_entry_missing_configuration}
    end
  end

  defp extract_configuration_id(_), do: {:error, :list_entry_not_object}

  defp validate_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, :list_entry_blank_id}

      byte_size(id) > @max_id_bytes ->
        {:error, :list_entry_id_too_long}

      not String.valid?(id) ->
        {:error, :list_entry_invalid_id}

      true ->
        {:ok, id}
    end
  end

  defp validate_id(_), do: {:error, :list_entry_invalid_id}

  defp show_primary(nil), do: nil

  defp show_primary(primary) when is_map(primary) do
    %{
      "status" => Atom.to_string(primary.status),
      "reason" => if(is_atom(primary.reason), do: Atom.to_string(primary.reason), else: nil),
      "phase" => phase_string(primary.phase),
      "exit_code" => primary.exit_code
    }
  end

  defp show_terminal(nil), do: nil
  defp show_terminal(terminal) when is_map(terminal), do: terminal
end
