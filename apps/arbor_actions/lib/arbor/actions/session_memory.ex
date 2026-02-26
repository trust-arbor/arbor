defmodule Arbor.Actions.SessionMemory do
  @moduledoc """
  Session memory operations as Jido actions.

  These actions bridge session memory operations to Arbor facades via runtime
  bridge (`Code.ensure_loaded?` + `apply/3`), keeping arbor_actions independent
  of memory/persistence libraries at compile time.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Recall` | Recall memories, goals, intents, or beliefs by recall_type |
  | `Update` | Index memory notes from LLM output |
  | `Checkpoint` | Write a session checkpoint for crash recovery |
  | `Consolidate` | Run KG decay/prune + identity consolidation |
  | `UpdateWorkingMemory` | Add concerns and curiosity to working memory |
  """

  require Logger

  # Shared runtime bridge — same pattern as Session.Adapters
  @doc false
  def bridge(module, function, args, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      try do
        apply(module, function, args)
      rescue
        e ->
          Logger.warning(
            "[SessionMemory] #{inspect(module)}.#{function}/#{length(args)} raised: #{Exception.message(e)}"
          )

          default
      catch
        :exit, reason ->
          Logger.warning(
            "[SessionMemory] #{inspect(module)}.#{function}/#{length(args)} exited: #{inspect(reason)}"
          )

          default
      end
    else
      default
    end
  end

  # ============================================================================
  # Recall
  # ============================================================================

  defmodule Recall do
    @moduledoc """
    Recall memories, goals, intents, or beliefs by recall_type.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `recall_type` | string | no | "goals", "intents", "beliefs", or default (query) |
    | `query` | string | no | Query string for default recall |

    ## Returns

    Map with the recalled data under a type-specific key.
    """
    use Jido.Action,
      name: "session_memory_recall",
      description: "Recall memories, goals, intents, or beliefs by type",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        recall_type: [type: :string, required: false, doc: "Type: goals/intents/beliefs/query"],
        query: [type: :string, required: false, doc: "Query for default recall"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      recall_type = params[:recall_type] || params["recall_type"] || "query"

      case recall_type do
        "goals" ->
          safe_recall("recall_goals", :goals, fn ->
            Arbor.Actions.SessionMemory.bridge(
              Arbor.Memory.GoalStore,
              :get_active_goals,
              [agent_id],
              []
            )
          end)

        "intents" ->
          safe_recall("recall_intents", :active_intents, fn ->
            result =
              Arbor.Actions.SessionMemory.bridge(
                Arbor.Memory,
                :pending_intentions,
                [agent_id],
                []
              )

            unwrap_intents(result)
          end)

        "beliefs" ->
          safe_recall("recall_beliefs", :beliefs, fn ->
            Arbor.Actions.SessionMemory.bridge(
              Arbor.Memory,
              :load_working_memory,
              [agent_id],
              %{}
            )
          end)

        _ ->
          query = params[:query] || params["query"] || params["session.input"] || ""

          safe_recall("memory_recall", :recalled_memories, fn ->
            Arbor.Actions.SessionMemory.bridge(
              Arbor.Memory,
              :recall,
              [agent_id, query],
              {:ok, []}
            )
          end)
      end
    end

    defp safe_recall(label, key, recall_fn) do
      try do
        case recall_fn.() do
          {:ok, data} -> {:ok, %{key => data}}
          {:error, reason} -> {:error, "#{label}: #{inspect(reason)}"}
          data when is_list(data) or is_map(data) -> {:ok, %{key => data}}
          other -> {:ok, %{key => other}}
        end
      catch
        kind, reason -> {:error, "#{label}: #{inspect({kind, reason})}"}
      end
    end

    # IntentStore returns [{Intent.t(), status_map}] tuples — unwrap to plain structs
    defp unwrap_intents(intents) when is_list(intents) do
      Enum.map(intents, fn
        {intent, _status} -> intent
        intent -> intent
      end)
    end

    defp unwrap_intents({:ok, intents}) when is_list(intents), do: unwrap_intents(intents)
    defp unwrap_intents(_), do: []
  end

  # ============================================================================
  # Update
  # ============================================================================

  defmodule Update do
    @moduledoc """
    Index memory notes from LLM output.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `turn_data` | map | no | Turn data containing memory notes |
    """
    use Jido.Action,
      name: "session_memory_update",
      description: "Index memory notes from LLM turn output",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        turn_data: [type: :map, required: false, doc: "Turn data with memory notes"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      turn_data = params[:turn_data] || params["turn_data"] || params["session.turn_data"] || %{}

      Arbor.Actions.SessionMemory.bridge(
        Arbor.Memory,
        :index_memory_notes,
        [agent_id, turn_data],
        :ok
      )

      {:ok, %{memory_updated: true}}
    end
  end

  # ============================================================================
  # Checkpoint
  # ============================================================================

  defmodule Checkpoint do
    @moduledoc """
    Write a session checkpoint for crash recovery.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `session_id` | string | yes | Session ID |
    | `turn_count` | integer | no | Current turn number |
    | `snapshot` | map | no | Context snapshot to persist |
    """
    use Jido.Action,
      name: "session_memory_checkpoint",
      description: "Write a session checkpoint for crash recovery",
      schema: [
        session_id: [type: :string, required: true, doc: "Session ID"],
        turn_count: [type: :integer, required: false, doc: "Current turn number"],
        snapshot: [type: :map, required: false, doc: "Context snapshot"]
      ]

    @impl true
    def run(params, _context) do
      session_id = params[:session_id] || params["session_id"] || params["session.id"]

      unless session_id do
        raise ArgumentError, "session_id is required"
      end

      turn_count =
        params[:turn_count] || params["turn_count"] || params["session.turn_count"] || 0

      snapshot = params[:snapshot] || params["snapshot"] || %{}

      Arbor.Actions.SessionMemory.bridge(
        Arbor.Persistence.Checkpoint,
        :write,
        [session_id, snapshot, [turn: turn_count]],
        :ok
      )

      {:ok, %{last_checkpoint: turn_count}}
    end
  end

  # ============================================================================
  # Consolidate
  # ============================================================================

  defmodule Consolidate do
    @moduledoc """
    Run knowledge graph decay/prune + identity consolidation.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    """
    use Jido.Action,
      name: "session_memory_consolidate",
      description: "Run KG decay/prune and identity consolidation",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      kg_result = safe_consolidate(Arbor.Memory, :consolidate, [agent_id, []])
      identity_result = safe_consolidate_identity(agent_id)

      {:ok,
       %{
         consolidated: true,
         consolidation_kg: format_result(kg_result),
         consolidation_identity: format_result(identity_result)
       }}
    end

    defp safe_consolidate(module, function, args) do
      case Arbor.Actions.SessionMemory.bridge(module, function, args, {:error, :unavailable}) do
        {:ok, metrics} -> {:ok, metrics}
        {:error, reason} -> {:error, reason}
        :ok -> {:ok, %{}}
        other -> {:ok, other}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    defp safe_consolidate_identity(agent_id) do
      case Arbor.Actions.SessionMemory.bridge(
             Arbor.Memory.IdentityConsolidator,
             :consolidate,
             [agent_id, []],
             {:error, :unavailable}
           ) do
        {:ok, _sk, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        :ok -> {:ok, %{}}
        other -> {:ok, other}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    defp format_result({:ok, metrics}) when is_map(metrics), do: metrics
    defp format_result({:ok, other}), do: %{result: inspect(other)}
    defp format_result({:error, reason}), do: %{error: inspect(reason)}
    defp format_result(other), do: %{result: inspect(other)}
  end

  # ============================================================================
  # UpdateWorkingMemory
  # ============================================================================

  defmodule UpdateWorkingMemory do
    @moduledoc """
    Add concerns and curiosity to working memory.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `concerns` | list | no | List of concern strings |
    | `curiosity` | list | no | List of curiosity strings |
    """
    use Jido.Action,
      name: "session_memory_update_wm",
      description: "Add concerns and curiosity to working memory",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        concerns: [type: {:list, :string}, required: false, doc: "Concern strings"],
        curiosity: [type: {:list, :string}, required: false, doc: "Curiosity strings"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      concerns =
        List.wrap(params[:concerns] || params["concerns"] || params["session.concerns"] || [])

      curiosity =
        List.wrap(params[:curiosity] || params["curiosity"] || params["session.curiosity"] || [])

      wm_mod = Arbor.Memory.WorkingMemory

      wm =
        Arbor.Actions.SessionMemory.bridge(
          Arbor.Memory,
          :load_working_memory,
          [agent_id],
          nil
        )

      if wm && Code.ensure_loaded?(wm_mod) do
        wm =
          Enum.reduce(concerns, wm, fn c, acc ->
            apply(wm_mod, :add_concern, [acc, c])
          end)

        wm =
          Enum.reduce(curiosity, wm, fn c, acc ->
            apply(wm_mod, :add_curiosity, [acc, c])
          end)

        Arbor.Actions.SessionMemory.bridge(
          Arbor.Memory,
          :save_working_memory,
          [agent_id, wm],
          :ok
        )
      end

      {:ok, %{wm_updated: true}}
    end
  end
end
