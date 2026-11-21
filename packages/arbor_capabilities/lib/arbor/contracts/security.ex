defmodule Arbor.Contracts.Security do
  @moduledoc """
  Boundary root for the `Arbor.Contracts.Security.*` contracts this package owns.

  The modules keep their pre-split names, so they cannot join the package's
  main boundary by namespace. Outgoing references are unchecked until they are
  renamed into the package namespace.
  """

  use Boundary, top_level?: true, check: [out: false], exports: :all
end
