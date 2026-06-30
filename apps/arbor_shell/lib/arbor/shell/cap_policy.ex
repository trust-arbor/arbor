defmodule Arbor.Shell.CapPolicy do
  @moduledoc """
  Derives a shell command allowlist from an agent's capabilities.

  This is the capability-derived-sandbox projection for shell: instead of the
  sandbox enforcing a hardcoded command allowlist (`Arbor.Shell.Sandbox`'s old
  `@strict_allowlist`) that ignored what the agent was actually granted, the
  allowlist is the set of commands the agent holds `arbor://shell/exec/<cmd>`
  capabilities for.

  This makes the sandbox's command check AGREE with the capability gate
  (`Arbor.Shell.authorize/3`) instead of conflicting with it. Before, an agent
  explicitly granted `arbor://shell/exec/git` still could not run `git` under a
  `:strict`/`:basic` sandbox because `git` was not in the hardcoded allowlist.

  ## Projection (capability URI → command name)

      "arbor://shell/exec"            -> :all       (bare exec = full shell)
      "arbor://shell/exec/**"         -> :all
      "arbor://shell/exec/git"        -> "git"
      "arbor://shell/exec/git/**"     -> "git"       (subcommands are arg-level)
      "arbor://shell/exec/git/status" -> "git"       (command name is 1st segment)

  Command-name granularity matches `Arbor.Shell`'s `extract_command_name/1`
  (first token, path stripped), so the derived allowlist never blocks a command
  the capability gate already authorized. Finer-grained (sub-command / argument)
  enforcement stays with the capability gate's full-URI check.

  ## Safety

  This module only produces the *command allowlist*. The orthogonal safety floor
  (shell-metacharacter blocking, dangerous-command/interpreter/flag blocking)
  stays in `Arbor.Shell.Sandbox` and is always applied — holding
  `arbor://shell/exec/git` lets an agent run `git`, but not `git; rm -rf` (a
  metacharacter escape) and not the dangerous-command/interpreter floor.
  """

  require Logger

  @prefix "arbor://shell/exec"

  @typedoc """
  A derived command allowlist: `:all` (a bare/wildcard `shell/exec` grant) or an
  explicit set of allowed command names.
  """
  @type allowlist :: :all | {:commands, MapSet.t(String.t())}

  @doc """
  Derive the shell command allowlist for an agent from its capabilities.

  Fails CLOSED: if the security infrastructure is unavailable or the agent has no
  capabilities, returns an empty allowlist (deny all). The capability gate in
  `Arbor.Shell.authorize/3` is the authoritative check; this is the sandbox-layer
  projection of the same grant.
  """
  @spec allowlist_for(String.t()) :: allowlist()
  def allowlist_for(agent_id) when is_binary(agent_id) do
    case Arbor.Security.list_capabilities(agent_id) do
      {:ok, caps} ->
        caps
        |> Enum.map(& &1.resource_uri)
        |> project()

      other ->
        Logger.warning(
          "[Shell.CapPolicy] could not list capabilities for #{agent_id} " <>
            "(#{inspect(other)}); failing closed to empty shell allowlist"
        )

        {:commands, MapSet.new()}
    end
  end

  def allowlist_for(_), do: {:commands, MapSet.new()}

  @doc """
  Project a list of capability resource URIs to a shell command allowlist.

  Pure — exposed for testing the projection independently of the security store.
  """
  @spec project([String.t()]) :: allowlist()
  def project(resource_uris) when is_list(resource_uris) do
    resource_uris
    |> Enum.filter(&String.starts_with?(&1, @prefix))
    |> Enum.reduce_while({:commands, MapSet.new()}, fn uri, {:commands, set} ->
      case command_from_uri(uri) do
        :wildcard -> {:halt, :all}
        {:command, cmd} -> {:cont, {:commands, MapSet.put(set, cmd)}}
        :none -> {:cont, {:commands, set}}
      end
    end)
  end

  @doc """
  Does the derived allowlist permit `command_name`?
  """
  @spec allows?(allowlist(), String.t()) :: boolean()
  def allows?(:all, _command_name), do: true
  def allows?({:commands, set}, command_name), do: MapSet.member?(set, command_name)

  # arbor://shell/exec[/...] -> :wildcard | {:command, name} | :none
  defp command_from_uri(uri) do
    case String.replace_prefix(uri, @prefix, "") do
      "" ->
        :wildcard

      "/**" ->
        :wildcard

      "/" <> rest ->
        case rest |> String.split("/") |> List.first() do
          "**" -> :wildcard
          "" -> :none
          cmd -> {:command, cmd}
        end

      _ ->
        :none
    end
  end
end
