defmodule Arbor.Trust.Host.Observation do
  @moduledoc "Product diagnostics through the public Signals facade."
  use Boundary, top_level?: true, deps: [Arbor.Trust, Arbor.Signals], exports: []
  @behaviour Arbor.Trust.Contracts.Observation
  @impl true
  def emit(category, type, data, opts) do
    if Keyword.has_key?(opts, :stream_id),
      do: Arbor.Signals.durable_emit(category, type, data, opts),
      else: Arbor.Signals.emit(category, type, data, opts)
  end
end
