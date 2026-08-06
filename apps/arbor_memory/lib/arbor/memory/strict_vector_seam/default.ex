defmodule Arbor.Memory.StrictVectorSeam.Default do
  @moduledoc false

  # Sole production implementation that may call Arbor.Memory.Embedding strict APIs.

  @behaviour Arbor.Memory.StrictVectorSeam

  alias Arbor.Memory.Embedding

  @impl true
  def encode_operation(input), do: Embedding.encode_strict_operation(input)

  @impl true
  def encode_batch(inputs), do: Embedding.encode_strict_batch(inputs)

  @impl true
  def execute(agent_id, input_or_operation, opts \\ []),
    do: Embedding.execute_strict(agent_id, input_or_operation, opts)

  @impl true
  def reconcile(agent_id, input_or_operation, opts \\ []),
    do: Embedding.reconcile_strict(agent_id, input_or_operation, opts)

  @impl true
  def search(agent_id, vector, opts \\ []),
    do: Embedding.search_strict(agent_id, vector, opts)

  @impl true
  def fetch(agent_id, source_namespace, source_key, opts \\ []),
    do: Embedding.fetch_strict(agent_id, source_namespace, source_key, opts)

  @impl true
  def list(agent_id, opts \\ []), do: Embedding.list_strict(agent_id, opts)
end
