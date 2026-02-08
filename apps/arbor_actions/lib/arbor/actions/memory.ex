defmodule Arbor.Actions.Memory do
  @moduledoc """
  Core memory actions for storing, recalling, connecting, and reflecting on memories.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Remember` | Store information in the knowledge graph |
  | `Recall` | Retrieve relevant memories via semantic search |
  | `Connect` | Create relationships between knowledge nodes |
  | `Reflect` | Trigger a reflection cycle and view memory stats |

  ## Examples

      {:ok, result} = Arbor.Actions.Memory.Remember.run(
        %{content: "Elixir uses pattern matching", type: "fact"},
        %{agent_id: "agent_001"}
      )

      {:ok, result} = Arbor.Actions.Memory.Recall.run(
        %{query: "pattern matching"},
        %{agent_id: "agent_001"}
      )
  """

  # ============================================================================
  # Shared Helpers
  # ============================================================================

  @doc false
  def extract_agent_id(context, params) do
    case context[:agent_id] || params[:agent_id] do
      nil -> {:error, :missing_agent_id}
      id -> {:ok, id}
    end
  end

  @doc false
  def ensure_memory(agent_id) do
    unless Arbor.Memory.initialized?(agent_id) do
      Arbor.Memory.init_for_agent(agent_id)
    end

    :ok
  end

  @doc false
  def safe_to_atom(type) when is_atom(type), do: type

  def safe_to_atom(type) when is_binary(type) do
    String.to_existing_atom(type)
  rescue
    ArgumentError -> String.to_atom(type)
  end

  # ============================================================================
  # Remember
  # ============================================================================

  defmodule Remember do
    @moduledoc """
    Store information in the knowledge graph.

    Adds a knowledge node with the given type and content. Optionally links
    to existing nodes by entity name.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `content` | string | yes | The information to remember |
    | `type` | string | yes | Memory type: fact, observation, insight, decision, preference, learning |
    | `importance` | float | no | Importance score 0.0-1.0 (default: 0.5) |
    | `entities` | list(string) | no | Entity names to link to |
    """

    use Jido.Action,
      name: "memory_remember",
      description:
        "Store information in the knowledge graph. Types: fact, observation, insight, decision, preference, learning. Optional: importance (0.0-1.0), entities list.",
      category: "memory",
      tags: ["memory", "knowledge", "store"],
      schema: [
        content: [type: :string, required: true, doc: "The information to remember"],
        type: [
          type: :string,
          required: true,
          doc: "Memory type: fact, observation, insight, decision, preference, learning"
        ],
        importance: [type: :float, default: 0.5, doc: "Importance score 0.0-1.0"],
        entities: [type: {:list, :string}, default: [], doc: "Related entity names to link"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{content: :data, type: :control, importance: :data, entities: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           type_atom <- MemoryHelpers.safe_to_atom(params.type),
           {:ok, node_id} <-
             Arbor.Memory.add_knowledge(agent_id, %{
               type: type_atom,
               content: params.content,
               relevance: params[:importance] || 0.5,
               metadata: %{source: :agent_tool}
             }) do
        linked = maybe_link_entities(agent_id, node_id, params[:entities] || [])

        Actions.emit_completed(__MODULE__, %{node_id: node_id})
        {:ok, %{node_id: node_id, type: type_atom, stored: true, linked_count: linked}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp maybe_link_entities(_agent_id, _node_id, []), do: 0

    defp maybe_link_entities(agent_id, node_id, entities) do
      Enum.count(entities, fn entity_name ->
        case Arbor.Memory.find_knowledge_by_name(agent_id, entity_name) do
          {:ok, entity_id} ->
            Arbor.Memory.link_knowledge(agent_id, node_id, entity_id, :related_to)
            true

          _ ->
            false
        end
      end)
    end
  end

  # ============================================================================
  # Recall
  # ============================================================================

  defmodule Recall do
    @moduledoc """
    Retrieve relevant memories via semantic search.

    Searches the agent's memory index for content similar to the query.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | The search query |
    | `limit` | integer | no | Maximum results (default: 10) |
    | `types` | list(string) | no | Filter by memory types |
    """

    use Jido.Action,
      name: "memory_recall",
      description:
        "Search memory using semantic search. Required: query. Optional: limit (default 10), types filter list, cascade (spreading activation).",
      category: "memory",
      tags: ["memory", "knowledge", "search", "recall"],
      schema: [
        query: [type: :string, required: true, doc: "The search query"],
        limit: [type: :non_neg_integer, default: 10, doc: "Maximum results to return"],
        types: [type: {:list, :string}, doc: "Filter by memory types"],
        cascade: [
          type: :boolean,
          default: false,
          doc: "Enable spreading activation to boost related nodes"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{query: :data, limit: :data, types: :data, cascade: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        opts =
          [limit: params[:limit] || 10]
          |> maybe_add_types(params[:types])

        case Arbor.Memory.recall(agent_id, params.query, opts) do
          {:ok, results} ->
            # Trigger spreading activation on top results if cascade enabled
            cascade_applied =
              if params[:cascade] == true and results != [] do
                apply_cascade(agent_id, results)
              else
                false
              end

            formatted =
              Enum.map(results, fn r ->
                %{
                  content: r[:content] || r[:text],
                  similarity: r[:similarity],
                  type: r[:type],
                  metadata: r[:metadata]
                }
              end)

            Actions.emit_completed(__MODULE__, %{count: length(formatted)})

            {:ok,
             %{
               results: formatted,
               count: length(formatted),
               query: params.query,
               cascade_applied: cascade_applied
             }}

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

    # Trigger spreading activation from the top recall result
    defp apply_cascade(agent_id, results) do
      top_result = hd(results)
      node_id = top_result[:id] || top_result[:entry_id]

      if node_id do
        case Arbor.Memory.cascade_recall(agent_id, node_id, 0.2) do
          {:ok, _stats} -> true
          _ -> false
        end
      else
        false
      end
    end

    defp maybe_add_types(opts, nil), do: opts
    defp maybe_add_types(opts, []), do: opts

    defp maybe_add_types(opts, types) when is_list(types) do
      type_atoms = Enum.map(types, &MemoryHelpers.safe_to_atom/1)
      Keyword.put(opts, :types, type_atoms)
    end
  end

  # ============================================================================
  # Connect
  # ============================================================================

  defmodule Connect do
    @moduledoc """
    Create a relationship between two knowledge nodes.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `from_id` | string | yes | Source node ID |
    | `to_id` | string | yes | Target node ID |
    | `relationship` | string | yes | Relationship type (e.g., causes, related_to, part_of, contradicts) |
    """

    use Jido.Action,
      name: "memory_connect",
      description:
        "Link two memory nodes. Required: from_id, to_id, relationship (e.g., causes, related_to, part_of, contradicts).",
      category: "memory",
      tags: ["memory", "knowledge", "link", "connect"],
      schema: [
        from_id: [type: :string, required: true, doc: "Source node ID"],
        to_id: [type: :string, required: true, doc: "Target node ID"],
        relationship: [
          type: :string,
          required: true,
          doc: "Relationship type: causes, related_to, part_of, contradicts, supports"
        ]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{from_id: :data, to_id: :data, relationship: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           rel_atom <- MemoryHelpers.safe_to_atom(params.relationship),
           :ok <- Arbor.Memory.link_knowledge(agent_id, params.from_id, params.to_id, rel_atom) do
        Actions.emit_completed(__MODULE__, %{
          from_id: params.from_id,
          to_id: params.to_id,
          relationship: rel_atom
        })

        {:ok,
         %{
           from_id: params.from_id,
           to_id: params.to_id,
           relationship: rel_atom,
           linked: true
         }}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # Reflect
  # ============================================================================

  defmodule Reflect do
    @moduledoc """
    Review recent memories and knowledge graph statistics.

    Triggers a reflection on the agent's memory state and returns stats
    about the knowledge graph.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `prompt` | string | no | Custom reflection prompt |
    | `include_stats` | boolean | no | Include graph stats (default: true) |
    """

    use Jido.Action,
      name: "memory_reflect",
      description:
        "Review recent memories and graph statistics. Optional: prompt (custom reflection), include_stats (default true).",
      category: "memory",
      tags: ["memory", "knowledge", "reflect", "stats"],
      schema: [
        prompt: [type: :string, doc: "Custom reflection prompt"],
        include_stats: [type: :boolean, default: true, doc: "Include graph statistics"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{prompt: :data, include_stats: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        result = %{}

        # Get graph stats if requested
        result =
          if params[:include_stats] != false do
            case Arbor.Memory.knowledge_stats(agent_id) do
              {:ok, stats} -> Map.put(result, :stats, stats)
              _ -> result
            end
          else
            result
          end

        # Run reflection if prompt provided
        result =
          if params[:prompt] do
            case Arbor.Memory.reflect(agent_id, params.prompt) do
              {:ok, reflection} -> Map.put(result, :reflection, reflection)
              {:error, _} -> result
            end
          else
            result
          end

        Actions.emit_completed(__MODULE__, %{has_stats: Map.has_key?(result, :stats)})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end
end
