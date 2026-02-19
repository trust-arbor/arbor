defmodule Arbor.Orchestrator.Middleware.CapabilityCheck do
  @moduledoc """
  Mandatory middleware that checks capability authorization before node execution.

  Bridges to `Arbor.Security.can?/3` when available. Halts execution if the
  agent lacks the required capability for the node's operation.

  Skipped when `opts[:authorization] == false` or when Arbor.Security is
  not loaded (standalone orchestrator usage).

  ## Token Assigns

    - `:agent_id` — the agent ID to check capabilities for
    - `:skip_capability_check` — set to true to bypass this middleware
  """

  use Arbor.Orchestrator.Middleware

  alias Arbor.Orchestrator.Engine.Outcome

  @impl true
  def before_node(token) do
    cond do
      Map.get(token.assigns, :skip_capability_check, false) ->
        token

      Map.get(token.assigns, :authorization) == false ->
        token

      not security_available?() ->
        token

      true ->
        check_capability(token)
    end
  end

  defp check_capability(token) do
    agent_id = Map.get(token.assigns, :agent_id, "system")
    node_type = Map.get(token.node.attrs, "type", "unknown")
    capability = "arbor://orchestrator/execute/#{node_type}"

    case apply(Arbor.Security, :can?, [agent_id, :execute, capability]) do
      true ->
        token

      false ->
        Token.halt(
          token,
          "capability denied: #{capability} for agent #{agent_id}",
          %Outcome{
            status: :fail,
            failure_reason: "Capability check failed: #{capability}"
          }
        )
    end
  rescue
    _ -> token
  catch
    :exit, _ -> token
  end

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :can?, 3)
  end
end
