defmodule Arbor.Orchestrator.Middleware.CapabilityCheck do
  @moduledoc """
  Mandatory middleware that checks capability authorization before node execution.

  Bridges to `Arbor.Security.authorize/4` when available. Halts execution if the
  agent lacks the required capability for the node's operation.

  When a compiled node has `capabilities_required` populated by the IR Compiler,
  ALL listed capabilities are checked. Falls back to a single type-based URI
  for uncompiled graphs.

  Skipped when `opts[:authorization] == false` or when Arbor.Security is
  not loaded (standalone orchestrator usage).

  ## Token Assigns

    - `:agent_id` — the agent ID to check capabilities for (defaults to `"agent_system"`)
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
        check_capabilities(token)
    end
  end

  @orchestrator_uri_prefix "arbor://orchestrator/execute/"

  @doc """
  Returns the list of capability URIs required for a node.

  Uses `node.capabilities_required` if populated by IR Compiler,
  otherwise falls back to a single URI derived from the node type.

  Bare capability names (e.g. `"llm_query"`) are normalized to full
  URIs (`"arbor://orchestrator/execute/llm_query"`) so they can be
  matched against wildcard grants like `"arbor://orchestrator/execute/**"`.
  """
  @spec capability_resources(Arbor.Orchestrator.Graph.Node.t()) :: [String.t()]
  def capability_resources(node) do
    case node.capabilities_required do
      caps when is_list(caps) and caps != [] ->
        Enum.map(caps, &normalize_capability_uri/1)

      _ ->
        node_type = Map.get(node.attrs, "type", "unknown")
        [@orchestrator_uri_prefix <> node_type]
    end
  end

  defp normalize_capability_uri(cap) when is_binary(cap) do
    if String.starts_with?(cap, "arbor://") do
      cap
    else
      @orchestrator_uri_prefix <> cap
    end
  end

  defp check_capabilities(token) do
    agent_id = Map.get(token.assigns, :agent_id, "agent_system")
    resources = capability_resources(token.node)

    check_all_resources(token, agent_id, resources)
  end

  defp check_all_resources(token, _agent_id, []), do: token

  defp check_all_resources(token, agent_id, [resource | rest]) do
    auth_opts = build_auth_opts(token, resource)

    case apply(Arbor.Security, :authorize, [agent_id, resource, :execute, auth_opts]) do
      {:ok, :authorized} ->
        check_all_resources(token, agent_id, rest)

      {:ok, :pending_approval, _} ->
        check_all_resources(token, agent_id, rest)

      {:error, reason} ->
        Token.halt(
          token,
          "capability denied: #{resource} for agent #{agent_id}",
          %Outcome{
            status: :fail,
            failure_reason: "Capability check failed: #{resource} (#{inspect(reason)})"
          }
        )
    end
  rescue
    _ -> token
  catch
    :exit, _ -> token
  end

  defp build_auth_opts(token, resource) do
    case Map.get(token.assigns, :signer) do
      signer when is_function(signer, 1) ->
        case signer.(resource) do
          {:ok, signed_request} -> [signed_request: signed_request]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :authorize, 4)
  end
end
