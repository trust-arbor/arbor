defmodule Arbor.Orchestrator.AgentLoop.Config do
  @moduledoc false

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_tool_rounds: pos_integer(),
          loop_detection_window: pos_integer()
        }

  defstruct max_turns: 30,
            max_tool_rounds: 10,
            loop_detection_window: 3
end
