defmodule Arbor.Actions.SessionExecution do
  @moduledoc """
  Session execution operations as Jido actions.

  These actions bridge action routing and execution with percept feedback to
  Arbor facades via runtime bridge.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `RouteActions` | Dispatch via execute_batch or route_pending_intentions |
  | `ExecuteActions` | Execute actions + create Percept structs + record in memory |
  """

  require Logger

  # ============================================================================
  # RouteActions
  # ============================================================================

  defmodule RouteActions do
    @moduledoc """
    Dispatch actions via execute_batch or route pending intentions.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `intent_source` | string | no | "intent_store" to route intents, default routes actions |
    | `actions` | list | no | Action specs to route |

    ## Returns

    `%{actions_routed: true}` or `%{intents_routed: true}`
    """
    use Jido.Action,
      name: "session_exec_route_actions",
      description: "Dispatch actions via execute_batch or route pending intentions",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        intent_source: [type: :string, required: false, doc: "intent_store or default"],
        actions: [type: {:list, :map}, required: false, doc: "Action specs to route"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      intent_source = params[:intent_source] || params["intent_source"]

      case intent_source do
        "intent_store" ->
          Arbor.Actions.SessionMemory.bridge(
            Arbor.Agent.ExecutorIntegration,
            :route_pending_intentions,
            [agent_id],
            :ok
          )

          {:ok, %{intents_routed: true}}

        _ ->
          actions =
            List.wrap(params[:actions] || params["actions"] || params["session.actions"] || [])

          Arbor.Actions.SessionMemory.bridge(
            Arbor.Actions,
            :execute_batch,
            [actions, [agent_id: agent_id]],
            :ok
          )

          {:ok, %{actions_routed: true}}
      end
    end
  end

  # ============================================================================
  # ExecuteActions
  # ============================================================================

  defmodule ExecuteActions do
    @moduledoc """
    Execute actions with percept feedback — runs actions, creates Percept structs,
    records in memory, and sets has_action_results flag.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `actions` | list | no | Action specs to execute |
    | `tool_turn` | integer | no | Current tool turn counter |

    ## Returns

    Map with has_action_results, percepts list, and updated tool_turn.
    """
    use Jido.Action,
      name: "session_exec_execute_actions",
      description: "Execute actions and create percept feedback for the agent",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        actions: [type: {:list, :map}, required: false, doc: "Action specs"],
        tool_turn: [type: :integer, required: false, doc: "Current tool turn counter"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      actions =
        List.wrap(params[:actions] || params["actions"] || params["session.actions"] || [])

      tool_turn =
        parse_int(
          params[:tool_turn] || params["tool_turn"] || params["session.tool_turn"],
          0
        )

      if actions == [] do
        {:ok, %{has_action_results: false, percepts: [], tool_turn: tool_turn}}
      else
        results =
          Arbor.Actions.SessionMemory.bridge(
            Arbor.Actions,
            :execute_batch,
            [actions, [agent_id: agent_id]],
            []
          )

        percepts =
          Enum.map(List.wrap(results), fn {spec, result} ->
            action_type = Map.get(spec, "type") || Map.get(spec, :type, "unknown")
            percept = result_to_percept(action_type, result)

            Arbor.Actions.SessionMemory.bridge(
              Arbor.Memory,
              :record_percept,
              [agent_id, percept],
              :ok
            )

            percept_to_map(percept)
          end)

        Logger.info(
          "[SessionExecution] execute_actions: #{length(actions)} actions, #{length(percepts)} percepts"
        )

        {:ok,
         %{
           has_action_results: true,
           percepts: percepts,
           tool_turn: tool_turn + 1
         }}
      end
    end

    defp result_to_percept(action_type, {:ok, result}) do
      data = %{action_type: action_type, result: truncate_result(result)}

      Arbor.Actions.SessionMemory.bridge(
        Arbor.Contracts.Memory.Percept,
        :success,
        [nil, data],
        %{id: generate_percept_id(), type: :action_result, outcome: :success, data: data}
      )
    end

    defp result_to_percept(action_type, {:error, :unauthorized}) do
      Arbor.Actions.SessionMemory.bridge(
        Arbor.Contracts.Memory.Percept,
        :blocked,
        [nil, "unauthorized: #{action_type}"],
        %{
          id: generate_percept_id(),
          type: :action_result,
          outcome: :blocked,
          data: %{action_type: action_type}
        }
      )
    end

    defp result_to_percept(action_type, {:error, reason}) do
      Arbor.Actions.SessionMemory.bridge(
        Arbor.Contracts.Memory.Percept,
        :failure,
        [nil, reason],
        %{
          id: generate_percept_id(),
          type: :action_result,
          outcome: :failure,
          error: reason,
          data: %{action_type: action_type}
        }
      )
    end

    defp percept_to_map(%{__struct__: _} = percept) do
      percept
      |> Map.from_struct()
      |> Map.update(:created_at, nil, fn
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        other -> other
      end)
      |> Map.update(:error, nil, fn
        nil -> nil
        err when is_binary(err) -> err
        err -> inspect(err)
      end)
    end

    defp percept_to_map(map) when is_map(map), do: map

    defp truncate_result(result) when is_binary(result) and byte_size(result) > 4000 do
      String.slice(result, 0, 3997) <> "..."
    end

    defp truncate_result(result) when is_map(result) do
      Map.new(result, fn
        {k, v} when is_binary(v) and byte_size(v) > 4000 ->
          {k, String.slice(v, 0, 3997) <> "..."}

        {k, v} ->
          {k, v}
      end)
    end

    defp truncate_result(result), do: result

    defp generate_percept_id do
      "prc_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
    end

    defp parse_int(nil, default), do: default
    defp parse_int(v, _default) when is_integer(v), do: v

    defp parse_int(v, default) when is_binary(v) do
      case Integer.parse(v) do
        {n, _} -> n
        :error -> default
      end
    end

    defp parse_int(_, default), do: default
  end
end
