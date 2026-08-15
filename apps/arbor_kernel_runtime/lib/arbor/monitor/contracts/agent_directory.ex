defmodule Arbor.Monitor.Contracts.AgentDirectory do
  @moduledoc """
  Consumer-owned port for diagnostician fallback lookup.

  Library-specific to `arbor_monitor`. Implementations live above this
  library and are injected via `Arbor.Monitor.Config.agent_directory_module/0`.
  """

  @type monitor_agent :: %{agent_id: String.t(), display_name: String.t() | nil}

  @callback list_monitor_agents() ::
              {:ok, [monitor_agent()]} | {:error, :directory_unavailable}
end
