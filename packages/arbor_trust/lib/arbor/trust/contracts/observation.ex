defmodule Arbor.Trust.Contracts.Observation do
  @moduledoc "Optional diagnostics. Failures never change policy, persistence acknowledgement or authority decisions."
  @callback emit(atom(), atom(), map(), keyword()) :: term()
end
