defmodule Arbor.LLM.Host do
  @moduledoc "Product adapters for the canonical LLM library."

  use Boundary, deps: [Arbor, Arbor.Common], exports: [Telemetry]
end
