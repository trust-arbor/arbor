defmodule Arbor.Actions.Session do
  @moduledoc """
  Pure logic session operations as Jido actions.

  These actions extract business logic from SessionHandler so DOT pipelines
  can use `exec target="action"` instead of hardcoded `session.*` types.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Classify` | Classify session input type (query/command/tool_result/blocked) |
  | `ModeSelect` | Select BDI cognitive mode from goals/intents/turn state |
  | `ProcessResults` | Parse and validate LLM JSON response into 10 typed output fields |
  """

  # ============================================================================
  # Classify
  # ============================================================================

  defmodule Classify do
    @moduledoc """
    Classify session input type.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `input` | string | no | The input to classify |
    | `blocked` | boolean | no | Whether the session is blocked |

    ## Returns

    `%{input_type: "query" | "command" | "tool_result" | "blocked"}`
    """
    use Jido.Action,
      name: "session_classify",
      description: "Classify session input as query, command, tool_result, or blocked",
      schema: [
        input: [type: :string, required: false, doc: "Input to classify"],
        blocked: [type: :boolean, required: false, doc: "Whether session is blocked"]
      ]

    @impl true
    def run(params, _context) do
      input = params[:input] || params["input"] || params["session.input"] || ""
      blocked = params[:blocked] || params["blocked"] || params["session.blocked"] || false

      input_type =
        cond do
          is_binary(input) and String.starts_with?(input, "/") -> "command"
          is_map(input) and Map.has_key?(input, "tool_result") -> "tool_result"
          blocked -> "blocked"
          true -> "query"
        end

      {:ok, %{input_type: input_type}}
    end
  end

  # ============================================================================
  # ModeSelect
  # ============================================================================

  defmodule ModeSelect do
    @moduledoc """
    Select BDI cognitive mode from goals, intents, and turn state.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `goals` | list | no | Active goals |
    | `active_intents` | list | no | Active intents |
    | `turn_count` | integer | no | Current turn number |
    | `user_waiting` | boolean | no | Whether a user is waiting for response |

    ## Returns

    `%{cognitive_mode: "conversation" | "consolidation" | "plan_execution" | "goal_pursuit" | "reflection"}`
    """
    use Jido.Action,
      name: "session_mode_select",
      description: "Select BDI cognitive mode based on goals, intents, and turn state",
      schema: [
        goals: [type: {:list, :map}, required: false, doc: "Active goals"],
        active_intents: [type: {:list, :map}, required: false, doc: "Active intents"],
        turn_count: [type: :integer, required: false, doc: "Current turn number"],
        user_waiting: [type: :boolean, required: false, doc: "User waiting for response"]
      ]

    require Logger

    @impl true
    def run(params, _context) do
      goals = List.wrap(get_param(params, :goals, []))
      intents = List.wrap(get_param(params, :active_intents, []))
      turn = parse_int(get_param(params, :turn_count, 0), 0)
      user_waiting = to_bool(get_param(params, :user_waiting, false))

      mode =
        cond do
          user_waiting -> "conversation"
          rem(turn, 5) == 0 and turn > 0 -> "consolidation"
          goals != [] and intents == [] -> "plan_execution"
          goals != [] -> "goal_pursuit"
          true -> "reflection"
        end

      Logger.info(
        "[Session.ModeSelect] goals=#{length(goals)}, intents=#{length(intents)}, turn=#{turn} → #{mode}"
      )

      {:ok, %{cognitive_mode: mode}}
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

    defp to_bool(true), do: true
    defp to_bool("true"), do: true
    defp to_bool(_), do: false

    defp get_param(params, key, default) do
      params[key] || params[Atom.to_string(key)] || params["session.#{key}"] || default
    end
  end

  # ============================================================================
  # ProcessResults
  # ============================================================================

  defmodule ProcessResults do
    @moduledoc """
    Parse and validate LLM JSON response into 10 typed output fields.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `raw_content` | string | yes | Raw LLM response (JSON string) |

    ## Returns

    Map with validated fields: actions, goal_updates, new_goals, memory_notes,
    concerns, curiosity, decompositions, new_intents, proposal_decisions, identity_insights
    """
    use Jido.Action,
      name: "session_process_results",
      description: "Parse and validate LLM JSON response into typed output fields",
      schema: [
        raw_content: [type: :string, required: false, doc: "Raw LLM response (JSON string)"]
      ]

    @impl true
    def run(params, _context) do
      raw = params[:raw_content] || params["raw_content"] || params["llm.content"] || ""

      case Jason.decode(raw) do
        {:ok, parsed} when is_map(parsed) ->
          {:ok,
           %{
             actions: validated_list(parsed, "actions", &valid_action?/1),
             goal_updates: validated_list(parsed, "goal_updates", &is_map/1),
             new_goals: validated_list(parsed, "new_goals", &is_map/1),
             memory_notes: validated_list(parsed, "memory_notes", &valid_memory_note?/1),
             concerns: validated_list(parsed, "concerns", &is_binary/1),
             curiosity: validated_list(parsed, "curiosity", &is_binary/1),
             decompositions: validated_list(parsed, "decompositions", &is_map/1),
             new_intents: validated_list(parsed, "new_intents", &is_map/1),
             proposal_decisions:
               validated_list(parsed, "proposal_decisions", &valid_proposal_decision?/1),
             identity_insights: validated_list(parsed, "identity_insights", &is_map/1)
           }}

        _ ->
          {:ok,
           %{
             actions: [],
             goal_updates: [],
             new_goals: [],
             memory_notes: [],
             concerns: [],
             curiosity: [],
             decompositions: [],
             new_intents: [],
             proposal_decisions: [],
             identity_insights: []
           }}
      end
    end

    defp validated_list(parsed, key, validator) do
      case Map.get(parsed, key) do
        items when is_list(items) -> Enum.filter(items, validator)
        _ -> []
      end
    end

    defp valid_action?(%{"type" => type}) when is_binary(type), do: true
    defp valid_action?(_), do: false

    defp valid_memory_note?(note) when is_binary(note), do: true
    defp valid_memory_note?(%{"text" => text}) when is_binary(text), do: true
    defp valid_memory_note?(_), do: false

    defp valid_proposal_decision?(%{"proposal_id" => id, "decision" => d})
         when is_binary(id) and d in ["accept", "reject", "defer"],
         do: true

    defp valid_proposal_decision?(_), do: false
  end
end
