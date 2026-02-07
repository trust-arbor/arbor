defmodule Arbor.Actions.MemoryIdentity do
  @moduledoc """
  Identity and self-knowledge actions.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `AddInsight` | Record a self-insight about thinking patterns |
  | `ReadSelf` | Query self-knowledge profile |
  | `IntrospectMemory` | Get memory system statistics |
  """

  # ============================================================================
  # AddInsight
  # ============================================================================

  defmodule AddInsight do
    @moduledoc """
    Record a self-insight about thinking patterns.

    Categories: capability, personality, trait, value, preference.
    Capabilities are stored with a proficiency score; traits and values
    are added to the SelfKnowledge struct.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `content` | string | yes | The insight content |
    | `category` | string | yes | Category: capability, personality, trait, value, preference |
    | `confidence` | float | no | Confidence score 0.0-1.0 (default: 0.5) |
    | `evidence` | string | no | Evidence supporting the insight |
    """

    use Jido.Action,
      name: "memory_add_insight",
      description:
        "Record a self-insight about your thinking patterns. Categories: capability, personality, trait, value, preference. Required: content, category. Optional: confidence (0.0-1.0), evidence.",
      category: "memory_identity",
      tags: ["memory", "identity", "self-knowledge", "insight"],
      schema: [
        content: [type: :string, required: true, doc: "The insight content"],
        category: [
          type: :string,
          required: true,
          doc: "Category: capability, personality, trait, value, preference"
        ],
        confidence: [type: :float, default: 0.5, doc: "Confidence score 0.0-1.0"],
        evidence: [type: :string, doc: "Evidence supporting the insight"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{content: :data, category: :control, confidence: :data, evidence: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        category = MemoryHelpers.safe_to_atom(params.category)

        opts =
          [confidence: params[:confidence] || 0.5]
          |> maybe_add_opt(:evidence, params[:evidence])

        case Arbor.Memory.add_insight(agent_id, params.content, category, opts) do
          {:ok, %Arbor.Memory.SelfKnowledge{} = sk} ->
            Actions.emit_completed(__MODULE__, %{category: category})
            {:ok, %{category: category, stored: true, type: :self_knowledge, version: sk.version}}

          {:ok, node_id} when is_binary(node_id) ->
            Actions.emit_completed(__MODULE__, %{category: category, node_id: node_id})
            {:ok, %{category: category, stored: true, type: :knowledge_node, node_id: node_id}}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, reason}
        end
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp maybe_add_opt(opts, _key, nil), do: opts
    defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
  end

  # ============================================================================
  # ReadSelf
  # ============================================================================

  defmodule ReadSelf do
    @moduledoc """
    Query the agent's self-knowledge profile.

    Aspects: memory_system, identity, tools, cognition, capabilities, all.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `aspect` | string | no | Aspect to query (default: all) |
    """

    use Jido.Action,
      name: "memory_read_self",
      description:
        "Query your self-knowledge. Aspects: memory_system, identity, tools, cognition, capabilities, all. Optional: aspect (default all).",
      category: "memory_identity",
      tags: ["memory", "identity", "self-knowledge", "read"],
      schema: [
        aspect: [type: :string, default: "all", doc: "Aspect to query: memory_system, identity, tools, cognition, capabilities, all"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{aspect: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        aspect = MemoryHelpers.safe_to_atom(params[:aspect] || "all")
        result = Arbor.Memory.query_self(agent_id, aspect)

        Actions.emit_completed(__MODULE__, %{aspect: aspect})
        {:ok, %{aspect: aspect, data: result}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # IntrospectMemory
  # ============================================================================

  defmodule IntrospectMemory do
    @moduledoc """
    Get memory system statistics and configuration.

    Returns knowledge graph stats, index stats, and cognitive preferences.
    """

    use Jido.Action,
      name: "memory_introspect",
      description:
        "View memory system statistics: graph stats, index stats, cognitive preferences, and composition.",
      category: "memory_identity",
      tags: ["memory", "introspect", "stats", "diagnostics"],
      schema: []

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        result = %{agent_id: agent_id}

        # Knowledge graph stats
        result =
          case Arbor.Memory.knowledge_stats(agent_id) do
            {:ok, stats} -> Map.put(result, :knowledge_graph, stats)
            _ -> result
          end

        # Index stats
        result =
          case Arbor.Memory.index_stats(agent_id) do
            {:ok, stats} -> Map.put(result, :index, stats)
            _ -> result
          end

        # Preferences
        prefs = Arbor.Memory.inspect_preferences(agent_id)
        result = Map.put(result, :preferences, prefs)

        Actions.emit_completed(__MODULE__, %{sections: Map.keys(result)})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end
end
