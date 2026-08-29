defmodule Arbor.Actions.Coding.CrossApp.ProgressCore do
  @moduledoc """
  Graph-neutral bounded CrossApp validation progress reducer.

  Closed snapshot keys: schema_version, status, identities, identities_digest,
  plan_digest, total_batch_count, total_file_count, passed_receipts,
  passed_receipts_digest, completed_batch_count, completed_file_count,
  next_batch_index, window_ordinal, static_stage_receipt_digest, capacity.

  Statuses: in_progress | completed. The immutable full plan is an injected
  binding, never retained. Capacity is a compact summary (no remaining suffix).

  CRC: no filesystem, process, clock, randomness, Application env, Registry,
  GenServer, or device IO. Identities, plan, static digest, and per-batch
  budget are injected.
  """

  alias Arbor.Actions.Coding.CrossApp.ContinuationCore
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @schema_version 1
  @max_state_json_bytes 163_840
  @max_identities_json_bytes 4_096
  @max_observation_json_bytes 163_840
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @forbidden_keys MapSet.new(
                    ~w(authority authorization capability credential fence_token secret token)
                  )

  @state_keys Enum.sort(~w(
    capacity
    completed_batch_count
    completed_file_count
    identities
    identities_digest
    next_batch_index
    passed_receipts
    passed_receipts_digest
    plan_digest
    schema_version
    static_stage_receipt_digest
    status
    total_batch_count
    total_file_count
    window_ordinal
  ))

  @binding_keys MapSet.new(
                  ~w(identities per_batch_budget_ms planned_batches static_stage_receipt_digest window_ordinal)
                )
  @required_binding_keys ~w(identities planned_batches static_stage_receipt_digest)
  @batch_keys Enum.sort(~w(count index inventory_sha256 label total))
  @receipt_keys Enum.sort(~w(count index inventory_sha256 label outcome total))
  @observation_keys Enum.sort(~w(disposition new_receipts schema_version))
  @capacity_keys Enum.sort(~w(
    available_budget_ms
    completed_batch_count
    completed_file_count
    interrupted_batch
    per_batch_budget_ms
    phase
    remaining_suffix_digest
    total_batch_count
    total_file_count
    unstarted_batch_count
    unstarted_file_count
  ))
  @statuses ~w(completed in_progress)

  @type error :: atom()
  @type state :: %{required(String.t()) => term()}

  @doc "Progress schema version."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Maximum encoded compact-progress JSON bytes."
  @spec max_json_bytes() :: 163_840
  def max_json_bytes, do: @max_state_json_bytes

  @doc "Derived JSON ceilings for compact progress."
  @spec limits() :: %{required(String.t()) => pos_integer()}
  def limits do
    %{
      "max_identities_json_bytes" => @max_identities_json_bytes,
      "max_observation_json_bytes" => @max_observation_json_bytes,
      "max_state_json_bytes" => @max_state_json_bytes
    }
  end

  @doc "Construct fresh in_progress compact progress from injected bindings."
  @spec new(term()) :: {:ok, state()} | {:error, error()}
  def new(bindings) do
    with {:ok, parsed} <- parse_bindings(bindings, :fresh),
         {:ok, state} <- build_fresh(parsed),
         :ok <- bound_state(state) do
      {:ok, state}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Rehydrate a compact snapshot against freshly injected bindings."
  @spec admit(term(), term()) :: {:ok, state()} | {:error, error()}
  def admit(snapshot, bindings) do
    with {:ok, parsed} <- parse_bindings(bindings, :admit),
         {:ok, state} <- rehydrate(snapshot, parsed),
         :ok <- bound_state(state) do
      {:ok, state}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "JSON snapshot with closed insertion order. Non-maps fail closed."
  @spec show(term()) :: state() | {:error, :malformed_state}
  def show(state) when is_map(state) and not is_struct(state) do
    case canonicalize_state(state) do
      {:ok, rebuilt} -> rebuilt
      {:error, _} -> {:error, :malformed_state}
    end
  end

  def show(_state), do: {:error, :malformed_state}

  @doc "Apply a window observation (new receipts plus completed or v3 capacity)."
  @spec advance(term(), term(), term()) :: {:ok, state()} | {:error, error()}
  def advance(state, bindings, observation) do
    with {:ok, parsed} <- parse_bindings(bindings, :advance),
         {:ok, current} <- rehydrate(state, parsed),
         :ok <- require_in_progress(current),
         {:ok, observation} <- admit_observation(observation),
         {:ok, receipts} <- apply_receipts(current, parsed.planned, observation["new_receipts"]),
         {:ok, next} <-
           apply_disposition(current, parsed, receipts, observation["disposition"]),
         :ok <- bound_state(next) do
      {:ok, next}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  defp parse_bindings(bindings, mode) do
    with :ok <- require_json_object(bindings),
         :ok <- require_allowed_keys(bindings, @binding_keys),
         :ok <- require_keys(bindings, @required_binding_keys),
         :ok <- reject_snapshot_keys(bindings),
         :ok <- reject_forbidden_keys(bindings),
         {:ok, identities} <- ContinuationCore.admit_identities(bindings["identities"]),
         :ok <- bound_json(identities, @max_identities_json_bytes, :oversized_state),
         {:ok, identities_digest} <- ContinuationCore.digest(identities),
         {:ok, planned, plan_digest, total_batches, total_files} <-
           admit_planned_batches(bindings["planned_batches"]),
         :ok <- match_plan_digest(identities["validation_plan_digest"], plan_digest),
         {:ok, static_digest} <- parse_hex(bindings["static_stage_receipt_digest"]),
         {:ok, window_ordinal} <- parse_optional_ordinal(bindings, mode),
         {:ok, per_batch} <- parse_optional_per_batch(bindings, mode) do
      {:ok,
       %{
         identities: identities,
         identities_digest: identities_digest,
         planned: planned,
         plan_digest: plan_digest,
         total_batches: total_batches,
         total_files: total_files,
         static_digest: static_digest,
         window_ordinal: window_ordinal,
         per_batch: per_batch
       }}
    else
      {:error, :oversized_state} = error -> error
      {:error, :identity_drift} = error -> error
      {:error, :plan_drift} = error -> error
      {:error, :ordinal_drift} = error -> error
      {:error, :invalid_batch_plan} = error -> error
      {:error, _reason} = error -> error
    end
  end

  defp reject_snapshot_keys(bindings) do
    if Map.has_key?(bindings, "schema_version") or Map.has_key?(bindings, "status") or
         Map.has_key?(bindings, "passed_receipts"),
       do: {:error, :malformed_state},
       else: :ok
  end

  defp parse_optional_ordinal(bindings, :fresh) do
    case Map.fetch(bindings, "window_ordinal") do
      :error -> {:ok, 0}
      {:ok, 0} -> {:ok, 0}
      {:ok, value} when is_integer(value) and not is_boolean(value) -> {:error, :ordinal_drift}
      {:ok, _} -> {:error, :malformed_state}
    end
  end

  defp parse_optional_ordinal(bindings, _mode) do
    case Map.fetch(bindings, "window_ordinal") do
      :error ->
        {:ok, :unspecified}

      {:ok, value} when is_integer(value) and not is_boolean(value) and value >= 0 ->
        {:ok, value}

      {:ok, _} ->
        {:error, :malformed_state}
    end
  end

  defp parse_optional_per_batch(bindings, _mode) do
    case Map.fetch(bindings, "per_batch_budget_ms") do
      :error ->
        {:ok, :unspecified}

      {:ok, value} when is_integer(value) and not is_boolean(value) and value > 0 ->
        {:ok, value}

      {:ok, _} ->
        {:error, :malformed_state}
    end
  end

  defp build_fresh(parsed) do
    with {:ok, receipts_digest} <- ContinuationCore.digest([]) do
      {:ok,
       build_state(%{
         status: "in_progress",
         identities: parsed.identities,
         identities_digest: parsed.identities_digest,
         plan_digest: parsed.plan_digest,
         total_batch_count: parsed.total_batches,
         total_file_count: parsed.total_files,
         passed_receipts: [],
         passed_receipts_digest: receipts_digest,
         completed_batch_count: 0,
         completed_file_count: 0,
         next_batch_index: 1,
         window_ordinal: 0,
         static_digest: parsed.static_digest,
         capacity: nil
       })}
    end
  end

  defp rehydrate(snapshot, parsed) do
    with :ok <- require_json_object(snapshot),
         :ok <- reject_forbidden_keys(snapshot),
         :ok <- require_exact_keys(snapshot, @state_keys),
         :ok <- require_schema(snapshot["schema_version"]),
         {:ok, status} <- parse_status(snapshot["status"]),
         :ok <- match_identities(snapshot["identities"], parsed.identities),
         :ok <-
           match(snapshot["identities_digest"], parsed.identities_digest, :identity_drift),
         :ok <- match(snapshot["plan_digest"], parsed.plan_digest, :plan_drift),
         :ok <-
           match(snapshot["total_batch_count"], parsed.total_batches, :plan_drift),
         :ok <- match(snapshot["total_file_count"], parsed.total_files, :plan_drift),
         :ok <-
           match(
             snapshot["static_stage_receipt_digest"],
             parsed.static_digest,
             :static_receipt_drift
           ),
         {:ok, receipts} <- parse_prefix(snapshot["passed_receipts"], parsed.planned),
         {:ok, receipts_digest} <- ContinuationCore.digest(receipts),
         :ok <-
           match(snapshot["passed_receipts_digest"], receipts_digest, :receipt_prefix_drift),
         completed_batches = length(receipts),
         completed_files = file_count(receipts),
         :ok <-
           match(snapshot["completed_batch_count"], completed_batches, :count_drift),
         :ok <- match(snapshot["completed_file_count"], completed_files, :count_drift),
         {:ok, capacity} <-
           parse_stored_capacity(snapshot["capacity"], parsed, receipts, status),
         :ok <- check_completed_shape(status, receipts, parsed.planned, capacity),
         expected_next = completed_batches + 1,
         :ok <- match_next_index(snapshot["next_batch_index"], expected_next, status, parsed),
         {:ok, ordinal} <- parse_stored_ordinal(snapshot["window_ordinal"]),
         :ok <- match_binding_ordinal(parsed.window_ordinal, ordinal),
         :ok <- check_ordinal_shape(ordinal, receipts, capacity, status) do
      {:ok,
       build_state(%{
         status: status,
         identities: parsed.identities,
         identities_digest: parsed.identities_digest,
         plan_digest: parsed.plan_digest,
         total_batch_count: parsed.total_batches,
         total_file_count: parsed.total_files,
         passed_receipts: receipts,
         passed_receipts_digest: receipts_digest,
         completed_batch_count: completed_batches,
         completed_file_count: completed_files,
         next_batch_index: snapshot["next_batch_index"],
         window_ordinal: ordinal,
         static_digest: parsed.static_digest,
         capacity: capacity
       })}
    end
  end

  defp canonicalize_state(state) do
    with :ok <- require_json_object(state),
         :ok <- reject_forbidden_keys(state),
         :ok <- require_exact_keys(state, @state_keys),
         :ok <- require_schema(state["schema_version"]),
         {:ok, status} <- parse_status(state["status"]),
         {:ok, identities} <- ContinuationCore.admit_identities(state["identities"]),
         {:ok, expected_identities_digest} <- ContinuationCore.digest(identities),
         {:ok, static_digest} <- parse_hex(state["static_stage_receipt_digest"]),
         {:ok, plan_digest} <- parse_hex(state["plan_digest"]),
         :ok <- match(plan_digest, identities["validation_plan_digest"], :malformed_state),
         {:ok, identities_digest} <- parse_hex(state["identities_digest"]),
         :ok <- match(identities_digest, expected_identities_digest, :malformed_state),
         {:ok, total_batches} <- parse_positive_integer(state["total_batch_count"]),
         {:ok, total_files} <- parse_positive_integer(state["total_file_count"]),
         {:ok, receipts} <- canonicalize_receipts(state["passed_receipts"], total_batches),
         {:ok, expected_receipts_digest} <- ContinuationCore.digest(receipts),
         {:ok, receipts_digest} <- parse_hex(state["passed_receipts_digest"]),
         :ok <- match(receipts_digest, expected_receipts_digest, :malformed_state),
         completed_batches = length(receipts),
         completed_files = file_count(receipts),
         :ok <- match(state["completed_batch_count"], completed_batches, :malformed_state),
         :ok <- match(state["completed_file_count"], completed_files, :malformed_state),
         :ok <- match(state["next_batch_index"], completed_batches + 1, :malformed_state),
         :ok <- check_intrinsic_completion(status, completed_batches, total_batches),
         {:ok, capacity} <- canonicalize_capacity(state["capacity"]),
         :ok <-
           check_intrinsic_capacity(
             capacity,
             status,
             total_batches,
             total_files,
             completed_batches,
             completed_files
           ),
         {:ok, ordinal} <- parse_stored_ordinal(state["window_ordinal"]),
         :ok <- check_ordinal_shape(ordinal, receipts, capacity, status),
         rebuilt <-
           build_state(%{
             status: status,
             identities: identities,
             identities_digest: identities_digest,
             plan_digest: plan_digest,
             total_batch_count: total_batches,
             total_file_count: total_files,
             passed_receipts: receipts,
             passed_receipts_digest: receipts_digest,
             completed_batch_count: completed_batches,
             completed_file_count: completed_files,
             next_batch_index: completed_batches + 1,
             window_ordinal: ordinal,
             static_digest: static_digest,
             capacity: capacity
           }),
         :ok <- bound_state(rebuilt) do
      {:ok, rebuilt}
    end
  end

  defp canonicalize_receipts(receipts, total_batches) when is_list(receipts) do
    receipts
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {receipt, expected_index}, {:ok, acc} ->
      with {:ok, canonical} <- canonicalize_receipt(receipt),
           :ok <- match(canonical["index"], expected_index, :malformed_state),
           :ok <- match(canonical["total"], total_batches, :malformed_state) do
        {:cont, {:ok, [canonical | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonicalize_receipts(_receipts, _total_batches), do: {:error, :malformed_state}

  defp canonicalize_receipt(receipt) when is_map(receipt) and not is_struct(receipt) do
    with :ok <- require_json_object(receipt),
         :ok <- reject_forbidden_keys(receipt),
         :ok <- require_exact_keys(receipt, @receipt_keys),
         :ok <- match(receipt["outcome"], "passed", :malformed_state),
         {:ok, batch} <- canonicalize_batch(Map.delete(receipt, "outcome")) do
      {:ok, Map.put(batch, "outcome", "passed")}
    end
  end

  defp canonicalize_receipt(_receipt), do: {:error, :malformed_state}

  defp canonicalize_capacity(nil), do: {:ok, nil}

  defp canonicalize_capacity(capacity) when is_map(capacity) and not is_struct(capacity) do
    with :ok <- require_json_object(capacity),
         :ok <- reject_forbidden_keys(capacity),
         :ok <- require_exact_keys(capacity, @capacity_keys),
         :ok <- reject_key(capacity, "unstarted_batches"),
         {:ok, interrupted} <- canonicalize_batch(capacity["interrupted_batch"]) do
      {:ok,
       build_capacity(%{
         phase: capacity["phase"],
         available_budget_ms: capacity["available_budget_ms"],
         per_batch_budget_ms: capacity["per_batch_budget_ms"],
         completed_batch_count: capacity["completed_batch_count"],
         completed_file_count: capacity["completed_file_count"],
         unstarted_batch_count: capacity["unstarted_batch_count"],
         unstarted_file_count: capacity["unstarted_file_count"],
         total_batch_count: capacity["total_batch_count"],
         total_file_count: capacity["total_file_count"],
         remaining_suffix_digest: capacity["remaining_suffix_digest"],
         interrupted_batch: interrupted
       })}
    end
  end

  defp canonicalize_capacity(_capacity), do: {:error, :malformed_state}

  defp canonicalize_batch(nil), do: {:ok, nil}

  defp canonicalize_batch(batch) when is_map(batch) and not is_struct(batch) do
    with :ok <- require_json_object(batch),
         :ok <- reject_forbidden_keys(batch),
         :ok <- require_exact_keys(batch, @batch_keys),
         {:ok, _digest} <- ValidationCapacityHandoff.ordered_plan_digest([batch]) do
      {:ok,
       %{
         "index" => batch["index"],
         "total" => batch["total"],
         "count" => batch["count"],
         "label" => batch["label"],
         "inventory_sha256" => batch["inventory_sha256"]
       }}
    end
  end

  defp canonicalize_batch(_batch), do: {:error, :malformed_state}

  defp check_intrinsic_completion("completed", completed, total) when completed == total, do: :ok

  defp check_intrinsic_completion("in_progress", completed, total) when completed < total, do: :ok

  defp check_intrinsic_completion(_status, _completed, _total), do: {:error, :malformed_state}

  defp check_intrinsic_capacity(nil, "completed", _total_batches, _total_files, _done, _files),
    do: :ok

  defp check_intrinsic_capacity(nil, "in_progress", _total_batches, _total_files, 0, 0),
    do: :ok

  defp check_intrinsic_capacity(
         capacity,
         "in_progress",
         total_batches,
         total_files,
         completed_batches,
         completed_files
       )
       when is_map(capacity) do
    interrupted = capacity["interrupted_batch"]
    interrupted_files = if is_map(interrupted), do: interrupted["count"], else: 0
    interrupted_batches = if is_map(interrupted), do: 1, else: 0
    expected_unstarted_batches = total_batches - completed_batches - interrupted_batches
    expected_unstarted_files = total_files - completed_files - interrupted_files

    with :ok <- require_nonnegative_integer(expected_unstarted_batches),
         :ok <- require_nonnegative_integer(expected_unstarted_files),
         :ok <- match(capacity["available_budget_ms"], 0, :malformed_state),
         {:ok, _per_batch} <- parse_positive_integer(capacity["per_batch_budget_ms"]),
         :ok <- match(capacity["completed_batch_count"], completed_batches, :malformed_state),
         :ok <- match(capacity["completed_file_count"], completed_files, :malformed_state),
         :ok <- match(capacity["total_batch_count"], total_batches, :malformed_state),
         :ok <- match(capacity["total_file_count"], total_files, :malformed_state),
         :ok <-
           match(
             capacity["unstarted_batch_count"],
             expected_unstarted_batches,
             :malformed_state
           ),
         :ok <-
           match(capacity["unstarted_file_count"], expected_unstarted_files, :malformed_state),
         {:ok, _suffix_digest} <- parse_hex(capacity["remaining_suffix_digest"]),
         :ok <-
           check_intrinsic_interrupted(
             interrupted,
             completed_batches,
             total_batches,
             capacity["phase"]
           ) do
      :ok
    end
  end

  defp check_intrinsic_capacity(
         _capacity,
         _status,
         _total_batches,
         _total_files,
         _completed_batches,
         _completed_files
       ),
       do: {:error, :malformed_state}

  defp check_intrinsic_interrupted(nil, 0, _total_batches, "structural"), do: :ok

  defp check_intrinsic_interrupted(nil, _completed_batches, _total_batches, "runtime"), do: :ok

  defp check_intrinsic_interrupted(interrupted, completed_batches, total_batches, "runtime")
       when is_map(interrupted) do
    with :ok <- match(interrupted["index"], completed_batches + 1, :malformed_state),
         :ok <- match(interrupted["total"], total_batches, :malformed_state) do
      :ok
    end
  end

  defp check_intrinsic_interrupted(_interrupted, _completed_batches, _total_batches, _phase),
    do: {:error, :malformed_state}

  defp require_in_progress(%{"status" => "in_progress"}), do: :ok
  defp require_in_progress(_state), do: {:error, :malformed_state}

  defp admit_observation(observation) do
    with :ok <- require_json_object(observation),
         :ok <- reject_forbidden_keys(observation),
         :ok <- require_exact_keys(observation, @observation_keys),
         :ok <- require_schema(observation["schema_version"]),
         :ok <- require_json_clean_list(observation["new_receipts"]),
         :ok <- require_json_object(observation["disposition"]),
         :ok <-
           bound_json(observation, @max_observation_json_bytes, :oversized_observation) do
      {:ok, observation}
    else
      {:error, :oversized_observation} = error -> error
      {:error, :malformed_state} -> {:error, :malformed_observation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_receipts(state, planned, new_receipts) when is_list(new_receipts) do
    Enum.reduce_while(new_receipts, {:ok, state["passed_receipts"]}, fn receipt, {:ok, prefix} ->
      case receipt_decision(prefix, planned, receipt) do
        {:ok, admitted} -> {:cont, {:ok, prefix ++ [admitted]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_receipts(_state, _planned, _new_receipts), do: {:error, :malformed_observation}

  defp apply_disposition(_state, _parsed, _receipts, %{"type" => "failed"}) do
    {:error, :malformed_observation}
  end

  defp apply_disposition(state, parsed, receipts, %{"type" => "completed"} = disposition) do
    with :ok <- require_exact_keys(disposition, ~w(type)),
         :ok <- require_complete_prefix(receipts, parsed.planned) do
      finalize(state, parsed, receipts, "completed", nil, state["window_ordinal"] + 1)
    end
  end

  defp apply_disposition(
         state,
         parsed,
         receipts,
         %{"type" => "capacity_handoff"} = disposition
       ) do
    with :ok <-
           require_exact_keys(disposition, Enum.sort(~w(capacity_handoff type))),
         {:ok, compact} <-
           reduce_capacity_handoff(
             disposition["capacity_handoff"],
             parsed.planned,
             receipts,
             parsed.per_batch
           ) do
      finalize(state, parsed, receipts, "in_progress", compact, state["window_ordinal"] + 1)
    end
  end

  defp apply_disposition(_state, _parsed, _receipts, _disposition),
    do: {:error, :malformed_observation}

  defp finalize(state, parsed, receipts, status, capacity, ordinal) do
    completed_batches = length(receipts)
    completed_files = file_count(receipts)
    next_index = completed_batches + 1

    with {:ok, receipts_digest} <- ContinuationCore.digest(receipts),
         :ok <- check_ordinal_shape(ordinal, receipts, capacity, status),
         :ok <- check_completed_shape(status, receipts, parsed.planned, capacity) do
      {:ok,
       build_state(%{
         status: status,
         identities: state["identities"],
         identities_digest: state["identities_digest"],
         plan_digest: parsed.plan_digest,
         total_batch_count: parsed.total_batches,
         total_file_count: parsed.total_files,
         passed_receipts: receipts,
         passed_receipts_digest: receipts_digest,
         completed_batch_count: completed_batches,
         completed_file_count: completed_files,
         next_batch_index: next_index,
         window_ordinal: ordinal,
         static_digest: parsed.static_digest,
         capacity: capacity
       })}
    end
  end

  defp receipt_decision(prefix, planned, receipt) do
    next = length(prefix) + 1

    cond do
      not receipt_shape?(receipt) ->
        {:error, :malformed_state}

      not valid_index?(receipt["index"]) ->
        {:error, :malformed_state}

      receipt["index"] <= length(prefix) ->
        {:error, :duplicate_receipt}

      receipt["index"] > next ->
        {:error, :skipped_receipt}

      receipt["index"] == next and compact(receipt) != compact(Enum.at(planned, next - 1)) and
          compact_matches_other_slot?(receipt, planned, next) ->
        {:error, :reordered_receipt}

      receipt["index"] == next ->
        accept_next_receipt(receipt, Enum.at(planned, next - 1), next)

      true ->
        {:error, :malformed_state}
    end
  end

  defp receipt_shape?(receipt) do
    is_map(receipt) and not is_struct(receipt) and json_clean?(receipt) and
      exact_keys?(receipt, @receipt_keys) and is_integer(receipt["index"]) and
      not is_boolean(receipt["index"])
  end

  defp valid_index?(index) when is_integer(index) and not is_boolean(index) and index >= 1,
    do: true

  defp valid_index?(_index), do: false

  defp compact(batch) when is_map(batch) do
    {batch["total"], batch["count"], batch["label"], batch["inventory_sha256"]}
  end

  defp compact_matches_other_slot?(receipt, planned, index) do
    wanted = compact(receipt)

    planned
    |> Enum.with_index(1)
    |> Enum.any?(fn {batch, j} -> j != index and compact(batch) == wanted end)
  end

  defp accept_next_receipt(receipt, expected, index) do
    cond do
      compact(receipt) != compact(expected) ->
        {:error, :contradictory_receipt}

      receipt["outcome"] != "passed" ->
        {:error, :contradictory_receipt}

      receipt["index"] != expected["index"] or receipt["total"] != expected["total"] or
        receipt["count"] != expected["count"] or receipt["label"] != expected["label"] or
          receipt["inventory_sha256"] != expected["inventory_sha256"] ->
        {:error, :contradictory_receipt}

      receipt["label"] !=
          expected_label(
            index,
            receipt["total"],
            receipt["count"],
            receipt["inventory_sha256"]
          ) ->
        {:error, :contradictory_receipt}

      true ->
        {:ok,
         %{
           "index" => expected["index"],
           "total" => expected["total"],
           "count" => expected["count"],
           "label" => expected["label"],
           "inventory_sha256" => expected["inventory_sha256"],
           "outcome" => "passed"
         }}
    end
  end

  defp expected_label(index, total, count, inventory_sha256),
    do: "batch-#{index}-of-#{total}-n#{count}-#{inventory_sha256}"

  defp parse_prefix(receipts, planned) when is_list(receipts) do
    with :ok <- require_json_clean_list(receipts),
         true <- length(receipts) <= length(planned),
         :ok <- validate_prefix(receipts, planned, 1) do
      {:ok, receipts}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_state}
    end
  end

  defp parse_prefix(_receipts, _planned), do: {:error, :malformed_state}

  defp validate_prefix([], _planned, _index), do: :ok

  defp validate_prefix([receipt | rest], planned, index) do
    expected = Enum.at(planned, index - 1)

    if receipt_shape?(receipt) and receipt["outcome"] == "passed" and
         receipt["index"] == index and compact(receipt) == compact(expected) do
      validate_prefix(rest, planned, index + 1)
    else
      {:error, :malformed_state}
    end
  end

  defp require_complete_prefix(receipts, planned) do
    if length(receipts) == length(planned) and receipts_match_plan?(receipts, planned) do
      :ok
    else
      {:error, :incomplete_plan}
    end
  end

  defp receipts_match_plan?(receipts, planned) do
    Enum.zip(receipts, planned)
    |> Enum.with_index(1)
    |> Enum.all?(fn {{receipt, batch}, index} ->
      receipt["outcome"] == "passed" and compact(receipt) == compact(batch) and
        receipt["index"] == index
    end)
  end

  defp reduce_capacity_handoff(handoff, planned, receipts, per_batch) do
    if is_map(handoff) and not is_struct(handoff) and json_clean?(handoff) do
      case ValidationCapacityHandoff.normalize(handoff) do
        {:ok, canonical} ->
          bind_live_capacity(canonical, planned, receipts, per_batch)

        {:error, _} ->
          {:error, :non_canonical_capacity_handoff}
      end
    else
      {:error, :non_canonical_capacity_handoff}
    end
  end

  defp bind_live_capacity(handoff, planned, receipts, per_batch) do
    with :ok <- require_per_batch(per_batch),
         :ok <- bind_handoff(handoff, planned, receipts, per_batch, :live) do
      {:ok, compact_from_v3(handoff)}
    else
      {:error, :malformed_state} = error -> error
      {:error, _reason} -> {:error, :non_canonical_capacity_handoff}
    end
  end

  defp require_per_batch(value) when is_integer(value) and value > 0, do: :ok
  defp require_per_batch(_value), do: {:error, :malformed_state}

  defp compact_from_v3(handoff) do
    {:ok, interrupted} = canonicalize_batch(handoff["interrupted_batch"])

    build_capacity(%{
      phase: handoff["phase"],
      available_budget_ms: handoff["available_budget_ms"],
      per_batch_budget_ms: handoff["per_batch_budget_ms"],
      completed_batch_count: handoff["completed_batch_count"],
      completed_file_count: handoff["completed_file_count"],
      unstarted_batch_count: handoff["unstarted_batch_count"],
      unstarted_file_count: handoff["unstarted_file_count"],
      total_batch_count: handoff["total_batch_count"],
      total_file_count: handoff["total_file_count"],
      remaining_suffix_digest: handoff["ordered_plan_sha256"],
      interrupted_batch: interrupted
    })
  end

  defp parse_stored_capacity(nil, _parsed, _receipts, _status), do: {:ok, nil}

  defp parse_stored_capacity(capacity, parsed, receipts, "in_progress")
       when is_map(capacity) do
    with :ok <- require_json_object(capacity),
         :ok <- reject_forbidden_keys(capacity),
         :ok <- require_exact_keys(capacity, @capacity_keys),
         :ok <- reject_key(capacity, "unstarted_batches"),
         :ok <- bind_compact_capacity(capacity, parsed, receipts),
         {:ok, compact} <- canonicalize_capacity(capacity) do
      {:ok, compact}
    else
      {:error, :capacity_drift} = error -> error
      {:error, :non_canonical_capacity_handoff} = error -> error
      {:error, _reason} -> {:error, :capacity_drift}
    end
  end

  defp parse_stored_capacity(capacity, _parsed, _receipts, "completed") when not is_nil(capacity),
    do: {:error, :capacity_drift}

  defp parse_stored_capacity(_capacity, _parsed, _receipts, _status),
    do: {:error, :malformed_state}

  defp bind_compact_capacity(capacity, parsed, receipts) do
    completed = length(receipts)
    interrupted = capacity["interrupted_batch"]
    remaining = remaining_from_plan(parsed.planned, completed, interrupted)

    with {:ok, suffix_digest} <- remaining_digest(remaining),
         :ok <- match(capacity["available_budget_ms"], 0, :capacity_drift),
         :ok <- match(capacity["completed_batch_count"], completed, :capacity_drift),
         :ok <- match(capacity["completed_file_count"], file_count(receipts), :capacity_drift),
         :ok <- match(capacity["total_batch_count"], parsed.total_batches, :capacity_drift),
         :ok <- match(capacity["total_file_count"], parsed.total_files, :capacity_drift),
         :ok <- match(capacity["remaining_suffix_digest"], suffix_digest, :capacity_drift),
         :ok <- match_compact_phase(capacity, completed, interrupted),
         :ok <- match_interrupted(interrupted, parsed.planned, completed),
         :ok <- match_unstarted_counts(capacity, remaining, interrupted),
         :ok <- match_stored_per_batch(parsed.per_batch, capacity["per_batch_budget_ms"]) do
      :ok
    else
      {:error, :capacity_drift} = error -> error
      {:error, _} -> {:error, :capacity_drift}
    end
  end

  defp remaining_from_plan(planned, completed, nil), do: Enum.drop(planned, completed)

  defp remaining_from_plan(planned, completed, interrupted) when is_map(interrupted) do
    [Enum.at(planned, completed) | Enum.drop(planned, completed + 1)]
  end

  defp remaining_from_plan(_planned, _completed, _interrupted), do: :invalid

  defp remaining_digest(:invalid), do: {:error, :capacity_drift}
  defp remaining_digest([]), do: {:error, :capacity_drift}

  defp remaining_digest(remaining) when is_list(remaining) do
    case ValidationCapacityHandoff.ordered_plan_digest(remaining) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, :capacity_drift}
    end
  end

  defp match_compact_phase(%{"phase" => "structural"}, 0, nil), do: :ok

  defp match_compact_phase(%{"phase" => "runtime"}, completed, nil)
       when is_integer(completed) and completed >= 0,
       do: :ok

  defp match_compact_phase(%{"phase" => "runtime"}, _completed, interrupted)
       when is_map(interrupted),
       do: :ok

  defp match_compact_phase(_capacity, _completed, _interrupted), do: {:error, :capacity_drift}

  defp match_interrupted(nil, planned, completed) do
    case Enum.drop(planned, completed) do
      [] -> {:error, :capacity_drift}
      _remaining -> :ok
    end
  end

  defp match_interrupted(interrupted, planned, completed) when is_map(interrupted) do
    case canonicalize_batch(Enum.at(planned, completed)) do
      {:ok, expected} ->
        if interrupted === expected, do: :ok, else: {:error, :capacity_drift}

      {:error, _} ->
        {:error, :capacity_drift}
    end
  end

  defp match_interrupted(_interrupted, _planned, _completed), do: {:error, :capacity_drift}

  defp match_unstarted_counts(capacity, remaining, nil) do
    unstarted = remaining

    with :ok <- match(capacity["unstarted_batch_count"], length(unstarted), :capacity_drift),
         :ok <- match(capacity["unstarted_file_count"], file_count(unstarted), :capacity_drift) do
      :ok
    end
  end

  defp match_unstarted_counts(capacity, remaining, interrupted) when is_map(interrupted) do
    unstarted = Enum.drop(remaining, 1)

    with :ok <- match(capacity["unstarted_batch_count"], length(unstarted), :capacity_drift),
         :ok <- match(capacity["unstarted_file_count"], file_count(unstarted), :capacity_drift) do
      :ok
    end
  end

  defp match_unstarted_counts(_capacity, _remaining, _interrupted),
    do: {:error, :capacity_drift}

  defp match_stored_per_batch(:unspecified, value)
       when is_integer(value) and not is_boolean(value) and value > 0,
       do: :ok

  defp match_stored_per_batch(expected, actual) when is_integer(expected),
    do: match(actual, expected, :capacity_drift)

  defp match_stored_per_batch(_expected, _actual), do: {:error, :capacity_drift}

  defp bind_handoff(handoff, planned, receipts, per_batch, mode) do
    completed = handoff["completed_batch_count"]
    interrupted = handoff["interrupted_batch"]
    unstarted = handoff["unstarted_batches"]
    remaining = remaining_batches(interrupted, unstarted)
    suffix = Enum.drop(planned, completed)
    prefix = Enum.take(receipts, completed)
    prefix_files = file_count(prefix)
    error = if mode == :live, do: :non_canonical_capacity_handoff, else: :malformed_state

    cond do
      not is_integer(completed) or is_boolean(completed) or completed < 0 ->
        {:error, error}

      mode == :live and completed != length(receipts) ->
        {:error, error}

      handoff["available_budget_ms"] != 0 ->
        {:error, error}

      per_batch != :unspecified and handoff["per_batch_budget_ms"] != per_batch ->
        {:error, error}

      remaining != suffix or suffix == [] ->
        {:error, error}

      handoff["completed_file_count"] != prefix_files ->
        {:error, error}

      is_nil(interrupted) and hd(unstarted) != Enum.at(planned, completed) ->
        {:error, error}

      is_nil(interrupted) and handoff["phase"] == "structural" and completed != 0 ->
        {:error, error}

      is_map(interrupted) and interrupted != Enum.at(planned, completed) ->
        {:error, error}

      is_map(interrupted) and unstarted != Enum.drop(planned, completed + 1) ->
        {:error, error}

      is_map(interrupted) and handoff["phase"] != "runtime" ->
        {:error, error}

      true ->
        :ok
    end
  end

  defp remaining_batches(nil, unstarted) when is_list(unstarted), do: unstarted

  defp remaining_batches(interrupted, unstarted)
       when is_map(interrupted) and is_list(unstarted) do
    [interrupted | unstarted]
  end

  defp remaining_batches(_interrupted, _unstarted), do: :invalid

  defp admit_planned_batches(batches) when is_list(batches) and batches != [] do
    with :ok <- require_json_clean_list(batches),
         :ok <- require_contiguous_plan(batches),
         {:ok, digest} <- plan_digest(batches) do
      {:ok, batches, digest, length(batches), file_count(batches)}
    else
      {:error, :invalid_batch_plan} = error -> error
      {:error, :malformed_state} = error -> error
      {:error, _} -> {:error, :invalid_batch_plan}
    end
  end

  defp admit_planned_batches(_batches), do: {:error, :invalid_batch_plan}

  defp plan_digest(batches) do
    case ValidationCapacityHandoff.ordered_plan_digest(batches) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, :invalid_batch_plan}
    end
  end

  defp match_plan_digest(supplied, computed) do
    if supplied === computed, do: :ok, else: {:error, :plan_drift}
  end

  defp require_contiguous_plan(batches) do
    total = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.all?(fn {batch, index} ->
      is_map(batch) and not is_struct(batch) and exact_keys?(batch, @batch_keys) and
        batch["index"] == index and batch["total"] == total and
        not Map.has_key?(batch, "paths")
    end)
    |> then(fn
      true -> :ok
      false -> {:error, :invalid_batch_plan}
    end)
  end

  defp file_count(batches) when is_list(batches) do
    Enum.reduce(batches, 0, fn batch, acc -> acc + batch["count"] end)
  end

  defp match_identities(snapshot_identities, binding_identities) do
    with {:ok, admitted} <- ContinuationCore.admit_identities(snapshot_identities) do
      match(admitted, binding_identities, :identity_drift)
    else
      {:error, _} -> {:error, :identity_drift}
    end
  end

  defp match_next_index(stored, expected, "in_progress", _parsed) do
    match(stored, expected, :index_drift)
  end

  defp match_next_index(stored, _expected, "completed", parsed) do
    match(stored, parsed.total_batches + 1, :index_drift)
  end

  defp match_next_index(_stored, _expected, _status, _parsed), do: {:error, :malformed_state}

  defp parse_stored_ordinal(value)
       when is_integer(value) and not is_boolean(value) and value >= 0,
       do: {:ok, value}

  defp parse_stored_ordinal(_value), do: {:error, :malformed_state}

  defp parse_positive_integer(value)
       when is_integer(value) and not is_boolean(value) and value > 0,
       do: {:ok, value}

  defp parse_positive_integer(_value), do: {:error, :malformed_state}

  defp require_nonnegative_integer(value)
       when is_integer(value) and not is_boolean(value) and value >= 0,
       do: :ok

  defp require_nonnegative_integer(_value), do: {:error, :malformed_state}

  defp match_binding_ordinal(:unspecified, _stored), do: :ok

  defp match_binding_ordinal(expected, stored) when is_integer(expected),
    do: match(stored, expected, :ordinal_drift)

  defp check_ordinal_shape(0, [], nil, "in_progress"), do: :ok
  defp check_ordinal_shape(0, _receipts, _capacity, _status), do: {:error, :ordinal_drift}

  defp check_ordinal_shape(ordinal, _receipts, capacity, "in_progress")
       when is_integer(ordinal) and ordinal >= 1 do
    if is_map(capacity), do: :ok, else: {:error, :ordinal_drift}
  end

  defp check_ordinal_shape(ordinal, receipts, nil, "completed")
       when is_integer(ordinal) and ordinal >= 1 do
    if receipts != [], do: :ok, else: {:error, :ordinal_drift}
  end

  defp check_ordinal_shape(_ordinal, _receipts, _capacity, _status),
    do: {:error, :ordinal_drift}

  defp check_completed_shape("completed", receipts, planned, nil) do
    if length(receipts) == length(planned), do: :ok, else: {:error, :malformed_state}
  end

  defp check_completed_shape("completed", _receipts, _planned, _capacity),
    do: {:error, :malformed_state}

  defp check_completed_shape("in_progress", receipts, planned, _capacity) do
    if length(receipts) < length(planned), do: :ok, else: {:error, :malformed_state}
  end

  defp check_completed_shape(_status, _receipts, _planned, _capacity),
    do: {:error, :malformed_state}

  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :malformed_state}

  defp require_schema(@schema_version), do: :ok
  defp require_schema(_version), do: {:error, :malformed_state}

  defp parse_hex(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_hex(_value), do: {:error, :malformed_state}

  defp build_state(attrs) do
    %{
      "schema_version" => @schema_version,
      "status" => attrs.status,
      "identities" => attrs.identities,
      "identities_digest" => attrs.identities_digest,
      "plan_digest" => attrs.plan_digest,
      "total_batch_count" => attrs.total_batch_count,
      "total_file_count" => attrs.total_file_count,
      "passed_receipts" => attrs.passed_receipts,
      "passed_receipts_digest" => attrs.passed_receipts_digest,
      "completed_batch_count" => attrs.completed_batch_count,
      "completed_file_count" => attrs.completed_file_count,
      "next_batch_index" => attrs.next_batch_index,
      "window_ordinal" => attrs.window_ordinal,
      "static_stage_receipt_digest" => attrs.static_digest,
      "capacity" => attrs.capacity
    }
  end

  defp build_capacity(attrs) do
    %{
      "phase" => attrs.phase,
      "available_budget_ms" => attrs.available_budget_ms,
      "per_batch_budget_ms" => attrs.per_batch_budget_ms,
      "completed_batch_count" => attrs.completed_batch_count,
      "completed_file_count" => attrs.completed_file_count,
      "unstarted_batch_count" => attrs.unstarted_batch_count,
      "unstarted_file_count" => attrs.unstarted_file_count,
      "total_batch_count" => attrs.total_batch_count,
      "total_file_count" => attrs.total_file_count,
      "remaining_suffix_digest" => attrs.remaining_suffix_digest,
      "interrupted_batch" => attrs.interrupted_batch
    }
  end

  defp bound_state(state), do: bound_json(state, @max_state_json_bytes, :oversized_state)

  defp bound_json(value, max, error) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max -> :ok
      {:ok, _encoded} -> {:error, error}
      {:error, _reason} -> {:error, :malformed_state}
    end
  end

  defp match(left, right, _error) when left === right, do: :ok
  defp match(_left, _right, error), do: {:error, error}

  defp require_json_object(value) when is_map(value) and not is_struct(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_state}
  end

  defp require_json_object(_value), do: {:error, :malformed_state}

  defp require_json_clean_list(list) when is_list(list) do
    if proper_list?(list) and Enum.all?(list, &json_clean?/1),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_json_clean_list(_list), do: {:error, :malformed_state}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> String.valid?(key) and json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value),
    do: proper_list?(value) and Enum.all?(value, &json_clean?/1)

  defp json_clean?(value) when is_binary(value), do: String.valid?(value)

  defp json_clean?(value)
       when is_integer(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp require_allowed_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_keys(map, keys) do
    if Enum.all?(keys, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == keys, do: :ok, else: {:error, :malformed_state}
  end

  defp reject_key(map, key) do
    if Map.has_key?(map, key), do: {:error, :malformed_state}, else: :ok
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == keys

  defp reject_forbidden_keys(value) do
    if contains_forbidden_key?(value),
      do: {:error, :malformed_state},
      else: :ok
  end

  defp contains_forbidden_key?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(value, fn {key, nested} ->
      forbidden_key?(key) or contains_forbidden_key?(nested)
    end)
  end

  defp contains_forbidden_key?(value) when is_list(value),
    do: Enum.any?(value, &contains_forbidden_key?/1)

  defp contains_forbidden_key?(_value), do: false

  defp forbidden_key?(key) when is_binary(key), do: MapSet.member?(@forbidden_keys, key)
  defp forbidden_key?(_key), do: true
end
