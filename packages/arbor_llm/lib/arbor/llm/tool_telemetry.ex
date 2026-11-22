defmodule Arbor.LLM.ToolTelemetry do
  @moduledoc "Optional host-owned observation of a completed tool call."

  @callback record_tool(String.t(), String.t(), term(), non_neg_integer()) :: term()
end
