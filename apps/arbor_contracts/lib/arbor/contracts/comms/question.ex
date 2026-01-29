defmodule Arbor.Contracts.Comms.Question do
  @moduledoc """
  A pending question from an agent to a human.

  Agents use questions to request human input when they encounter
  blockers, need decisions, or want clarification. Questions are
  sent via comms channels and answers are routed back to the
  requesting agent.

  ## Lifecycle

      pending → answered
      pending → expired
      pending → cancelled

  ## Display Hashes

  Each question gets a short display hash (e.g. "abc123") so humans
  can reference it in replies without typing full IDs:

      # Agent asks
      [abc123] Questions about: auth-redesign
      1. Should we use JWT or session tokens?
      2. Any latency constraints?

      # Human replies
      /answer abc123 JWT, and keep it under 50ms

  ## Usage

      question = Question.new(
        agent: :roadmap_brainstorm,
        correlation_id: "roadmap/1-brainstorming/auth-redesign.md",
        questions: ["Should we use JWT or session tokens?"],
        context: %{item_title: "Auth Redesign"}
      )
  """

  use TypedStruct

  typedstruct do
    @typedoc "A pending question from an agent"

    field(:id, String.t(), enforce: true)
    field(:agent, atom(), enforce: true)
    field(:correlation_id, String.t(), enforce: true)
    field(:questions, [String.t()], enforce: true)
    field(:display_hash, String.t(), enforce: true)
    field(:status, status(), default: :pending)
    field(:answer, String.t())
    field(:answered_at, DateTime.t())
    field(:answered_via, atom())
    field(:asked_at, DateTime.t(), enforce: true)
    field(:expires_at, DateTime.t())
    field(:sent_via, atom())
    field(:sent_to, String.t())
    field(:context, map(), default: %{})
  end

  @typedoc "Question lifecycle status"
  @type status :: :pending | :answered | :expired | :cancelled

  @doc """
  Create a new pending question.

  ## Required

  - `:agent` — atom identifying the requesting agent
  - `:correlation_id` — string to match answers back (e.g. roadmap item path)
  - `:questions` — list of question strings

  ## Optional

  - `:expires_at` — when this question expires
  - `:context` — additional context (item title, session info, etc.)
  """
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    struct!(__MODULE__,
      id: attrs[:id] || generate_id(),
      agent: Keyword.fetch!(attrs, :agent),
      correlation_id: Keyword.fetch!(attrs, :correlation_id),
      questions: Keyword.fetch!(attrs, :questions),
      display_hash: attrs[:display_hash] || generate_hash(),
      status: :pending,
      asked_at: attrs[:asked_at] || DateTime.utc_now(),
      expires_at: attrs[:expires_at],
      context: attrs[:context] || %{}
    )
  end

  @doc """
  Mark a question as answered.
  """
  @spec answer(t(), String.t(), atom()) :: t()
  def answer(%__MODULE__{} = q, answer_text, channel) do
    %{q | status: :answered, answer: answer_text, answered_at: DateTime.utc_now(), answered_via: channel}
  end

  @doc """
  Check if a question has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Check if a question is still pending (not answered, expired, or cancelled).
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: :pending} = q), do: not expired?(q)
  def pending?(%__MODULE__{}), do: false

  @doc """
  Format a question for sending via a text-based channel.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = q) do
    title = q.context[:item_title] || q.correlation_id

    header = "[#{q.display_hash}] Questions about: #{title}"

    body =
      q.questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, i} -> "#{i}. #{question}" end)

    footer = "Reply with: /answer #{q.display_hash} <your answer>"

    Enum.join([header, "", body, "", footer], "\n")
  end

  defp generate_id do
    "q_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp generate_hash do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower) |> binary_part(0, 6)
  end
end
