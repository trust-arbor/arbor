defmodule Arbor.Persistence.Config do
  @moduledoc """
  Configuration seam for Persistence-owned backends.

  Vector storage defaults to the library-owned Ecto adapter. Deployments may
  configure another behaviour implementation or the explicit Unsupported
  adapter. A malformed module value fails closed before dispatch.
  """

  alias Arbor.Persistence.VectorStore.Ecto, as: EctoVectorStore

  @doc "Returns the configured vector-store backend or the library-owned Ecto adapter."
  @spec vector_store_backend() :: {:ok, module()} | {:error, :invalid_config}
  def vector_store_backend do
    :arbor_persistence
    |> Application.get_env(:vector_store_backend, EctoVectorStore)
    |> validate_vector_store_backend()
  end

  @doc "Validates a module atom without loading or invoking it."
  @spec validate_vector_store_backend(term()) :: {:ok, module()} | {:error, :invalid_config}
  def validate_vector_store_backend(backend) when is_atom(backend) and not is_nil(backend),
    do: {:ok, backend}

  def validate_vector_store_backend(_backend), do: {:error, :invalid_config}
end
