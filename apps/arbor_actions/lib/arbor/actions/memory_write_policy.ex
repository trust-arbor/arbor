defmodule Arbor.Actions.MemoryWritePolicy do
  @moduledoc """
  Pure admission for the Session-owned private-turn memory write restriction.

  The runtime context may add `memory_write_policy: :deny`; parameters never
  relax it. This is containment, not ownership or permission to read private
  data. Generic semantic recall is also refused because its query embedding
  does not prove the Session's selected local route. Absent/nil policy preserves existing authorization. Unknown nonnil
  policies fail closed, including on otherwise read-only actions.

  Memory families default to denied so a new action cannot silently acquire
  private-turn writes. The read allowlist includes the operational Session
  checkpoint, which is not a general memory producer. Incidental read access
  accounting is allowed. Uncontained child launches are denied separately;
  this does not claim to prevent every external disclosure route.
  """

  @memory_families [
    Arbor.Actions.Memory,
    Arbor.Actions.MemoryIdentity,
    Arbor.Actions.MemoryCognitive,
    Arbor.Actions.MemoryReview,
    Arbor.Actions.MemoryCode,
    Arbor.Actions.Relationship,
    Arbor.Actions.SessionMemory,
    Arbor.Actions.SessionGoals,
    Arbor.Actions.SessionExecution
  ]

  @read_actions [
    Arbor.Actions.Memory.LoadWorking,
    Arbor.Actions.MemoryIdentity.ReadSelf,
    Arbor.Actions.MemoryIdentity.IntrospectMemory,
    Arbor.Actions.MemoryReview.ReviewSuggestions,
    Arbor.Actions.MemoryCode.ListCode,
    Arbor.Actions.MemoryCode.ViewCode,
    Arbor.Actions.SessionMemory.Recall,
    Arbor.Actions.SessionMemory.Checkpoint
  ]

  @other_writers [
    Arbor.Actions.Skill.Activate,
    Arbor.Actions.Skill.Deactivate,
    Arbor.Actions.Scheduler.EnqueueRoutine,
    Arbor.Actions.Scheduler.CancelRoutine
  ]
  @uncontained_launches [
    Arbor.Actions.Agent.SpawnWorker,
    Arbor.Actions.Pipeline.Run,
    Arbor.Actions.Council.Consult,
    Arbor.Actions.Council.ConsultOne,
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Acp.StartSession,
    Arbor.Actions.Acp.SendMessage
  ]

  @turn_data_keys [:turn_data, "turn_data", "session.turn_data"]
  @note_keys [:memory_notes, "memory_notes", "session.memory_notes"]
  @denied {:error, :private_turn_memory_write_denied}

  @spec check(module(), map(), map()) :: :ok | {:error, atom()}
  def check(action_module, params, context) do
    case Map.get(context, :memory_write_policy) do
      nil -> :ok
      :deny -> check_restricted(action_module, params)
      _invalid -> @denied
    end
  end

  defp check_restricted(Arbor.Actions.SessionMemory.Update, params) do
    if empty_update?(params), do: :ok, else: @denied
  end

  defp check_restricted(Arbor.Actions.Memory.Recall, _params),
    do: {:error, :private_turn_memory_query_denied}

  defp check_restricted(action_module, _params)
       when action_module in [
              Arbor.Actions.Relationship.Get,
              Arbor.Actions.Relationship.Browse,
              Arbor.Actions.Relationship.Summarize
            ],
       do: {:error, :private_turn_relationship_read_denied}

  defp check_restricted(action_module, _params) when action_module in @read_actions, do: :ok

  defp check_restricted(action_module, _params) do
    if memory_family?(action_module) or action_module in @other_writers or
         action_module in @uncontained_launches,
       do: @denied,
       else: :ok
  end

  defp memory_family?(module) when is_atom(module) do
    name = Atom.to_string(module)

    Enum.any?(@memory_families, fn family ->
      module == family or String.starts_with?(name, Atom.to_string(family) <> ".")
    end)
  end

  defp memory_family?(_module), do: false

  defp empty_update?(params) when is_map(params) and not is_struct(params) do
    params
    |> Map.take(@turn_data_keys)
    |> Map.values()
    |> Enum.all?(&empty_turn_data?/1)
  end

  defp empty_update?(_params), do: false

  defp empty_turn_data?(nil), do: true

  defp empty_turn_data?(data) when is_map(data) and not is_struct(data) do
    data
    |> Map.take(@note_keys)
    |> Map.values()
    |> Enum.all?(&(&1 in [nil, []]))
  end

  defp empty_turn_data?(_data), do: false
end
