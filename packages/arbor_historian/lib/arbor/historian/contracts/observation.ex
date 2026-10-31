defmodule Arbor.Historian.Contracts.Observation do
  @moduledoc "Optional diagnostics only; results never authorize or acknowledge durable state."
  @callback emit(atom(), atom(), map()) :: term()
end
