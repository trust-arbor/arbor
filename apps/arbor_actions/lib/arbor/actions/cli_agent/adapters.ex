defmodule Arbor.Actions.CliAgent.Adapters do
  @moduledoc """
  Adapter registry for CLI-based coding agents.

  Each adapter implements the execution protocol for a specific CLI agent:
  binary resolution, argument building, output parsing, and permission flags.

  ## Supported Agents

  | Agent | Adapter | Status |
  |-------|---------|--------|
  | `"claude"` | `Adapters.Claude` | Implemented |
  | `"opencode"` | — | Planned |
  | `"codex"` | — | Planned |
  | `"gemini"` | — | Planned |
  | `"qwen"` | — | Planned |

  ## Adapter Contract

  Each adapter must export:

  - `execute(params, context)` — Run the prompt, return `{:ok, result_map}` or `{:error, reason}`
  - `available?()` — Return `true` if the binary is in PATH
  - `build_args(params, tool_flags)` — Build CLI arg list (for testing)
  - `parse_result(output, params)` — Parse raw output into result map (for testing)
  """

  alias Arbor.Actions.CliAgent.Adapters

  @adapters %{
    "claude" => Adapters.Claude
  }

  @doc """
  Resolve an adapter module for the given agent name.

  ## Examples

      iex> Adapters.resolve("claude")
      {:ok, Arbor.Actions.CliAgent.Adapters.Claude}

      iex> Adapters.resolve("codex")
      {:error, {:unsupported_agent, "codex"}}
  """
  @spec resolve(String.t()) :: {:ok, module()} | {:error, term()}
  def resolve(agent_name) do
    case Map.get(@adapters, agent_name) do
      nil -> {:error, {:unsupported_agent, agent_name}}
      adapter -> {:ok, adapter}
    end
  end

  @doc """
  List all registered agent names.
  """
  @spec list_agents() :: [String.t()]
  def list_agents, do: Map.keys(@adapters)

  @doc """
  Check which registered agents are available (binary in PATH).
  """
  @spec available_agents() :: [String.t()]
  def available_agents do
    Enum.filter(@adapters, fn {_name, adapter} ->
      Arbor.Common.LazyLoader.exported?(adapter, :available?, 0) and
        adapter.available?()
    end)
    |> Enum.map(fn {name, _adapter} -> name end)
  end
end
