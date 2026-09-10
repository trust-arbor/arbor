defmodule Arbor.Orchestrator.Session.PrivateMemory do
  @moduledoc false

  # Session-local admission lifecycle. Calls stay in the Session process; opaque
  # handles never enter shared TurnAuthority, graph values, or provider options.
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers
  alias Arbor.Memory
  alias Arbor.Orchestrator.Session.Persistence
  alias Arbor.Orchestrator.Session.PrivateMemory.{Core, Embedding}
  alias Arbor.Security

  @budget_ms 30_000
  @max_pending 5

  def prepare_turn(state, user_message, authority) do
    case Embedding.route() do
      :disabled ->
        {:ok, %{status: "disabled", recall: []}}

      {:ok, _route} when is_nil(authority) ->
        {:ok, %{status: "unavailable", reason: "authenticated_session_required", recall: []}}

      {:ok, route} ->
        prepare_enabled_turn(state, user_message, authority, route)

      {:error, _} = error ->
        error
    end
  end

  defp prepare_enabled_turn(state, user_message, authority, route) do
    admission = for_authority(state, authority)
    deadline = System.monotonic_time(:millisecond) + @budget_ms

    with :ok <- Embedding.validate_inputs([user_message.content]),
         {:ok, scope} <- Security.authorize_private_memory_turn(admission, :read),
         {:ok, ^scope} <- Security.authorize_private_memory_turn(admission, :write),
         :ok <- Embedding.authorize(route, scope) do
      sources =
        state |> Persistence.load_private_memory_sources() |> Core.sources(state.session_id)

      pending = select_pending(admission, sources, deadline)

      turn = %{
        status: "enabled",
        recall: [],
        route: route,
        pending: pending,
        deadline: deadline,
        query: user_message.content,
        source: nil
      }

      with {:ok, ^scope} <- Security.authorize_private_memory_turn(admission, :read),
           {:ok, ^scope} <- Security.authorize_private_memory_turn(admission, :write),
           :ok <- Embedding.authorize(route, scope) do
        {:embed, turn, [user_message.content | Enum.map(pending, & &1.content)]}
      else
        _ -> {:error, :private_memory_admission_unavailable}
      end
    else
      _ -> {:error, :private_memory_admission_unavailable}
    end
  end

  defp select_pending(admission, sources, deadline) do
    Enum.reduce_while(sources, [], fn source, pending ->
      if length(pending) >= @max_pending or System.monotonic_time(:millisecond) >= deadline do
        {:halt, pending}
      else
        case Memory.prepare_private_conversation_index(admission, source) do
          {:ok, {:pending, content}} -> {:cont, pending ++ [%{source: source, content: content}]}
          _ -> {:cont, pending}
        end
      end
    end)
  end

  # Only the live Session receives the embedding result and calls Memory. A
  # terminated or superseded stage can never transfer its admission to a worker.
  def finish_preflight(state, turn, {:ok, [query | vectors]})
      when length(vectors) == length(turn.pending) do
    admission = current(state)

    recovered =
      Enum.zip(turn.pending, vectors)
      |> Enum.count(fn {pending, vector} ->
        match?(
          {:ok, _},
          Memory.index_private_conversation_source(admission, pending.source, vector)
        )
      end)

    case Memory.recall_private_conversations(admission, query, limit: 5, threshold: 0.3) do
      {:ok, recall} ->
        %{turn | recall: recall} |> Map.put(:recovered, recovered) |> retain_budget()

      _ ->
        Map.merge(turn, %{recall: [], recall_status: "unavailable", recovered: recovered})
        |> retain_budget()
    end
  end

  def finish_preflight(_state, turn, _error),
    do:
      Map.merge(turn, %{recall: [], recall_status: "unavailable", recovered: 0})
      |> retain_budget()

  defp retain_budget(turn),
    do: Map.put(turn, :remaining_ms, max(turn.deadline - System.monotonic_time(:millisecond), 0))

  def prepare_commit(state, user_content, assistant_content) do
    case Map.get(state, :private_memory_turn) do
      %{status: "enabled"} ->
        case Memory.prepare_private_conversation_source(current(state), %{
               user: user_content,
               assistant: assistant_content
             }) do
          {:ok, source} -> {:ok, source}
          _ -> {:error, :private_memory_source_unavailable}
        end

      _ ->
        {:ok, nil}
    end
  end

  def prepare_committed_index(state) do
    case Map.get(state, :private_memory_turn) do
      %{status: "enabled", source: source} = turn when is_map(source) ->
        deadline = System.monotonic_time(:millisecond) + turn.remaining_ms

        with {:ok, scope} <- Security.authorize_private_memory_turn(current(state), :write),
             :ok <- Embedding.authorize(turn.route, scope),
             {:ok, {:pending, content}} <-
               Memory.prepare_private_conversation_index(current(state), source),
             {:ok, ^scope} <- Security.authorize_private_memory_turn(current(state), :write),
             :ok <- Embedding.authorize(turn.route, scope) do
          {:embed, %{turn | deadline: deadline}, [content]}
        else
          {:ok, {:indexed, id}} -> {:done, %{status: "indexed", id: id}}
          _ -> {:done, %{status: "pending"}}
        end

      %{status: status} ->
        {:done, %{status: status}}

      _ ->
        {:done, %{status: "disabled"}}
    end
  end

  def finish_committed_index(state, {:ok, [embedding]}) do
    case Memory.index_private_conversation_source(
           current(state),
           state.private_memory_turn.source,
           embedding
         ) do
      {:ok, id} -> %{status: "indexed", id: id}
      _ -> %{status: "pending"}
    end
  end

  def finish_committed_index(_state, _), do: %{status: "pending"}

  # The side worker contains only route + texts. Its linked watcher ends it if
  # the Session dies; the LLM facade in turn reaps its actual provider operation.
  def start_embedding(owner, token, stage, route, texts, remaining_ms) do
    spawn_monitor(fn ->
      worker = self()

      spawn_link(fn ->
        owner_ref = Process.monitor(owner)
        worker_ref = Process.monitor(worker)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
          {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
        end
      end)

      result = Embedding.run(route, texts, remaining_ms)
      send(owner, {:private_memory_embedding_result, token, stage, worker, result})
    end)
  end

  def for_authority(state, %TurnAuthority{turn_id: turn_id}),
    do: Map.get(admissions(state), turn_id)

  def for_authority(_state, nil), do: nil

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
    for_authority(state, state.turn_authority)
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
