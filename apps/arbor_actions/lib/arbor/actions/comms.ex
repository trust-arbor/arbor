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

    def taint_roles do
      %{
        channel: :control,
        to: :control,
        message: :data,
        subject: :data,
        attachments: {:control, requires: [:path_traversal]},
        from: :control,
        format: :data
      }
    end

    # Egress classification (2026-06-14 decision): sending a message bridges to an
    # external service (Signal, Email) — agent-authored content leaves to a fixed
    # third-party provider. :external_provider via the reader's fail-closed
    # default. (PollMessages is ingress — covered by its output_taint, not gated.)
    def effect_class, do: :network_egress

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

    def taint_roles do
      %{
        channel: :control,
        max_messages: :data
      }
    end

    # Provenance (taint-tracking-rebuild Phase 1): polled messages come from
    # external senders (Slack/email/etc.) — untrusted content crossing the
    # trust boundary, a prime prompt-injection vector.
    @doc false
    def output_taint, do: :untrusted

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

  defmodule NotifySession do
    @moduledoc """
    Post a proactive, agent-initiated message into the agent's own chat session
    (the A1 proactive notify channel).

    Callable from heartbeat pipelines so an agent can surface progress or a thought
    to the user *without* waiting for a turn — the old 💭 affordance, returned as a
    governed channel. Emits an `:agent` / `:notification` signal; the dashboard
    subscribes to `agent.*` and renders it as a visually-distinct agent-initiated
    message.

    ## Governance

    Gated by the `arbor://comms/notify/session` capability (default mode **allow** +
    a rate-limit constraint as the anti-spam budget; the user dials block/ask/auto
    in their trust profile). **Egress-classed** (`:network_egress`): the notify
    channel is an output boundary — agent-authored, possibly taint-derived content
    reaches the user — so the egress ceiling + taint conjunct apply. The destination
    is the user's session: `on_host` for a local dashboard (allowed), and a
    remote/multi-user session would resolve to its host here and gate accordingly.

    ## Examples

        Arbor.Actions.Comms.NotifySession.run(
          %{text: "Finished the dependency audit — 3 findings, posting details.", kind: :progress},
          %{agent_id: "agent_abc", session_id: "sess_1"}
        )
    """

    use Jido.Action,
      name: "comms_notify_session",
      description: "Post a proactive agent-initiated message into the session's chat channel",
      category: "comms",
      tags: ["comms", "notify", "proactive", "heartbeat"],
      schema: [
        text: [type: :string, required: true, doc: "Message to surface to the user"],
        kind: [
          type: :atom,
          default: :notification,
          doc: "Notification kind: :notification | :thought | :progress"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{text: :data, kind: :control}
    end

    # Egress classification (A1, 2026-06-15): the notify channel is an output
    # boundary — agent-authored content reaches the user. Classed :network_egress
    # so the egress ceiling + taint conjunct apply; the tier resolves from the
    # session destination (egress_destination/2 → on_host for a local session).
    def effect_class, do: :network_egress

    # A local dashboard session lives on the same host (loopback) → :on_host →
    # allowed. A remote/multi-user session would resolve to its actual host here
    # once that lands, gating per the egress posture.
    def egress_destination(_params, _context), do: "localhost"

    @doc """
    Default rate-limit budget (tokens per `rate_limit_refill_period_seconds`, 1h by
    default) for the notify capability — the anti-spam budget behind the
    allow-by-default trust posture. Applied as the `:rate_limit` constraint when the
    `arbor://comms/notify/session` capability is granted to an agent. Tunable via
    `config :arbor_actions, :notify_session_rate_limit`.
    """
    @spec default_rate_limit() :: pos_integer()
    def default_rate_limit,
      do: Application.get_env(:arbor_actions, :notify_session_rate_limit, 30)

    @impl true
    def run(params, context) do
      Actions.emit_started(__MODULE__, params)

      agent_id = context_get(context, :agent_id, "session.agent_id")
      session_id = context_get(context, :session_id, "session.session_id")
      kind = params[:kind] || :notification

      data = %{
        agent_id: agent_id,
        session_id: session_id,
        text: params.text,
        kind: kind,
        source: :heartbeat
      }

      # `agent.notification` → the dashboard's `agent.*` subscription; it filters by
      # agent_id and renders proactive messages distinctly.
      Arbor.Signals.emit(:agent, :notification, data)

      result = %{status: :notified, kind: kind, agent_id: agent_id}
      Actions.emit_completed(__MODULE__, result)
      {:ok, result}
    rescue
      e ->
        Actions.emit_failed(__MODULE__, Exception.message(e))
        {:error, "notify_session failed: #{Exception.message(e)}"}
    end

    # Context may be atom-keyed (direct calls) or string-keyed "session.*" (engine).
    defp context_get(context, atom_key, string_key) do
      Map.get(context, atom_key) || Map.get(context, string_key)
    end
  end
end
