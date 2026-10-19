defmodule Arbor.Gateway.MCP.ClientConfigCore do
  @moduledoc """
  Pure normalization and validation of an MCP client connection config, applied
  once at `ClientSupervisor.start_connection/2` before any process starts.

  Configs arrive atom-keyed from code and string-keyed from persisted agent
  profile metadata (`Arbor.Agent.Manager.connect_mcp_servers/1`). Until
  2026-09-28 (Imp review D7) `ClientConnection` read atom keys only, so a
  string-keyed stdio server silently became `command: []`, a string-keyed
  HTTP server crashed on `Map.fetch!(config, :url)` inside the connection
  process, and a string `"transport"` was ignored in favor of the `:stdio`
  default. Now known keys are read in either form (no atoms are created from
  input), the transport comes from a fixed allow-list, and each transport's
  required field is validated, returning `{:error, {:invalid_mcp_config,
  field}}` instead of starting a connection that can only fail.
  """

  @transports %{
    "stdio" => :stdio,
    "http" => :http,
    "sse" => :sse,
    "beam" => :beam,
    "test" => :test
  }
  @transport_atoms Map.values(@transports)

  # Known config keys, read as atom or string. Anything else keeps its atom
  # key; unknown string keys are dropped rather than atomized.
  @known_keys [:transport, :command, :env, :url, :server, :name, :auto_discover, :agent_id]

  # Process-injection keys. Approval of the MCP server does not make these
  # executable — env is part of the program (CVE-2026-111091 / CVE-2026-88755).
  # Keep this list aligned with Arbor.AI.AcpSession.McpLaunchCore.
  @forbidden_mcp_env_exact MapSet.new(~w(NODE_OPTIONS PYTHONPATH PYTHONSTARTUP BASH_ENV))
  @forbidden_mcp_env_prefixes ~w(LD_ DYLD_)

  @spec normalize(String.t(), map()) ::
          {:ok, map()}
          | {:error, {:invalid_mcp_config, atom()} | {:forbidden_mcp_env, String.t()}}
  def normalize(server_name, config) when is_binary(server_name) and is_map(config) do
    known = Map.new(@known_keys, &{&1, fetch(config, &1)})

    base =
      config
      |> Enum.filter(fn {key, _value} -> is_atom(key) and key not in @known_keys end)
      |> Map.new()
      |> Map.merge(Map.reject(known, fn {_key, value} -> is_nil(value) end))
      |> Map.put(:server_name, server_name)

    with {:ok, transport} <- transport(known.transport),
         {:ok, base} <- validate(transport, Map.put(base, :transport, transport)),
         :ok <- valid_env(known.env) do
      {:ok, base}
    end
  end

  def normalize(_server_name, _config), do: {:error, {:invalid_mcp_config, :config}}

  defp fetch(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(key))
    end
  end

  defp transport(nil), do: {:ok, :stdio}
  defp transport(value) when value in @transport_atoms, do: {:ok, value}

  defp transport(value) when is_binary(value) do
    case Map.fetch(@transports, value) do
      {:ok, transport} -> {:ok, transport}
      :error -> {:error, {:invalid_mcp_config, :transport}}
    end
  end

  defp transport(_value), do: {:error, {:invalid_mcp_config, :transport}}

  defp validate(:stdio, config) do
    case Map.get(config, :command) do
      command when is_binary(command) and command != "" ->
        {:ok, %{config | command: [command]}}

      [executable | _] = command when is_binary(executable) and executable != "" ->
        if Enum.all?(command, &is_binary/1),
          do: {:ok, config},
          else: {:error, {:invalid_mcp_config, :command}}

      _other ->
        {:error, {:invalid_mcp_config, :command}}
    end
  end

  defp validate(transport, config) when transport in [:http, :sse] do
    case Map.get(config, :url) do
      "http://" <> rest when rest != "" -> {:ok, config}
      "https://" <> rest when rest != "" -> {:ok, config}
      _other -> {:error, {:invalid_mcp_config, :url}}
    end
  end

  defp validate(transport, config) when transport in [:beam, :test] do
    case Map.get(config, :server) do
      server when is_pid(server) or (is_atom(server) and not is_nil(server)) -> {:ok, config}
      {name, node} when is_atom(name) and is_atom(node) -> {:ok, config}
      _other -> {:error, {:invalid_mcp_config, :server}}
    end
  end

  # ClientConnection passes the map through to the stdio transport; only the
  # shape it relies on is checked here. Process-injection keys fail closed
  # even when the server itself is approved. There is no operator override
  # for this denylist (searched 2026-10-19); do not add one without a
  # dedicated audit.
  defp valid_env(nil), do: :ok

  defp valid_env(env) when is_map(env) do
    Enum.reduce_while(env, :ok, fn {key, _value}, :ok ->
      case env_key_string(key) do
        {:ok, name} ->
          if forbidden_mcp_env?(name) do
            {:halt, {:error, {:forbidden_mcp_env, name}}}
          else
            {:cont, :ok}
          end

        :error ->
          {:halt, {:error, {:invalid_mcp_config, :env}}}
      end
    end)
  end

  defp valid_env(_env), do: {:error, {:invalid_mcp_config, :env}}

  defp env_key_string(key) when is_binary(key) and key != "", do: {:ok, key}

  defp env_key_string(key) when is_atom(key) and not is_nil(key) do
    {:ok, Atom.to_string(key)}
  end

  defp env_key_string(_key), do: :error

  defp forbidden_mcp_env?(name) when is_binary(name) do
    upper = String.upcase(name)

    MapSet.member?(@forbidden_mcp_env_exact, upper) or
      Enum.any?(@forbidden_mcp_env_prefixes, &String.starts_with?(upper, &1))
  end
end
