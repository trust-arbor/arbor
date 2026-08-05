defmodule Arbor.Persistence.Config do
  @moduledoc """
  Configuration seam for Persistence-owned backends.

  Vector storage remains disabled until an operator explicitly configures a
  concrete backend after the additive migration and cutover checks. A malformed
  configured module fails closed before dispatch.
  """

  alias Arbor.Persistence.VectorStore.Unsupported

  @doc "Returns the configured vector-store backend or the fail-closed adapter."
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
