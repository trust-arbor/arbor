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
  @spec to_arbor_tool(String.t(), map()) :: map()
  def to_arbor_tool(server_name, %{"name" => name} = tool) do
    %{
      name: "mcp.#{server_name}.#{name}",
      description: Map.get(tool, "description", "MCP tool: #{name}"),
      input_schema: normalize_schema(Map.get(tool, "inputSchema", %{})),
      source: :mcp,
      server_name: server_name,
      mcp_tool_name: name,
      capability_uri: capability_uri(server_name, name),
      annotations: normalize_annotations(tool)
    }
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
  Authorize an agent to call an MCP tool.

  Production uses `Arbor.Trust.authorize/4`, the same boundary native actions
  and the ACP ToolServer use, so the `:cautious` baseline `:ask` and
  ApprovalGuard apply. A missing MCP `destructiveHint` is treated as
  destructive. Server-supplied hints are advisory: `readOnlyHint` must never
  skip Trust or approval.

  Injected `:security_module` values keep the capability-only seam used by
  fail-closed tests. Fails closed when security or Trust is unavailable.
  """
  @spec authorize(String.t(), String.t(), String.t(), keyword()) ::
          :ok
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized, String.t()}
  def authorize(agent_id, server_name, tool_name, opts \\ []) do
    uri = capability_uri(server_name, tool_name)
    annotations = annotations_from_opts(opts)

    # Hints from MCP servers are advisory. Missing destructiveHint is
    # destructive. readOnlyHint must never skip Trust/approval.
    _destructive? = destructive_annotation?(annotations)
    authorize_held(agent_id, uri, :execute, opts)
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

  defp normalize_schema(%{"type" => _} = schema), do: schema

  defp normalize_schema(schema) when is_map(schema) do
    Map.put_new(schema, "type", "object")
  end

  defp normalize_schema(_), do: %{"type" => "object", "properties" => %{}}

  defp normalize_annotations(tool) do
    case Map.get(tool, "annotations") || Map.get(tool, :annotations) do
      annotations when is_map(annotations) -> annotations
      _ -> %{}
    end
  end

  defp annotations_from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :annotations) do
      annotations when is_map(annotations) -> annotations
      _ -> %{}
    end
  end

  defp annotations_from_opts(_opts), do: %{}

  defp destructive_annotation?(annotations) when is_map(annotations) do
    # A missing hint is treated as destructive.
    annotation_flag(annotations, "destructiveHint", :destructiveHint) != false
  end

  defp destructive_annotation?(_), do: true

  defp annotation_flag(annotations, string_key, atom_key) do
    cond do
      Map.has_key?(annotations, string_key) -> Map.get(annotations, string_key)
      Map.has_key?(annotations, atom_key) -> Map.get(annotations, atom_key)
      true -> :missing
    end
  end

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
      # external MCP tool call while CapabilityStore was down or restarting.
      {:error, :unauthorized, "security subsystem unavailable; cannot authorize #{uri}"}
    end
  end

  defp authorize_with_trust(agent_id, uri, action, opts) do
    if trust_available?() do
      trust_opts = Keyword.drop(List.wrap(opts), [:annotations])

      case trust_module().authorize(agent_id, uri, action, trust_opts) do
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

  # Security module, overridable via config for tests / deployment swaps
  # (mirrors the Config-module seam used across arbor_security).
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
