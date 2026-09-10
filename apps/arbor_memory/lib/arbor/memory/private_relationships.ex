defmodule Arbor.Memory.PrivateRelationships do
  @moduledoc false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{TaintedValue, TaintEnvelope}
  alias Arbor.Memory.{Config, MemoryStore, MutationAdmission, PrivateConversationSource}
  alias Arbor.Memory.Cores.PrivateRelationshipCore, as: Core

  def get(admission) do
    with {:ok, scope} <- authorize(admission, :read),
         :ok <- MemoryStore.require_node_restart_authority(),
         {:ok, key} <- Core.key(scope),
         {:ok, body, expected} <- load(key, scope),
         {:ok, ^scope} <- authorize(admission, :read) do
      {:ok, %{relationship: Core.projection(body), fence: expected}}
    else
      {:ok, _changed_scope} -> {:error, :invalid_memory_admission}
      error -> error
    end
  end

  def apply_source(admission, source, expected) do
    with true <- expected == :not_found or is_struct(expected, Record),
         {:ok, source_scope, _content} <- PrivateConversationSource.admit(source),
         {:ok, ^source_scope} <- authorize(admission, :write),
         :ok <- security(:verify_private_memory_source, [source["descriptor"], source["stamp"]]) do
      case Core.parse(source["user_content"]) do
        {:ok, directive} -> apply_directive(admission, source_scope, source, directive, expected)
        :ignored -> {:ok, :not_requested}
        error -> error
      end
    else
      false -> {:error, :invalid_private_relationship_fence}
      {:ok, _other_scope} -> {:error, :private_relationship_source_not_current}
      error -> error
    end
  end

  defp apply_directive(admission, scope, source, directive, expected) do
    with :ok <- MemoryStore.require_node_restart_authority(),
         {:ok, lease} <- MutationAdmission.acquire(scope.agent_id) do
      try do
        with {:ok, key} <- Core.key(scope),
             {:ok, previous, observed} <- load(key, scope) do
          apply_observed(admission, scope, key, previous, observed, expected, source, directive)
        end
      after
        MutationAdmission.release(lease)
      end
    end
  end

  defp apply_observed(admission, scope, key, previous, observed, expected, source, directive) do
    cond do
      previous && previous["last_source_id"] == source["descriptor"]["source_id"] ->
        if previous["source_proof"] === Map.take(source, ["descriptor", "stamp"]),
          do: {:ok, :unchanged},
          else: {:error, :private_relationship_conflict}

      observed !== expected ->
        {:error, :private_relationship_conflict}

      true ->
        case Core.decide(previous && previous["current_focus"], directive) do
          {:write, _value} ->
            put(admission, scope, key, source, directive, observed)

          :unchanged ->
            {:ok, :unchanged}

          error ->
            error
        end
    end
  end

  defp put(admission, scope, key, source, directive, expected) do
    body = Core.body(scope, source, directive, Core.next_revision(expected))

    with {:ok, descriptor} <- Core.descriptor(body, key),
         {:ok, stamp} <- security(:attest_private_relationship_snapshot, [admission, descriptor]),
         body <- Map.put(body, "owner_stamp", stamp),
         :ok <- Core.admit_body(body),
         {:ok, ^scope} <- authorize(admission, :write) do
      commit(key, expected, body, descriptor)
    else
      {:ok, _changed_scope} -> {:error, :invalid_memory_admission}
      error -> error
    end
  end

  defp commit(key, expected, body, descriptor) do
    case MemoryStore.compare_and_swap_tainted(Core.namespace(), key, expected, body,
           taint: TaintEnvelope.missing_fallback()
         ) do
      {:ok, %Record{data: ^body} = record} ->
        with {:ok, ^descriptor} <- Core.record_descriptor(record),
             :ok <- verify_record(record) do
          {:ok, :saved}
        else
          _ -> {:error, :outcome_unknown}
        end

      {:error, {:memory_store, :critical, :outcome_unknown}} ->
        {:error, :outcome_unknown}

      {:error, {:memory_store, :critical, :conflict}} ->
        {:error, :private_relationship_conflict}

      {:error, _} = error ->
        error

      _ ->
        {:error, :outcome_unknown}
    end
  end

  defp load(key, scope) do
    case MemoryStore.load_tainted_authoritative_with_status(Core.namespace(), key) do
      {:ok, %TaintedValue{value: body, taint: taint}, :verified, %Record{data: body} = record,
       :namespaced} ->
        with true <- taint == TaintEnvelope.missing_fallback(),
             :ok <- verify_record(record),
             true <- Core.same_pair?(body, scope) do
          {:ok, body, record}
        else
          _ -> {:error, :invalid_private_relationship_snapshot}
        end

      {:error, :not_found} ->
        {:ok, nil, :not_found}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_private_relationship_snapshot}
    end
  end

  defp verify_record(record) do
    with {:ok, descriptor} <- Core.record_descriptor(record),
         :ok <-
           security(:verify_private_relationship_snapshot, [
             descriptor,
             record.data["owner_stamp"]
           ]),
         proof <- record.data["source_proof"] do
      security(:verify_private_memory_source, [proof["descriptor"], proof["stamp"]])
    end
  end

  # RelationshipStore remains the destruction/absence owner. Verify the whole
  # bounded inventory before selecting an agent, then delete only exact records.
  def inventory(agent_id) do
    with :ok <- MemoryStore.require_node_restart_authority(),
         {:ok, rows} <- MemoryStore.load_all_tainted_authoritative(Core.namespace()),
         {:ok, verified} <- verify_inventory(rows) do
      {:ok,
       Enum.filter(verified, fn {_key, record} -> record.data["scope"]["agent_id"] == agent_id end)}
    end
  end

  def delete_inventory(records) do
    Enum.reduce_while(records, :ok, fn {key, record}, :ok ->
      case MemoryStore.compare_and_delete_tainted(Core.namespace(), key, record) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_inventory(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      {key, %TaintedValue{}, :verified}, {:ok, acc} ->
        case MemoryStore.load_tainted_authoritative_with_status(Core.namespace(), key) do
          {:ok, %TaintedValue{taint: taint}, :verified, %Record{} = record, :namespaced} ->
            with true <- taint == TaintEnvelope.missing_fallback(),
                 :ok <- verify_record(record) do
              {:cont, {:ok, [{key, record} | acc]}}
            else
              _ -> {:halt, {:error, :invalid_private_relationship_snapshot}}
            end

          _ ->
            {:halt, {:error, :invalid_private_relationship_snapshot}}
        end

      _, _ ->
        {:halt, {:error, :invalid_private_relationship_snapshot}}
    end)
  end

  defp authorize(admission, operation),
    do: security(:authorize_private_memory_turn, [admission, operation])

  defp security(function, args) do
    apply(Config.private_memory_security(), function, args)
  rescue
    _ -> {:error, :private_relationship_authority_unavailable}
  catch
    _, _ -> {:error, :private_relationship_authority_unavailable}
  end
end
