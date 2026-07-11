defmodule Arbor.Shell.CapPolicy do
  @moduledoc """
  Derives the legacy sandbox command projection from agent capabilities.

  This projection remains for low-level compatibility when a trusted system
  caller explicitly passes `:allowlist` to `Arbor.Shell.Sandbox.check/3`.
  Generic agent APIs no longer use it for execution: a command capability says
  *who may request* a resource, but does not prove that the executable cannot
  dispatch another command or evaluate runtime input.

  `Arbor.Shell.authorize/3` and its sync/async/streaming execution variants now
  enforce a separate fixed direct-executable policy before authorization.

  ## Projection (capability URI → command name)

      "arbor://shell/exec"            -> :all       (legacy projection only)
      "arbor://shell/exec/**"         -> :all
      "arbor://shell/exec/git"        -> "git"
      "arbor://shell/exec/git/**"     -> "git"       (subcommands are arg-level)
      "arbor://shell/exec/git/status" -> "git"       (command name is 1st segment)

  This is command-name granularity only. It is not an executable-shape proof and
  must not be used to select an agent child process.

  ## Safety

  This module only produces a legacy projection. Holding
  `arbor://shell/exec/git` does **not** make generic Git execution available;
  agents use schema-specific Git actions. The closed direct-executable policy in
  `Arbor.Shell.prepare_agent_command/2` is the agent execution boundary.
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
