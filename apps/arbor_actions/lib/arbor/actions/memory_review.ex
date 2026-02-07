defmodule Arbor.Actions.MemoryReview do
  @moduledoc """
  Queue review actions for managing pending proposals and suggestions.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `ReviewQueue` | List, approve, or reject pending facts and learnings |
  | `ReviewSuggestions` | Review subconscious insight suggestions |
  | `AcceptSuggestion` | Accept a suggestion, integrating it into knowledge |
  | `RejectSuggestion` | Reject a suggestion, removing from queue |
  """

  # ============================================================================
  # ReviewQueue
  # ============================================================================

  defmodule ReviewQueue do
    @moduledoc """
    Manage pending facts and learnings queue.

    Actions: list (default), approve, reject, approve_all.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `action` | string | no | Action: list, approve, reject, approve_all (default: list) |
    | `type` | string | no | Filter by type: fact, learning |
    | `item_id` | string | no | Required for approve/reject |
    """

    use Jido.Action,
      name: "memory_review_queue",
      description:
        "Manage auto-extracted facts and learnings. Actions: list (default), approve, reject, approve_all. Optional: type (fact, learning), item_id (for approve/reject).",
      category: "memory_review",
      tags: ["memory", "review", "proposals", "facts", "learnings"],
      schema: [
        action: [
          type: :string,
          default: "list",
          doc: "Action: list, approve, reject, approve_all"
        ],
        type: [type: :string, doc: "Filter by type: fact, learning"],
        item_id: [type: :string, doc: "Proposal ID for approve/reject"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{action: :control, type: :control, item_id: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        action = params[:action] || "list"
        execute_action(agent_id, action, params)
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp execute_action(agent_id, "list", params) do
      opts =
        if params[:type] do
          [type: MemoryHelpers.safe_to_atom(params.type)]
        else
          []
        end

      case Arbor.Memory.get_proposals(agent_id, opts) do
        {:ok, proposals} ->
          formatted =
            Enum.map(proposals, fn p ->
              %{id: p.id, type: p.type, content: p.content, confidence: p.confidence}
            end)

          Actions.emit_completed(__MODULE__, %{count: length(formatted)})
          {:ok, %{action: :list, proposals: formatted, count: length(formatted)}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp execute_action(agent_id, "approve", %{item_id: item_id}) when is_binary(item_id) do
      case Arbor.Memory.accept_proposal(agent_id, item_id) do
        {:ok, node_id} ->
          Actions.emit_completed(__MODULE__, %{approved: item_id})
          {:ok, %{action: :approve, item_id: item_id, node_id: node_id, approved: true}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp execute_action(_agent_id, "approve", _params) do
      {:error, :item_id_required}
    end

    defp execute_action(agent_id, "reject", %{item_id: item_id}) when is_binary(item_id) do
      case Arbor.Memory.reject_proposal(agent_id, item_id) do
        :ok ->
          Actions.emit_completed(__MODULE__, %{rejected: item_id})
          {:ok, %{action: :reject, item_id: item_id, rejected: true}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp execute_action(_agent_id, "reject", _params) do
      {:error, :item_id_required}
    end

    defp execute_action(agent_id, "approve_all", params) do
      type =
        if params[:type] do
          MemoryHelpers.safe_to_atom(params.type)
        else
          nil
        end

      case Arbor.Memory.accept_all_proposals(agent_id, type) do
        {:ok, results} ->
          Actions.emit_completed(__MODULE__, %{approved_count: length(results)})
          {:ok, %{action: :approve_all, approved: results, count: length(results)}}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp execute_action(_agent_id, action, _params) do
      {:error, {:unknown_action, action}}
    end
  end

  # ============================================================================
  # ReviewSuggestions
  # ============================================================================

  defmodule ReviewSuggestions do
    @moduledoc """
    Review subconscious insight suggestions.

    These are behavior patterns detected by the InsightDetector
    that have not yet been added to knowledge.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `limit` | integer | no | Maximum suggestions (default: 10) |
    """

    use Jido.Action,
      name: "memory_review_suggestions",
      description:
        "Review subconscious insight suggestions — behavior patterns detected but not yet in knowledge. Optional: limit (default 10).",
      category: "memory_review",
      tags: ["memory", "review", "suggestions", "insights"],
      schema: [
        limit: [type: :non_neg_integer, default: 10, doc: "Maximum suggestions to return"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{limit: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id) do
        opts = [max_suggestions: params[:limit] || 10]
        suggestions = Arbor.Memory.detect_insights(agent_id, opts)

        # detect_insights returns a list directly (not {:ok, ...})
        suggestions = if is_list(suggestions), do: suggestions, else: []

        formatted =
          Enum.map(suggestions, fn s ->
            %{
              id: s[:id],
              type: s[:type],
              content: s[:content] || s[:description],
              confidence: s[:confidence]
            }
          end)

        Actions.emit_completed(__MODULE__, %{count: length(formatted)})
        {:ok, %{suggestions: formatted, count: length(formatted)}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # AcceptSuggestion
  # ============================================================================

  defmodule AcceptSuggestion do
    @moduledoc """
    Accept a suggestion, integrating it into the knowledge graph.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `suggestion_id` | string | yes | Suggestion ID to accept |
    """

    use Jido.Action,
      name: "memory_accept_suggestion",
      description:
        "Accept a suggestion, creating a self-insight with confidence boost. Required: suggestion_id.",
      category: "memory_review",
      tags: ["memory", "review", "suggestion", "accept"],
      schema: [
        suggestion_id: [type: :string, required: true, doc: "Suggestion ID to accept"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{suggestion_id: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           {:ok, node_id} <- Arbor.Memory.accept_proposal(agent_id, params.suggestion_id) do
        Actions.emit_completed(__MODULE__, %{accepted: params.suggestion_id})
        {:ok, %{suggestion_id: params.suggestion_id, node_id: node_id, accepted: true}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end

  # ============================================================================
  # RejectSuggestion
  # ============================================================================

  defmodule RejectSuggestion do
    @moduledoc """
    Reject a suggestion, removing it from the queue.

    Helps calibrate the pattern detection system.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `suggestion_id` | string | yes | Suggestion ID to reject |
    """

    use Jido.Action,
      name: "memory_reject_suggestion",
      description:
        "Reject a suggestion, removing from queue. Helps calibrate pattern detection. Required: suggestion_id.",
      category: "memory_review",
      tags: ["memory", "review", "suggestion", "reject"],
      schema: [
        suggestion_id: [type: :string, required: true, doc: "Suggestion ID to reject"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Memory, as: MemoryHelpers

    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{suggestion_id: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, agent_id} <- MemoryHelpers.extract_agent_id(context, params),
           :ok <- MemoryHelpers.ensure_memory(agent_id),
           :ok <- Arbor.Memory.reject_proposal(agent_id, params.suggestion_id) do
        Actions.emit_completed(__MODULE__, %{rejected: params.suggestion_id})
        {:ok, %{suggestion_id: params.suggestion_id, rejected: true}}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end
  end
end
