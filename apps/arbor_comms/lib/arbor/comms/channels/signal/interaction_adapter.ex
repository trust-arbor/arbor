defmodule Arbor.Comms.Channels.Signal.InteractionAdapter do
  @moduledoc """
  Signal channel adapter for `Arbor.Comms.InteractionRouter`.

  Delivers interaction requests to the operator's phone via signal-cli
  and parses APPROVE / DENY replies back into router responses.

  ## Message format

  Outbound (sent to the operator):

      🔒 Agent <agent_id> needs approval:

      <description>

      Reply: APPROVE <request_id> or DENY <request_id>

  Inbound (parsed back into a response): the first word of the message
  must be one of `APPROVE`/`YES`/`OK` or `DENY`/`REJECT`/`NO` (case
  insensitive). The message must also include the `irq_<hex>` request
  id so multi-pending requests don't collide — if no id is found, the
  message is treated as regular chat (`:not_interaction`).

  ## Configuration

      config :arbor_comms, :signal,
        enabled: true,
        account: "+1...",
        interaction_user_id: "hysun",
        interaction_recipient: "+1..."

  The `:interaction_user_id` is the Arbor user_id whose interactions
  this Signal account receives. The `:interaction_recipient` is the
  phone number to send approval requests to (usually that user's
  device). When both are set and `:enabled` is true,
  `Arbor.Comms.Channels.Signal.PresenceKeeper` keeps a "Signal is
  always present for this user" registration in `PresenceTracker`, so
  the router can route to Signal when no other channel (e.g.,
  dashboard) is more recently active.
  """

  @behaviour Arbor.Contracts.Comms.ChannelAdapter

  require Logger

  alias Arbor.Comms.Channels.Signal
  alias Arbor.Contracts.Comms.Interaction

  # Request IDs are `irq_<16 hex chars>` — see `Interaction.generate_id/0`.
  @request_id_regex ~r/(irq_[a-f0-9]{16})/

  # First-word matchers. Case-insensitive; allow common synonyms.
  @approve_regex ~r/^\s*(APPROVE|APPROVED|YES|Y|OK|ACK)\b/i
  @deny_regex ~r/^\s*(DENY|DENIED|REJECT|REJECTED|NO|N|NACK)\b/i

  # Signal has a hard 2000-char outbound limit; the body of an
  # interaction description is operator-authored and untrusted in
  # length. Cap the description so the overhead + tail still fits.
  @description_budget 1500

  @impl true
  def channel_kind, do: :signal

  @impl true
  @doc """
  Send the interaction as a Signal message. The recipient phone is
  resolved from (in priority order): the channel_meta provided by
  PresenceTracker (typically `%{phone: "+1..."}`), the interaction's
  metadata `:signal_recipient` key, then the app-config
  `:interaction_recipient`.

  Returns `:ok` or `{:error, reason}`; the router treats any error as
  "queue this interaction; some other route or retry will deliver."
  """
  def send_interaction(channel_meta, %Interaction{} = interaction) do
    case recipient_from(channel_meta, interaction) do
      nil ->
        {:error, :no_signal_recipient}

      phone when is_binary(phone) ->
        Signal.send_message(phone, format_message(interaction))
    end
  end

  @impl true
  @doc """
  Parse an inbound Signal message. Returns
  `{:interaction_response, request_id, response, metadata}` when the
  message looks like an approval response — first-word match against
  APPROVE/DENY (or synonyms) AND contains a recognizable `irq_<hex>`
  request id.

  Returns `:not_interaction` for plain chat traffic so the inbound
  router can dispatch normally.
  """
  def parse_response(raw) when is_binary(raw) do
    decision =
      cond do
        Regex.match?(@approve_regex, raw) -> :approved
        Regex.match?(@deny_regex, raw) -> :rejected
        true -> nil
      end

    request_id = extract_request_id(raw)

    case {decision, request_id} do
      {nil, _} ->
        :not_interaction

      {_, nil} ->
        :not_interaction

      {response, rid} ->
        {:interaction_response, rid, response, %{channel: :signal, raw: raw}}
    end
  end

  def parse_response(_), do: :not_interaction

  # ──────────────────────────────────────────────────────────────────

  defp format_message(%Interaction{} = i) do
    description = String.slice(to_string(i.description || ""), 0, @description_budget)

    """
    🔒 Agent #{i.agent_id} needs approval:

    #{description}

    Reply: APPROVE #{i.request_id} or DENY #{i.request_id}
    """
    |> String.trim()
  end

  defp extract_request_id(text) when is_binary(text) do
    case Regex.run(@request_id_regex, text) do
      [_, rid] -> rid
      [rid] -> rid
      _ -> nil
    end
  end

  defp recipient_from(channel_meta, %Interaction{} = interaction) do
    cond do
      is_map(channel_meta) and is_binary(Map.get(channel_meta, :phone)) ->
        Map.get(channel_meta, :phone)

      is_map(channel_meta) and is_binary(Map.get(channel_meta, "phone")) ->
        Map.get(channel_meta, "phone")

      is_binary(Map.get(interaction.metadata, :signal_recipient)) ->
        Map.get(interaction.metadata, :signal_recipient)

      is_binary(Map.get(interaction.metadata, "signal_recipient")) ->
        Map.get(interaction.metadata, "signal_recipient")

      true ->
        config_recipient()
    end
  end

  defp config_recipient do
    case Application.get_env(:arbor_comms, :signal, []) do
      kw when is_list(kw) -> Keyword.get(kw, :interaction_recipient)
      _ -> nil
    end
  end
end
