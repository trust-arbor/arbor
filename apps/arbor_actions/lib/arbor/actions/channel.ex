defmodule Arbor.Actions.Channel do
  @moduledoc """
  Channel actions for internal Arbor channel communication.

  These actions allow agents to interact with unified channels (group, dm,
  public, ops_room) managed by `Arbor.Comms`. Unlike `Arbor.Actions.Comms`
  which bridges external services (Signal, Email), these operate on internal
  channels.

  All calls go through a runtime bridge (`Code.ensure_loaded?` + `apply/3`)
  so that `arbor_actions` has no compile-time dependency on `arbor_comms`.
  """

  @comms_module Arbor.Comms

  defp comms_available? do
    Code.ensure_loaded?(@comms_module)
  end

  @doc false
  def call_comms(fun, args) do
    if comms_available?() do
      apply(@comms_module, fun, args)
    else
      {:error, :comms_unavailable}
    end
  end

  # ============================================================================
  # Channel.List
  # ============================================================================

  defmodule List do
    @moduledoc """
    List active channels with their metadata.

    Returns channel IDs, names, types, and member counts for all active channels.
    Optionally filter by channel type.
    """

    use Jido.Action,
      name: "channel_list",
      description: "List active internal channels",
      category: "channel",
      tags: ["channel", "list", "discovery"],
      schema: [
        type: [
          type: :string,
          doc: "Filter by type (group, dm, public, ops_room)"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{type: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      case Arbor.Actions.Channel.call_comms(:list_channels, []) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        channels when is_list(channels) ->
          channel_infos =
            channels
            |> Enum.map(fn {channel_id, _pid} ->
              case Arbor.Actions.Channel.call_comms(:get_channel_info, [channel_id]) do
                {:ok, info} ->
                  %{
                    channel_id: channel_id,
                    name: Map.get(info, :name, channel_id),
                    type: Map.get(info, :type, :group),
                    member_count: Map.get(info, :member_count, 0)
                  }

                _ ->
                  nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> maybe_filter_type(params[:type])

          result = %{channels: channel_infos}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end

    defp maybe_filter_type(channels, nil), do: channels

    defp maybe_filter_type(channels, type_str) when is_binary(type_str) do
      type_atom = String.to_existing_atom(type_str)
      Enum.filter(channels, &(&1.type == type_atom))
    rescue
      ArgumentError -> channels
    end
  end

  # ============================================================================
  # Channel.Read
  # ============================================================================

  defmodule Read do
    @moduledoc """
    Read message history from a channel.

    Returns messages oldest-first with sender info and timestamps.
    """

    use Jido.Action,
      name: "channel_read",
      description: "Read message history from an internal channel",
      category: "channel",
      tags: ["channel", "read", "history"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to read from"
        ],
        limit: [
          type: :integer,
          default: 20,
          doc: "Maximum number of messages to return"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, limit: :data}
    end

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)
      channel_id = params.channel_id
      limit = params[:limit] || 20

      case Arbor.Actions.Channel.call_comms(:channel_history, [channel_id, [limit: limit]]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:ok, messages} when is_list(messages) ->
          formatted =
            Enum.map(messages, fn msg ->
              %{
                sender_name: Map.get(msg, :sender_name, "unknown"),
                sender_type: Map.get(msg, :sender_type, :unknown),
                content: Map.get(msg, :content, ""),
                timestamp: Map.get(msg, :timestamp) |> format_timestamp()
              }
            end)

          result = %{channel_id: channel_id, messages: formatted, count: length(formatted)}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end

    defp format_timestamp(nil), do: nil
    defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp format_timestamp(other), do: to_string(other)
  end

  # ============================================================================
  # Channel.Send
  # ============================================================================

  defmodule Send do
    @moduledoc """
    Send a message to an internal channel.

    Extracts sender identity from the execution context (`agent_id`, `agent_name`).
    """

    use Jido.Action,
      name: "channel_send",
      description: "Send a message to an internal channel",
      category: "channel",
      tags: ["channel", "send", "messaging"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to send to"
        ],
        content: [
          type: :string,
          required: true,
          doc: "Message content"
        ],
        metadata: [
          type: :map,
          default: %{},
          doc: "Optional message metadata"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control, content: :data, metadata: :data}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      content = params.content
      metadata = params[:metadata] || %{}
      sender_id = Map.get(context, :agent_id, "unknown")
      sender_name = Map.get(context, :agent_name, "Agent")
      sender_type = :agent

      case Arbor.Actions.Channel.call_comms(:send_to_channel, [
             channel_id,
             sender_id,
             sender_name,
             sender_type,
             content,
             metadata
           ]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        {:ok, message} ->
          result = %{
            channel_id: channel_id,
            message_id: Map.get(message, :id, "unknown"),
            status: :sent
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end
  end

  # ============================================================================
  # Channel.Join
  # ============================================================================

  defmodule Join do
    @moduledoc """
    Join an internal channel.

    Builds a member map from the execution context and adds the agent as a member.
    """

    use Jido.Action,
      name: "channel_join",
      description: "Join an internal channel",
      category: "channel",
      tags: ["channel", "join", "membership"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to join"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id, "unknown")
      agent_name = Map.get(context, :agent_name, "Agent")

      member = %{id: agent_id, name: agent_name, type: :agent}

      case Arbor.Actions.Channel.call_comms(:join_channel, [channel_id, member]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        :ok ->
          result = %{channel_id: channel_id, status: :joined}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end
  end

  # ============================================================================
  # Channel.Leave
  # ============================================================================

  defmodule Leave do
    @moduledoc """
    Leave an internal channel.

    Uses `agent_id` from the execution context as the member to remove.
    """

    use Jido.Action,
      name: "channel_leave",
      description: "Leave an internal channel",
      category: "channel",
      tags: ["channel", "leave", "membership"],
      schema: [
        channel_id: [
          type: :string,
          required: true,
          doc: "Channel ID to leave"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{channel_id: :control}
    end

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      channel_id = params.channel_id
      agent_id = Map.get(context, :agent_id, "unknown")

      case Arbor.Actions.Channel.call_comms(:leave_channel, [channel_id, agent_id]) do
        {:error, :comms_unavailable} = err ->
          Actions.emit_failed(__MODULE__, :comms_unavailable)
          err

        {:error, :not_found} ->
          Actions.emit_failed(__MODULE__, :not_found)
          {:error, :not_found}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}

        :ok ->
          result = %{channel_id: channel_id, status: :left}
          Actions.emit_completed(__MODULE__, result)
          {:ok, result}
      end
    end
  end
end
