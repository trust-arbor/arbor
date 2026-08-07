defmodule Arbor.Persistence.VectorStore do
  @moduledoc """
  Persistence-owned backend behaviour for validated vector transport values.

  Backends receive only canonical Contracts values and closed, normalized
  options from the public facade. Implementations remain responsible for
  atomic storage effects and validating durable values before return.
  """

  alias Arbor.Contracts.Persistence.{VectorMatch, VectorOperation, VectorReceipt, VectorRecord}

  @type backend_error ::
          :backend_failure
          | :closed
          | :conflict
          | :indeterminate
          | :not_found
          | :unsupported
  @type identity :: VectorRecord.identity()
  @type opts :: keyword()

  @doc "Executes one validated mutation or bounded atomic batch."
  @callback execute(VectorOperation.t(), opts()) ::
              {:ok, VectorReceipt.t()}
              | {:error, :backend_failure | :closed | :conflict | :indeterminate | :unsupported}

  @doc "Reconciles an operation from its canonical fingerprint-bound intent."
  @callback reconcile(VectorOperation.t(), opts()) ::
              {:ok, VectorReceipt.t()}
              | {:ok, :absent}
              | {:error, :backend_failure | :closed | :conflict | :indeterminate | :unsupported}

  @doc "Fetches one row by exact logical identity."
  @callback fetch(identity(), opts()) ::
              {:ok, VectorRecord.t()}
              | {:error, :backend_failure | :closed | :not_found | :unsupported}

  @doc "Lists a bounded tenant-owned row set using normalized filter options."
  @callback list(String.t(), opts()) ::
              {:ok, [VectorRecord.t()]}
              | {:error, :backend_failure | :closed | :unsupported}

  @doc """
  Searches using an exact normalized vector and closed Boundary options.

  Options are the deterministic seven-key keyword list:
  `model_id`, `dimensions`, `encoding`, `category`, `source_namespace`,
  `threshold` (`float | nil`), `limit`.
  """
  @callback search(String.t(), [float()], opts()) ::
              {:ok, [VectorMatch.t()]}
              | {:error, :backend_failure | :closed | :unsupported}

  @doc """
  Idempotently destroys exact-agent strict V1 rows and operation receipts, then
  closes the durable agent fence.
  """
  @callback destroy(String.t(), opts()) ::
              :ok | {:error, :backend_failure | :indeterminate | :unsupported}
end
