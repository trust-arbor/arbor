defmodule Arbor.Gateway.MCP.ResourceBridge do
  @moduledoc """
  Bridges MCP server resources into Arbor's capability-based system.

  Converts MCP resource definitions to Arbor-compatible format and handles
  capability authorization for resource access.

  ## Capability URIs

  Each MCP resource is mapped to a capability URI:

      arbor://mcp/<server-name>/resource/<resource-name>

  For example, connecting a filesystem MCP server named "fs" that exposes
  a `config.json` resource produces:

      arbor://mcp/fs/resource/config.json

  ## Taint

  All MCP resource contents are tagged as `:untrusted` with `:external` source,
  since they come from outside the Arbor security boundary.
  """

  @doc """
  Convert an MCP resource definition to an Arbor-compatible resource map.
  """
  @spec to_arbor_resource(String.t(), map()) :: map()
  def to_arbor_resource(server_name, %{"uri" => uri, "name" => name} = resource) do
    %{
      uri: uri,
      name: name,
      description: Map.get(resource, "description", ""),
      mime_type: Map.get(resource, "mimeType", ""),
      source: :mcp,
      server_name: server_name,
      capability_uri: capability_uri(server_name, name)
    }
  end

  @doc """
  Convert all resources from an MCP server to Arbor-compatible format.
  """
  @spec to_arbor_resources(String.t(), [map()]) :: [map()]
  def to_arbor_resources(server_name, resources) when is_list(resources) do
    Enum.map(resources, &to_arbor_resource(server_name, &1))
  end

  @doc """
  Build the capability URI for an MCP resource.

      iex> ResourceBridge.capability_uri("fs", "config.json")
      "arbor://mcp/fs/resource/config.json"
  """
  @spec capability_uri(String.t(), String.t()) :: String.t()
  def capability_uri(server_name, resource_name) do
    "arbor://mcp/#{server_name}/resource/#{resource_name}"
  end

  @doc """
  Authorize an agent to read an MCP resource.

  Production uses `Arbor.Trust.authorize/4`, matching native actions.
  MCP resource reads receive the same Trust decision as MCP tool calls.

  Injected `:security_module` values keep the capability-only seam used by
  fail-closed tests. Fails closed when security or Trust is unavailable.
  """
  @spec authorize(String.t(), String.t(), String.t(), keyword()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized, String.t()}
  def authorize(agent_id, server_name, resource_name, opts \\ []) do
    uri = capability_uri(server_name, resource_name)
    authorize_held(agent_id, uri, :read, opts)
  rescue
    # FAIL CLOSED: a crash while consulting security must DENY, never grant.
    # (2026-06-09 Sentinel finding — the previous `:ok` auto-authorized an
    # external MCP resource read on any exception.)
    e ->
      {:error, :unauthorized,
       "authorization check failed for #{capability_uri(server_name, resource_name)}: " <>
         Exception.message(e)}
  catch
    :exit, reason ->
      {:error, :unauthorized,
       "authorization check exited for #{capability_uri(server_name, resource_name)}: " <>
         inspect(reason)}
  end

  @doc """
  Wrap MCP resource content with taint metadata.

  Resource contents are tagged as `:untrusted` since they originate from
  external processes outside the Arbor trust boundary.
  """
  @spec taint_contents(term(), String.t(), String.t()) :: map()
  def taint_contents(contents, server_name, resource_uri) do
    %{
      value: contents,
      taint: %{
        level: :untrusted,
        sensitivity: :internal,
        confidence: :plausible,
        source: "mcp:#{server_name}/resource/#{resource_uri}",
        sanitizations: 0
      }
    }
  end

  # -- Private --

  defp authorize_held(agent_id, uri, action, opts) do
    if security_available?() do
      case security_module() do
        Arbor.Security ->
          authorize_with_trust(agent_id, uri, action, opts)

        injected ->
          authorize_with_injected_security(injected, agent_id, uri, action)
      end
    else
      # FAIL CLOSED: no security subsystem means no authorization decision, so
      # deny. This branch used to return :ok ("permissive mode"), granting every
      # external MCP resource read while CapabilityStore was down or restarting.
      {:error, :unauthorized, "security subsystem unavailable; cannot authorize #{uri}"}
    end
  end

  defp authorize_with_trust(agent_id, uri, action, opts) do
    if trust_available?() do
      case trust_module().authorize(agent_id, uri, action, List.wrap(opts)) do
        {:ok, :authorized} ->
          :ok

        {:ok, :pending_approval, proposal_id} when is_binary(proposal_id) ->
          {:ok, :pending_approval, proposal_id}

        {:error, {:pending_approval, proposal_id}} when is_binary(proposal_id) ->
          {:ok, :pending_approval, proposal_id}

        {:error, reason} ->
          {:error, :unauthorized,
           "Agent #{agent_id} lacks capability: #{uri} (#{inspect(reason)})"}

        other ->
          {:error, :unauthorized,
           "Agent #{agent_id} lacks capability: #{uri} (#{inspect(other)})"}
      end
    else
      {:error, :unauthorized, "security subsystem unavailable; cannot authorize #{uri}"}
    end
  end

  defp authorize_with_injected_security(injected, agent_id, uri, action) do
    case apply(injected, :authorize, [agent_id, uri, action]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, :unauthorized, "Agent #{agent_id} lacks capability: #{uri} (#{inspect(reason)})"}
    end
  end

  # Security module, overridable via config for tests / deployment swaps.
  defp security_module do
    Application.get_env(:arbor_gateway, :security_module, Arbor.Security)
  end

  defp trust_module do
    Application.get_env(:arbor_gateway, :trust_module, Arbor.Trust)
  end

  defp security_available? do
    mod = security_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :authorize, 3) and
      security_running?(mod)
  end

  defp security_running?(Arbor.Security),
    do: Arbor.Security.capability_authorization_available?()

  defp security_running?(_injected), do: true

  defp trust_available? do
    mod = trust_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :authorize, 4)
  end
end
