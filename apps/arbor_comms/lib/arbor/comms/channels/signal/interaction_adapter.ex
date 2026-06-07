defmodule Arbor.Comms.Channels.Signal.InteractionAdapter do
  @moduledoc """
  Signal channel adapter for `Arbor.Comms.InteractionRouter`.

  Delivers interaction requests to the operator's phone via signal-cli
  and parses APPROVE / DENY replies back into router responses.

  ## Message format

  Outbound (sent to the operator):

      🔒 Agent <agent_id> needs approval:

      <description>

      Reply: APPROVE or DENY
      (id: <request_id> — include if multiple pending)

  Inbound: the first word must match an APPROVE / DENY synonym
  (YES/OK/Y/NO/N/REJECT/ACK/NACK, case-insensitive). The `irq_<hex>`
  request id is OPTIONAL on the reply.

    * Reply WITH the id → `{:interaction_response, id, response, meta}`.
      The router routes directly. Use this when multiple approvals
      are pending and you need to disambiguate.

    * Reply WITHOUT the id → `{:interaction_response_partial, response,
      meta}`. The router looks up pending interactions for the
      sender's user_id: zero → treat as chat; one → use it; multiple
      → an automatic Signal reply lists the pending requests and the
      operator's reply is held off until they re-send with an id.

  The mobile-Signal UX motivation: tapping/long-pressing to extract a
  long hex string is slow; the common case (one pending approval)
  should accept a one-word reply.

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
  Parse an inbound Signal message into a `ChannelAdapter.parse_result`.

  Decision-word match on the first content word (APPROVE/DENY +
  synonyms, case-insensitive). The `irq_<hex>` id is optional.

    * decision + id → `{:interaction_response, id, response, meta}`
    * decision only → `{:interaction_response_partial, response, meta}`
    * neither → `:not_interaction`

  See the moduledoc for the multi-pending disambiguation flow the
  router uses on the partial path.
  """
  def parse_response(raw) when is_binary(raw) do
    decision =
      cond do
        Regex.match?(@approve_regex, raw) -> :approved
        Regex.match?(@deny_regex, raw) -> :rejected
        true -> nil
      end

    request_id = extract_request_id(raw)
    meta = %{channel: :signal, raw: raw}

    case {decision, request_id} do
      {nil, _} ->
        :not_interaction

      {response, nil} ->
        {:interaction_response_partial, response, meta}

      {response, rid} ->
        {:interaction_response, rid, response, meta}
    end
  end

  def parse_response(_), do: :not_interaction

  # ──────────────────────────────────────────────────────────────────

  defp format_message(%Interaction{} = i) do
    description = String.slice(to_string(i.description || ""), 0, @description_budget)

    """
    🔒 Agent #{i.agent_id} needs approval:

    #{description}

    Reply: APPROVE or DENY
    (id: #{i.request_id} — include if multiple pending)
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
