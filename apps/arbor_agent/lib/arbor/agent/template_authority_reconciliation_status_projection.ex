defmodule Arbor.Agent.TemplateAuthorityReconciliationStatusProjection do
  @moduledoc false

  # Pure public status/receipt projection for template-authority reconciliation
  # operations. Redacts private journal payloads, capability IDs, desired
  # authority, and backend details.
  #
  # assert_status/1 is the public validator for a status/receipt map (e.g. one
  # deserialized from a store). It checks closed keysets, bounded IDs/codes/times
  # and time order, known status/phase coherence, retry bounds, terminal shape,
  # journal-summary count coherence/bounds, and the derived
  # outstanding/fence_required/replaceable relationships — failing closed on any
  # malformed or self-inconsistent status.

  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Op

  @version 1
  @kind "template_authority_reconciliation_status"

  @status_keys MapSet.new([
                 "version",
                 "kind",
                 "status",
                 "phase",
                 "operation_id",
                 "target_agent_id",
                 "scope",
                 "durability",
                 "outstanding",
                 "fence_required",
                 "replaceable",
                 "retry",
                 "terminal",
                 "created_at_unix_ms",
                 "updated_at_unix_ms",
                 "journal_summary"
               ])

  @retry_keys MapSet.new(["attempt", "max_attempts", "last_code"])
  @terminal_keys MapSet.new(["reason_code", "at_unix_ms", "phase_at_terminal", "blocked_kind"])
  @summary_keys MapSet.new([
                  "entry_count",
                  "pending_count",
                  "needs_reconcile_count",
                  "succeeded_count"
                ])

  @max_operation_id_bytes 128
  @max_agent_id_bytes 256
  @max_reason_bytes 64
  @max_journal_entries 256
  @max_retry 10_000
  @max_json_safe_integer 9_007_199_254_740_991

  # Validation vocabulary is sourced from the operation core so the two modules
  # cannot drift: every phase/status/blocked-kind the core admits is exactly the
  # set this projection accepts. This keeps the boundary at four files with no
  # new umbrella dependency and no generic abstraction; numeric bounds and ID
  # grammars stay local to each module.
  @statuses Op.statuses() |> MapSet.new()
  @phases Op.phases() |> MapSet.new()
  @abortable_phases Op.abortable_phases() |> MapSet.new()
  @blocked_kinds Op.blocked_kinds() |> MapSet.new()
  @primary_outcome_phases Op.primary_outcome_phases() |> MapSet.new()
  @phase_index Op.phases() |> Enum.with_index() |> Map.new()
  @cap_index Op.phases() |> Enum.find_index(&(&1 == "capability_effects"))

  @operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @reason_code_re ~r/\A[a-z][a-z0-9_]*\z/

  @type status_map :: %{optional(String.t()) => term()}

  @spec project(term()) :: {:ok, status_map()} | {:error, term()}
  def project(record) do
    with {:ok, record} <- admit_for_projection(record) do
      assert_status(build_status(record))
    end
  end

  @spec assert_status(term()) :: {:ok, status_map()} | {:error, term()}
  def assert_status(status) when is_map(status) do
    with :ok <- closed_keyset(status, @status_keys),
         :ok <- assert_fixed_scalars(status),
         :ok <- assert_status_phase_coherence(status),
         :ok <- assert_ids(status),
         :ok <- assert_time_order(status),
         :ok <- assert_retry(status["retry"]),
         :ok <- assert_terminal(status),
         :ok <- assert_summary(status),
         :ok <- assert_retry_phase_coherence(status),
         :ok <- assert_derived(status) do
      {:ok, status}
    end
  end

  def assert_status(_), do: error(:invalid_status)

  @spec version() :: pos_integer()
  def version, do: @version

  @spec kind() :: String.t()
  def kind, do: @kind

  defp admit_for_projection(record) do
    case Op.admit(record) do
      {:ok, admitted} ->
        {:ok, admitted}

      {:error, {:template_authority_reconciliation_operation, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  defp build_status(record) do
    %{
      "version" => @version,
      "kind" => @kind,
      "status" => record["status"],
      "phase" => record["phase"],
      "operation_id" => record["operation_id"],
      "target_agent_id" => record["target_agent_id"],
      "scope" => "local_owner",
      "durability" => "node_restart",
      "outstanding" => Op.outstanding?(record),
      "fence_required" => Op.fence_required?(record),
      "replaceable" => Op.replaceable?(record),
      "retry" => project_retry(record["retry"]),
      "terminal" => project_terminal(record["terminal"]),
      "created_at_unix_ms" => record["created_at_unix_ms"],
      "updated_at_unix_ms" => record["updated_at_unix_ms"],
      "journal_summary" => journal_summary(record["journal"])
    }
  end

  defp project_retry(%{
         "attempt" => attempt,
         "max_attempts" => max_attempts,
         "last_code" => last_code
       }) do
    %{
      "attempt" => attempt,
      "max_attempts" => max_attempts,
      "last_code" => last_code
    }
  end

  defp project_terminal(nil), do: nil

  defp project_terminal(%{
         "reason_code" => reason_code,
         "at_unix_ms" => at,
         "phase_at_terminal" => phase,
         "blocked_kind" => blocked_kind
       }) do
    %{
      "reason_code" => reason_code,
      "at_unix_ms" => at,
      "phase_at_terminal" => phase,
      "blocked_kind" => blocked_kind
    }
  end

  defp journal_summary(%{"entries" => entries}) when is_list(entries) do
    counts =
      Enum.reduce(
        entries,
        %{"pending" => 0, "needs_reconcile" => 0, "succeeded" => 0},
        fn entry, acc ->
          case entry["state"] do
            "pending" -> Map.update!(acc, "pending", &(&1 + 1))
            "needs_reconcile" -> Map.update!(acc, "needs_reconcile", &(&1 + 1))
            "succeeded" -> Map.update!(acc, "succeeded", &(&1 + 1))
            _ -> acc
          end
        end
      )

    %{
      "entry_count" => length(entries),
      "pending_count" => counts["pending"],
      "needs_reconcile_count" => counts["needs_reconcile"],
      "succeeded_count" => counts["succeeded"]
    }
  end

  defp journal_summary(_) do
    %{
      "entry_count" => 0,
      "pending_count" => 0,
      "needs_reconcile_count" => 0,
      "succeeded_count" => 0
    }
  end

  # ---------------------------------------------------------------------------
  # assert_status validators
  # ---------------------------------------------------------------------------

  defp assert_fixed_scalars(status) do
    if status["version"] == @version and status["kind"] == @kind and
         status["scope"] == "local_owner" and status["durability"] == "node_restart" and
         is_boolean(status["outstanding"]) and is_boolean(status["fence_required"]) and
         is_boolean(status["replaceable"]) do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_status_phase_coherence(status) do
    s = status["status"]
    phase = status["phase"]

    cond do
      not MapSet.member?(@statuses, s) ->
        error(:invalid_status)

      not MapSet.member?(@phases, phase) ->
        error(:invalid_status)

      s == "active" and phase == "completed" ->
        error(:invalid_status)

      s == "completed" and phase != "completed" ->
        error(:invalid_status)

      s == "aborted_pre_effect" and not MapSet.member?(@abortable_phases, phase) ->
        error(:invalid_status)

      s == "blocked" and phase == "completed" ->
        error(:invalid_status)

      true ->
        :ok
    end
  end

  defp assert_ids(status) do
    if valid_id?(status["operation_id"], @max_operation_id_bytes, @operation_id_re) and
         valid_id?(status["target_agent_id"], @max_agent_id_bytes, @agent_id_re) do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_time_order(status) do
    c = status["created_at_unix_ms"]
    u = status["updated_at_unix_ms"]

    if valid_time?(c) and valid_time?(u) and u >= c do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_retry(retry) when is_map(retry) do
    with :ok <- closed_keyset(retry, @retry_keys),
         attempt when is_integer(attempt) and attempt >= 0 and attempt <= @max_retry <-
           retry["attempt"],
         max when is_integer(max) and max >= 1 and max <= @max_retry <- retry["max_attempts"],
         true <- attempt <= max,
         :ok <- assert_retry_last_code(retry["last_code"], attempt) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_status)
    end
  end

  defp assert_retry(_), do: error(:invalid_status)

  # A fresh retry (attempt 0) carries no last_code: no retry has fired, so the
  # core always resets last_code to nil on every successful acknowledge. Once a
  # retry has fired (attempt > 0) last_code is optional (a retry may be recorded
  # with a nil reason) but, when present, must still be a bounded reason code.
  defp assert_retry_last_code(nil, _attempt), do: :ok
  defp assert_retry_last_code(_code, 0), do: error(:invalid_status)
  defp assert_retry_last_code(code, _attempt), do: assert_optional_reason(code)

  defp assert_optional_reason(nil), do: :ok

  defp assert_optional_reason(code) when is_binary(code) do
    if valid_reason_code?(code), do: :ok, else: error(:invalid_status)
  end

  defp assert_optional_reason(_), do: error(:invalid_status)

  defp assert_terminal(%{"status" => "active"} = status) do
    if is_nil(status["terminal"]), do: :ok, else: error(:invalid_status)
  end

  defp assert_terminal(%{"status" => status} = st)
       when status in ~w(completed aborted_pre_effect blocked) do
    terminal = st["terminal"]
    c = st["created_at_unix_ms"]
    u = st["updated_at_unix_ms"]
    phase = st["phase"]

    with terminal when is_map(terminal) <- terminal,
         :ok <- closed_keyset(terminal, @terminal_keys),
         true <- valid_reason_code?(terminal["reason_code"]),
         true <- valid_time?(terminal["at_unix_ms"]),
         true <- terminal["at_unix_ms"] >= c and terminal["at_unix_ms"] <= u,
         true <- MapSet.member?(@phases, terminal["phase_at_terminal"]),
         :ok <- assert_terminal_shape(status, terminal, phase) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_status)
    end
  end

  defp assert_terminal(_), do: error(:invalid_status)

  defp assert_terminal_shape("completed", terminal, phase) do
    if terminal["reason_code"] == "completed" and terminal["phase_at_terminal"] == "completed" and
         terminal["blocked_kind"] == nil and phase == "completed" do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_terminal_shape("aborted_pre_effect", terminal, phase) do
    if MapSet.member?(@abortable_phases, phase) and
         terminal["phase_at_terminal"] == phase and
         is_nil(terminal["blocked_kind"]) and
         terminal["reason_code"] != "completed" do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_terminal_shape("blocked", terminal, phase) do
    if terminal["phase_at_terminal"] == phase and
         MapSet.member?(@blocked_kinds, terminal["blocked_kind"]) and
         terminal["reason_code"] != "completed" do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_terminal_shape(_, _, _), do: error(:invalid_status)

  # The public journal_summary must describe a journal project/1 can actually
  # emit for the receipt's phase. Pre-capability phases never carry entries; at
  # capability_effects at most one entry is needs_reconcile (the unresolved head
  # of the journal, which may persist into a blocked receipt via hold_blocked);
  # every post-capability phase has all entries succeeded. These relationships
  # are derived from OperationCore's journal-phase invariants.
  defp assert_summary(%{"journal_summary" => summary, "phase" => phase})
       when is_map(summary) do
    with :ok <- closed_keyset(summary, @summary_keys),
         true <-
           Enum.all?(@summary_keys, fn k ->
             is_integer(summary[k]) and summary[k] >= 0
           end),
         true <- summary["entry_count"] <= @max_journal_entries,
         true <-
           summary["pending_count"] + summary["needs_reconcile_count"] +
             summary["succeeded_count"] == summary["entry_count"],
         :ok <- assert_summary_phase_shape(summary, phase) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_status)
    end
  end

  defp assert_summary(_), do: error(:invalid_status)

  defp assert_summary_phase_shape(summary, phase) do
    p_idx = phase_index(phase)
    needs = summary["needs_reconcile_count"]

    cond do
      p_idx < @cap_index ->
        # reserved..runtime_quiesced: the journal is always empty.
        if summary["entry_count"] == 0, do: :ok, else: error(:invalid_status)

      p_idx == @cap_index ->
        # capability_effects: succeeded prefix plus at most one needs_reconcile
        # head plus a pending tail — needs_reconcile_count is bounded to <= 1.
        if needs <= 1, do: :ok, else: error(:invalid_status)

      true ->
        # profile_commit..completed: every entry has succeeded.
        if summary["succeeded_count"] == summary["entry_count"] and
             summary["pending_count"] == 0 and needs == 0 do
          :ok
        else
          error(:invalid_status)
        end
    end
  end

  defp phase_index(phase), do: Map.get(@phase_index, phase, -1)

  # Retry attempt is phase-coupled in the core (validate_retry_coherence /
  # validate_reconciliation_required): a positive attempt is admissible only in a
  # primary outcome phase (a phase-level retry with no journal binding) or at
  # capability_effects (a journal retry bound to the unresolved head). It is
  # never admissible at runtime_quiesced or completed — no reducer can fire a
  # retry there, and completion/acknowledge reset attempt to 0. At
  # capability_effects a positive attempt additionally requires an unresolved
  # journal head (pending or needs_reconcile) to bind last_effect_id to; and an
  # active capability_effects receipt carrying a needs_reconcile head implies
  # reconciliation_required, which the core only sets after a retry fired
  # (attempt > 0). Blocked receipts may retain a needs-reconcile head with
  # reconciliation redacted, so the needs->attempt coupling is scoped to active
  # only. The primary retryable phase vocabulary is sourced from OperationCore
  # so the two modules cannot drift.
  defp assert_retry_phase_coherence(%{
         "retry" => %{"attempt" => attempt},
         "status" => status,
         "phase" => phase,
         "journal_summary" => summary
       })
       when is_integer(attempt) do
    unresolved = summary["pending_count"] + summary["needs_reconcile_count"]
    needs = summary["needs_reconcile_count"]

    cond do
      attempt == 0 ->
        if status == "active" and phase == "capability_effects" and needs > 0 do
          error(:invalid_status)
        else
          :ok
        end

      attempt > 0 ->
        cond do
          phase == "capability_effects" ->
            if unresolved >= 1, do: :ok, else: error(:invalid_status)

          MapSet.member?(@primary_outcome_phases, phase) ->
            :ok

          true ->
            error(:invalid_status)
        end
    end
  end

  defp assert_retry_phase_coherence(_), do: error(:invalid_status)

  # The derived booleans must be consistent with status and the (redacted)
  # fence_required projection. fence_required is re-derivable for active and
  # blocked receipts: the core's fence-state invariants require an installed or
  # pending fence in those two statuses, so a public receipt with
  # fence_required false in either state can never be emitted by project/1 and
  # must be rejected. completed and aborted_pre_effect genuinely vary (cleanup
  # may or may not be acked), so fence_required stays free there and only
  # outstanding/replaceable are derived against it.
  defp assert_derived(status) do
    if status["outstanding"] == derive_outstanding(status) and
         status["replaceable"] == derive_replaceable(status) and
         assert_fence_required(status) == :ok do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp assert_fence_required(%{"status" => s, "fence_required" => fr})
       when s in ~w(active blocked) do
    if fr == true, do: :ok, else: error(:invalid_status)
  end

  # A reserved abort clears the fence before the dispatch fence is ever
  # installed, so the core always emits fence_required=false for it. A public
  # receipt with fence_required=true at an aborted reserved phase can never be
  # emitted by project/1 and must be rejected. Fenced/prepared aborts and
  # completed receipts genuinely vary (cleanup may or may not be acked), so
  # fence_required stays free there.
  defp assert_fence_required(%{
         "status" => "aborted_pre_effect",
         "phase" => "reserved",
         "fence_required" => fr
       }) do
    if fr == false, do: :ok, else: error(:invalid_status)
  end

  defp assert_fence_required(_), do: :ok

  defp derive_outstanding(%{"status" => s}) when s in ~w(active blocked), do: true

  defp derive_outstanding(%{"status" => s, "fence_required" => fr})
       when s in ~w(completed aborted_pre_effect),
       do: fr == true

  defp derive_outstanding(_), do: false

  defp derive_replaceable(%{"status" => s, "fence_required" => fr})
       when s in ~w(completed aborted_pre_effect),
       do: fr != true

  defp derive_replaceable(_), do: false

  defp closed_keyset(map, expected) when is_map(map) do
    keys = Map.keys(map) |> MapSet.new()

    if MapSet.equal?(keys, expected) and Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      error(:invalid_status)
    end
  end

  defp closed_keyset(_, _), do: error(:invalid_status)

  defp valid_id?(id, max, re)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= max do
    String.valid?(id) and Regex.match?(re, id)
  end

  defp valid_id?(_, _, _), do: false

  defp valid_reason_code?(code)
       when is_binary(code) and byte_size(code) > 0 and byte_size(code) <= @max_reason_bytes do
    String.valid?(code) and Regex.match?(@reason_code_re, code)
  end

  defp valid_reason_code?(_), do: false

  defp valid_time?(t) when is_integer(t) and t >= 0 and t <= @max_json_safe_integer, do: true
  defp valid_time?(_), do: false

  defp error(reason),
    do: {:error, {:template_authority_reconciliation_status, reason}}
end
