defmodule Arbor.Orchestrator.UnifiedLLM.StreamEvent do
  @moduledoc false

  @type type :: :start | :delta | :tool_call | :tool_result | :step_finish | :finish | :error

  @type t :: %__MODULE__{type: type(), data: map()}
  defstruct type: :start, data: %{}
end
