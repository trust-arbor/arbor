defmodule Arbor.Kernel.DevTools do
  @moduledoc false

  use Boundary,
    top_level?: true,
    check: [in: false, out: false],
    exports: []
end
