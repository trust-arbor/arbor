defmodule Arbor.Security.CapabilityMutationAudit do
  @moduledoc """
  Thin audit boundary called synchronously by CapabilityStore, its sole writer.

  Prepares the existing journal before exact authority CAS/CAD. A failed or
  ambiguous store response is reobserved through the same AuthorityStore owner;
  pending intent is retained when authoritative observation is unavailable.
  Reductions remain possible with unavailable journal, but never turn a failed
  delete into an acknowledged success. Post-effect journal failure is reported
  separately and cannot roll back or disguise the known authority effect.

  Journal refusals keep the public result vocabulary (a refused grant is
  `{:error, :audit_unavailable}`; a refused reduction executes `:degraded`)
  and add a closed reason class to `last_status/0`: `:capacity` (soft or
  hard capacity), `:identity` (`:operation_terminal | :retired_version`) or
  `:unavailable` (anything else). A refused grant emits
  `[:arbor, :security, :audit_journal, :refused]`; every degraded
  (unjournaled) reduction emits
  `[:arbor, :security, :audit_journal, :degraded_reduction]` and is counted.
  The first 10 degraded reductions of the calling process log a warning, then
  every 100th with the cumulative count, so a sustained outage cannot flood
  the log an operator reads.
  """

  require Logger

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityAuditCore, as: Core
  alias Arbor.Security.CapabilityStore.Serializer

  @store :arbor_security_capabilities
  @status_key {__MODULE__, :last_status}
  @correlation_key {__MODULE__, :correlation}
  @degraded_key {__MODULE__, :degraded_reductions}
  @warn_first 10
  @warn_every 100

  def with_correlation(correlation, fun) do
    value =
      if is_binary(correlation) and byte_size(correlation) == 36 and
           Regex.match?(~r/^inv_[0-9a-f]{32}$/, correlation), do: correlation, else: nil

    Process.put(@correlation_key, value)

    try do
      fun.()
    after
      Process.delete(@correlation_key)
    end
  end

  def last_status do
    @status_key
    |> Process.get(%{audit: :none, effect: :none, operation: :none, reason: :none})
    |> Map.put(:degraded_reductions, Process.get(@degraded_key, 0))
  end

  @doc false
  @spec reason_class(term()) :: :capacity | :identity | :unavailable
  def reason_class(reason) when reason in [:soft_capacity_exhausted, :capacity_exhausted],
    do: :capacity

  def reason_class(reason) when reason in [:operation_terminal, :retired_version],
    do: :identity

  def reason_class(_reason), do: :unavailable

  @doc false
  @spec warn_degraded_reduction?(pos_integer()) :: boolean()
  def warn_degraded_reduction?(count) when is_integer(count) and count > 0,
    do: count <= @warn_first or rem(count, @warn_every) == 0

  def warn_degraded_reduction?(_count), do: false

  def put(%Capability{} = cap, mode) when mode in [:create, :upsert] do
    with {:ok, before} <- entry(cap.id),
         :ok <- admit_put(mode, before) do
      data = Serializer.serialize(cap)
      proposed = Record.new(cap.id, data)
      replacement = Core.replacement(proposed, before)

      if match?(%Record{}, before) and before.data == data do
        {:ok, before}
      else
        mutate(:grant, before, replacement, data)
      end
    end
  rescue
    _ -> {:error, :audit_unavailable}
  catch
    _, _ -> {:error, :audit_unavailable}
  end

  def delete(key, expected \\ :current) do
    with {:ok, before} <- entry(key),
         :ok <- admit_delete(expected, before) do
      case before do
        %Record{} -> mutate(:revoke, before, {:tombstone, before.generation}, before.data)
        _ -> :ok
      end
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  def reconcile do
    case AuditJournalOwner.pending_intents() do
      {:ok, pending} ->
        Enum.each(pending, &reconcile_one/1)
        :ok

      _ ->
        {:error, :audit_unavailable}
    end
  end

  defp reconcile_one(%{"intent" => intent, "status" => "prepared"}) do
    case entry(intent["authority_key"]) do
      {:ok, current} -> record_observation(intent, Core.observation(intent, current))
      _ -> :ok
    end
  end

  defp reconcile_one(_), do: :ok

  defp mutate(operation, before, after_entry, data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Core.intent(operation, before, after_entry, data, now, Process.get(@correlation_key)) do
      {:ok, intent} ->
        prepare_mutation(operation, intent, before, after_entry)

      _ when operation == :revoke ->
        note_degraded_reduction(:invalid_audit_intent, nil)
        with_reason(degraded_reduction(before, after_entry), :invalid_audit_intent)

      _ ->
        {:error, :invalid_audit_intent}
    end
  end

  defp prepare_mutation(operation, intent, before, after_entry) do
    case AuditJournalOwner.prepare(intent) do
      {:ok, original, "prepared"} ->
        execute(operation, original, before, after_entry, :tracked)

      {:ok, original, "effect_applied"} ->
        reobserve(operation, original, :tracked)

      {:error, reason} when operation == :revoke ->
        note_degraded_reduction(reason, intent["operation_id"])
        with_reason(execute(operation, intent, before, after_entry, :degraded), reason)

      other ->
        refused_grant(operation, intent, refusal_reason(other))
    end
  end

  defp refusal_reason({:error, reason}), do: reason
  defp refusal_reason(_other), do: :unexpected_prepare_result

  defp refused_grant(operation, intent, reason) do
    class = reason_class(reason)

    :telemetry.execute(
      [:arbor, :security, :audit_journal, :refused],
      %{count: 1},
      %{operation: operation, reason: class}
    )

    status(operation, intent["operation_id"], :not_applied, :refused, class)
    {:error, :audit_unavailable}
  end

  # A reduction the journal could not record executes unjournaled. It is
  # always counted and signalled; the warning is rate limited per process.
  defp note_degraded_reduction(reason, operation_id) do
    count = Process.get(@degraded_key, 0) + 1
    Process.put(@degraded_key, count)
    class = reason_class(reason)

    :telemetry.execute(
      [:arbor, :security, :audit_journal, :degraded_reduction],
      %{count: 1, total: count},
      %{reason: class}
    )

    if warn_degraded_reduction?(count) do
      Logger.warning(
        "Capability reduction executed without a journal record (degraded #{count}, " <>
          "reason #{class}, operation #{operation_id || "none"})"
      )
    end

    :ok
  end

  # The degraded execution path records its own effect/audit status; the
  # refusal reason class is added to it.
  defp with_reason(result, reason) do
    Process.put(@status_key, Map.put(last_status_raw(), :reason, reason_class(reason)))
    result
  end

  defp last_status_raw,
    do: Process.get(@status_key, %{audit: :none, effect: :none, operation: :none, reason: :none})

  # Legacy stored keys may predate the closed journal schema. Their removal
  # still uses the exact authority owner and observation; no fabricated audit
  # record or successful-but-unobserved deletion is reported.
  defp degraded_reduction(%Record{} = before, after_entry) do
    with {:ok, fingerprint} <- Core.fingerprint(before),
         {:ok, after_fingerprint} <- Core.fingerprint(after_entry) do
      intent = %{
        "authority_key" => before.key,
        "operation_id" => nil,
        "before_fence" => fingerprint,
        "after_fingerprint" => after_fingerprint
      }

      execute(:revoke, intent, before, after_entry, :degraded)
    end
  end

  defp execute(operation, intent, before, after_entry, audit) do
    # Even an error may follow a committed effect. The authoritative read is
    # ordered after this call at the same serialized owner, never an ETS read.
    result = attempt_effect(operation, intent["authority_key"], before, after_entry)
    observed = reobserve(operation, intent, audit)

    # Preserve the acknowledged facade's exact-conflict classification. A
    # backend CAS conflict does not become this caller's newly applied effect.
    if result == {:error, :conflict}, do: {:error, :conflict}, else: observed
  end

  defp attempt_effect(operation, key, before, after_entry) do
    effect(operation, key, before, after_entry)
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp effect(:grant, key, %Record{} = before, after_entry),
    do:
      AuthorityStore.acknowledged_compare_and_swap(key, {:value, before}, after_entry,
        name: @store
      )

  defp effect(:grant, key, before, after_entry),
    do: AuthorityStore.acknowledged_compare_and_create(key, before, after_entry, name: @store)

  defp effect(:revoke, key, before, _after_entry),
    do: AuthorityStore.acknowledged_compare_and_delete(key, before, name: @store)

  defp reobserve(operation, intent, audit) do
    case entry(intent["authority_key"]) do
      {:ok, current} ->
        observation = Core.observation(intent, current)

        recorded =
          if audit == :tracked,
            do: record_observation(intent, observation),
            else: {:error, :audit_unavailable}

        finish(operation, intent["operation_id"], current, observation, recorded)

      _ ->
        status(operation, intent["operation_id"], :unknown, :degraded)
        {:error, :outcome_unknown}
    end
  end

  defp finish(operation, id, current, :applied, recorded) do
    audit = if match?({:ok, _}, recorded), do: :recorded, else: :degraded
    status(operation, id, :applied, audit)
    if operation == :grant, do: {:ok, current}, else: :ok
  end

  defp finish(operation, id, _current, {:rejected, _reason}, recorded) do
    status(
      operation,
      id,
      :not_applied,
      if(match?({:ok, _}, recorded), do: :recorded, else: :degraded)
    )

    {:error, :conflict}
  end

  defp finish(operation, id, _current, :unknown, _recorded) do
    status(operation, id, :unknown, :degraded)
    {:error, :outcome_unknown}
  end

  defp record_observation(_intent, :unknown), do: {:error, :outcome_unknown}

  # Exact unchanged-before state permits a later retry of the same stable
  # intent. It is not a terminal rejection of all future attempts.
  defp record_observation(_intent, {:rejected, _}), do: {:error, :not_applied}

  defp record_observation(intent, observation),
    do: AuditJournalOwner.observe(intent["operation_id"], observation)

  defp entry(key), do: AuthorityStore.authoritative_entry(key, name: @store)
  defp admit_put(:create, %Record{}), do: {:error, :conflict}
  defp admit_put(_mode, _entry), do: :ok
  defp admit_delete(:current, _entry), do: :ok
  defp admit_delete(expected, expected), do: :ok
  defp admit_delete(_expected, _entry), do: {:error, :conflict}

  # Diagnostic state belongs to the serialized CapabilityStore caller. It is
  # not durable evidence, permission, or a substitute for journal replay.
  defp status(operation, id, effect, audit, reason \\ :none),
    do:
      Process.put(@status_key, %{
        operation: operation,
        operation_id: id,
        effect: effect,
        audit: audit,
        reason: reason
      })
end
