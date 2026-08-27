defmodule Arbor.Actions.Coding.CrossApp.ContinuationCore do
  @moduledoc """
  Pure reducer for CrossApp validation continuation.

  Slice 1 owns a closed, versioned, JSON-clean continuation state inside
  arbor_actions. CONTRACT_RULES AC-1 keeps this state Actions-owned: there is
  only one production consumer, so it is not an `Arbor.Contracts` module and is
  not grandfathered. Live schema-v3 capacity evidence is admitted only through
  `Arbor.Contracts.Coding.ValidationCapacityHandoff.normalize/1`.

  Closed state keys: schema_version, status, identities, planned_batches,
  accepted_receipts, claim, fence_generation, per_batch_budget_ms,
  static_stage_receipt_digest, capacity_handoff, terminal_reason.

  Statuses: open | claimed | failed | cancelled | completed.

  Public transitions: new/1, show/1, claim/2, accept_passed_receipt/2,
  accept_capacity_handoff/2, fail/2, cancel/2, expire_claim/2, revoke_claim/2,
  complete/2. Claimed live mutations require matching fence_generation+token
  and now < expires_at. expire_claim matches the fence then requires
  now >= expires_at. revoke_claim matches the fence and ignores time.
  Receipts are an ordered prefix of the immutable path-free plan; complete
  requires an active unexpired claim and exactly one passed receipt per batch.

  Identities bind task, work-packet (`sha256:` digest), base_commit/base_tree_oid,
  candidate_head/candidate_tree_oid, validation-plan, toolchain,
  dependency-baseline, wrapper, validator implementation, principal (claim
  owner), and configuration. CrossApp is pre-commit: candidate_head MUST equal
  base_commit (exact parent/HEAD). candidate_tree_oid is the staged committable
  tree, independently bound and immutable; it MUST NOT be required to equal
  base_tree_oid, and differs when the task has real changes.

  Derived JSON ceilings (v3 handoff max_json_bytes is 256_000; compact plans
  fit that bound; receipts add `outcome` still under 256_000; identities 4_096;
  claim 1_024; envelope 1_024):

  * plan / receipts / handoff collections: 256_000 each
  * state: 778_240 = 256_000*3 + 4_096 + 1_024 + 1_024 + 4_096 slack
  * persist effect: 778_368; mint_successor: 516_352; terminal: 512
  * effects list: 1_294_848

  CRC: no filesystem, process, registry, clock, randomness, or Application env.
  Identities, timestamps, expiry, and fence values are injected. Transitions
  encode the full state and the effects list once; persist size uses the
  documented 128-byte envelope plus the already-measured state.
  """

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @schema_version 1
  @max_plan_json_bytes 256_000
  @max_receipts_json_bytes 256_000
  @max_handoff_json_bytes 256_000
  @max_identities_json_bytes 4_096
  @max_claim_json_bytes 1_024
  @max_state_json_bytes 778_240
  @max_persist_effect_bytes 778_368
  @max_mint_effect_bytes 516_352
  @max_terminal_effect_bytes 512
  @max_effects_json_bytes 1_294_848
  @persist_envelope_bytes 128
  @max_id_bytes 256
  @max_reason_bytes 256
  @max_fence_generation 1_000_000
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @work_packet_digest_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @oid_regex ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @token_regex ~r/\A[A-Za-z0-9._:-]+\z/
  @offset_regex ~r/(?:Z|[+-]\d{2}:\d{2})\z/

  @identity_keys Enum.sort(~w(
    task_id
    work_packet_digest
    base_commit
    base_tree_oid
    candidate_head
    candidate_tree_oid
    validation_plan_digest
    toolchain_digest
    dependency_baseline_digest
    wrapper_digest
    validator_id
    principal_id
    configuration_digest
  ))

  @fresh_keys Enum.sort(~w(
    identities
    planned_batches
    per_batch_budget_ms
    static_stage_receipt_digest
  ))

  @state_keys Enum.sort(~w(
    schema_version
    status
    identities
    planned_batches
    accepted_receipts
    claim
    fence_generation
    per_batch_budget_ms
    static_stage_receipt_digest
    capacity_handoff
    terminal_reason
  ))

  @claim_keys Enum.sort(~w(owner_id fence_token fence_generation claimed_at expires_at))
  @batch_keys Enum.sort(~w(index total count label inventory_sha256))
  @receipt_keys Enum.sort(~w(index total count label inventory_sha256 outcome))
  @oid_keys ~w(base_commit base_tree_oid candidate_head candidate_tree_oid)
  @hex_identity_keys ~w(
    validation_plan_digest
    toolchain_digest
    dependency_baseline_digest
    wrapper_digest
    configuration_digest
  )
  @id_keys ~w(task_id validator_id principal_id)
  @terminal_statuses ~w(failed cancelled completed)
  @live_statuses ~w(open claimed failed cancelled completed)

  @type error ::
          :malformed_state
          | :oversized_state
          | :oversized_effects
          | :identity_drift
          | :invalid_batch_plan
          | :claim_required
          | :claim_active
          | :wrong_fence
          | :stale_fence
          | :not_expired
          | :terminal_state
          | :duplicate_receipt
          | :skipped_receipt
          | :reordered_receipt
          | :contradictory_receipt
          | :non_canonical_capacity_handoff
          | :incomplete_plan

  @type state :: %{required(String.t()) => term()}
  @type effects :: [map()]

  @doc "Continuation schema version."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Maximum encoded continuation-state JSON bytes."
  @spec max_json_bytes() :: 778_240
  def max_json_bytes, do: @max_state_json_bytes

  @doc "Derived JSON ceilings for state collections and effects."
  @spec limits() :: %{required(String.t()) => pos_integer()}
  def limits do
    %{
      "max_plan_json_bytes" => @max_plan_json_bytes,
      "max_receipts_json_bytes" => @max_receipts_json_bytes,
      "max_handoff_json_bytes" => @max_handoff_json_bytes,
      "max_identities_json_bytes" => @max_identities_json_bytes,
      "max_claim_json_bytes" => @max_claim_json_bytes,
      "max_state_json_bytes" => @max_state_json_bytes,
      "max_persist_effect_bytes" => @max_persist_effect_bytes,
      "max_mint_effect_bytes" => @max_mint_effect_bytes,
      "max_terminal_effect_bytes" => @max_terminal_effect_bytes,
      "max_effects_json_bytes" => @max_effects_json_bytes,
      "persist_envelope_bytes" => @persist_envelope_bytes,
      "max_fence_generation" => @max_fence_generation
    }
  end

  @doc "Construct a fresh continuation or rehydrate a show/1 snapshot."
  @spec new(term()) :: {:ok, state()} | {:error, error()}
  def new(input) do
    with :ok <- require_json_object(input),
         {:ok, state} <- construct_or_rehydrate(input),
         :ok <- bound_state(state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "JSON snapshot; identical to internal state. Non-maps fail closed."
  @spec show(term()) :: state() | {:error, :malformed_state}
  def show(state) when is_map(state) and not is_struct(state), do: state
  def show(_state), do: {:error, :malformed_state}

  @doc "Open a fenced single-owner window. Core assigns fence_generation."
  @spec claim(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def claim(state, input) do
    allowed = claim_allowed_keys()

    with {:ok, state} <- snapshot_state(state),
         :ok <- require_json_object(input),
         :ok <- require_allowed_keys(input, allowed),
         :ok <- require_keys(input, ~w(fence_token claimed_at expires_at now)),
         :ok <- reject_key(input, "fence_generation"),
         :ok <- check_identity_drift(state, input),
         :ok <- claim_status(state),
         {:ok, token} <- parse_token(input["fence_token"]),
         {:ok, claimed_at, claimed_dt} <- parse_stored_datetime(input["claimed_at"]),
         {:ok, expires_at, expires_dt} <- parse_stored_datetime(input["expires_at"]),
         {:ok, now_dt} <- parse_datetime(input["now"]),
         :ok <- validate_claim_window(claimed_dt, now_dt, expires_dt),
         {:ok, owner_id} <- claim_owner(state, input),
         {:ok, generation} <- next_generation(state["fence_generation"]) do
      claim = %{
        "owner_id" => owner_id,
        "fence_token" => token,
        "fence_generation" => generation,
        "claimed_at" => claimed_at,
        "expires_at" => expires_at
      }

      state
      |> Map.put("status", "claimed")
      |> Map.put("claim", claim)
      |> Map.put("fence_generation", generation)
      |> ok_persist()
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Accept the next planned batch as passed. Requires a live unexpired claim."
  @spec accept_passed_receipt(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def accept_passed_receipt(state, input) do
    with {:ok, state, _parsed} <- claimed_live_gate(state, input, ~w(receipt), ~w(receipt)),
         {:ok, receipt} <- receipt_decision(state, input["receipt"]) do
      state
      |> Map.update!("accepted_receipts", &(&1 ++ [receipt]))
      |> ok_persist()
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Admit live schema-v3 capacity evidence and emit persist plus mint_successor."
  @spec accept_capacity_handoff(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def accept_capacity_handoff(state, input) do
    with {:ok, state, _parsed} <- claimed_live_gate(state, input, ~w(handoff), ~w(handoff)),
         {:ok, handoff, remaining} <- admit_capacity_handoff(state, input["handoff"]) do
      state =
        state
        |> Map.put("capacity_handoff", handoff)
        |> clear_claim("open", state["terminal_reason"])

      mint = %{
        "op" => "mint_successor",
        "schema_version" => @schema_version,
        "identities" => state["identities"],
        "static_stage_receipt_digest" => state["static_stage_receipt_digest"],
        "fence_generation" => state["fence_generation"],
        "remaining_batches" => remaining,
        "handoff" => handoff
      }

      ok_effects(state, [persist_effect(state), mint])
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Terminal failure under a live unexpired claim."
  @spec fail(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def fail(state, input), do: terminate(state, input, "failed")

  @doc "Terminal cancellation under a live unexpired claim."
  @spec cancel(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def cancel(state, input), do: terminate(state, input, "cancelled")

  @doc "Clear an expired claim. now >= expires_at succeeds; now < expires_at is :not_expired."
  @spec expire_claim(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def expire_claim(state, input) do
    with {:ok, state, parsed} <- claimed_match_gate(state, input, [], []),
         :ok <- expire_time(parsed.now_dt, state) do
      state
      |> clear_claim("open", state["terminal_reason"])
      |> ok_persist()
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Revoke the active claim. Time is parsed and ignored."
  @spec revoke_claim(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def revoke_claim(state, input) do
    with {:ok, state, _parsed} <- claimed_match_gate(state, input, [], []) do
      state
      |> clear_claim("open", state["terminal_reason"])
      |> ok_persist()
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Complete only under an active matching unexpired claim with a full receipt prefix."
  @spec complete(term(), term()) :: {:ok, state(), effects()} | {:error, error()}
  def complete(state, input) do
    with {:ok, state, _parsed} <- claimed_live_gate(state, input, [], []),
         :ok <- require_complete_receipts(state) do
      state
      |> clear_claim("completed", nil)
      |> ok_terminal("completed", nil)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  defp construct_or_rehydrate(input) do
    if Map.has_key?(input, "schema_version") do
      rehydrate(input)
    else
      construct_fresh(input)
    end
  end

  defp construct_fresh(input) do
    with :ok <- require_allowed_keys(input, @fresh_keys),
         :ok <- require_keys(input, @fresh_keys),
         {:ok, identities} <- parse_identities(input["identities"]),
         {:ok, static_digest} <- parse_hex(input["static_stage_receipt_digest"]),
         {:ok, planned} <- parse_planned_batches(input["planned_batches"]),
         {:ok, plan_digest} <- plan_digest(planned),
         :ok <- match_plan_digest(identities["validation_plan_digest"], plan_digest),
         {:ok, per_batch} <- parse_positive_integer(input["per_batch_budget_ms"]),
         :ok <- admit_per_batch_budget(per_batch, planned) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "status" => "open",
         "identities" => identities,
         "planned_batches" => planned,
         "accepted_receipts" => [],
         "claim" => nil,
         "fence_generation" => 0,
         "per_batch_budget_ms" => per_batch,
         "static_stage_receipt_digest" => static_digest,
         "capacity_handoff" => nil,
         "terminal_reason" => nil
       }}
    end
  end

  defp rehydrate(input) do
    with :ok <- require_allowed_keys(input, @state_keys),
         :ok <- require_keys(input, @state_keys),
         :ok <- require_schema(input["schema_version"]),
         {:ok, status} <- parse_status(input["status"]),
         {:ok, identities} <- parse_identities(input["identities"]),
         {:ok, static_digest} <- parse_hex(input["static_stage_receipt_digest"]),
         {:ok, planned} <- parse_planned_batches(input["planned_batches"]),
         {:ok, plan_digest} <- plan_digest(planned),
         :ok <- match_plan_digest(identities["validation_plan_digest"], plan_digest),
         {:ok, per_batch} <- parse_positive_integer(input["per_batch_budget_ms"]),
         :ok <- admit_per_batch_budget(per_batch, planned),
         {:ok, receipts} <- parse_receipts(input["accepted_receipts"], planned),
         {:ok, generation} <- parse_generation(input["fence_generation"]),
         {:ok, claim} <- parse_claim(input["claim"], status, identities, generation),
         {:ok, handoff} <-
           parse_stored_handoff(input["capacity_handoff"], planned, receipts, per_batch),
         {:ok, reason} <- parse_terminal_reason(input["terminal_reason"], status),
         :ok <- require_completed_shape(status, receipts, planned) do
      {:ok,
       %{
         "schema_version" => @schema_version,
         "status" => status,
         "identities" => identities,
         "planned_batches" => planned,
         "accepted_receipts" => receipts,
         "claim" => claim,
         "fence_generation" => generation,
         "per_batch_budget_ms" => per_batch,
         "static_stage_receipt_digest" => static_digest,
         "capacity_handoff" => handoff,
         "terminal_reason" => reason
       }}
    end
  end

  defp snapshot_state(state) do
    with :ok <- require_json_object(state),
         :ok <- require_allowed_keys(state, @state_keys),
         :ok <- require_keys(state, @state_keys),
         :ok <- require_schema(state["schema_version"]),
         {:ok, _status} <- parse_status(state["status"]) do
      {:ok, state}
    end
  end

  defp claimed_live_gate(state, input, extra_allowed, extra_required) do
    with {:ok, state, parsed} <- claimed_match_gate(state, input, extra_allowed, extra_required),
         :ok <- live_not_expired(parsed.now_dt, state) do
      {:ok, state, parsed}
    end
  end

  defp claimed_match_gate(state, input, extra_allowed, extra_required) do
    allowed = fence_allowed_keys(extra_allowed)
    required = ~w(fence_token fence_generation now) ++ extra_required

    with {:ok, state} <- snapshot_state(state),
         :ok <- require_json_object(input),
         :ok <- require_allowed_keys(input, allowed),
         :ok <- require_keys(input, required),
         {:ok, token} <- parse_token(input["fence_token"]),
         {:ok, generation} <- parse_generation(input["fence_generation"]),
         {:ok, now_dt} <- parse_datetime(input["now"]),
         :ok <- check_identity_drift(state, input),
         :ok <- check_owner_id(state, input),
         :ok <- require_claimed(state),
         :ok <- match_generation(state, generation),
         :ok <- match_token(state, token) do
      {:ok, state, %{token: token, generation: generation, now_dt: now_dt}}
    end
  end

  defp fence_allowed_keys(extra) do
    extra ++ ~w(fence_token fence_generation now identities reason owner_id) ++ @identity_keys
  end

  defp claim_allowed_keys do
    ~w(fence_token claimed_at expires_at now owner_id identities) ++ @identity_keys
  end

  defp require_claimed(state) do
    cond do
      state["status"] in @terminal_statuses -> {:error, :terminal_state}
      state["status"] != "claimed" -> {:error, :claim_required}
      true -> :ok
    end
  end

  defp claim_status(state) do
    cond do
      state["status"] in @terminal_statuses -> {:error, :terminal_state}
      state["status"] == "claimed" -> {:error, :claim_active}
      state["status"] != "open" -> {:error, :malformed_state}
      true -> :ok
    end
  end

  defp match_generation(state, generation) do
    if generation == state["claim"]["fence_generation"],
      do: :ok,
      else: {:error, :stale_fence}
  end

  defp match_token(state, token) do
    if token == state["claim"]["fence_token"],
      do: :ok,
      else: {:error, :wrong_fence}
  end

  defp live_not_expired(now_dt, state) do
    with {:ok, expires_dt} <- datetime_from_stored(state["claim"]["expires_at"]) do
      if DateTime.compare(now_dt, expires_dt) == :lt,
        do: :ok,
        else: {:error, :stale_fence}
    end
  end

  defp expire_time(now_dt, state) do
    with {:ok, expires_dt} <- datetime_from_stored(state["claim"]["expires_at"]) do
      if DateTime.compare(now_dt, expires_dt) == :lt,
        do: {:error, :not_expired},
        else: :ok
    end
  end

  defp claim_owner(state, input) do
    principal = state["identities"]["principal_id"]

    case Map.fetch(input, "owner_id") do
      :error -> {:ok, principal}
      {:ok, owner} when owner === principal -> {:ok, principal}
      {:ok, _} -> {:error, :identity_drift}
    end
  end

  defp validate_claim_window(claimed_dt, now_dt, expires_dt) do
    claimed_ok? = DateTime.compare(claimed_dt, now_dt) in [:lt, :eq]
    now_open? = DateTime.compare(now_dt, expires_dt) == :lt
    expires_after? = DateTime.compare(expires_dt, claimed_dt) == :gt

    if claimed_ok? and now_open? and expires_after?,
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp next_generation(current) when is_integer(current) and current >= 0 do
    next = current + 1

    if next <= @max_fence_generation,
      do: {:ok, next},
      else: {:error, :oversized_state}
  end

  defp next_generation(_current), do: {:error, :malformed_state}

  defp terminate(state, input, default_reason) do
    with {:ok, state, _parsed} <- claimed_live_gate(state, input, ~w(reason), []),
         {:ok, reason} <- parse_reason(Map.get(input, "reason"), default_reason) do
      state
      |> clear_claim(default_reason, reason)
      |> ok_terminal(default_reason, reason)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  defp parse_reason(nil, default), do: {:ok, default}

  defp parse_reason(reason, _default) when is_binary(reason) do
    if valid_reason?(reason), do: {:ok, reason}, else: {:error, :malformed_state}
  end

  defp parse_reason(_reason, _default), do: {:error, :malformed_state}

  defp valid_reason?(reason) do
    byte_size(reason) > 0 and byte_size(reason) <= @max_reason_bytes and
      String.valid?(reason) and printable?(reason) and not String.contains?(reason, <<0>>)
  end

  # Receipt errors after the live fence: malformed, then duplicate (index already
  # accepted), skipped (index > next), reordered (index == next but compact
  # matches a different planned slot), then contradictory.
  defp receipt_decision(state, receipt) do
    planned = state["planned_batches"]
    accepted = state["accepted_receipts"]
    next = length(accepted) + 1

    cond do
      not receipt_shape?(receipt) ->
        {:error, :malformed_state}

      not valid_index?(receipt["index"]) ->
        {:error, :malformed_state}

      true ->
        index = receipt["index"]

        cond do
          index <= length(accepted) ->
            {:error, :duplicate_receipt}

          index > next ->
            {:error, :skipped_receipt}

          index == next and compact(receipt) != compact(Enum.at(planned, index - 1)) and
              compact_matches_other_slot?(receipt, planned, index) ->
            {:error, :reordered_receipt}

          index == next ->
            accept_next_receipt(receipt, Enum.at(planned, index - 1), index)

          true ->
            {:error, :malformed_state}
        end
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

  defp admit_capacity_handoff(state, handoff) do
    if is_map(handoff) and not is_struct(handoff) and json_clean?(handoff) do
      case ValidationCapacityHandoff.normalize(handoff) do
        {:ok, canonical} -> bind_capacity_handoff(state, canonical)
        {:error, _} -> {:error, :non_canonical_capacity_handoff}
      end
    else
      {:error, :non_canonical_capacity_handoff}
    end
  end

  defp bind_capacity_handoff(state, handoff) do
    case bind_handoff(
           handoff,
           state["planned_batches"],
           state["accepted_receipts"],
           state["per_batch_budget_ms"],
           :live
         ) do
      :ok ->
        remaining = remaining_batches(handoff["interrupted_batch"], handoff["unstarted_batches"])
        {:ok, handoff, remaining}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bind_handoff(handoff, planned, receipts, per_batch, mode) do
    completed = handoff["completed_batch_count"]
    interrupted = handoff["interrupted_batch"]
    unstarted = handoff["unstarted_batches"]
    remaining = remaining_batches(interrupted, unstarted)
    suffix = Enum.drop(planned, completed)
    prefix = Enum.take(receipts, completed)
    prefix_files = Enum.reduce(prefix, 0, fn receipt, acc -> acc + receipt["count"] end)
    error = if mode == :live, do: :non_canonical_capacity_handoff, else: :malformed_state

    cond do
      not is_integer(completed) or completed < 0 ->
        {:error, error}

      mode == :live and completed != length(receipts) ->
        {:error, error}

      mode == :stored and completed > length(receipts) ->
        {:error, error}

      handoff["available_budget_ms"] != 0 ->
        {:error, error}

      handoff["per_batch_budget_ms"] != per_batch ->
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

  defp require_complete_receipts(state) do
    planned = state["planned_batches"]
    receipts = state["accepted_receipts"]

    if length(receipts) == length(planned) and
         receipts_match_plan?(receipts, planned) do
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

  defp clear_claim(state, status, reason) do
    state
    |> Map.put("status", status)
    |> Map.put("claim", nil)
    |> Map.put("terminal_reason", reason)
  end

  defp ok_persist(state) do
    ok_effects(state, [persist_effect(state)])
  end

  defp ok_terminal(state, status, reason) do
    terminal = %{
      "op" => "terminal",
      "schema_version" => @schema_version,
      "status" => status,
      "reason" => reason
    }

    ok_effects(state, [persist_effect(state), terminal])
  end

  defp persist_effect(state) when is_map(state) do
    %{
      "op" => "persist",
      "schema_version" => @schema_version,
      "snapshot" => state
    }
  end

  defp ok_effects(state, effects) do
    state_bytes = json_size(state)

    with :ok <- bound_measured(state_bytes, @max_state_json_bytes, :oversized_state),
         :ok <- bound_effects(effects, state_bytes) do
      {:ok, state, effects}
    end
  end

  defp bound_state(state), do: bound_json(state, @max_state_json_bytes, :oversized_state)

  defp bound_effects(effects, state_bytes) when is_list(effects) do
    with :ok <- bound_json(effects, @max_effects_json_bytes, :oversized_effects),
         :ok <- bound_effect_ops(effects, state_bytes) do
      :ok
    end
  end

  defp bound_effects(_effects, _state_bytes), do: {:error, :oversized_effects}

  defp bound_effect_ops([], _state_bytes), do: :ok

  defp bound_effect_ops([%{"op" => "persist"} | rest], state_bytes) do
    with :ok <-
           bound_measured(
             state_bytes + @persist_envelope_bytes,
             @max_persist_effect_bytes,
             :oversized_effects
           ) do
      bound_effect_ops(rest, state_bytes)
    end
  end

  defp bound_effect_ops([%{"op" => "mint_successor"} = mint | rest], state_bytes) do
    with :ok <- bound_json(mint, @max_mint_effect_bytes, :oversized_effects) do
      bound_effect_ops(rest, state_bytes)
    end
  end

  defp bound_effect_ops([%{"op" => "terminal"} = terminal | rest], state_bytes) do
    with :ok <- bound_json(terminal, @max_terminal_effect_bytes, :oversized_effects) do
      bound_effect_ops(rest, state_bytes)
    end
  end

  defp bound_effect_ops(_effects, _state_bytes), do: {:error, :oversized_effects}

  defp bound_measured(size, max, error) when is_integer(size) do
    if size <= max, do: :ok, else: {:error, error}
  end

  defp bound_json(value, max, error) do
    if json_size(value) <= max, do: :ok, else: {:error, error}
  end

  defp json_size(value), do: byte_size(Jason.encode!(value))

  defp parse_identities(identities) do
    with :ok <- require_json_object(identities),
         :ok <- bound_json(identities, @max_identities_json_bytes, :oversized_state),
         :ok <- require_allowed_keys(identities, @identity_keys),
         :ok <- require_keys(identities, @identity_keys),
         :ok <- validate_identity_fields(identities) do
      {:ok, Map.take(identities, @identity_keys)}
    end
  end

  defp validate_identity_fields(identities) do
    with :ok <- require_all(@id_keys, identities, &parse_id/1),
         :ok <- require_work_packet_digest(identities["work_packet_digest"]),
         :ok <- require_all(@oid_keys, identities, &parse_oid/1),
         :ok <- require_all(@hex_identity_keys, identities, &parse_hex/1),
         :ok <- require_precommit_head(identities) do
      :ok
    else
      {:error, _reason} = error -> error
      {:ok, _value} -> :ok
    end
  end

  defp require_precommit_head(identities) do
    if identities["candidate_head"] === identities["base_commit"],
      do: :ok,
      else: {:error, :identity_drift}
  end

  defp require_all([], _map, _fun), do: :ok

  defp require_all([key | rest], map, fun) do
    case fun.(map[key]) do
      {:ok, _} -> require_all(rest, map, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_work_packet_digest(value) when is_binary(value) do
    if Regex.match?(@work_packet_digest_regex, value),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_work_packet_digest(_value), do: {:error, :malformed_state}

  defp parse_id(value) when is_binary(value) do
    if valid_id?(value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_id(_value), do: {:error, :malformed_state}

  defp valid_id?(value) do
    byte_size(value) > 0 and byte_size(value) <= @max_id_bytes and String.valid?(value) and
      printable?(value) and not String.contains?(value, <<0>>)
  end

  defp parse_oid(value) when is_binary(value) do
    if Regex.match?(@oid_regex, value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_oid(_value), do: {:error, :malformed_state}

  defp parse_hex(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_hex(_value), do: {:error, :malformed_state}

  defp parse_token(value) when is_binary(value) do
    if byte_size(value) > 0 and byte_size(value) <= @max_id_bytes and
         Regex.match?(@token_regex, value),
       do: {:ok, value},
       else: {:error, :malformed_state}
  end

  defp parse_token(_value), do: {:error, :malformed_state}

  defp parse_positive_integer(value)
       when is_integer(value) and not is_boolean(value) and value > 0,
       do: {:ok, value}

  defp parse_positive_integer(_value), do: {:error, :malformed_state}

  defp parse_generation(value)
       when is_integer(value) and not is_boolean(value) and value >= 0 and
              value <= @max_fence_generation,
       do: {:ok, value}

  defp parse_generation(_value), do: {:error, :malformed_state}

  defp parse_status(status) when status in @live_statuses, do: {:ok, status}
  defp parse_status(_status), do: {:error, :malformed_state}

  defp require_schema(@schema_version), do: :ok
  defp require_schema(_version), do: {:error, :malformed_state}

  defp parse_planned_batches(batches) when is_list(batches) and batches != [] do
    with :ok <- require_json_clean_list(batches),
         :ok <- bound_json(batches, @max_plan_json_bytes, :oversized_state),
         {:ok, _digest} <- plan_digest(batches),
         :ok <- require_contiguous_plan(batches) do
      {:ok, batches}
    else
      {:error, :oversized_state} = error -> error
      {:error, :malformed_state} = error -> error
      {:error, _} -> {:error, :invalid_batch_plan}
      :error -> {:error, :invalid_batch_plan}
    end
  end

  defp parse_planned_batches(_batches), do: {:error, :invalid_batch_plan}

  defp plan_digest(batches) do
    case ValidationCapacityHandoff.ordered_plan_digest(batches) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, :invalid_batch_plan}
    end
  end

  defp match_plan_digest(supplied, computed) do
    if supplied == computed, do: :ok, else: {:error, :identity_drift}
  end

  defp require_contiguous_plan(batches) do
    total = length(batches)

    batches
    |> Enum.with_index(1)
    |> Enum.all?(fn {batch, index} ->
      exact_keys?(batch, @batch_keys) and batch["index"] == index and batch["total"] == total and
        not Map.has_key?(batch, "paths")
    end)
    |> then(fn
      true -> :ok
      false -> {:error, :invalid_batch_plan}
    end)
  end

  defp admit_per_batch_budget(per_batch, batches) do
    with {:ok, digest} <- plan_digest(batches),
         file_count <- Enum.reduce(batches, 0, fn batch, acc -> acc + batch["count"] end),
         {:ok, _handoff} <-
           ValidationCapacityHandoff.new(%{
             "schema_version" => ValidationCapacityHandoff.schema_version(),
             "phase" => "structural",
             "available_budget_ms" => 0,
             "per_batch_budget_ms" => per_batch,
             "completed_batch_count" => 0,
             "completed_file_count" => 0,
             "unstarted_batch_count" => length(batches),
             "unstarted_file_count" => file_count,
             "total_batch_count" => length(batches),
             "total_file_count" => file_count,
             "ordered_plan_sha256" => digest,
             "interrupted_batch" => nil,
             "unstarted_batches" => batches
           }) do
      :ok
    else
      {:error, _} -> {:error, :malformed_state}
    end
  end

  defp parse_receipts(receipts, planned) when is_list(receipts) do
    with :ok <- require_json_clean_list(receipts),
         :ok <- bound_json(receipts, @max_receipts_json_bytes, :oversized_state),
         true <- length(receipts) <= length(planned),
         :ok <- validate_receipt_prefix(receipts, planned, 1) do
      {:ok, receipts}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_state}
    end
  end

  defp parse_receipts(_receipts, _planned), do: {:error, :malformed_state}

  defp validate_receipt_prefix([], _planned, _index), do: :ok

  defp validate_receipt_prefix([receipt | rest], planned, index) do
    expected = Enum.at(planned, index - 1)

    if receipt_shape?(receipt) and receipt["outcome"] == "passed" and
         receipt["index"] == index and compact(receipt) == compact(expected) do
      validate_receipt_prefix(rest, planned, index + 1)
    else
      {:error, :malformed_state}
    end
  end

  defp parse_claim(nil, status, _identities, generation)
       when status != "claimed" and is_integer(generation) do
    {:ok, nil}
  end

  defp parse_claim(claim, "claimed", identities, generation) when is_map(claim) do
    with :ok <- require_json_object(claim),
         :ok <- bound_json(claim, @max_claim_json_bytes, :oversized_state),
         :ok <- require_allowed_keys(claim, @claim_keys),
         :ok <- require_keys(claim, @claim_keys),
         {:ok, token} <- parse_token(claim["fence_token"]),
         {:ok, claim_generation} <- parse_generation(claim["fence_generation"]),
         true <- claim_generation == generation and generation >= 1,
         true <- claim["owner_id"] === identities["principal_id"],
         {:ok, claimed_at, claimed_dt} <- parse_stored_datetime(claim["claimed_at"]),
         {:ok, expires_at, expires_dt} <- parse_stored_datetime(claim["expires_at"]),
         true <- DateTime.compare(expires_dt, claimed_dt) == :gt do
      {:ok,
       %{
         "owner_id" => identities["principal_id"],
         "fence_token" => token,
         "fence_generation" => claim_generation,
         "claimed_at" => claimed_at,
         "expires_at" => expires_at
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_state}
    end
  end

  defp parse_claim(_claim, _status, _identities, _generation), do: {:error, :malformed_state}

  defp parse_stored_handoff(nil, _planned, _receipts, _per_batch), do: {:ok, nil}

  defp parse_stored_handoff(handoff, planned, receipts, per_batch) when is_map(handoff) do
    with :ok <- require_json_object(handoff),
         :ok <- bound_json(handoff, @max_handoff_json_bytes, :oversized_state),
         {:ok, canonical} <- normalize_live_handoff(handoff),
         :ok <- bind_handoff(canonical, planned, receipts, per_batch, :stored) do
      {:ok, canonical}
    end
  end

  defp parse_stored_handoff(_handoff, _planned, _receipts, _per_batch),
    do: {:error, :malformed_state}

  defp normalize_live_handoff(handoff) do
    case ValidationCapacityHandoff.normalize(handoff) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _} -> {:error, :malformed_state}
    end
  end

  defp parse_terminal_reason(nil, status) when status in ["open", "claimed", "completed"],
    do: {:ok, nil}

  defp parse_terminal_reason(reason, status)
       when status in ["failed", "cancelled"] and is_binary(reason) do
    if valid_reason?(reason), do: {:ok, reason}, else: {:error, :malformed_state}
  end

  defp parse_terminal_reason(_reason, _status), do: {:error, :malformed_state}

  defp require_completed_shape("completed", receipts, planned) do
    if length(receipts) == length(planned), do: :ok, else: {:error, :malformed_state}
  end

  defp require_completed_shape(_status, _receipts, _planned), do: :ok

  defp check_identity_drift(state, input) do
    identities = state["identities"]

    cond do
      Map.has_key?(input, "identities") and not is_map(input["identities"]) ->
        {:error, :malformed_state}

      Map.has_key?(input, "identities") and input["identities"] !== identities ->
        {:error, :identity_drift}

      true ->
        Enum.reduce_while(@identity_keys, :ok, fn key, :ok ->
          case Map.fetch(input, key) do
            :error ->
              {:cont, :ok}

            {:ok, value} ->
              if value === identities[key],
                do: {:cont, :ok},
                else: {:halt, {:error, :identity_drift}}
          end
        end)
    end
  end

  defp check_owner_id(state, input) do
    case Map.fetch(input, "owner_id") do
      :error ->
        :ok

      {:ok, owner} ->
        if owner === state["identities"]["principal_id"],
          do: :ok,
          else: {:error, :identity_drift}
    end
  end

  defp parse_stored_datetime(value) do
    with {:ok, dt} <- parse_datetime(value) do
      {:ok, value, dt}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        if Regex.match?(@offset_regex, value),
          do: {:ok, dt},
          else: {:error, :malformed_state}

      _ ->
        {:error, :malformed_state}
    end
  end

  defp parse_datetime(_value), do: {:error, :malformed_state}

  defp datetime_from_stored(value) do
    parse_datetime(value)
  end

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
      {key, nested} when is_binary(key) -> json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value),
    do: proper_list?(value) and Enum.all?(value, &json_clean?/1)

  defp json_clean?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp require_allowed_keys(map, allowed) do
    allowed_set = MapSet.new(allowed)

    if Enum.all?(Map.keys(map), &MapSet.member?(allowed_set, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_keys(map, keys) do
    if Enum.all?(keys, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp reject_key(map, key) do
    if Map.has_key?(map, key), do: {:error, :malformed_state}, else: :ok
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == keys

  defp printable?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F))
  end
end
