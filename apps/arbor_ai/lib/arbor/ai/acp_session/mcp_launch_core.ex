defmodule Arbor.AI.AcpSession.McpLaunchCore do
  @moduledoc """
  Pure decision: how an ACP session's bound `mcpServers` list reaches an
  adapter-backed provider process.

  Native ACP agents read `mcpServers` from `session/new`, and `AcpSession`
  already sends the bound list on every operation. Three ex_mcp 1.3.0 adapters
  need launch-time wiring instead (found 2026-09-27 following Imp review D6;
  before this, the ACP ToolServer reached neither Claude nor Codex):

  - `ClaudeSDK` ignores `session/new` `mcpServers` and only takes servers at
    launch through `--mcp-config`. The plan writes them, in Claude's own
    format, to a file in the session's private runtime home and passes the
    path, never the JSON: the ToolServer descriptor carries a live bearer
    token and argv is visible to `ps`. `--strict-mcp-config` is always set so
    servers from the user's own Claude configuration never join an Arbor
    session (agent-security-gates #12). Bound server names are pre-allowed
    (`mcp__<name>`) because the ToolServer authorizes every call itself as the
    owning agent; strict mode is what makes that name unambiguous.
  - `Codex` and `ZCode` refuse an MCP server unless it is authorized, failing
    `session/new` outright. The plan trusts exactly the bound list and drops
    any caller-supplied `:authorize_mcp_server`, so a caller's `:all` cannot
    widen it.
  - Any other adapter (e.g. `Pi`) has no MCP support: bound servers are an
    error rather than a ToolServer nothing connects to.

  `apply_adapter_opts/2` applies a plan to adapter options. The impure half
  (staging the file) lives in `Arbor.AI.AcpSession.RuntimeHome`.
  """

  @claude_sdk ExMCP.ACP.Adapters.ClaudeSDK
  @trusted_list_adapters [ExMCP.ACP.Adapters.Codex, ExMCP.ACP.Adapters.ZCode]
  @claude_mcp_config_basename "claude-mcp-config.json"
  @server_name_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @type plan :: %{
          file: {String.t(), binary()} | nil,
          adapter_put: keyword(),
          adapter_append: keyword(),
          adapter_delete: [atom()],
          allow_tools: [String.t()]
        }

  @doc """
  Plan the launch-time MCP wiring for `adapter` (the client's `:adapter`
  module, `nil` for a native ACP command) given the session's bound servers
  and its private runtime-home directory.
  """
  @spec plan(module() | nil, [map()], String.t()) :: {:ok, plan()} | {:error, term()}
  def plan(nil, _servers, _runtime_home), do: {:ok, noop()}

  def plan(@claude_sdk, servers, runtime_home)
      when is_list(servers) and is_binary(runtime_home) do
    with {:ok, claude_servers} <- claude_servers(servers) do
      base = %{noop() | adapter_put: [strict_mcp_config: true], adapter_delete: [:mcp_servers]}

      if claude_servers == %{} do
        {:ok, base}
      else
        path = Path.join(runtime_home, @claude_mcp_config_basename)
        contents = Jason.encode!(%{"mcpServers" => claude_servers})

        {:ok,
         %{
           base
           | file: {path, contents},
             # `--flag=value` so a path that started with `-` cannot become a
             # new Claude CLI option (CVE-2026-96620). Arbor owns this path.
             adapter_append: [extra_args: ["--mcp-config=#{path}"]],
             allow_tools:
               claude_servers |> Map.keys() |> Enum.sort() |> Enum.map(&("mcp__" <> &1))
         }}
      end
    end
  end

  def plan(adapter, servers, _runtime_home)
      when adapter in @trusted_list_adapters and is_list(servers) do
    {:ok,
     %{
       noop()
       | adapter_put: [trusted_mcp_servers: servers],
         adapter_delete: [:authorize_mcp_server]
     }}
  end

  def plan(_adapter, [], _runtime_home), do: {:ok, noop()}

  def plan(adapter, servers, _runtime_home) when is_atom(adapter) and is_list(servers),
    do: {:error, {:acp_mcp_servers_unsupported, adapter}}

  def plan(_adapter, _servers, _runtime_home), do: {:error, :invalid_acp_mcp_servers}

  @doc """
  Apply a plan to adapter options: delete, then put, then append to list
  options (e.g. `:extra_args`, which other launch paths may already set).
  """
  @spec apply_adapter_opts(keyword(), plan()) :: {:ok, keyword()} | {:error, atom()}
  def apply_adapter_opts(adapter_opts, plan) when is_list(adapter_opts) and is_map(plan) do
    if Keyword.keyword?(adapter_opts) do
      adapter_opts
      |> Keyword.drop(plan.adapter_delete)
      |> Keyword.merge(plan.adapter_put)
      |> append_all(plan.adapter_append)
    else
      {:error, :invalid_acp_adapter_options}
    end
  end

  def apply_adapter_opts(_adapter_opts, _plan), do: {:error, :invalid_acp_adapter_options}

  defp noop,
    do: %{file: nil, adapter_put: [], adapter_append: [], adapter_delete: [], allow_tools: []}

  defp append_all(adapter_opts, appends) do
    Enum.reduce_while(appends, {:ok, adapter_opts}, fn {key, values}, {:ok, acc} ->
      case Keyword.get(acc, key, []) do
        existing when is_list(existing) ->
          {:cont, {:ok, Keyword.put(acc, key, existing ++ values)}}

        _other ->
          {:halt, {:error, :invalid_acp_adapter_options}}
      end
    end)
  end

  # ACP `mcpServers` entries (name/value header and env lists) -> Claude's
  # `mcpServers` map (name -> config, header and env maps).
  defp claude_servers(servers) do
    Enum.reduce_while(servers, {:ok, %{}}, fn server, {:ok, acc} ->
      case claude_server(server) do
        {:ok, name, _config} when is_map_key(acc, name) ->
          {:halt, {:error, :duplicate_acp_mcp_server}}

        {:ok, name, config} ->
          {:cont, {:ok, Map.put(acc, name, config)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp claude_server(%{"type" => type, "name" => name, "url" => url} = server)
       when type in ["http", "sse"] do
    with :ok <- valid_name(name),
         :ok <- valid_url(url),
         {:ok, headers} <- pairs_to_map(Map.get(server, "headers", [])) do
      {:ok, name, %{"type" => type, "url" => url, "headers" => headers}}
    end
  end

  defp claude_server(%{"name" => name, "command" => command} = server)
       when not is_map_key(server, "type") or
              :erlang.map_get("type", server) == "stdio" do
    args = Map.get(server, "args", [])

    with :ok <- valid_name(name),
         true <- is_binary(command) and command != "",
         true <- is_list(args) and Enum.all?(args, &is_binary/1),
         {:ok, env} <- pairs_to_map(Map.get(server, "env", [])) do
      {:ok, name, %{"type" => "stdio", "command" => command, "args" => args, "env" => env}}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_acp_mcp_server}
    end
  end

  defp claude_server(_server), do: {:error, :invalid_acp_mcp_server}

  defp valid_name(name) when is_binary(name) do
    if Regex.match?(@server_name_pattern, name), do: :ok, else: {:error, :invalid_acp_mcp_server}
  end

  defp valid_name(_name), do: {:error, :invalid_acp_mcp_server}

  defp valid_url("http://" <> rest) when rest != "", do: :ok
  defp valid_url("https://" <> rest) when rest != "", do: :ok
  defp valid_url(_url), do: {:error, :invalid_acp_mcp_server}

  defp pairs_to_map(pairs) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      %{"name" => name, "value" => value}, {:ok, acc}
      when is_binary(name) and name != "" and is_binary(value) and not is_map_key(acc, name) ->
        {:cont, {:ok, Map.put(acc, name, value)}}

      _pair, _acc ->
        {:halt, {:error, :invalid_acp_mcp_server}}
    end)
  end

  defp pairs_to_map(_pairs), do: {:error, :invalid_acp_mcp_server}
end
