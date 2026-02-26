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
  Check if an agent has the capability to read an MCP resource.

  Uses Arbor.Security.authorize/3 when available, falls back to permissive
  mode when security infrastructure isn't running (dev/test).
  """
  @spec authorize(String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized, String.t()}
  def authorize(agent_id, server_name, resource_name) do
    uri = capability_uri(server_name, resource_name)

    if security_available?() do
      case apply(Arbor.Security, :authorize, [agent_id, uri, %{action: :read}]) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, :unauthorized,
           "Agent #{agent_id} lacks capability: #{uri} (#{inspect(reason)})"}
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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

  defp security_available? do
    Code.ensure_loaded?(Arbor.Security) and
      function_exported?(Arbor.Security, :authorize, 3) and
      Process.whereis(Arbor.Security.CapabilityStore) != nil
  end
end
