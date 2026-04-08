defmodule Arbor.Contracts.Session.UserMessage do
  @moduledoc """
  Typed envelope for a user message at the entry boundary of a session.

  This is the **single source of truth** for "the user sent something". Every
  transport adapter (dashboard LiveView, CLI, ACP session, future
  Signal/Discord/Slack) builds a `UserMessage` with the most accurate
  `sent_at` timestamp it has access to, and hands it to `Session.send_message`.
  Session reads `sent_at` for the persisted user-entry timestamp instead of
  stamping `DateTime.utc_now/0` somewhere late in the pipeline.

  ## Why this exists

  Before this struct, "the user sent a message" flowed through the system as
  a bare `String.t()`. Adapters that knew the real send time (the dashboard
  has it, Signal/Discord/Slack get it from their platform) had nowhere to put
  it, so Session stamped a single `DateTime.utc_now/0` at *turn-end* and
  applied it to BOTH the user entry and the assistant entry. The persisted
  user/assistant timestamps were equal by construction. Restored chat
  history occasionally rendered the user message *after* the assistant
  response because the SessionEntry query had no deterministic tiebreaker
  on equal timestamps. (Patched in commit `24246be2` by bumping the
  assistant timestamp +1µs — that workaround can be removed once this
  envelope is in place and adapters carry the real `sent_at`.)

  This is also the structural fix for future Signal/Discord/Slack adapters,
  whose platforms provide timestamps that are more accurate than anything
  we could stamp on the server.

  ## Construction

  Adapters call one of the `from_*` constructors at the boundary:

      # Dashboard LiveView — sub-millisecond before sending to Session
      UserMessage.from_dashboard(content, agent_id)

      # Bare string fallback (CLI / Manager.chat / backwards compat)
      UserMessage.from_string(content)

      # Future adapters supply their own constructors:
      # UserMessage.from_signal_envelope(envelope)
      # UserMessage.from_discord_event(event)
      # UserMessage.from_slack_event(event)

  All constructors stamp `sent_at` from the most accurate source the
  transport provides; only `from_string/1` falls back to
  `DateTime.utc_now/0`.

  ## Convention

  The `:transport` tag exists so consumers can render different UI per
  source ("via Slack" vs "via dashboard"), and so future telemetry can
  group by transport. The `:transport_metadata` map is a free-form
  carry-along for adapter-specific fields (Discord channel ID, Slack
  thread_ts, Signal phone number, etc.) that don't deserve a top-level
  field.
  """

  use TypedStruct

  @type transport ::
          :dashboard | :cli | :acp | :signal | :discord | :slack | :http | nil

  typedstruct do
    @typedoc "A user message at the session entry boundary"

    field(:content, String.t(), enforce: true)
    field(:sent_at, DateTime.t(), enforce: true)
    field(:sender, String.t() | nil)
    field(:sender_id, String.t() | nil)
    field(:transport, transport())
    field(:transport_metadata, map(), default: %{})
  end

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Wrap a bare string with `DateTime.utc_now/0` for the timestamp.

  This is the backwards-compatibility fallback. Callers that have access to
  a more accurate `sent_at` should use a transport-specific constructor
  (`from_dashboard/2`, future `from_signal_envelope/1`, etc.) instead.

  ## Examples

      iex> msg = UserMessage.from_string("hello")
      iex> msg.content
      "hello"
      iex> %DateTime{} = msg.sent_at
      iex> msg.transport
      nil
  """
  @spec from_string(String.t()) :: t()
  def from_string(content) when is_binary(content) do
    %__MODULE__{
      content: content,
      sent_at: DateTime.utc_now()
    }
  end

  @doc """
  Build a UserMessage from a dashboard LiveView send-message handler.

  Captures the wall-clock moment the user clicked Send (sub-millisecond
  before the LiveView dispatches to Session). Tags the transport as
  `:dashboard` and sets `sender_id` to the agent_id of the LiveView
  context (typically `current_agent_id`).

  ## Parameters

  - `content` — the user's message text
  - `agent_id` — the principal id of whoever sent the message (the OIDC
    user, or `"human_dashboard"` in dev mode), used for `sender_id`

  ## Examples

      iex> msg = UserMessage.from_dashboard("hello", "human_alice")
      iex> msg.content
      "hello"
      iex> msg.transport
      :dashboard
      iex> msg.sender_id
      "human_alice"
  """
  @spec from_dashboard(String.t(), String.t() | nil) :: t()
  def from_dashboard(content, agent_id \\ nil) when is_binary(content) do
    %__MODULE__{
      content: content,
      sent_at: DateTime.utc_now(),
      sender_id: agent_id,
      transport: :dashboard
    }
  end

  @doc """
  Build a UserMessage from a CLI invocation (e.g. `Manager.chat/3`).

  CLI calls don't have a transport-provided timestamp — the user typed the
  command and pressed Enter, and we stamp `DateTime.utc_now/0` when we see
  the call. The `sender` parameter is the display name (e.g. `"User"`,
  `"Hysun"`, or whatever the CLI passes).

  ## Examples

      iex> msg = UserMessage.from_cli("hello", "Hysun")
      iex> msg.transport
      :cli
      iex> msg.sender
      "Hysun"
  """
  @spec from_cli(String.t(), String.t() | nil) :: t()
  def from_cli(content, sender \\ nil) when is_binary(content) do
    %__MODULE__{
      content: content,
      sent_at: DateTime.utc_now(),
      sender: sender,
      transport: :cli
    }
  end

  @doc """
  Coerce any of the accepted shapes (`%UserMessage{}`, bare string) into
  a `%UserMessage{}`. This is the convenience used by `Session.send_message`
  and `Manager.chat` so they can accept both shapes uniformly.

  ## Examples

      iex> UserMessage.coerce("hello") |> Map.get(:content)
      "hello"

      iex> existing = UserMessage.from_string("hi")
      iex> ^existing = UserMessage.coerce(existing)
  """
  @spec coerce(t() | String.t()) :: t()
  def coerce(%__MODULE__{} = msg), do: msg
  def coerce(content) when is_binary(content), do: from_string(content)
end
