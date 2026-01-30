defmodule Arbor.Contracts.Comms.QuestionRegistry do
  @moduledoc """
  Behaviour for managing pending agent questions.

  The question registry tracks questions from agents to humans,
  matches inbound answers to pending questions, and notifies
  agents when their questions are answered.

  ## Persistence

  Implementations should use `Arbor.Persistence.QueryableStore`
  for backing storage, making the persistence layer pluggable
  (ETS for dev, Postgres for production).

  ## Notification

  When a question is answered, the registry broadcasts via
  `Arbor.Signals`:

      {:comms, :question_answered, %{
        question_id: "q_abc123",
        agent: :roadmap_brainstorm,
        correlation_id: "roadmap/1-brainstorming/item.md",
        answer: "Use approach B"
      }}

  Agents subscribe to these signals to receive answers.

  ## Example

      # Agent asks a question
      {:ok, question} = Registry.ask(:roadmap_brainstorm,
        correlation_id: "roadmap/item.md",
        questions: ["JWT or sessions?"],
        send_via: :signal,
        send_to: "+1XXXXXXXXXX"
      )

      # Human answers via /answer command (prefix match)
      :ok = Registry.answer("abc", "JWT", :signal)

      # Agent receives signal
      handle_signal(:comms, :question_answered, payload)
  """

  alias Arbor.Contracts.Comms.Question

  @doc """
  Submit a question from an agent. Persists it and sends via comms.

  ## Options

  - `:correlation_id` (required) — matches answers back to context
  - `:questions` (required) — list of question strings
  - `:send_via` — channel to send the question on (default: :signal)
  - `:send_to` — recipient identifier
  - `:expires_at` — when the question expires
  - `:context` — additional context map
  """
  @callback ask(agent :: atom(), opts :: keyword()) ::
              {:ok, Question.t()} | {:error, term()}

  @doc """
  Answer a question by its display hash (or prefix).

  Uses `find_by_hash/1` to locate the question via prefix matching,
  marks it answered, persists the update, and broadcasts a signal
  to the requesting agent.
  """
  @callback answer(hash_prefix :: String.t(), answer :: String.t(), channel :: atom()) ::
              :ok | {:error, :not_found | :ambiguous | :already_answered | :expired}

  @doc """
  List pending questions, optionally filtered by agent.
  """
  @callback pending(opts :: keyword()) :: [Question.t()]

  @doc """
  Look up a pending question by display hash prefix.

  Matches any pending question whose `display_hash` starts with
  the given prefix. Returns `{:error, :ambiguous}` if the prefix
  matches more than one pending question — the caller should ask
  the human to provide more characters.

  ## Examples

      # Full hash
      find_by_hash("abc123")  #=> {:ok, %Question{}}

      # Prefix — unambiguous
      find_by_hash("abc")     #=> {:ok, %Question{}}

      # Prefix — multiple matches
      find_by_hash("a")       #=> {:error, :ambiguous}
  """
  @callback find_by_hash(hash_prefix :: String.t()) ::
              {:ok, Question.t()} | {:error, :not_found | :ambiguous}

  @doc """
  Cancel a pending question.
  """
  @callback cancel(question_id :: String.t()) :: :ok | {:error, :not_found}

  @doc """
  Expire questions past their expiration time. Called periodically.
  """
  @callback expire_stale() :: non_neg_integer()
end
