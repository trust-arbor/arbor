defmodule Arbor.Dashboard.Live.ChatLive.GroupChat do
  @moduledoc """
  Group chat event handling extracted from ChatLive.

  Helper module (not a LiveComponent) — receives socket, returns socket.
  Handles group creation modal, group messaging, and participant tracking.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  alias Arbor.Agent.{Lifecycle, Manager}

  @doc """
  Returns the default assigns for group chat state.
  Merge into the socket during mount.
  """
  def init_assigns do
    %{
      group_pid: nil,
      group_id: nil,
      group_participants: [],
      group_mode: false,
      show_group_modal: false,
      available_for_group: [],
      group_selection: %{},
      group_name_input: "Group Chat"
    }
  end

  # ── handle_event callbacks ────────────────────────────────────────

  def handle_event("show-group-modal", _params, socket) do
    available = Lifecycle.list_agents()

    {:noreply,
     assign(socket,
       show_group_modal: true,
       available_for_group: available,
       group_selection: %{},
       group_name_input: "Group Chat"
     )}
  end

  def handle_event("toggle-group-agent", %{"agent-id" => agent_id}, socket) do
    current = socket.assigns.group_selection

    updated =
      if Map.has_key?(current, agent_id) do
        Map.delete(current, agent_id)
      else
        Map.put(current, agent_id, true)
      end

    {:noreply, assign(socket, group_selection: updated)}
  end

  def handle_event("update-group-name", %{"value" => name}, socket) do
    {:noreply, assign(socket, group_name_input: name)}
  end

  def handle_event("confirm-create-group", _params, socket) do
    selected_ids = Map.keys(socket.assigns.group_selection)
    group_name = socket.assigns.group_name_input

    if Enum.empty?(selected_ids) do
      {:noreply, assign(socket, error: "Please select at least one agent")}
    else
      ensure_agents_running(selected_ids)
      Process.sleep(100)

      participant_specs = build_participant_specs(selected_ids)

      case Manager.create_group(group_name, participant_specs) do
        {:ok, group_pid} ->
          {group_id, _} =
            Manager.list_groups()
            |> Enum.find(fn {_id, pid} -> pid == group_pid end)

          try do
            Phoenix.PubSub.subscribe(Arbor.Dashboard.PubSub, "group_chat:#{group_id}")
          rescue
            _ -> :ok
          end

          participants = build_participant_list(participant_specs)

          socket =
            socket
            |> assign(
              group_pid: group_pid,
              group_id: group_id,
              group_participants: participants,
              group_mode: true,
              show_group_modal: false
            )
            |> stream(:messages, [], reset: true)

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, error: "Failed to create group: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("cancel-group-modal", _params, socket) do
    {:noreply, assign(socket, show_group_modal: false)}
  end

  def handle_event("leave-group", _params, socket) do
    if socket.assigns.group_id do
      try do
        Phoenix.PubSub.unsubscribe(
          Arbor.Dashboard.PubSub,
          "group_chat:#{socket.assigns.group_id}"
        )
      rescue
        _ -> :ok
      end
    end

    socket =
      socket
      |> assign(
        group_pid: nil,
        group_id: nil,
        group_participants: [],
        group_mode: false
      )
      |> stream(:messages, [], reset: true)

    {:noreply, socket}
  end

  # ── handle_info callbacks ─────────────────────────────────────────

  def handle_info({:group_message, message}, socket) do
    if message.sender_id == "human_primary" and message.sender_type == :human do
      {:noreply, socket}
    else
      msg_entry = %{
        id: "msg-#{System.unique_integer([:positive])}",
        role: if(message.sender_type == :agent, do: :assistant, else: :user),
        content: message.content,
        sender_name: message.sender_name,
        sender_type: message.sender_type,
        sender_id: message.sender_id,
        timestamp: message.timestamp,
        sender_color: sender_color_hue(message.sender_id)
      }

      try do
        if socket.assigns.agent || socket.assigns.group_id do
          agent_key = socket.assigns.agent || socket.assigns.group_id
          Arbor.Memory.append_chat_message(agent_key, msg_entry)
        end
      rescue
        _ -> :ok
      end

      socket = stream_insert(socket, :messages, msg_entry)
      {:noreply, socket}
    end
  end

  def handle_info({:group_participant_joined, participant}, socket) do
    updated_participants = [participant | socket.assigns.group_participants]
    {:noreply, assign(socket, group_participants: updated_participants)}
  end

  def handle_info({:group_participant_left, participant_id}, socket) do
    updated_participants =
      Enum.reject(socket.assigns.group_participants, &(&1.id == participant_id))

    {:noreply, assign(socket, group_participants: updated_participants)}
  end

  # ── Private Helpers ───────────────────────────────────────────────

  defp ensure_agents_running(agent_ids) do
    Enum.each(agent_ids, fn agent_id ->
      unless Arbor.Agent.running?(agent_id) do
        Manager.resume_agent(agent_id)
      end
    end)
  end

  defp build_participant_specs(selected_ids) do
    agent_specs =
      Enum.map(selected_ids, fn agent_id ->
        name =
          case Lifecycle.restore(agent_id) do
            {:ok, profile} -> profile.display_name || "Agent"
            _ -> "Agent"
          end

        %{id: agent_id, name: name, type: :agent}
      end)

    human_spec = %{id: "human_primary", name: "User", type: :human}
    [human_spec | agent_specs]
  end

  defp build_participant_list(participant_specs) do
    Enum.map(participant_specs, fn spec ->
      %{
        id: spec.id,
        name: spec.name,
        type: spec.type,
        color: sender_color_hue(spec.id)
      }
    end)
  end

  defp sender_color_hue(sender_id) do
    :erlang.phash2(sender_id, 360)
  end
end
