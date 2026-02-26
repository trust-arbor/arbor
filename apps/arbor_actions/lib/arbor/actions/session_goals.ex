defmodule Arbor.Actions.SessionGoals do
  @moduledoc """
  Session goal management operations as Jido actions.

  These actions extract goal-related business logic from SessionHandler/Adapters
  so DOT pipelines use `exec target="action"` instead of hardcoded session types.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `UpdateGoals` | Apply progress updates + create new goals with case-insensitive dedup |
  | `StoreDecompositions` | Create Intent structs from decomposition JSON |
  | `ProcessProposalDecisions` | Route accept/reject/defer to Proposal facade |
  | `StoreIdentity` | Store identity insights via Memory.add_insight |
  """

  require Logger

  # ============================================================================
  # UpdateGoals
  # ============================================================================

  defmodule UpdateGoals do
    @moduledoc """
    Apply goal progress updates and create new goals with dedup.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `goal_updates` | list | no | Progress updates [{id, progress, status}] |
    | `new_goals` | list | no | New goals [{description, priority}] |

    ## Returns

    `%{goals_updated: true}`
    """
    use Jido.Action,
      name: "session_goals_update",
      description: "Apply goal progress updates and create new goals with dedup",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        goal_updates: [type: {:list, :map}, required: false, doc: "Progress updates"],
        new_goals: [type: {:list, :map}, required: false, doc: "New goals to create"]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      goal_updates =
        List.wrap(
          params[:goal_updates] || params["goal_updates"] || params["session.goal_updates"] || []
        )

      new_goals =
        List.wrap(params[:new_goals] || params["new_goals"] || params["session.new_goals"] || [])

      goal_store = Arbor.Memory.GoalStore
      apply_goal_progress_updates(goal_store, goal_updates, agent_id)
      existing = fetch_existing_goal_descriptions(goal_store, agent_id)
      add_new_goals(goal_store, new_goals, existing, agent_id)

      {:ok, %{goals_updated: true}}
    end

    defp apply_goal_progress_updates(goal_store, goal_updates, agent_id) do
      Enum.each(goal_updates, fn update ->
        goal_id = update["id"] || update[:id]
        progress = update["progress"] || update[:progress]

        if goal_id && progress do
          Arbor.Actions.SessionMemory.bridge(
            goal_store,
            :update_goal_progress,
            [agent_id, goal_id, progress],
            :ok
          )
        end
      end)
    end

    defp fetch_existing_goal_descriptions(goal_store, agent_id) do
      try do
        case Arbor.Actions.SessionMemory.bridge(
               goal_store,
               :get_active_goals,
               [agent_id],
               []
             ) do
          goals when is_list(goals) ->
            goals
            |> Enum.map(fn g ->
              desc = if is_map(g), do: Map.get(g, :description, ""), else: ""
              String.downcase(String.trim(desc))
            end)
            |> MapSet.new()

          _ ->
            MapSet.new()
        end
      rescue
        _ -> MapSet.new()
      end
    end

    defp add_new_goals(goal_store, new_goals, existing_descriptions, agent_id) do
      Enum.each(new_goals, fn goal_desc ->
        description = extract_goal_description(goal_desc)

        if description != "" and
             not MapSet.member?(existing_descriptions, String.downcase(description)) do
          Arbor.Actions.SessionMemory.bridge(
            goal_store,
            :add_goal,
            [agent_id, description, []],
            :ok
          )
        end
      end)
    end

    defp extract_goal_description(desc) when is_binary(desc), do: String.trim(desc)

    defp extract_goal_description(desc) when is_map(desc) do
      (desc["description"] || desc[:description] || "")
      |> to_string()
      |> String.trim()
    end

    defp extract_goal_description(_), do: ""
  end

  # ============================================================================
  # StoreDecompositions
  # ============================================================================

  defmodule StoreDecompositions do
    @moduledoc """
    Create Intent structs from decomposition JSON and store via Memory facade.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `decompositions` | list | no | Decomposition maps with goal_id + intentions |

    ## Returns

    `%{decompositions_stored: true}`
    """
    use Jido.Action,
      name: "session_goals_store_decomps",
      description: "Create Intent structs from goal decompositions",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        decompositions: [
          type: {:list, :map},
          required: false,
          doc: "Decomposition maps"
        ]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      decompositions =
        List.wrap(
          params[:decompositions] || params["decompositions"] ||
            params["session.decompositions"] || []
        )

      Enum.each(decompositions, &store_decomposition(&1, agent_id))

      {:ok, %{decompositions_stored: true}}
    end

    defp store_decomposition(decomp, agent_id) do
      goal_id = decomp["goal_id"] || decomp[:goal_id]
      intentions = decomp["intentions"] || decomp[:intentions] || []

      Enum.each(List.wrap(intentions), fn intent_data ->
        store_intent(intent_data, goal_id, agent_id)
      end)
    end

    defp store_intent(intent_data, goal_id, agent_id) do
      action = intent_data["action"] || intent_data[:action] || "unknown"
      params = intent_data["params"] || intent_data[:params] || %{}
      params = if is_map(params), do: params, else: %{}
      reasoning = intent_data["reasoning"] || intent_data[:reasoning]
      target = intent_data["target"] || intent_data[:target]
      description = intent_data["description"] || intent_data[:description] || action

      opts = [
        goal_id: goal_id,
        reasoning: reasoning || description,
        target: target
      ]

      intent =
        Arbor.Actions.SessionMemory.bridge(
          Arbor.Contracts.Memory.Intent,
          :action,
          [action, params, opts],
          nil
        )

      if intent do
        Arbor.Actions.SessionMemory.bridge(
          Arbor.Memory,
          :record_intent,
          [agent_id, intent],
          :ok
        )
      end
    end
  end

  # ============================================================================
  # ProcessProposalDecisions
  # ============================================================================

  defmodule ProcessProposalDecisions do
    @moduledoc """
    Route accept/reject/defer decisions to Proposal facade.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `decisions` | list | no | Decision maps [{proposal_id, decision, reason?}] |

    ## Returns

    `%{proposals_processed: true}`
    """
    use Jido.Action,
      name: "session_goals_process_proposals",
      description: "Route accept/reject/defer decisions to Proposal facade",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        decisions: [
          type: {:list, :map},
          required: false,
          doc: "Decision maps"
        ]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      decisions =
        List.wrap(
          params[:decisions] || params["decisions"] ||
            params["session.proposal_decisions"] || []
        )

      Enum.each(decisions, &apply_proposal_decision(&1, agent_id))

      {:ok, %{proposals_processed: true}}
    end

    defp apply_proposal_decision(decision, agent_id) do
      proposal_id = decision["proposal_id"] || decision[:proposal_id]
      action = decision["decision"] || decision[:decision]

      if proposal_id do
        dispatch_proposal_action(action, agent_id, proposal_id, decision)
      end
    end

    defp dispatch_proposal_action("accept", agent_id, proposal_id, _decision) do
      Arbor.Actions.SessionMemory.bridge(
        Arbor.Memory.Proposal,
        :accept,
        [agent_id, proposal_id],
        :ok
      )
    end

    defp dispatch_proposal_action("reject", agent_id, proposal_id, decision) do
      reason = decision["reason"] || decision[:reason]

      Arbor.Actions.SessionMemory.bridge(
        Arbor.Memory.Proposal,
        :reject,
        [agent_id, proposal_id, [reason: reason]],
        :ok
      )
    end

    defp dispatch_proposal_action(_action, _agent_id, _proposal_id, _decision), do: :ok
  end

  # ============================================================================
  # StoreIdentity
  # ============================================================================

  defmodule StoreIdentity do
    @moduledoc """
    Store identity insights via Memory.add_insight.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `agent_id` | string | yes | Agent ID |
    | `insights` | list | no | Identity insight maps [{category, content, confidence}] |

    ## Returns

    `%{identity_stored: true}`
    """
    use Jido.Action,
      name: "session_goals_store_identity",
      description: "Store identity insights from LLM self-discovery",
      schema: [
        agent_id: [type: :string, required: true, doc: "Agent ID"],
        insights: [
          type: {:list, :map},
          required: false,
          doc: "Identity insight maps"
        ]
      ]

    @impl true
    def run(params, _context) do
      agent_id = params[:agent_id] || params["agent_id"] || params["session.agent_id"]

      unless agent_id do
        raise ArgumentError, "agent_id is required"
      end

      insights =
        List.wrap(
          params[:insights] || params["insights"] ||
            params["session.identity_insights"] || []
        )

      try do
        Enum.each(insights, fn insight ->
          category = insight["category"] || insight[:category]
          content = insight["content"] || insight[:content]
          confidence = insight["confidence"] || insight[:confidence] || 0.5

          if category && content do
            cat_atom =
              if is_atom(category), do: category, else: String.to_existing_atom(category)

            Arbor.Actions.SessionMemory.bridge(
              Arbor.Memory,
              :add_insight,
              [agent_id, content, cat_atom, [confidence: confidence]],
              :ok
            )
          end
        end)
      rescue
        _ -> :ok
      end

      {:ok, %{identity_stored: true}}
    end
  end
end
