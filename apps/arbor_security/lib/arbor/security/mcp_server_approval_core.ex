defmodule Arbor.Security.McpServerApprovalCore do
  @moduledoc """
  Pure: the exact-approval capability URI for connecting an MCP server on an
  agent's behalf (Imp review D7, 2026-09-28).

  An agent-bound MCP connection spawns the configured stdio command or dials
  the configured URL as that agent. Before this, `Arbor.Agent.Manager`
  connected every server in a profile's `mcp_servers` metadata with no
  capability check, so anything that could write that metadata got process
  spawn on the agent's next start. The operator's `Arbor.Agent.set_mcp_config/2`
  now grants one capability per server bound to its exact config, and
  `Arbor.Gateway.connect_mcp_server/2` requires it.

      arbor://mcp_server/connect/<sha256(name)>/<sha256(config projection)>

  - The name is hashed so a caller-chosen server name can never become URI
    syntax (`*`, `/`, `..`).
  - The projection covers only what determines what runs or where it
    connects (`transport`, `command`, `env`, `url`, `server`, `cwd`,
    `environment_policy`). `cwd`/`cd` and `environment_policy`/`env_policy`
    are aliases. Key form (atom or string), a bare command string vs a
    one-element list, and the `:stdio` default all normalize to the same
    digest. Changing any of those fields changes the digest, so edited
    metadata no longer matches its approval.
  - A dedicated `mcp_server` domain keeps the grant out of reach of existing
    `arbor://mcp/<server>/<tool>` tool-call grants and `arbor://agent/...`
    wildcards.
  """

  @prefix "arbor://mcp_server/connect"
  @fields [:transport, :command, :env, :url, :server, :cwd, :environment_policy]

  @doc "The registered URI prefix every approval lives under."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @spec resource_uri(String.t(), map()) :: {:ok, String.t()} | {:error, :invalid_mcp_server}
  def resource_uri(name, config) when is_binary(name) and name != "" and is_map(config) do
    projection =
      Map.new(@fields, fn field ->
        {Atom.to_string(field), normalize(field, fetch(config, field))}
      end)

    digest = sha256(:erlang.term_to_binary(projection, [:deterministic]))
    {:ok, "#{@prefix}/#{sha256(name)}/#{digest}"}
  end

  def resource_uri(_name, _config), do: {:error, :invalid_mcp_server}

  defp fetch(config, :cwd), do: fetch_first(config, [:cwd, "cwd", :cd, "cd"])

  defp fetch(config, :environment_policy) do
    fetch_first(config, [
      :environment_policy,
      "environment_policy",
      :env_policy,
      "env_policy"
    ])
  end

  defp fetch(config, field) do
    case Map.fetch(config, field) do
      {:ok, value} -> value
      :error -> Map.get(config, Atom.to_string(field))
    end
  end

  defp fetch_first(config, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(config, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp normalize(:transport, nil), do: "stdio"
  defp normalize(:transport, transport) when is_atom(transport), do: Atom.to_string(transport)
  defp normalize(:command, command) when is_binary(command), do: [command]

  defp normalize(:env, env) when is_map(env),
    do: env |> Enum.map(fn {key, value} -> {to_string(key), value} end) |> Enum.sort()

  defp normalize(:environment_policy, policy) when is_atom(policy), do: Atom.to_string(policy)

  defp normalize(_field, value), do: value

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
