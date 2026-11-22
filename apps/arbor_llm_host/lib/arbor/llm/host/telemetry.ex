defmodule Arbor.LLM.Host.Telemetry do
  @moduledoc "Records tool observations in the product's existing telemetry store."

  @behaviour Arbor.LLM.ToolTelemetry

  alias Arbor.Common.AgentTelemetry.Store

  @impl true
  def record_tool(agent_id, tool_name, result, duration_ms) do
    Store.record_tool(agent_id, tool_name, result, duration_ms)
  end
end
