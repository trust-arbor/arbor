defmodule Arbor.Gateway.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into Arbor's capability-based action system.

  Converts MCP tool schemas to Arbor-compatible tool definitions and handles
  capability authorization for tool invocations.

  ## Capability URIs

  Each MCP tool is mapped to a capability URI:

      arbor://mcp/<server-name>/<tool-name>

  For example, connecting a GitHub MCP server named "github" that exposes
  a `create_issue` tool produces:

      arbor://mcp/github/create_issue

  ## Taint

  All MCP tool outputs are tagged as `:untrusted` with `:external` source,
  since they come from outside the Arbor security boundary.
  """

  @doc """
  Convert an MCP tool definition to an Arbor-compatible tool map.

  The returned map follows the same shape as Arbor action tool definitions,
  making MCP tools interchangeable with native actions from the agent's perspective.
  """
  @description_max_bytes 640

  @spec to_arbor_tool(String.t(), map()) :: map()
  def to_arbor_tool(server_name, %{"name" => name} = tool) do
    raw_description = Map.get(tool, "description", "MCP tool: #{name}")

    %{
      name: "mcp.#{server_name}.#{name}",
      description: sanitize_description(server_name, raw_description),
      input_schema: normalize_schema(Map.get(tool, "inputSchema", %{})),
      source: :mcp,
      server_name: server_name,
      mcp_tool_name: name,
      capability_uri: capability_uri(server_name, name)
    }
  end

  @doc """
  Label for MCP tool results that re-enter an agent or operator prompt.

  The gateway must keep this label — stripping it is a security regression.
  """
  @spec untrusted_result_label(String.t(), String.t()) :: String.t()
  def untrusted_result_label(server_name, tool_name)
      when is_binary(server_name) and is_binary(tool_name) do
    safe_server = flatten_label_token(server_name, 64)
    safe_tool = flatten_label_token(tool_name, 64)
    "[UNTRUSTED MCP result from server \"#{safe_server}\" tool \"#{safe_tool}\"]"
  end

  @doc """
  Convert all tools from an MCP server to Arbor-compatible format.
  """
  @spec to_arbor_tools(String.t(), [map()]) :: [map()]
  def to_arbor_tools(server_name, tools) when is_list(tools) do
    Enum.map(tools, &to_arbor_tool(server_name, &1))
  end

  @doc """
  Build the capability URI for an MCP tool.

      iex> ToolBridge.capability_uri("github", "create_issue")
      "arbor://mcp/github/create_issue"
  """
  @spec capability_uri(String.t(), String.t()) :: String.t()
  def capability_uri(server_name, tool_name) do
    "arbor://mcp/#{server_name}/#{tool_name}"
  end

  @doc """
  Check if an agent has the capability to call an MCP tool.

  Delegates to `Arbor.Security.authorize/3`. Fails closed: when the security
  subsystem is not loaded or its `CapabilityStore` is not running (startup,
  restart), the call is denied rather than granted.
  """
  @spec authorize(String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized, String.t()}
  def authorize(agent_id, server_name, tool_name) do
    uri = capability_uri(server_name, tool_name)

    if security_available?() do
      case apply(security_module(), :authorize, [agent_id, uri, :execute]) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, :unauthorized,
           "Agent #{agent_id} lacks capability: #{uri} (#{inspect(reason)})"}
      end
    else
      # FAIL CLOSED: no security subsystem means no authorization decision, so
      # deny. This branch used to return :ok ("permissive mode"), granting every
      # external MCP tool call while CapabilityStore was down or restarting.
      {:error, :unauthorized, "security subsystem unavailable; cannot authorize #{uri}"}
    end
  rescue
    # FAIL CLOSED: a crash while consulting security must DENY, never grant.
    # Returning :ok here let any exception during the capability check
    # auto-authorize an external MCP tool call (2026-06-09 Sentinel finding).
    e ->
      {:error, :unauthorized,
       "authorization check failed for #{capability_uri(server_name, tool_name)}: " <>
         Exception.message(e)}
  catch
    :exit, reason ->
      {:error, :unauthorized,
       "authorization check exited for #{capability_uri(server_name, tool_name)}: " <>
         inspect(reason)}
  end

  @doc """
  Wrap an MCP tool result with taint metadata.

  MCP outputs are tagged as `:untrusted` since they originate from
  external processes outside the Arbor trust boundary.
  """
  @spec taint_result(term(), String.t(), String.t()) :: map()
  def taint_result(result, server_name, tool_name) do
    %{
      value: result,
      taint: %{
        level: :untrusted,
        sensitivity: :internal,
        confidence: :plausible,
        source: "mcp:#{server_name}/#{tool_name}",
        sanitizations: 0
      }
    }
  end

  @doc """
  Parse an Arbor tool name back to server_name and tool_name.

  Returns `{:ok, server_name, tool_name}` or `:error`.

      iex> ToolBridge.parse_tool_name("mcp.github.create_issue")
      {:ok, "github", "create_issue"}
  """
  @spec parse_tool_name(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_tool_name("mcp." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [server_name, tool_name] when server_name != "" and tool_name != "" ->
        {:ok, server_name, tool_name}

      _ ->
        :error
    end
  end

  def parse_tool_name(_), do: :error

  # -- Private --

  defp sanitize_description(server_name, description) do
    prefix = untrusted_description_prefix(server_name)
    budget = max(@description_max_bytes - byte_size(prefix), 32)
    prefix <> flatten_label_token(description, budget)
  end

  defp untrusted_description_prefix(server_name) do
    safe_server = flatten_label_token(server_name, 64)
    "[UNTRUSTED MCP description from server \"#{safe_server}\"] "
  end

  defp flatten_label_token(value, max_bytes) when is_binary(value) do
    taint = %Arbor.Contracts.Security.Taint{
      level: :untrusted,
      sensitivity: :internal,
      sanitizations: 0,
      confidence: :plausible,
      source: "mcp_description",
      chain: []
    }

    {:ok, sanitized, _taint} =
      Arbor.Common.Sanitizers.LogInjection.sanitize(value, taint,
        max_length: max_bytes,
        redact: false
      )

    sanitized
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_bytes(max_bytes)
  end

  defp flatten_label_token(value, max_bytes) do
    flatten_label_token(to_string(value), max_bytes)
  end

  defp truncate_bytes(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_bytes(value, max_bytes) do
    String.slice(value, 0, max_bytes)
  end

  defp normalize_schema(%{"type" => _} = schema), do: schema

  defp normalize_schema(schema) when is_map(schema) do
    Map.put_new(schema, "type", "object")
  end

  defp normalize_schema(_), do: %{"type" => "object", "properties" => %{}}

  # Security module, overridable via config for tests / deployment swaps
  # (mirrors the Config-module seam used across arbor_security).
  defp security_module do
    Application.get_env(:arbor_gateway, :security_module, Arbor.Security)
  end

  defp security_available? do
    mod = security_module()

    Code.ensure_loaded?(mod) and function_exported?(mod, :authorize, 3) and
      security_running?(mod)
  end

  defp security_running?(Arbor.Security),
    do: Arbor.Security.capability_authorization_available?()

  defp security_running?(_injected), do: true
end
