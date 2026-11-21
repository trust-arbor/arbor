defmodule Arbor.Contracts.Comms.Interaction do
  @moduledoc """
  A request from an agent for human input — approval, clarification,
  decision, confirmation, notification, or escalation.

  Interactions are the unit routed by `Arbor.Comms.InteractionRouter`
  to the human's currently-active interface. The agent submits an
  interaction non-blocking; the response arrives asynchronously via
  the per-agent PubSub topic.

  Multi-node correct from the start: the `request_id` is the routing
  key. Persistent storage of the interaction record lets channel
  adapters look up where to route a response without holding agent
  state, which means channel adapters on Node B can route responses
  to agents waiting on Node A.

  See `.arbor/roadmap/1-brainstorming/human-in-the-loop-router.md` for
  the design context.
  """

  use TypedStruct

  @typedoc """
  Interaction kind. Approval is the immediate Phase 1 use case;
  clarification/confirmation/decision/notification/escalation are
  planned for later phases and included in the type so adapters can
  pattern-match without breaking API.
  """
  @type kind ::
          :approval | :clarification | :confirmation | :decision | :notification | :escalation

  @typedoc """
  Urgency hints to routing — `:critical` may broadcast to all channels
  simultaneously, `:low` may queue.
  """
  @type urgency :: :low | :normal | :high | :critical

  @typedoc """
  Response shape. `:approved`/`:rejected` are the approval kind's
  responses; later kinds extend this.
  """
  @type response ::
          :approved | :rejected | :acknowledged | {:text, String.t()} | {:choice, term()}

  typedstruct enforce: true do
    @typedoc "An interaction request awaiting human response."

    field(:request_id, String.t())
    field(:kind, kind())
    field(:agent_id, String.t())
    # The human principal the interaction is targeted at. Often resolved
    # from the agent's operator at submission time.
    field(:user_id, String.t())
    # Short prose for the human to read.
    field(:description, String.t())
    # Free-form metadata (the original Consensus proposal, capability ID,
    # context for the LLM's question, etc.). Channel adapters can pull
    # what they need from here.
    field(:metadata, map(), default: %{})
    # Resource URI for approval kind; may be nil for other kinds.
    field(:resource_uri, String.t() | nil, enforce: false)
    field(:urgency, urgency(), default: :normal)
    # Wall-clock cutoff. After this passes, the router may escalate or
    # mark the interaction abandoned. ISO 8601 string.
    field(:expires_at, DateTime.t() | nil, enforce: false)
    # The PubSub topic the waiting agent subscribes to for the response.
    # Defaults to "interaction:agent:" <> agent_id.
    field(:response_topic, String.t())
    # When the interaction was submitted (UTC).
    field(:submitted_at, DateTime.t())
  end

  @doc """
  Construct a new interaction request. Fills in defaults (request_id,
  response_topic, submitted_at) and validates the required fields.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: new(Enum.into(attrs, %{}))

  def new(%{} = attrs) do
    agent_id = Map.get(attrs, :agent_id) || Map.get(attrs, "agent_id")

    if agent_id in [nil, ""] do
      {:error, :agent_id_required}
    else
      request_id = Map.get(attrs, :request_id) || Map.get(attrs, "request_id") || generate_id()

      interaction = %__MODULE__{
        request_id: request_id,
        kind: pick(attrs, :kind) || :approval,
        agent_id: agent_id,
        user_id: pick(attrs, :user_id) || "system",
        description: pick(attrs, :description) || "",
        metadata: pick(attrs, :metadata) || %{},
        resource_uri: pick(attrs, :resource_uri),
        urgency: pick(attrs, :urgency) || :normal,
        expires_at: pick(attrs, :expires_at),
        response_topic: pick(attrs, :response_topic) || "interaction:agent:#{agent_id}",
        submitted_at: pick(attrs, :submitted_at) || DateTime.utc_now()
      }

      {:ok, interaction}
    end
  end

  @doc "Default response topic for an agent."
  @spec response_topic_for_agent(String.t()) :: String.t()
  def response_topic_for_agent(agent_id) when is_binary(agent_id) do
    "interaction:agent:#{agent_id}"
  end

  defp pick(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp generate_id do
    "irq_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
