defmodule Arbor.Memory.ThinkingInventory do
  @moduledoc false

  alias Arbor.Contracts.Security.TaintedValue
  alias Arbor.Memory.ThinkingCodec

  @type plan :: {String.t(), [ThinkingCodec.decoded_item()]}
  @type inventory :: %{plans: [plan()], quarantined: MapSet.t(String.t())}

  @spec classify(term(), pos_integer(), pos_integer()) ::
          {:ok, inventory()} | {:error, :invalid_durable_state}
  def classify(records, limit, max_agents)
      when is_integer(limit) and limit > 0 and is_integer(max_agents) and max_agents > 0 do
    classify_rows(records, limit, max_agents, 0, %{}, MapSet.new())
  end

  def classify(_records, _limit, _max_agents), do: {:error, :invalid_durable_state}

  @spec absence_ids(MapSet.t(String.t()), [plan()], MapSet.t(String.t())) ::
          MapSet.t(String.t())
  def absence_ids(%MapSet{} = previously_owned, plans, %MapSet{} = quarantined)
      when is_list(plans) do
    plan_ids = MapSet.new(plans, &elem(&1, 0))

    previously_owned
    |> MapSet.difference(plan_ids)
    |> MapSet.difference(quarantined)
  end

  defp classify_rows([], _limit, _max_agents, _count, candidates, quarantined) do
    {:ok, %{plans: Map.to_list(candidates), quarantined: quarantined}}
  end

  defp classify_rows([row | rest], limit, max_agents, count, candidates, quarantined)
       when count < max_agents do
    {candidates, quarantined} = classify_row(row, limit, candidates, quarantined)
    classify_rows(rest, limit, max_agents, count + 1, candidates, quarantined)
  end

  defp classify_rows(_records, _limit, _max_agents, _count, _candidates, _quarantined),
    do: {:error, :invalid_durable_state}

  defp classify_row(row, limit, candidates, quarantined) do
    case identified_agent_id(row) do
      :error ->
        {candidates, quarantined}

      {:ok, agent_id} ->
        case decode_candidate(row, agent_id, limit) do
          {:ok, items} -> store_candidate(agent_id, items, candidates, quarantined)
          :quarantine -> quarantine_id(agent_id, candidates, quarantined)
        end
    end
  end

  defp identified_agent_id(row) do
    cond do
      is_tuple(row) and tuple_size(row) >= 1 and ThinkingCodec.valid_identifier?(elem(row, 0)) ->
        {:ok, elem(row, 0)}

      ThinkingCodec.valid_identifier?(row) ->
        {:ok, row}

      true ->
        :error
    end
  end

  defp decode_candidate(
         {agent_id, %TaintedValue{value: aggregate, taint: outer}, status},
         agent_id,
         limit
       ) do
    case ThinkingCodec.decode_aggregate(agent_id, aggregate, outer, status, limit) do
      {:ok, items} -> {:ok, items}
      _ -> :quarantine
    end
  end

  defp decode_candidate(_row, _agent_id, _limit), do: :quarantine

  defp store_candidate(agent_id, items, candidates, quarantined) do
    cond do
      MapSet.member?(quarantined, agent_id) ->
        {candidates, quarantined}

      Map.has_key?(candidates, agent_id) ->
        quarantine_id(agent_id, candidates, quarantined)

      true ->
        {Map.put(candidates, agent_id, items), quarantined}
    end
  end

  defp quarantine_id(agent_id, candidates, quarantined) do
    {Map.delete(candidates, agent_id), MapSet.put(quarantined, agent_id)}
  end
end
