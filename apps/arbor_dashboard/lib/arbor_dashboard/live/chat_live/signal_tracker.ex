defmodule Arbor.Dashboard.Live.ChatLive.SignalTracker do
  @moduledoc """
  Signal tracking and processing extracted from ChatLive.

  Helper module (not a LiveComponent) — receives socket, returns socket.
  Handles heartbeat, action, goal, and memory note signals from the
  Arbor signal bus.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]

  @doc """
  Process a signal that matches the current agent.
  Dispatches to all signal tracking sub-handlers.
  Returns the updated socket.
  """
  def process_signal(socket, signal) do
    socket
    |> maybe_track_stream(signal)
    |> maybe_add_action(signal)
    |> maybe_track_heartbeat(signal)
    |> maybe_refresh_goals(signal)
    |> maybe_track_memory_note(signal)
  end

  # ── Stream Delta Tracking ──────────────────────────────────────────

  defp maybe_track_stream(socket, signal) do
    case signal.type do
      :stream_delta ->
        text = flex_get(signal.data, :text) || ""
        current = socket.assigns[:streaming_text] || ""
        assign(socket, streaming_text: current <> text)

      :stream_finish ->
        # Text stays visible until query_result replaces it
        socket

      _ ->
        socket
    end
  end

  # ── Action Tracking ───────────────────────────────────────────────

  # Action cycle lifecycle signals (started/completed/error/throttled) are
  # infrastructure — they belong in the Signals pane, not the Actions pane.
  # Only actual tool executions and intent dispatches go to Actions.
  @action_cycle_lifecycle ~w(
    action_cycle_started action_cycle_completed
    action_cycle_error action_cycle_throttled
    percept_received
  )

  defp maybe_add_action(socket, signal) do
    event = to_string(signal.type)

    is_action =
      (String.contains?(event, "action") or String.contains?(event, "tool")) and
        event not in @action_cycle_lifecycle

    if is_action do
      action_entry = %{
        id: "act-#{System.unique_integer([:positive])}",
        name: get_action_name(signal),
        event: to_string(signal.type),
        outcome: get_action_outcome(signal),
        timestamp: signal.timestamp,
        details: Map.merge(signal.metadata || %{}, signal.data || %{})
      }

      socket
      |> stream_insert(:actions, action_entry)
      |> assign(:action_count, (socket.assigns[:action_count] || 0) + 1)
    else
      socket
    end
  end

  defp get_action_name(signal) do
    # Check both metadata and data — tool loop signals put tool name in data
    extract_name(signal.metadata) || extract_name(signal.data) || to_string(signal.type)
  end

  defp extract_name(%{action: name}) when is_binary(name), do: name
  defp extract_name(%{"action" => name}) when is_binary(name), do: name
  defp extract_name(%{tool: name}) when is_binary(name), do: name
  defp extract_name(%{"tool" => name}) when is_binary(name), do: name
  defp extract_name(%{capability: cap, op: op}), do: "#{cap}.#{op}"
  defp extract_name(%{"capability" => cap, "op" => op}), do: "#{cap}.#{op}"
  defp extract_name(%{name: name}) when is_binary(name), do: name
  defp extract_name(%{"name" => name}) when is_binary(name), do: name
  defp extract_name(_), do: nil

  defp get_action_outcome(signal) do
    extract_outcome(signal.metadata)
  end

  defp extract_outcome(meta) do
    get_explicit_outcome(meta) ||
      get_success_outcome(meta) ||
      get_error_outcome(meta) ||
      :unknown
  end

  defp get_explicit_outcome(meta) do
    meta[:outcome] || meta["outcome"] || meta[:status] || meta["status"]
  end

  defp get_success_outcome(meta) do
    case {meta[:success], meta["success"]} do
      {true, _} -> :success
      {_, true} -> :success
      {false, _} -> :failure
      {_, false} -> :failure
      _ -> nil
    end
  end

  defp get_error_outcome(meta) do
    if Map.has_key?(meta, :error) or Map.has_key?(meta, "error"), do: :failure
  end

  # ── Goal Tracking ─────────────────────────────────────────────────

  @doc """
  Fetch goals for an agent. Used by ChatLive mount and toggle handlers.
  """
  def fetch_goals(agent_id, show_completed) do
    unless Code.ensure_loaded?(Arbor.Memory), do: throw(:no_memory)

    if show_completed do
      fetch_all_goals(agent_id)
    else
      fetch_active_goals(agent_id)
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
    :no_memory -> []
  end

  defp maybe_refresh_goals(socket, signal) do
    event = to_string(signal.type)

    if String.contains?(event, "goal") do
      agent_id = socket.assigns.agent_id
      show_completed = socket.assigns.show_completed_goals
      assign(socket, agent_goals: fetch_goals(agent_id, show_completed))
    else
      socket
    end
  end

  defp fetch_all_goals(agent_id) do
    cond do
      function_exported?(Arbor.Memory, :get_all_goals, 1) ->
        agent_id |> Arbor.Memory.get_all_goals() |> sort_goals()

      function_exported?(Arbor.Memory, :get_active_goals, 1) ->
        Arbor.Memory.get_active_goals(agent_id)

      true ->
        []
    end
  end

  defp fetch_active_goals(agent_id) do
    if function_exported?(Arbor.Memory, :get_active_goals, 1) do
      Arbor.Memory.get_active_goals(agent_id)
    else
      []
    end
  end

  defp sort_goals(goals) do
    Enum.sort_by(goals, fn goal ->
      case goal.status do
        :active -> {0, -goal.priority}
        _ -> {1, goal.achieved_at || goal.created_at}
      end
    end)
  end

  # ── Memory Note Tracking ──────────────────────────────────────────

  defp maybe_track_memory_note(socket, signal) do
    event = to_string(signal.type)

    if event == "agent_memory_note" do
      assign(socket, memory_notes_total: socket.assigns.memory_notes_total + 1)
    else
      socket
    end
  end

  # ── Heartbeat / LLM Tracking ─────────────────────────────────────

  defp maybe_track_heartbeat(socket, signal) do
    if to_string(signal.type) == "heartbeat_complete" do
      heartbeat = parse_heartbeat_data(signal)

      socket
      |> apply_heartbeat_assigns(heartbeat)
      |> maybe_stream_llm_interaction(heartbeat, signal.timestamp)
    else
      socket
    end
  end

  defp parse_heartbeat_data(signal) do
    data = signal.data || %{}
    usage = flex_get(data, :usage) || %{}

    %{
      mode: flex_get(data, :cognitive_mode),
      thinking: flex_get(data, :agent_thinking),
      llm_actions: flex_get(data, :llm_actions) || 0,
      notes_count: flex_get(data, :memory_notes_count) || 0,
      memory_notes: flex_get(data, :memory_notes) || [],
      concerns: flex_get(data, :concerns) || [],
      curiosity: flex_get(data, :curiosity) || [],
      identity_insights: flex_get(data, :identity_insights) || [],
      hb_in: flex_get(usage, :input_tokens) || 0,
      hb_out: flex_get(usage, :output_tokens) || 0,
      hb_cached: flex_get(usage, :cache_read_input_tokens) || 0
    }
  end

  defp apply_heartbeat_assigns(socket, hb) do
    assign(socket,
      heartbeat_count: socket.assigns.heartbeat_count + 1,
      last_llm_mode: hb.mode,
      last_llm_thinking: hb.thinking,
      last_memory_notes: hb.memory_notes,
      last_concerns: hb.concerns,
      last_curiosity: hb.curiosity,
      last_identity_insights: hb.identity_insights,
      memory_notes_total: socket.assigns.memory_notes_total + hb.notes_count,
      hb_input_tokens: socket.assigns.hb_input_tokens + hb.hb_in,
      hb_output_tokens: socket.assigns.hb_output_tokens + hb.hb_out,
      hb_cached_tokens: socket.assigns.hb_cached_tokens + hb.hb_cached
    )
  end

  defp maybe_stream_llm_interaction(socket, hb, timestamp) do
    if hb.thinking && hb.thinking != "" do
      interaction = %{
        id: "llm-#{System.unique_integer([:positive])}",
        mode: hb.mode || :unknown,
        thinking: hb.thinking,
        actions: hb.llm_actions,
        notes: hb.notes_count,
        memory_notes: hb.memory_notes,
        concerns: hb.concerns,
        curiosity: hb.curiosity,
        identity_insights: hb.identity_insights,
        timestamp: timestamp
      }

      stream_insert(socket, :llm_interactions, interaction)
    else
      socket
    end
  end

  # ── Shared Helpers ────────────────────────────────────────────────

  defp flex_get(map, atom_key) when is_atom(atom_key) do
    map[atom_key] || map[Atom.to_string(atom_key)]
  end
end
