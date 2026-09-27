defmodule Arbor.Orchestrator.Session.TranscriptCore do
  @moduledoc "Pure bounded reconciliation of durable entries with an acknowledged local suffix."

  alias Arbor.Orchestrator.Session.Persistence.Core
  alias Arbor.Orchestrator.Session.PrivateMemory.Core, as: PrivateMemoryCore

  def reconcile(snapshot, scope, anchor, messages) do
    with :ok <- validate_snapshot(snapshot, scope, anchor),
         :ok <- coherent_sources(snapshot, scope, anchor),
         {:ok, plan} <- plan(snapshot, anchor, messages) do
      {:ok, Map.put(plan, :cursor, snapshot.head)}
    end
  rescue
    _ -> {:error, :transcript_invalid}
  catch
    _, _ -> {:error, :transcript_invalid}
  end

  defp coherent_sources(snapshot, scope, anchor) do
    boundary = Map.get(snapshot, :boundary_entries, [])

    valid_boundary? =
      case {boundary, snapshot.entries, anchor} do
        {[], _, _} ->
          true

        {[entry], [first | _], nil} ->
          snapshot.truncated and first.role == "assistant" and entry.role == "user" and
            entry.entry_ordinal + 1 == first.entry_ordinal and
            valid_entry?(entry, scope.engagement_id)

        _ ->
          false
      end

    if valid_boundary? and
         PrivateMemoryCore.coherent_transcript_sources?(
           boundary ++ snapshot.entries,
           scope.session_id
         ),
       do: :ok,
       else: {:error, :transcript_incomplete_source}
  end

  defp validate_snapshot(snapshot, scope, anchor) do
    cursor = if is_map(anchor), do: anchor.cursor, else: 0
    entries = snapshot.entries
    ordinals = Enum.map(entries, & &1.entry_ordinal)
    ids = Enum.map(entries, & &1.id)

    if snapshot.session_id == scope.session_id and snapshot.agent_id == scope.agent_id and
         snapshot.engagement_id == scope.engagement_id and snapshot.has_more == false and
         is_integer(snapshot.head) and snapshot.head >= cursor and
         snapshot.cursor == snapshot.head and
         length(entries) <= 1_000 and length(Enum.uniq(ids)) == length(ids) and
         Enum.all?(ordinals, &(is_integer(&1) and &1 > cursor and &1 <= snapshot.head)) and
         strictly_ordered?(ordinals) and
         Enum.all?(entries, &valid_entry?(&1, scope.engagement_id)) and
         (entries != [] or snapshot.head == cursor) do
      :ok
    else
      {:error, :transcript_invalid}
    end
  end

  defp valid_entry?(entry, engagement_id) do
    is_binary(entry.id) and byte_size(entry.id) == 36 and
      entry.role in ["user", "assistant"] and is_list(entry.content) and
      is_map(entry.metadata) and entry.metadata["engagement_id"] == engagement_id and
      entry.taint_status in [:verified, :legacy_unlabeled]
  end

  defp strictly_ordered?([]), do: true
  defp strictly_ordered?([_]), do: true
  defp strictly_ordered?([a, b | rest]), do: a < b and strictly_ordered?([b | rest])

  defp plan(snapshot, nil, messages) do
    if Enum.all?(messages, &(Map.get(&1, "role") == "system")) do
      {:ok, %{mode: :bootstrap, messages: messages ++ restore(snapshot.entries), suffix: []}}
    else
      {:error, :transcript_unanchored}
    end
  end

  defp plan(snapshot, %{messages: expected, pending: pending} = anchor, messages)
       when messages == expected do
    expected_entries = Enum.map(pending, & &1.entry)
    ids = MapSet.new(expected_entries, & &1.id)
    durable_own = Enum.filter(snapshot.entries, &MapSet.member?(ids, &1.id))

    if Enum.map(durable_own, &descriptor/1) == Enum.map(expected_entries, &descriptor/1) do
      live_by_id = Map.new(pending, &{&1.entry.id, &1.message})
      suffix = Enum.map(snapshot.entries, &Map.get(live_by_id, &1.id, restore_entry(&1)))
      own_prefix? = Enum.take(snapshot.entries, length(pending)) == durable_own
      external_suffix = suffix |> Enum.drop(length(pending)) |> Enum.reject(&is_nil/1)

      cond do
        suffix == [] or (own_prefix? and external_suffix == []) ->
          {:ok, %{mode: :keep, messages: messages, suffix: []}}

        own_prefix? ->
          {:ok, %{mode: :append, messages: messages ++ external_suffix, suffix: external_suffix}}

        true ->
          suffix = Enum.reject(suffix, &is_nil/1)
          {:ok, %{mode: :rebase, messages: anchor.base_messages ++ suffix, suffix: suffix}}
      end
    else
      {:error, :transcript_acknowledgment_missing}
    end
  end

  defp plan(_, _, _), do: {:error, :transcript_unanchored}

  defp descriptor(entry), do: Map.take(entry, [:id, :role, :content, :metadata])
  defp restore(entries), do: Enum.map(entries, &restore_entry/1)

  defp restore_entry(entry) do
    [message] = Core.restore_messages([entry])

    Map.merge(message, %{
      "id" => entry.id,
      "entry_ordinal" => entry.entry_ordinal,
      "timestamp" => entry.timestamp,
      "model" => entry.model,
      "token_usage" => entry.token_usage
    })
  end
end
