defmodule Arbor.LLM.TestSupport do
  @moduledoc false

  # This boundary is compiled only by the owning test project. ExUnit never
  # becomes a dependency of the shipped production namespace.
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [Arbor, ExUnit],
    exports: :all
end
