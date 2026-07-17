defmodule Arbor.Shell.AppleContainerUnitCore do
  @moduledoc """
  Pure Apple Container unit lifecycle reducer (Construct-Reduce-Convert).

  Decides preflight → create → start → enforcing cleanup transitions and
  returns effects as plain data for a later imperative shell. Performs no IO,
  process execution, time, randomness, config, or GenServer calls.

  Plan input is unforgeable: request fields are re-admitted through
  `AppleContainerPlanCore.new/1` and the supplied plan must exactly equal the
  canonical reconstruction before any effect is emitted.

  A successful candidate terminal is forbidden until positive proof that the
  exact named unit is absent from a successful `container list --all --format
  json` (matching `configuration.id`). After create is attempted, every
  outcome enters cleanup (force-stop → force-delete → verify_absent). When
  absence is not proven, cleanup retries with an exponential delay effect so
  the imperative shell does not invent retry policy.

  Once absence is proven after a completed start, the terminal effect is
  `{:terminal, {:ok, shell_result}}` even for nonzero exit, timeout, output
  limit, cancellation, or containment_failure — matching Shell facade
  semantics. Preflight/create failures become `{:terminal, {:error, reason}}`.
  """

  alias Arbor.Shell.AppleContainerPlanCore

  # Successful list JSON used for absence proof only.
  @max_list_json_bytes 262_144
  # Create / force-stop / delete stdout is validated then discarded.
  @max_setup_cleanup_stdout_bytes 8_192
  # Candidate (start) stdout hard maximum matches Shell Executor.
  @max_candidate_stdout_bytes 16_777_216

  @max_list_entries 256
  @max_id_bytes 256
  @max_cleanup_diagnostics 16
  @max_cleanup_rounds 10_000

  @cleanup_retry_initial_ms 50
  @cleanup_retry_max_ms 2_000

  @logical_result_keys [
    :exit_code,
    :stdout,
    :stderr,
    :duration_ms,
    :timed_out,
    :cancelled,
    :killed,
    :output_limit_exceeded,
    :output_truncated,
    :containment_failure
  ]

  @allowed_result_keys MapSet.new(
                         @logical_result_keys ++
                           Enum.map(@logical_result_keys, &Atom.to_string/1)
                       )

  @boolean_result_keys [
    :timed_out,
    :cancelled,
    :killed,
    :output_limit_exceeded,
    :output_truncated,
    :containment_failure
  ]

  @type phase ::
          :verify_absent
          | :create
          | :start
          | :force_stop
          | :delete

  @type shell_result :: %{
          optional(:cancelled) => boolean(),
          optional(:containment_failure) => boolean(),
          optional(:duration_ms) => non_neg_integer(),
          exit_code: non_neg_integer(),
          stdout: binary(),
          stderr: String.t(),
          timed_out: boolean(),
          killed: boolean(),
          output_truncated: boolean(),
          output_limit_exceeded: boolean()
        }

  @type effect ::
          {:run, phase(), [String.t()]}
          | {:retry_after, non_neg_integer(), {:run, phase(), [String.t()]}}
          | {:terminal, {:ok, shell_result()} | {:error, atom()}}

  @type state :: %{
          unit_name: String.t(),
          argv: AppleContainerPlanCore.argv_plans(),
          stage: :preflight | :create | :start | :cleanup | :terminal,
          cleanup_step: :force_stop | :delete | :verify_absent | nil,
          create_attempted: boolean(),
          candidate_result: shell_result() | nil,
          error_reason: atom() | nil,
          cleanup_round: non_neg_integer(),
          cleanup_retry_ms: pos_integer(),
          cleanup_diagnostics: [atom()],
          terminal: {:ok, shell_result()} | {:error, atom()} | nil
        }

  @doc """
  Construct preflight lifecycle state from a canonical PlanCore plan.

  Reconstructs the closed PlanCore request from plan fields, re-admits it via
  `AppleContainerPlanCore.new/1`, and requires exact structural equality with
  the supplied plan before emitting the preflight `verify_absent` effect.
  """
  @spec new(term()) :: {:ok, state(), [effect()]} | {:error, term()}
  def new(plan) when is_map(plan) do
    with {:ok, canonical} <- admit_canonical_plan(plan) do
      state = %{
        unit_name: canonical.unit_name,
        argv: canonical.argv,
        stage: :preflight,
        cleanup_step: nil,
        create_attempted: false,
        candidate_result: nil,
        error_reason: nil,
        cleanup_round: 0,
        cleanup_retry_ms: @cleanup_retry_initial_ms,
        cleanup_diagnostics: [],
        terminal: nil
      }

      {:ok, state, [{:run, :verify_absent, canonical.argv.verify_absent}]}
    end
  rescue
    _ -> {:error, :invalid_plan}
  end

  def new(_), do: {:error, :invalid_plan}

  @doc """
  Apply an exact phase command result to lifecycle state.

  `phase` must match the pending effect. Returns updated state plus effects
  (next run, delayed retry, and/or terminal).
  """
  @spec apply_result(state(), phase(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def apply_result(%{stage: :terminal} = _state, _phase, _result) do
    {:error, :lifecycle_already_terminal}
  end

  def apply_result(state, phase, result) when is_map(state) and is_atom(phase) do
    with :ok <- expect_phase(state, phase),
         {:ok, normalized} <- normalize_result(result, phase) do
      reduce(state, phase, normalized)
    end
  rescue
    _ -> {:error, :invalid_command_result}
  end

  def apply_result(_state, _phase, _result), do: {:error, :invalid_command_result}

  @doc """
  Request cancellation.

  Before create is attempted, terminates as `{:error, :preflight_cancelled}`.
  At or after create (including while create/start is pending), records
  cancellation and enters enforcing cleanup without emitting a terminal
  effect. The future shell must first exhaust any active local PortSession,
  then interpret cleanup effects.
  """
  @spec cancel(state()) :: {:ok, state(), [effect()]} | {:error, term()}
  def cancel(%{stage: :terminal} = _state), do: {:error, :lifecycle_already_terminal}

  def cancel(state) when is_map(state) do
    cond do
      state.stage == :preflight and state.create_attempted == false ->
        terminal = {:error, :preflight_cancelled}

        state = %{
          state
          | stage: :terminal,
            terminal: terminal,
            error_reason: :preflight_cancelled
        }

        {:ok, state, [{:terminal, terminal}]}

      state.stage in [:create, :start, :cleanup] or state.create_attempted ->
        state =
          state
          |> Map.put(:error_reason, state.error_reason || :cancelled)
          |> maybe_mark_candidate_cancelled()

        enter_cleanup(state)

      true ->
        terminal = {:error, :cancelled}

        state = %{
          state
          | stage: :terminal,
            terminal: terminal,
            error_reason: :cancelled
        }

        {:ok, state, [{:terminal, terminal}]}
    end
  rescue
    _ -> {:error, :invalid_state}
  end

  def cancel(_), do: {:error, :invalid_state}

  @doc """
  JSON-clean lifecycle view.

  Includes candidate stdout only while a start result is retained or terminal
  success is held. Never includes setup/cleanup command stdout.
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
      "cleanup_retry_ms" => state.cleanup_retry_ms,
      "cleanup_diagnostics" => Enum.map(state.cleanup_diagnostics, &Atom.to_string/1),
      "error_reason" =>
        if(is_atom(state.error_reason), do: Atom.to_string(state.error_reason), else: nil),
      "candidate_result" => show_shell_result(state.candidate_result),
      "terminal" => show_terminal(state.terminal)
    }
  end

  # --- Canonical plan admission ----------------------------------------------

  defp admit_canonical_plan(plan) do
    with {:ok, request} <- extract_plan_request(plan),
         {:ok, canonical} <- AppleContainerPlanCore.new(request),
         :ok <- require_exact_plan(plan, canonical) do
      {:ok, canonical}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_plan}
    end
  end

  defp extract_plan_request(plan) do
    with {:ok, image} <- fetch_required_binary(plan, :image),
         {:ok, init_image} <- fetch_required_binary(plan, :init_image),
         {:ok, kernel_path} <- fetch_required_binary(plan, :kernel_path),
         {:ok, name} <- fetch_unit_name(plan),
         {:ok, projections} <- fetch_required_map(plan, :projections),
         {:ok, host_runtime_roots} <- fetch_required_map(plan, :host_runtime_roots),
         {:ok, mix_env} <- fetch_required_binary(plan, :mix_env),
         {:ok, command_args} <- fetch_command_args_field(plan),
         {:ok, resource_profile} <- fetch_resource_profile_field(plan) do
      {:ok,
       %{
         image: image,
         init_image: init_image,
         kernel_path: kernel_path,
         name: name,
         projections: projections,
         host_runtime_roots: host_runtime_roots,
         mix_env: mix_env,
         command_args: command_args,
         resource_profile: resource_profile
       }}
    end
  end

  # Re-admit the closed profile via PlanCore (single allowlist / limit map).
  # Legacy plans that omit the field are reconstructed as PlanCore's default
  # (`:standard`; see `normalize_legacy_resource_profile/1`).
  defp fetch_resource_profile_field(plan) do
    case {Map.fetch(plan, :resource_profile), Map.fetch(plan, "resource_profile")} do
      {{:ok, profile}, :error} ->
        AppleContainerPlanCore.normalize_resource_profile(profile)

      {:error, {:ok, profile}} ->
        AppleContainerPlanCore.normalize_resource_profile(profile)

      {:error, :error} ->
        # Compatibility: missing field → explicit default for PlanCore.
        {:ok, AppleContainerPlanCore.default_resource_profile()}

      _other ->
        {:error, :invalid_resource_profile}
    end
  end

  defp fetch_unit_name(plan) do
    # PlanCore emits :unit_name; request construction uses :name.
    case {Map.fetch(plan, :unit_name), Map.fetch(plan, :name), Map.fetch(plan, "unit_name"),
          Map.fetch(plan, "name")} do
      {{:ok, name}, :error, :error, :error} when is_binary(name) and name != "" ->
        {:ok, name}

      {:error, {:ok, name}, :error, :error} when is_binary(name) and name != "" ->
        {:ok, name}

      {:error, :error, {:ok, name}, :error} when is_binary(name) and name != "" ->
        {:ok, name}

      {:error, :error, :error, {:ok, name}} when is_binary(name) and name != "" ->
        {:ok, name}

      {{:ok, name}, {:ok, name}, :error, :error} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        {:error, :invalid_unit_name}
    end
  end

  defp fetch_required_binary(plan, key) do
    with :ok <- reject_duplicate_field_alias(plan, key),
         value when is_binary(value) and value != "" <- get_field(plan, key) do
      {:ok, value}
    else
      {:error, _} = err -> err
      _ -> {:error, {:invalid_plan_field, key}}
    end
  end

  defp fetch_required_map(plan, key) do
    with :ok <- reject_duplicate_field_alias(plan, key),
         value when is_map(value) <- get_field(plan, key) do
      {:ok, value}
    else
      {:error, _} = err -> err
      _ -> {:error, {:invalid_plan_field, key}}
    end
  end

  defp fetch_command_args_field(plan) do
    with :ok <- reject_duplicate_field_alias(plan, :command_args),
         args when is_list(args) <- get_field(plan, :command_args),
         true <- Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, _} = err -> err
      _ -> {:error, {:invalid_plan_field, :command_args}}
    end
  end

  defp reject_duplicate_field_alias(map, key) when is_atom(key) do
    atom? = Map.has_key?(map, key)
    string? = Map.has_key?(map, Atom.to_string(key))

    if atom? and string? do
      {:error, {:duplicate_plan_field_alias, key}}
    else
      :ok
    end
  end

  defp require_exact_plan(supplied, canonical) do
    # Legacy plans may omit `:resource_profile`; reconstruction makes them
    # explicitly `:standard` before equality so standard units still admit.
    supplied = normalize_legacy_resource_profile(supplied)

    if supplied == canonical do
      :ok
    else
      {:error, :plan_not_canonical}
    end
  end

  defp normalize_legacy_resource_profile(plan) when is_map(plan) do
    cond do
      Map.has_key?(plan, :resource_profile) or Map.has_key?(plan, "resource_profile") ->
        plan

      true ->
        Map.put(plan, :resource_profile, AppleContainerPlanCore.default_resource_profile())
    end
  end

  # --- Phase expectation -----------------------------------------------------

  defp expect_phase(%{stage: :preflight}, :verify_absent), do: :ok
  defp expect_phase(%{stage: :create}, :create), do: :ok
  defp expect_phase(%{stage: :start}, :start), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :force_stop}, :force_stop), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :delete}, :delete), do: :ok
  defp expect_phase(%{stage: :cleanup, cleanup_step: :verify_absent}, :verify_absent), do: :ok
  defp expect_phase(_state, _phase), do: {:error, :unexpected_phase}

  # --- Result normalization --------------------------------------------------

  defp normalize_result(result, phase) when is_map(result) do
    with :ok <- validate_result_keys(result),
         :ok <- reject_duplicate_result_aliases(result),
         {:ok, exit_code} <- fetch_exit_code(result),
         {:ok, stdout} <- fetch_stdout(result, phase),
         {:ok, flags} <- fetch_boolean_flags(result),
         {:ok, duration_ms} <- fetch_optional_duration_ms(result) do
      # Intermediate form always carries boolean flags for reduce; optional
      # false cancelled/containment_failure are dropped when projecting the
      # retained candidate to match Shell result shape.
      normalized =
        %{
          exit_code: exit_code,
          stdout: phase_stdout(phase, stdout),
          stderr: "",
          timed_out: flags.timed_out,
          killed: derive_killed(flags),
          output_truncated: flags.output_truncated,
          output_limit_exceeded: flags.output_limit_exceeded,
          cancelled: flags.cancelled,
          containment_failure: flags.containment_failure,
          __raw_stdout__: stdout
        }
        |> maybe_put_duration(duration_ms)

      {:ok, normalized}
    end
  end

  defp normalize_result(_, _), do: {:error, :invalid_command_result}

  defp phase_stdout(:start, stdout), do: stdout
  defp phase_stdout(_phase, _stdout), do: ""

  defp validate_result_keys(result) do
    keys = Map.keys(result)

    if Enum.all?(keys, &MapSet.member?(@allowed_result_keys, &1)) do
      :ok
    else
      {:error, :unsupported_result_keys}
    end
  end

  defp reject_duplicate_result_aliases(result) do
    Enum.reduce_while(@logical_result_keys, :ok, fn key, :ok ->
      atom? = Map.has_key?(result, key)
      string? = Map.has_key?(result, Atom.to_string(key))

      if atom? and string? do
        {:halt, {:error, {:duplicate_result_key_alias, key}}}
      else
        {:cont, :ok}
      end
    end)
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

  defp fetch_stdout(result, phase) do
    case get_field(result, :stdout) do
      nil ->
        {:ok, ""}

      out when is_binary(out) ->
        max = stdout_limit_for_phase(phase)

        if byte_size(out) > max do
          {:error, :stdout_too_long}
        else
          {:ok, out}
        end

      _ ->
        {:error, :invalid_stdout}
    end
  end

  @doc false
  @spec phase_output_limit(phase()) :: pos_integer()
  def phase_output_limit(phase), do: stdout_limit_for_phase(phase)

  @doc false
  @spec classify_exact_absence(term(), term()) ::
          :absent | :present | {:error, term()}
  def classify_exact_absence(unit_name, raw_result) do
    with {:ok, name} <- admit_classifier_unit_name(unit_name),
         {:ok, normalized} <- normalize_result(raw_result, :verify_absent) do
      classify_list_absence(normalized, name)
    end
  rescue
    _ -> {:error, :invalid_command_result}
  end

  defp stdout_limit_for_phase(:start), do: @max_candidate_stdout_bytes
  defp stdout_limit_for_phase(:verify_absent), do: @max_list_json_bytes
  defp stdout_limit_for_phase(:create), do: @max_setup_cleanup_stdout_bytes
  defp stdout_limit_for_phase(:force_stop), do: @max_setup_cleanup_stdout_bytes
  defp stdout_limit_for_phase(:delete), do: @max_setup_cleanup_stdout_bytes

  defp admit_classifier_unit_name(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, :invalid_unit_name}

      not String.valid?(name) ->
        {:error, :invalid_unit_name}

      byte_size(name) > @max_id_bytes ->
        {:error, :invalid_unit_name}

      true ->
        {:ok, name}
    end
  end

  defp admit_classifier_unit_name(_), do: {:error, :invalid_unit_name}

  defp fetch_boolean_flags(result) do
    Enum.reduce_while(@boolean_result_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case fetch_boolean(result, key) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp fetch_boolean(result, key) do
    case get_field(result, key) do
      nil -> {:ok, false}
      true -> {:ok, true}
      false -> {:ok, false}
      _ -> {:error, {:invalid_boolean_flag, key}}
    end
  end

  defp derive_killed(flags) do
    flags.killed or flags.timed_out or flags.cancelled or flags.output_limit_exceeded or
      flags.output_truncated or flags.containment_failure
  end

  defp fetch_optional_duration_ms(result) do
    case get_field(result, :duration_ms) do
      nil ->
        {:ok, :absent}

      ms when is_integer(ms) and ms >= 0 and ms <= 86_400_000 ->
        {:ok, ms}

      _ ->
        {:error, :invalid_duration_ms}
    end
  end

  defp maybe_put_duration(map, :absent), do: map
  defp maybe_put_duration(map, ms) when is_integer(ms), do: Map.put(map, :duration_ms, ms)

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp project_candidate(result) do
    result
    |> Map.delete(:__raw_stdout__)
    |> drop_false_optional(:cancelled)
    |> drop_false_optional(:containment_failure)
  end

  defp drop_false_optional(map, key) do
    if Map.get(map, key) == true, do: map, else: Map.delete(map, key)
  end

  defp list_stdout(result) do
    Map.get(result, :__raw_stdout__, result.stdout)
  end

  # --- Reduce ----------------------------------------------------------------

  defp reduce(%{stage: :preflight} = state, :verify_absent, result) do
    case classify_list_absence(result, state.unit_name) do
      :absent ->
        state = %{state | stage: :create, create_attempted: true}
        {:ok, state, [{:run, :create, state.argv.create}]}

      :present ->
        terminal = {:error, :unit_name_collision}

        state = %{
          state
          | stage: :terminal,
            terminal: terminal,
            error_reason: :unit_name_collision
        }

        {:ok, state, [{:terminal, terminal}]}

      {:error, reason} ->
        terminal = {:error, reason}
        state = %{state | stage: :terminal, terminal: terminal, error_reason: reason}
        {:ok, state, [{:terminal, terminal}]}
    end
  end

  defp reduce(%{stage: :create} = state, :create, result) do
    cond do
      result.cancelled ->
        enter_cleanup(%{state | error_reason: :cancelled})

      unclean_flags?(result) or result.exit_code != 0 ->
        enter_cleanup(%{state | error_reason: create_failure_reason(result)})

      true ->
        state = %{state | stage: :start}
        {:ok, state, [{:run, :start, state.argv.start}]}
    end
  end

  defp reduce(%{stage: :start} = state, :start, result) do
    candidate = project_candidate(result)
    state = %{state | candidate_result: candidate, error_reason: nil}
    enter_cleanup(state)
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
        terminal = finalize_terminal(state)
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
    result.timed_out or result.output_limit_exceeded or result.output_truncated or
      Map.get(result, :containment_failure) == true
  end

  defp create_failure_reason(result) do
    cond do
      result.timed_out -> :create_timeout
      result.output_limit_exceeded or result.output_truncated -> :create_output_limit
      Map.get(result, :containment_failure) == true -> :create_containment_failure
      true -> :create_failed
    end
  end

  defp enter_cleanup(state) do
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

  defp finalize_terminal(%{candidate_result: %{} = candidate}) do
    # Completed start result (any exit/flag combination) is Shell-success data.
    {:ok, candidate}
  end

  defp finalize_terminal(%{error_reason: reason}) when is_atom(reason) and not is_nil(reason) do
    {:error, reason}
  end

  defp finalize_terminal(_state), do: {:error, :missing_primary_outcome}

  defp maybe_mark_candidate_cancelled(%{candidate_result: nil} = state), do: state

  defp maybe_mark_candidate_cancelled(%{candidate_result: candidate} = state)
       when is_map(candidate) do
    updated =
      candidate
      |> Map.put(:cancelled, true)
      |> Map.put(:killed, true)

    %{state | candidate_result: updated}
  end

  defp record_cleanup_diag(state, step, result) do
    class =
      cond do
        Map.get(result, :cancelled) == true -> :cancelled
        result.timed_out -> :timeout
        result.output_limit_exceeded or result.output_truncated -> :output_limit
        Map.get(result, :containment_failure) == true -> :containment_failure
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

  # --- List absence proof ----------------------------------------------------

  # Positive absence: exit 0, no unclean flags, bounded JSON list, every entry
  # has nonblank bounded configuration.id, exact unit name not present.
  defp classify_list_absence(result, unit_name) do
    cond do
      Map.get(result, :cancelled) == true ->
        {:error, :list_cancelled}

      result.timed_out ->
        {:error, :list_timeout}

      result.output_limit_exceeded or result.output_truncated ->
        {:error, :list_output_limit}

      Map.get(result, :containment_failure) == true ->
        {:error, :list_containment_failure}

      result.exit_code != 0 ->
        {:error, :list_nonzero_exit}

      true ->
        parse_list_for_unit(list_stdout(result), unit_name)
    end
  end

  defp parse_list_for_unit(stdout, unit_name) when is_binary(stdout) do
    with :ok <- bounded_list_stdout(stdout),
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

  defp bounded_list_stdout(stdout) do
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

  defp show_shell_result(nil), do: nil

  defp show_shell_result(result) when is_map(result) do
    base = %{
      "exit_code" => result.exit_code,
      "stdout" => result.stdout,
      "stderr" => Map.get(result, :stderr, ""),
      "timed_out" => result.timed_out == true,
      "killed" => result.killed == true,
      "output_truncated" => result.output_truncated == true,
      "output_limit_exceeded" => result.output_limit_exceeded == true
    }

    base
    |> maybe_show_optional("cancelled", Map.get(result, :cancelled) == true)
    |> maybe_show_optional("containment_failure", Map.get(result, :containment_failure) == true)
    |> maybe_show_duration(Map.get(result, :duration_ms))
  end

  defp maybe_show_optional(map, _key, false), do: map
  defp maybe_show_optional(map, key, true), do: Map.put(map, key, true)

  defp maybe_show_duration(map, ms) when is_integer(ms), do: Map.put(map, "duration_ms", ms)
  defp maybe_show_duration(map, _), do: map

  defp show_terminal(nil), do: nil

  defp show_terminal({:ok, result}) when is_map(result) do
    %{"status" => "ok", "result" => show_shell_result(result)}
  end

  defp show_terminal({:error, reason}) when is_atom(reason) do
    %{"status" => "error", "reason" => Atom.to_string(reason)}
  end
end
