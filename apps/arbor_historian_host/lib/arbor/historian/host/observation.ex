defmodule Arbor.Historian.Host.Observation do
  @moduledoc false
  @behaviour Arbor.Historian.Contracts.Observation
  @impl true
  def emit(category, type, data), do: Arbor.Signals.emit(category, type, data)
end
