defmodule Arbor.Persistence.Contracts.EventBus do
  @moduledoc "Best-effort event transport selected by the composing application."

  @callback emit(atom(), atom(), map(), keyword()) :: term()
  @callback subscribe(String.t(), function()) :: term()
end
