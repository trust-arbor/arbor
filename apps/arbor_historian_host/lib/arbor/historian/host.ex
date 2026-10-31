defmodule Arbor.Historian.Host do
  @moduledoc "Product bindings for the canonical Historian application; owns no authority tree."
  use Boundary,
    top_level?: true,
    deps: [Arbor.Historian, Arbor.Security, Arbor.Signals],
    exports: :all
end
