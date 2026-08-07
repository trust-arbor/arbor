defmodule Arbor.Memory.StrictVectorSeam do
  @moduledoc false

  # Owner-controlled injectable seam for Memory durable semantic vector I/O.
  # Selected only from Index process start options or trusted application config.
  # Production owners (Index, IndexOps, Retrieval, MemoryStore) resolve this seam;
  # only the Default implementation calls Arbor.Memory.Embedding strict APIs.

  @type agent_id :: String.t()
  @type opts :: keyword()

  @callback encode_operation(term()) ::
              {:ok, Arbor.Contracts.Persistence.VectorOperation.t(), map()} | {:error, atom()}

  @callback encode_batch(term()) ::
              {:ok, Arbor.Contracts.Persistence.VectorOperation.t(), [map()]} | {:error, atom()}

  @callback execute(agent_id(), term(), opts()) :: {:ok, term()} | {:error, term()}

  @callback reconcile(agent_id(), term(), opts()) ::
              {:ok, term()} | {:ok, :absent} | {:error, term()}

  @callback search(agent_id(), term(), opts()) :: {:ok, [map()]} | {:error, term()}

  @callback fetch(agent_id(), String.t(), String.t(), opts()) ::
              {:ok, map()} | {:error, term()}

  @callback list(agent_id(), opts()) :: {:ok, [map()]} | {:error, term()}

  @callback destroy(agent_id(), opts()) :: :ok | {:error, term()}

  @doc "Resolve the trusted seam module for non-Index callers."
  @spec resolve() :: module()
  def resolve do
    Application.get_env(
      :arbor_memory,
      :strict_vector_seam,
      Arbor.Memory.StrictVectorSeam.Default
    )
  end

  @doc "Resolve seam from Index start opts, else trusted application config."
  @spec resolve(keyword()) :: module()
  def resolve(opts) when is_list(opts) do
    Keyword.get_lazy(opts, :strict_vector_seam, &resolve/0)
  end
end
