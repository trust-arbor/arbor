defmodule Arbor.Persistence.VectorStore.Unsupported do
  @moduledoc """
  Explicit fail-closed vector backend for deployments that disable vector storage.
  """

  @behaviour Arbor.Persistence.VectorStore

  @impl true
  def execute(_operation, _opts), do: {:error, :unsupported}

  @impl true
  def reconcile(_operation, _opts), do: {:error, :unsupported}

  @impl true
  def fetch(_identity, _opts), do: {:error, :unsupported}

  @impl true
  def list(_agent_id, _opts), do: {:error, :unsupported}

  @impl true
  def search(_agent_id, _vector, _opts), do: {:error, :unsupported}

  @impl true
  def destroy(_agent_id, _opts), do: {:error, :unsupported}
end
