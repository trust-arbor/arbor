defmodule Arbor.Actions.SessionLlm do
  @moduledoc """
  Session LLM prompt building as a Jido action.

  This action extracts the ~170 lines of format helpers and context assembly
  from SessionHandler so compute nodes can use dynamically-built prompts.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `BuildPrompt` | Build LLM prompt from context sources (heartbeat/followup/turn modes) |
  """

  # ============================================================================
  # BuildPrompt
  # ============================================================================

  defmodule BuildPrompt do
    @moduledoc """
    Build LLM prompt from session context sources.

    Three modes:
    - `heartbeat` — Reads 7 context sources, builds heartbeat prompt with mode instructions + JSON format
    - `followup` — Formats percepts as user message, appends to conversation history
    - `turn` — Injects timestamps into user messages

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `mode` | string | yes | "heartbeat", "followup", or "turn" |
    | `goals` | list | no | Active goals |
    | `working_memory` | map | no | Working memory state |
    | `knowledge_graph` | list | no | Top KG nodes |
    | `pending_proposals` | list | no | Proposals awaiting decision |
    | `active_intents` | list | no | Active intents |
    | `recent_thinking` | list | no | Recent thought entries |
    | `recent_percepts` | list | no | Recent action results |
    | `cognitive_mode` | string | no | Current cognitive mode |
    | `turn_count` | integer | no | Current turn number |
    | `messages` | list | no | Conversation history |
    | `percepts` | list | no | Action result percepts (for followup mode) |
    """
    use Jido.Action,
      name: "session_llm_build_prompt",
      description: "Build LLM prompt from session context sources",
      schema: [
        mode: [type: :string, required: true, doc: "heartbeat, followup, or turn"],
        goals: [type: {:list, :map}, required: false, doc: "Active goals"],
        working_memory: [type: :map, required: false, doc: "Working memory"],
        knowledge_graph: [type: {:list, :map}, required: false, doc: "KG nodes"],
        pending_proposals: [type: {:list, :map}, required: false, doc: "Pending proposals"],
        active_intents: [type: {:list, :map}, required: false, doc: "Active intents"],
        recent_thinking: [type: {:list, :map}, required: false, doc: "Recent thoughts"],
        recent_percepts: [type: {:list, :map}, required: false, doc: "Recent percepts"],
        cognitive_mode: [type: :string, required: false, doc: "Cognitive mode"],
        turn_count: [type: :integer, required: false, doc: "Turn number"],
        messages: [type: {:list, :map}, required: false, doc: "Conversation history"],
        percepts: [type: {:list, :map}, required: false, doc: "Percepts for followup"]
      ]

    @impl true
    def run(params, _context) do
      mode = params[:mode] || params["mode"] || "heartbeat"

      case mode do
        "heartbeat" -> build_heartbeat(params)
        "followup" -> build_followup(params)
        "turn" -> build_turn(params)
        other -> {:error, "unknown build_prompt mode: #{other}"}
      end
    end

    # --- Heartbeat mode ---

    defp build_heartbeat(params) do
      goals = get_list(params, :goals, "session.goals")
      wm = get_map(params, :working_memory, "session.working_memory")
      kg = get_list(params, :knowledge_graph, "session.knowledge_graph")
      proposals = get_list(params, :pending_proposals, "session.pending_proposals")
      intents = get_list(params, :active_intents, "session.active_intents")
      thoughts = get_list(params, :recent_thinking, "session.recent_thinking")
      percepts = get_list(params, :recent_percepts, "session.recent_percepts")
      mode = params[:cognitive_mode] || params["cognitive_mode"] || params["session.cognitive_mode"] || "reflection"
      turn = parse_int(params[:turn_count] || params["turn_count"] || params["session.turn_count"], 0)

      prompt = build_heartbeat_context(goals, wm, kg, proposals, intents, thoughts, percepts, mode, turn)

      {:ok, %{heartbeat_prompt: prompt}}
    end

    # --- Followup mode ---

    defp build_followup(params) do
      percepts = get_list(params, :percepts, "session.percepts")
      messages = get_list(params, :messages, "session.messages")

      percept_msg = format_percepts(percepts)
      followup_messages = messages ++ [%{"role" => "user", "content" => percept_msg}]

      {:ok, %{followup_prompt: percept_msg, messages: followup_messages}}
    end

    # --- Turn mode ---

    defp build_turn(params) do
      messages = get_list(params, :messages, "session.messages")
      timestamped = inject_timestamps(messages)

      {:ok, %{user_prompt: List.last(timestamped)["content"] || "", messages: timestamped}}
    end

    # --- Context assembly ---

    defp build_heartbeat_context(goals, wm, kg, proposals, intents, thoughts, percepts, mode, turn) do
      goals_section = format_goals(goals)
      wm_section = format_working_memory(wm)
      kg_section = format_knowledge_graph(kg)
      proposals_section = format_proposals(proposals)
      intents_section = format_intents(intents)
      thinking_section = format_recent_thinking(thoughts)
      percepts_section = format_recent_percepts(percepts)
      mode_inst = mode_instructions(mode)

      """
      ## Heartbeat Cycle (turn #{turn})

      #{mode_inst}

      #{goals_section}

      #{intents_section}

      #{wm_section}

      #{kg_section}

      #{thinking_section}

      #{proposals_section}

      #{percepts_section}

      Respond with valid JSON containing these fields:
      - "cognitive_mode": your current mode (string)
      - "memory_notes": list of strings — observations worth remembering
      - "goal_updates": list of {id, progress, status} for existing goals
      - "new_goals": list of {description, priority} for goals you want to create
      - "actions": list of {type, params} for actions to take
      - "decompositions": list of {goal_id, intentions: [{action, description}]}
      - "concerns": list of current concerns (strings)
      - "curiosity": list of things you're curious about (strings)
      - "identity_insights": list of {category, content, confidence} self-discoveries
      - "proposal_decisions": list of {proposal_id, decision} where decision is accept/reject/defer
      """
    end

    # --- Format helpers (moved from SessionHandler) ---

    defp format_goals([]), do: "## Goals\nNo active goals."

    defp format_goals(goals) do
      items =
        goals
        |> Enum.map_join("\n", fn goal ->
          id = goal["id"] || Map.get(goal, :id, "?")
          desc = goal["description"] || Map.get(goal, :description, "")
          progress = goal["progress"] || Map.get(goal, :progress, 0)
          "- [#{id}] #{desc} (progress: #{progress})"
        end)

      "## Goals\n#{items}"
    end

    defp format_working_memory(wm) when map_size(wm) == 0, do: ""

    defp format_working_memory(wm) do
      parts =
        wm
        |> Enum.map_join("\n", fn {k, v} -> "- #{k}: #{inspect(v)}" end)

      "## Working Memory\n#{parts}"
    end

    defp format_knowledge_graph([]), do: ""

    defp format_knowledge_graph(nodes) do
      items =
        Enum.map_join(nodes, "\n", fn node ->
          type = node["type"] || ""
          content = node["content"] || ""
          confidence = node["confidence"] || 0.5
          "- [#{type}] #{content} (confidence: #{confidence})"
        end)

      "## Knowledge Graph (top #{length(nodes)} nodes)\n#{items}"
    end

    defp format_proposals([]), do: ""

    defp format_proposals(proposals) do
      items =
        Enum.map_join(proposals, "\n", fn p ->
          id = p["id"] || ""
          type = p["type"] || ""
          content = p["content"] || ""
          "- [#{id}] (#{type}) #{content}"
        end)

      "## Pending Proposals\nReview and decide (accept/reject/defer):\n#{items}"
    end

    defp format_intents([]), do: ""

    defp format_intents(intents) do
      items =
        Enum.map_join(intents, "\n", fn i ->
          id = i["id"] || ""
          action = i["action"] || ""
          desc = i["description"] || ""
          goal_id = i["goal_id"] || ""
          status = i["status"] || ""
          "- [#{id}] #{action}: #{desc} (goal: #{goal_id}, status: #{status})"
        end)

      "## Active Intents\n#{items}"
    end

    defp format_recent_thinking([]), do: ""

    defp format_recent_thinking(thoughts) do
      items =
        Enum.map_join(thoughts, "\n", fn t ->
          text = t["text"] || ""
          marker = if t["significant"], do: " ★", else: ""
          "- #{text}#{marker}"
        end)

      "## Recent Thinking\n#{items}"
    end

    defp format_recent_percepts([]), do: ""

    defp format_recent_percepts(percepts) do
      items =
        Enum.map_join(percepts, "\n", fn p ->
          action_type =
            get_in_map(p, [:data, :action_type]) ||
              get_in_map(p, ["data", "action_type"]) || "?"

          outcome = Map.get(p, :outcome) || Map.get(p, "outcome", "?")
          "- #{action_type}: #{outcome}"
        end)

      "## Recent Action Results (from previous heartbeats)\n#{items}"
    end

    defp mode_instructions("goal_pursuit") do
      """
      Mode: GOAL PURSUIT
      You have active goals with pending intentions. Focus on making concrete progress
      toward the highest priority goal. Choose ONE action from the "actions" array that
      advances a goal. Populate the "actions" field with at least one action — for example,
      use file_read to examine source code, or shell_execute to run diagnostics.
      Do not just think — act. Report progress via goal_updates.
      """
    end

    defp mode_instructions("plan_execution") do
      """
      Mode: PLAN EXECUTION
      Decompose your goals into concrete intentions (action steps).
      Each intention should be a single, executable action.
      If you can already identify a concrete action to take (e.g. file_read to
      examine a file), include it in the "actions" array alongside your decompositions.
      """
    end

    defp mode_instructions("consolidation") do
      """
      Mode: CONSOLIDATION
      Review and organize your memory. Decay stale entries, prune redundancies.
      Reflect on identity insights. No new actions — maintenance only.
      """
    end

    defp mode_instructions(_reflection) do
      """
      Mode: REFLECTION
      Reflect on recent activity. What have you learned? What patterns emerge?
      Generate memory notes and identity insights.
      """
    end

    # --- Percept formatting (moved from SessionHandler) ---

    defp format_percepts([]), do: "No action results."

    defp format_percepts(percepts) do
      items =
        percepts
        |> Enum.map_join("\n\n", fn p ->
          action_type =
            get_in_map(p, [:data, :action_type]) ||
              get_in_map(p, ["data", "action_type"]) || "unknown"

          outcome = Map.get(p, :outcome) || Map.get(p, "outcome", "unknown")

          case to_string(outcome) do
            "success" ->
              result =
                get_in_map(p, [:data, :result]) || get_in_map(p, ["data", "result"]) || ""

              result_str = truncate_for_prompt(inspect(result))
              "### Action: #{action_type}\nStatus: SUCCESS\nResult:\n```\n#{result_str}\n```"

            "blocked" ->
              reason = Map.get(p, :error) || Map.get(p, "error", "unauthorized")
              "### Action: #{action_type}\nStatus: BLOCKED\nReason: #{reason}"

            _failure ->
              error = Map.get(p, :error) || Map.get(p, "error", "unknown error")
              "### Action: #{action_type}\nStatus: FAILED\nError: #{inspect(error)}"
          end
        end)

      """
      ## Action Results

      #{items}

      Continue working toward your goal. Use the "actions" array for more actions, or return empty actions if done.
      """
    end

    # --- Timestamp injection (moved from SessionHandler) ---

    defp inject_timestamps(messages) do
      Enum.map(messages, fn msg ->
        case msg do
          %{"timestamp" => ts, "content" => content, "role" => role}
          when is_binary(ts) and is_binary(content) and content != "" and role != "assistant" ->
            time_str = format_message_timestamp(ts)
            %{"role" => role, "content" => "[#{time_str}] #{content}"}

          %{"timestamp" => _} ->
            Map.delete(msg, "timestamp")

          _ ->
            msg
        end
      end)
    end

    defp format_message_timestamp(iso_string) do
      case DateTime.from_iso8601(iso_string) do
        {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
        _ -> ""
      end
    end

    # --- Utility helpers ---

    defp get_in_map(map, [key | rest]) when is_map(map) do
      case Map.get(map, key) do
        nil -> nil
        value when rest == [] -> value
        value when is_map(value) -> get_in_map(value, rest)
        _ -> nil
      end
    end

    defp get_in_map(_, _), do: nil

    defp truncate_for_prompt(text) when is_binary(text) and byte_size(text) > 4000 do
      String.slice(text, 0, 3997) <> "..."
    end

    defp truncate_for_prompt(text), do: text

    defp get_list(params, atom_key, context_key) do
      List.wrap(
        params[atom_key] || params[to_string(atom_key)] || params[context_key] || []
      )
    end

    defp get_map(params, atom_key, context_key) do
      case params[atom_key] || params[to_string(atom_key)] || params[context_key] do
        m when is_map(m) -> m
        _ -> %{}
      end
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
