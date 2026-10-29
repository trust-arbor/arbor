defmodule Arbor.Contracts.CapabilityMatch do
  @moduledoc """
  A search result from the capability resolver.

  Wraps a `CapabilityDescriptor` with scoring and resolution metadata.

  ## Fields

  - `descriptor` — the matched capability descriptor
  - `score` — normalized relevance score (0.0 to 1.0)
  - `tier` — which resolution tier found it (1 = keyword, 2 = semantic, 3 = composed)
  - `reason` — why this matched (for agent transparency)
  """

  use TypedStruct

  alias Arbor.Contracts.CapabilityDescriptor

  typedstruct do
    @typedoc "A scored capability match result"

    field(:descriptor, CapabilityDescriptor.t(), enforce: true)
    field(:score, float(), enforce: true)
    field(:tier, pos_integer(), default: 1)
    field(:reason, String.t() | nil)
  end
end
