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
  | `ProcessResults` | Parse and validate LLM JSON response into typed output fields plus a parse status |
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
      tags: ["pipeline_internal"],
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
    | `new_percepts` | list | no | Percepts since the last cycle (idle detection) |
    | `pending_proposals` | list | no | Proposals awaiting a decision (idle detection) |
    | `beat_count` | integer | no | Heartbeat ordinal (idle detection) |
    | `idle_every` | integer | no | Reflect only every N idle beats; nil disables idle |

    ## Returns

    `%{cognitive_mode: "conversation" | "consolidation" | "plan_execution" | "goal_pursuit" | "reflection" | "idle"}`

    ## Idle

    A heartbeat with nothing to act on — no goals, no intents, no new percepts,
    no pending proposals — used to run a full reflection LLM call every beat
    (prompt grew 8.2k → 10.3k tokens per cycle on an idle conversationalist,
    2026-08-27). When `idle_every` is set, such beats return `"idle"` and the
    graph skips the LLM; every `idle_every`-th beat still reflects so the
    agent keeps its inner life. Graphs opt in by passing `param.idle_every`
    and routing `idle` past the LLM nodes; graphs that do not set it are
    unchanged.
    """
    use Jido.Action,
      name: "session_mode_select",
      tags: ["pipeline_internal"],
      description: "Select BDI cognitive mode based on goals, intents, and turn state",
      schema: [
        goals: [type: {:list, :map}, required: false, doc: "Active goals"],
        active_intents: [type: {:list, :map}, required: false, doc: "Active intents"],
        turn_count: [type: :integer, required: false, doc: "Current turn number"],
        user_waiting: [type: :boolean, required: false, doc: "User waiting for response"],
        new_percepts: [type: {:list, :any}, required: false, doc: "Percepts since last cycle"],
        pending_proposals: [
          type: {:list, :any},
          required: false,
          doc: "Proposals awaiting decision"
        ],
        beat_count: [type: :integer, required: false, doc: "Heartbeat ordinal"],
        idle_every: [type: :integer, required: false, doc: "Reflect every N idle beats"]
      ]

    require Logger

    @impl true
    def run(params, _context) do
      goals = List.wrap(get_param(params, :goals, []))
      intents = List.wrap(get_param(params, :active_intents, []))
      turn = parse_int(get_param(params, :turn_count, 0), 0)
      user_waiting = to_bool(get_param(params, :user_waiting, false))
      percepts = List.wrap(get_param(params, :new_percepts, []))
      proposals = List.wrap(get_param(params, :pending_proposals, []))
      beat = parse_int(get_param(params, :beat_count, 0), 0)
      idle_every = parse_int(get_param(params, :idle_every, nil), nil)

      nothing_to_do? = goals == [] and intents == [] and percepts == [] and proposals == []

      idle? =
        is_integer(idle_every) and idle_every > 0 and nothing_to_do? and
          rem(beat, idle_every) != 0

      mode =
        cond do
          user_waiting -> "conversation"
          rem(turn, 5) == 0 and turn > 0 -> "consolidation"
          goals != [] and intents == [] -> "plan_execution"
          goals != [] -> "goal_pursuit"
          idle? -> "idle"
          true -> "reflection"
        end

      Logger.info(
        "[Session.ModeSelect] goals=#{length(goals)}, intents=#{length(intents)}, " <>
          "percepts=#{length(percepts)}, proposals=#{length(proposals)}, turn=#{turn}, " <>
          "beat=#{beat}, idle_every=#{inspect(idle_every)} → #{mode}"
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
    Parse and validate LLM JSON response into typed output fields.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `raw_content` | string | yes | Raw LLM response (JSON string) |

    Heartbeat graphs bind `last_response` and `session.cognitive_mode` instead;
    both arrive as string keys.

    ## Returns

    Map with validated fields: actions, goal_updates, new_goals, memory_notes,
    concerns, curiosity, decompositions, new_intents, proposal_decisions,
    identity_insights, proposals, fix_proposal — plus the parse outcome:
    `parse_status` (`"parsed" | "parse_failed" | "no_reply"`), `parse_error`,
    and `parse_rejected_fields`. See `Arbor.Actions.Session.ProcessResultsCore`.

    A reply that does not parse still yields empty fields, so no actions run
    (fail closed). It is no longer silent: it is marked `parse_failed`, logged
    as a warning with a bounded, redacted preview, and emitted as an
    `agent.heartbeat_parse_failed` signal — so a broken reply can be told apart
    from an idle agent.
    """
    use Jido.Action,
      name: "session_process_results",
      tags: ["pipeline_internal"],
      description: "Parse and validate LLM JSON response into typed output fields",
      schema: [
        raw_content: [type: :string, required: false, doc: "Raw LLM response (JSON string)"]
      ]

    alias Arbor.Actions.Session.ProcessResultsCore
    alias Arbor.Common.SensitiveData

    require Logger

    @impl true
    def run(params, context) do
      raw =
        params[:raw_content] || params["raw_content"] || params["llm.content"] ||
          params["last_response"] || params["session.llm_response"] || ""

      mode =
        params[:cognitive_mode] || params["cognitive_mode"] || params["session.cognitive_mode"]

      core = ProcessResultsCore.new(raw, cognitive_mode: mode)

      cond do
        ProcessResultsCore.parse_failed?(core) ->
          report_parse_failure(core, raw, mode, context)

        core.rejected_fields != [] ->
          Logger.info(
            "[Session.ProcessResults] heartbeat reply parsed with malformed fields " <>
              "#{Enum.join(core.rejected_fields, ",")}; their invalid items were dropped. " <>
              "agent=#{label(context_agent_id(context))} mode=#{label(mode)}"
          )

        true ->
          :ok
      end

      {:ok, ProcessResultsCore.show(core)}
    end

    # Visibility only: the result is already fail-closed (empty fields).
    defp report_parse_failure(core, raw, mode, context) do
      agent_id = context_agent_id(context)
      reason = Atom.to_string(core.reason)

      preview =
        raw
        |> ProcessResultsCore.preview_window()
        |> SensitiveData.redact()
        |> ProcessResultsCore.truncate_preview()

      Logger.warning(
        "[Session.ProcessResults] heartbeat reply did not parse (#{reason}); no actions " <>
          "will run. agent=#{label(agent_id)} mode=#{label(mode)} " <>
          "bytes=#{core.reply_bytes} preview=#{inspect(preview)}"
      )

      emit_parse_failed(%{
        agent_id: agent_id,
        reason: reason,
        cognitive_mode: text_or_nil(mode),
        reply_bytes: core.reply_bytes
      })
    end

    # Fire-and-forget observability, once per failed parse. The payload carries
    # no reply content: signals fan out to every subscriber.
    defp emit_parse_failed(data) do
      if Process.whereis(Arbor.Signals.Bus) != nil do
        metadata = if data.agent_id, do: %{agent_id: data.agent_id}, else: %{}
        Arbor.Signals.emit(:agent, :heartbeat_parse_failed, data, metadata: metadata)
      end

      :ok
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    defp context_agent_id(context) when is_map(context) do
      case Map.get(context, :agent_id) || Map.get(context, "agent_id") do
        id when is_binary(id) ->
          id

        _ ->
          case Map.get(context, :auth_context) do
            %{principal_id: id} when is_binary(id) -> id
            _ -> nil
          end
      end
    end

    defp context_agent_id(_context), do: nil

    defp label(value), do: text_or_nil(value) || "unknown"

    defp text_or_nil(value) when is_binary(value) and value != "", do: value
    defp text_or_nil(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
    defp text_or_nil(_value), do: nil
  end
end
