defmodule Arbor.Orchestrator.Session.PrivateMemory do
  @moduledoc false

  # Session-local admission lifecycle. Calls stay in the Session process; opaque
  # handles never enter shared TurnAuthority, graph values, or provider options.
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers
  alias Arbor.Security

  @doc false
  def exchange(receipt, user_message, state) do
    turn_id = Identifiers.generate_id("turn_")

    with {:ok, authority} <-
           TurnAuthority.new(
             turn_id: turn_id,
             authenticated_principal_id: user_message.sender_id,
             disclosure_capability_id: nil
           ),
         {:ok, admission} <-
           Security.exchange_private_memory_receipt(
             receipt,
             state.agent_id,
             user_message.sender_id,
             %{session_id: state.session_id, turn_id: turn_id}
           ) do
      {:ok, authority, admission}
    else
      _ -> {:error, :unauthenticated}
    end
  rescue
    _ -> {:error, :unauthenticated}
  catch
    _, _ -> {:error, :unauthenticated}
  end

  @doc false
  def retain(state, %TurnAuthority{turn_id: turn_id}, admission) do
    Map.put(state, :private_memory_admissions, Map.put(admissions(state), turn_id, admission))
  end

  @doc false
  def activate(_state, _user_message, nil), do: :ok

  def activate(state, user_message, %TurnAuthority{turn_id: turn_id}) do
    with {:ok, admission} <- Map.fetch(admissions(state), turn_id),
         :ok <-
           Security.activate_private_memory_admission(admission, user_message.engagement_id) do
      :ok
    else
      _ -> {:error, :private_memory_admission_unavailable}
    end
  rescue
    _ -> {:error, :private_memory_admission_unavailable}
  catch
    _, _ -> {:error, :private_memory_admission_unavailable}
  end

  @doc false
  def current(state) do
    case state.turn_authority do
      %TurnAuthority{turn_id: turn_id} -> Map.get(admissions(state), turn_id)
      nil -> nil
    end
  end

  @doc false
  def close(state, %TurnAuthority{turn_id: turn_id}) do
    {admission, remaining} = Map.pop(admissions(state), turn_id)
    close_admission(admission)
    Map.put(state, :private_memory_admissions, remaining)
  end

  def close(state, nil), do: state

  @doc false
  def close_admission(nil), do: :ok

  def close_admission(admission) do
    Security.close_private_memory_admission(admission)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def close_all(state) do
    Enum.each(admissions(state), fn {_turn_id, admission} -> close_admission(admission) end)
    :ok
  end

  @doc false
  def prune(state) do
    retained =
      state.turn_queue
      |> Enum.reduce(MapSet.new(), fn
        {_message, %TurnAuthority{turn_id: turn_id}, _from}, ids -> MapSet.put(ids, turn_id)
        _, ids -> ids
      end)
      |> retain_active(state)

    remaining =
      Enum.reduce(admissions(state), %{}, fn {turn_id, admission}, acc ->
        if MapSet.member?(retained, turn_id) do
          Map.put(acc, turn_id, admission)
        else
          close_admission(admission)
          acc
        end
      end)

    Map.put(state, :private_memory_admissions, remaining)
  end

  defp retain_active(ids, %{turn_in_flight: true, turn_authority: %TurnAuthority{turn_id: id}}),
    do: MapSet.put(ids, id)

  defp retain_active(ids, _state), do: ids

  defp admissions(state), do: Map.get(state, :private_memory_admissions, %{})
end
