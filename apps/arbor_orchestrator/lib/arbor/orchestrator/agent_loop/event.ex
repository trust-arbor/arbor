defmodule Arbor.Orchestrator.AgentLoop.Event do
  @moduledoc false

  @type t :: %__MODULE__{
          type: atom(),
          session_id: String.t(),
          turn: non_neg_integer(),
          data: map()
        }
  defstruct type: :unknown, session_id: "", turn: 0, data: %{}
end
