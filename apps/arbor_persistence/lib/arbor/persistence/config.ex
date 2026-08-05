defmodule Arbor.Persistence.Config do
  @moduledoc """
  Configuration seam for Persistence-owned backends.

  Vector storage remains disabled until a concrete adapter is configured. A
  malformed configured module fails closed instead of reaching dispatch.
  """

  alias Arbor.Persistence.VectorStore.Unsupported

  @doc "Returns the configured vector-store backend or the explicit unsupported adapter."
  @spec vector_store_backend() :: {:ok, module()} | {:error, :invalid_config}
  def vector_store_backend do
    :arbor_persistence
    |> Application.get_env(:vector_store_backend, Unsupported)
    |> validate_vector_store_backend()
  end

  @doc "Validates a module atom without loading or invoking it."
  @spec validate_vector_store_backend(term()) :: {:ok, module()} | {:error, :invalid_config}
  def validate_vector_store_backend(backend) when is_atom(backend) and not is_nil(backend),
    do: {:ok, backend}

  def validate_vector_store_backend(_backend), do: {:error, :invalid_config}
end
