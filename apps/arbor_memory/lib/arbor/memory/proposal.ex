defmodule Arbor.Memory.Proposal do
  @moduledoc """
  Unified proposal queue for the "subconscious proposes, agent decides" pattern.

  Proposals are suggestions from background processes that await agent review
  before integration into goal, intent, or knowledge authorities.

  Storage is owned by the supervised `Arbor.Memory.Proposal.Store` (ephemeral
  process map). The legacy public ETS table `:arbor_memory_proposals` is not
  read or written by production proposal code.
  """

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.Proposal.Store

  @type proposal_type ::
          :fact
          | :insight
          | :learning
          | :pattern
          | :preconscious
          | :goal
          | :goal_update
          | :thought
          | :concern
          | :curiosity
          | :identity
          | :intent
          | :cognitive_mode

  @type proposal_status :: :pending | :accepted | :rejected | :deferred

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          type: proposal_type(),
          content: String.t(),
          confidence: float(),
          source: String.t() | nil,
          evidence: [String.t()],
          metadata: map(),
          created_at: DateTime.t(),
          status: proposal_status()
        }

  @enforce_keys [:id, :agent_id, :type, :content]
  defstruct [
    :id,
    :agent_id,
    :type,
    :content,
    confidence: 0.5,
    source: nil,
    evidence: [],
    metadata: %{},
    created_at: nil,
    status: :pending
  ]

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Create a proposal with conservative missing provenance (raw compatibility).
  """
  @spec create(String.t(), proposal_type(), map()) ::
          {:ok, t()} | {:ok, :reinforced} | {:error, term()}
  def create(agent_id, type, data) do
    create_tainted(agent_id, type, data, TaintEnvelope.missing_fallback(), :legacy_unlabeled)
  end

  @doc """
  Create a proposal with an explicit caller-supplied taint label (strict).
  """
  @spec create_tainted(String.t(), proposal_type(), map(), Taint.t()) ::
          {:ok, t()} | {:ok, :reinforced} | {:error, term()}
  def create_tainted(agent_id, type, data, taint) do
    create_tainted(agent_id, type, data, taint, :verified)
  end

  @doc false
  @spec create_tainted(String.t(), proposal_type(), map(), Taint.t(), provenance_status()) ::
          {:ok, t()} | {:ok, :reinforced} | {:error, term()}
  def create_tainted(agent_id, type, data, taint, provenance_status) do
    case Store.create(agent_id, type, data, taint, provenance_status) do
      {:ok, :reinforced} -> {:ok, :reinforced}
      {:ok, proposal} -> {:ok, to_struct(proposal)}
      {:error, _} = error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "List pending proposals (raw; after exact sidecar verification)."
  @spec list_pending(String.t(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list_pending(agent_id, opts \\ []) do
    case list_pending_tainted(agent_id, opts) do
      {:ok, items} ->
        {:ok, Enum.map(items, fn {%TaintedValue{value: proposal}, _status} -> proposal end)}

      {:error, _} = error ->
        error
    end
  end

  @doc "List pending proposals with taint and explicit provenance status."
  @spec list_pending_tainted(String.t(), keyword()) ::
          {:ok, [{TaintedValue.t(), provenance_status()}]} | {:error, term()}
  def list_pending_tainted(agent_id, opts \\ []) do
    case Store.list_pending_tainted(agent_id, opts) do
      {:ok, items} ->
        {:ok,
         Enum.map(items, fn {%TaintedValue{value: value, taint: taint}, status} ->
           {TaintedValue.wrap(to_struct(value), taint), status}
         end)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Get a proposal by id (raw; after exact sidecar verification)."
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(agent_id, proposal_id) do
    case get_tainted(agent_id, proposal_id) do
      {:ok, %TaintedValue{value: proposal}, _status} -> {:ok, proposal}
      {:error, _} = error -> error
    end
  end

  @doc "Get a proposal with taint and explicit provenance status."
  @spec get_tainted(String.t(), String.t()) ::
          {:ok, TaintedValue.t(), provenance_status()} | {:error, term()}
  def get_tainted(agent_id, proposal_id) do
    case Store.get_tainted(agent_id, proposal_id) do
      {:ok, %TaintedValue{value: value, taint: taint}, status} ->
        {:ok, TaintedValue.wrap(to_struct(value), taint), status}

      {:error, _} = error ->
        error
    end
  end

  @doc "Count pending proposals."
  @spec count_pending(String.t(), keyword()) :: non_neg_integer()
  def count_pending(agent_id, opts \\ []) do
    case Store.count_pending(agent_id, opts) do
      n when is_integer(n) -> n
      {:error, _} -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Review
  # ---------------------------------------------------------------------------

  @doc "Accept a proposal through its single target authority (raw decision taint)."
  @spec accept(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def accept(agent_id, proposal_id) do
    accept_tainted(agent_id, proposal_id, TaintEnvelope.missing_fallback(), :legacy_unlabeled)
  end

  @doc "Accept a proposal with an explicit decision taint (strict)."
  @spec accept_tainted(String.t(), String.t(), Taint.t()) ::
          {:ok, String.t()} | {:error, term()}
  def accept_tainted(agent_id, proposal_id, taint) do
    accept_tainted(agent_id, proposal_id, taint, :verified)
  end

  @doc false
  def accept_tainted(agent_id, proposal_id, taint, status) do
    Store.accept(agent_id, proposal_id, taint, status)
  end

  @doc "Reject a proposal (raw decision taint)."
  @spec reject(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject(agent_id, proposal_id, opts \\ []) do
    reject_tainted(
      agent_id,
      proposal_id,
      opts,
      TaintEnvelope.missing_fallback(),
      :legacy_unlabeled
    )
  end

  @doc "Reject a proposal with an explicit decision taint (strict)."
  @spec reject_tainted(String.t(), String.t(), keyword(), Taint.t()) ::
          :ok | {:error, term()}
  def reject_tainted(agent_id, proposal_id, opts, taint) do
    reject_tainted(agent_id, proposal_id, opts, taint, :verified)
  end

  @doc false
  def reject_tainted(agent_id, proposal_id, opts, taint, status) do
    Store.reject(agent_id, proposal_id, opts, taint, status)
  end

  @doc "Defer a proposal (raw decision taint)."
  @spec defer(String.t(), String.t()) :: :ok | {:error, term()}
  def defer(agent_id, proposal_id) do
    defer_tainted(agent_id, proposal_id, TaintEnvelope.missing_fallback(), :legacy_unlabeled)
  end

  @doc "Defer a proposal with an explicit decision taint (strict)."
  @spec defer_tainted(String.t(), String.t(), Taint.t()) :: :ok | {:error, term()}
  def defer_tainted(agent_id, proposal_id, taint) do
    defer_tainted(agent_id, proposal_id, taint, :verified)
  end

  @doc false
  def defer_tainted(agent_id, proposal_id, taint, status) do
    Store.defer(agent_id, proposal_id, taint, status)
  end

  @doc "Undefer a proposal (raw decision taint)."
  @spec undefer(String.t(), String.t()) :: :ok | {:error, term()}
  def undefer(agent_id, proposal_id) do
    undefer_tainted(agent_id, proposal_id, TaintEnvelope.missing_fallback(), :legacy_unlabeled)
  end

  @doc "Undefer a proposal with an explicit decision taint (strict)."
  @spec undefer_tainted(String.t(), String.t(), Taint.t()) :: :ok | {:error, term()}
  def undefer_tainted(agent_id, proposal_id, taint) do
    undefer_tainted(agent_id, proposal_id, taint, :verified)
  end

  @doc false
  def undefer_tainted(agent_id, proposal_id, taint, status) do
    Store.undefer(agent_id, proposal_id, taint, status)
  end

  @doc """
  Accept all pending proposals.

  When every attempt succeeds: `{:ok, [{proposal_id, target_id}, ...]}`.
  When any fails: `{:error, {:batch_incomplete, ordered_results}}` with every
  attempt's bounded result in deterministic order.
  """
  @spec accept_all(String.t(), proposal_type() | nil) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, {:batch_incomplete, list()} | term()}
  def accept_all(agent_id, type \\ nil) do
    Store.accept_all(
      agent_id,
      type,
      TaintEnvelope.missing_fallback(),
      :legacy_unlabeled
    )
  end

  @doc "Delete one proposal."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(agent_id, proposal_id), do: Store.delete(agent_id, proposal_id)

  @doc """
  Delete all proposals for an agent (compatibility wrapper).

  Returns `:ok` only when content is authoritatively absent after deletion.
  """
  @spec delete_all(String.t()) :: :ok | {:error, term()}
  def delete_all(agent_id) do
    case Store.delete_agent_content(agent_id) do
      :ok ->
        case Store.agent_content_absent?(agent_id) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, :absence_uncertain}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Idempotent agent-content delete for the proposal owner."
  @spec delete_agent_content(String.t()) :: :ok | {:error, term()}
  def delete_agent_content(agent_id), do: Store.delete_agent_content(agent_id)

  @doc "Authoritative absence check for proposal content."
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def agent_content_absent?(agent_id), do: Store.agent_content_absent?(agent_id)

  @doc "Get statistics about proposals for an agent."
  @spec stats(String.t()) :: map()
  def stats(agent_id) do
    case Store.stats(agent_id) do
      {:ok, stats} ->
        stats

      {:error, _} ->
        %{
          total: 0,
          pending: 0,
          accepted: 0,
          rejected: 0,
          deferred: 0,
          by_type: %{},
          avg_confidence: 0.0
        }
    end
  end

  defp to_struct(%__MODULE__{} = proposal), do: proposal

  defp to_struct(map) when is_map(map) do
    %__MODULE__{
      id: Map.fetch!(map, :id),
      agent_id: Map.fetch!(map, :agent_id),
      type: Map.fetch!(map, :type),
      content: Map.fetch!(map, :content),
      confidence: Map.get(map, :confidence, 0.5),
      source: Map.get(map, :source),
      evidence: Map.get(map, :evidence, []),
      metadata: Map.get(map, :metadata, %{}),
      created_at: Map.get(map, :created_at),
      status: Map.get(map, :status, :pending)
    }
  end
end
