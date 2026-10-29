defmodule Arbor.Contracts.Comms.Engagement do
  @moduledoc """
  A device-independent conversation: the thing a user thinks of as "this thread
  with this agent," independent of which transport it physically flows through.

  One Engagement may have **one or more channels attached** (a dashboard tab, a
  Signal DM, a voice call) — same conversation, multiple transports. Channels are
  where messages physically enter/leave; the Engagement is what survives across
  reconnects, what gets parked/resumed, and what `Message.conversation_id` points
  at. Sessions key their per-conversation transcript on `(agent_id, id)`.

  This is the persisted record. The *live* Session pid is intentionally NOT a
  field — pids are transient (unserializable, change on restart), so the running
  Session is resolved at lookup time, not stored here.

  See `.arbor/roadmap/2-planned/channels-as-engagements.md`.

  ## Scope

  `scope` is how a new channel resolves to an Engagement (set at creation):

    * `:channel` (default) — each channel is its own Engagement (1:1). The
      (agent, channel) UX: each Signal DM / dashboard tab is a separate thread.
    * `:user` — the user has a root Engagement; their dashboard / Signal / voice
      channels all attach to it. The (agent) UX: one coherent context across
      devices.
    * `:role` — Engagement scoped to a workflow/team role; channels attach as
      participants join (shared on-call rooms, project channels).

  ## Visibility (audience class)

  `visibility` is the engagement's audience class. It drives discoverability and —
  critically — **memory disclosure gating**: the agent stores everything it learns
  (one unified per-agent memory) but may recall a memory from engagement *Y* into
  engagement *X* only when `audience(X) ⊆ audience(Y)` (never *widen* who hears
  it). The coarse tag is the fast default; the precise check is membership-set
  containment.

    * `:private` (default — fail-closed) — audience is one human (the
      initiator/owner). A 1:1 DM / TUI chat. Narrowest; never leaves the pair.
    * `:group` — a closed, enumerated set of humans (+ the agent). A Discord group.
    * `:internal` — agent-to-agent / system channels; no external human is party.
    * `:public` — open/unbounded; anyone may join (a public channel). Widest;
      content is recallable anywhere.

  Defaults to `:private` so a new engagement is non-disclosing until its audience
  is established. Membership (humans + agents party to the engagement) is the
  precise access-control truth `visibility` summarizes.
  """

  @type scope :: :channel | :user | :role
  @type status :: :active | :parked | :archived
  @type visibility :: :private | :group | :internal | :public

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          owner_tenant: String.t() | nil,
          attached_channels: [String.t()],
          scope: scope(),
          status: status(),
          visibility: visibility(),
          primary_channel: String.t() | nil,
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @enforce_keys [:agent_id]
  defstruct [
    :id,
    :agent_id,
    :owner_tenant,
    :primary_channel,
    :created_at,
    attached_channels: [],
    scope: :channel,
    status: :active,
    visibility: :private,
    metadata: %{}
  ]

  @doc """
  Create a new Engagement with an auto-generated id and `created_at`.

  Requires `:agent_id`. Defaults: `scope: :channel`, `status: :active`,
  `attached_channels: []`.
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    attrs =
      attrs
      |> Keyword.put_new(:id, generate_id())
      |> Keyword.put_new(:created_at, DateTime.utc_now())

    struct!(__MODULE__, attrs)
  end

  @doc "Attach a channel id to the engagement (idempotent)."
  @spec attach_channel(t(), String.t()) :: t()
  def attach_channel(%__MODULE__{attached_channels: channels} = engagement, channel_id)
      when is_binary(channel_id) do
    if channel_id in channels do
      engagement
    else
      %{engagement | attached_channels: channels ++ [channel_id]}
    end
  end

  @doc "Detach a channel id (the engagement persists even with no channels)."
  @spec detach_channel(t(), String.t()) :: t()
  def detach_channel(%__MODULE__{attached_channels: channels} = engagement, channel_id) do
    %{engagement | attached_channels: List.delete(channels, channel_id)}
  end

  defp generate_id do
    "eng_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
