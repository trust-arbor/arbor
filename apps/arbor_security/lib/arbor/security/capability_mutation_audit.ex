defmodule Arbor.Security.CapabilityMutationAudit do
  @moduledoc """
  Thin audit boundary called synchronously by CapabilityStore, its sole writer.

  Prepares the existing journal before exact authority CAS/CAD. A failed or
  ambiguous store response is reobserved through the same AuthorityStore owner;
  pending intent is retained when authoritative observation is unavailable.
  Reductions remain possible with unavailable journal, but never turn a failed
  delete into an acknowledged success. Post-effect journal failure is reported
  separately and cannot roll back or disguise the known authority effect.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Security.AuditJournalOwner
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.CapabilityAuditCore, as: Core
  alias Arbor.Security.CapabilityStore.Serializer

  @store :arbor_security_capabilities
  @status_key {__MODULE__, :last_status}
  @correlation_key {__MODULE__, :correlation}

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

  def last_status, do: Process.get(@status_key, %{audit: :none, effect: :none, operation: :none})

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
      {:ok, intent} -> prepare_mutation(operation, intent, before, after_entry)
      _ when operation == :revoke -> degraded_reduction(before, after_entry)
      _ -> {:error, :invalid_audit_intent}
    end
  end

  defp prepare_mutation(operation, intent, before, after_entry) do
    case AuditJournalOwner.prepare(intent) do
      {:ok, original, "prepared"} ->
        execute(operation, original, before, after_entry, :tracked)

      {:ok, original, "effect_applied"} ->
        reobserve(operation, original, :tracked)

      {:error, _} when operation == :revoke ->
        execute(operation, intent, before, after_entry, :degraded)

      _ ->
        {:error, :audit_unavailable}
    end
  end

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
  defp status(operation, id, effect, audit),
    do:
      Process.put(@status_key, %{
        operation: operation,
        operation_id: id,
        effect: effect,
        audit: audit
      })
end
