defmodule Arbor.Actions.Comms do
  @moduledoc """
  Communication actions for sending messages through Arbor channels.

  Channel modules are resolved at runtime via config so that
  `arbor_actions` has no compile-time dependency on `arbor_comms`.

  ## Configuration

      config :arbor_actions, :channel_senders, %{
        signal: Arbor.Comms.Channels.Signal,
        email: Arbor.Comms.Channels.Email
      }
  """

  alias Arbor.Actions

  defmodule SendMessage do
    @moduledoc """
    Send a message through a communication channel.

    Resolves the channel module at runtime via `:channel_senders` config,
    optionally formats the message for the channel's constraints, then
    calls `send_message/3` on the resolved module.

    ## Examples

        Arbor.Actions.Comms.SendMessage.run(
          %{channel: :signal, to: "+1XXXXXXXXXX", message: "Hello!"},
          %{}
        )

        Arbor.Actions.Comms.SendMessage.run(
          %{channel: :email, to: "user@example.com", message: "Report attached",
            subject: "Daily Report", attachments: ["/tmp/report.pdf"]},
          %{}
        )
    """

    use Jido.Action,
      name: "comms_send_message",
      description: "Send a message through a communication channel",
      category: "comms",
      tags: ["comms", "messaging", "send"],
      schema: [
        channel: [
          type: :atom,
          required: true,
          doc: "Channel to send through (e.g. :signal, :email)"
        ],
        to: [type: :string, required: true, doc: "Recipient address"],
        message: [type: :string, required: true, doc: "Message body"],
        subject: [type: :string, doc: "Email subject (email channel only)"],
        attachments: [type: {:list, :string}, default: [], doc: "File paths to attach"],
        from: [type: :string, doc: "Sender address override"],
        format: [type: :boolean, default: true, doc: "Format message for channel constraints"]
      ]

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      channel = params.channel
      senders = Application.get_env(:arbor_actions, :channel_senders, %{})

      case Map.fetch(senders, channel) do
        {:ok, module} ->
          message =
            if params[:format] != false do
              module.format_for_channel(params.message)
            else
              params.message
            end

          opts =
            []
            |> maybe_add(:subject, params[:subject])
            |> maybe_add(:from, params[:from])
            |> maybe_add_list(:attachments, params[:attachments])

          case module.send_message(params.to, message, opts) do
            :ok ->
              result = %{channel: channel, to: params.to, status: :sent}
              Actions.emit_completed(__MODULE__, result)
              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, "Send failed on #{channel}: #{inspect(reason)}"}
          end

        :error ->
          available = senders |> Map.keys() |> Enum.join(", ")
          error = "Unknown channel :#{channel}. Available: #{available}"
          Actions.emit_failed(__MODULE__, error)
          {:error, error}
      end
    end

    defp maybe_add(opts, _key, nil), do: opts
    defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

    defp maybe_add_list(opts, _key, []), do: opts
    defp maybe_add_list(opts, _key, nil), do: opts
    defp maybe_add_list(opts, key, list), do: Keyword.put(opts, key, list)
  end

  defmodule PollMessages do
    @moduledoc """
    Poll a communication channel for new inbound messages.

    Resolves the channel module at runtime via `:channel_receivers` config,
    then calls `poll/0` on the resolved module.

    ## Examples

        Arbor.Actions.Comms.PollMessages.run(
          %{channel: :signal},
          %{}
        )

        Arbor.Actions.Comms.PollMessages.run(
          %{channel: :limitless, max_messages: 5},
          %{}
        )
    """

    use Jido.Action,
      name: "comms_poll_messages",
      description: "Poll a communication channel for new inbound messages",
      category: "comms",
      tags: ["comms", "messaging", "poll", "receive"],
      schema: [
        channel: [
          type: :atom,
          required: true,
          doc: "Channel to poll (e.g. :signal, :limitless)"
        ],
        max_messages: [
          type: :integer,
          default: 10,
          doc: "Maximum number of messages to return"
        ]
      ]

    @impl true
    def run(params, _context) do
      Actions.emit_started(__MODULE__, params)

      channel = params.channel
      receivers = Application.get_env(:arbor_actions, :channel_receivers, %{})

      case Map.fetch(receivers, channel) do
        {:ok, module} ->
          case module.poll() do
            {:ok, messages} ->
              max = params[:max_messages] || 10
              messages = Enum.take(messages, max)

              result = %{
                channel: channel,
                message_count: length(messages),
                messages: messages
              }

              Actions.emit_completed(__MODULE__, result)
              {:ok, result}

            {:error, reason} ->
              Actions.emit_failed(__MODULE__, reason)
              {:error, "Poll failed on #{channel}: #{inspect(reason)}"}
          end

        :error ->
          available = receivers |> Map.keys() |> Enum.join(", ")
          error = "Unknown channel :#{channel}. Available: #{available}"
          Actions.emit_failed(__MODULE__, error)
          {:error, error}
      end
    end
  end
end
