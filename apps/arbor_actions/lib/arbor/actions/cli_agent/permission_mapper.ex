defmodule Arbor.Actions.CliAgent.PermissionMapper do
  @moduledoc """
  Bidirectional mapping between Arbor capability URIs and Claude CLI tool names.

  Translates an agent's granted capabilities into `--allowedTools` / `--disallowedTools`
  CLI flags so that a Claude subprocess only has access to tools the calling agent
  is authorized for.

  Currently Claude-specific. Other CLI agents have different permission models
  and will need their own mappers or an adapter-aware extension.

  ## Capability URI → CLI Tools

      "arbor://shell/exec"  → ["Bash"]
      "arbor://fs/read"     → ["Read", "Glob", "Grep"]
      "arbor://fs/write"    → ["Edit", "Write", "NotebookEdit"]
      "arbor://net/http"    → ["WebFetch"]
      "arbor://net/search"  → ["WebSearch"]
      "arbor://tool/use"    → :all (wildcard — all tools allowed)

  ## Runtime Bridge

  Uses `Code.ensure_loaded?/1` + `apply/3` to call `Arbor.Security` without a
  compile-time dependency (arbor_actions is Level 2, arbor_security is Level 1).
  If Security is unavailable, returns empty flags (no restrictions) — the outer
  `authorize_and_execute/4` has already verified the action capability.
  """

  @capability_to_tools %{
    "arbor://shell/exec" => ["Bash"],
    "arbor://fs/read" => ["Read", "Glob", "Grep"],
    "arbor://fs/write" => ["Edit", "Write", "NotebookEdit"],
    "arbor://net/http" => ["WebFetch"],
    "arbor://net/search" => ["WebSearch"],
    "arbor://tool/use" => :all
  }

  @tool_to_capability %{
    "Bash" => "arbor://shell/exec",
    "Read" => "arbor://fs/read",
    "Glob" => "arbor://fs/read",
    "Grep" => "arbor://fs/read",
    "Edit" => "arbor://fs/write",
    "Write" => "arbor://fs/write",
    "NotebookEdit" => "arbor://fs/write",
    "WebFetch" => "arbor://net/http",
    "WebSearch" => "arbor://net/search"
  }

  @doc """
  Build `--allowedTools` CLI flags from an agent's granted capabilities.

  Queries `Arbor.Security.list_capabilities/2` at runtime for the agent's
  capabilities, then maps them to CLI tool names.

  Returns `{:ok, flags}` where flags is either:
  - `[]` — no restrictions (agent has wildcard or Security unavailable)
  - `["--allowedTools", "Read,Glob,Grep,Bash"]` — restricted to listed tools

  ## Examples

      iex> PermissionMapper.capabilities_to_tool_flags("agent_abc123")
      {:ok, ["--allowedTools", "Read,Glob,Grep,Bash"]}

      # Agent with tool/use wildcard
      iex> PermissionMapper.capabilities_to_tool_flags("agent_full_access")
      {:ok, []}
  """
  @spec capabilities_to_tool_flags(String.t()) :: {:ok, [String.t()]}
  def capabilities_to_tool_flags(agent_id) do
    case list_agent_capabilities(agent_id) do
      {:ok, capabilities} ->
        case capabilities_to_tools(capabilities) do
          :all ->
            {:ok, []}

          tools when is_list(tools) and tools != [] ->
            {:ok, ["--allowedTools", Enum.join(tools, ",")]}

          [] ->
            {:ok, []}
        end

      {:error, _reason} ->
        # Security unavailable — no restrictions
        {:ok, []}
    end
  end

  @doc """
  Convert a list of capability URIs to CLI tool names.

  Returns `:all` if any capability maps to the wildcard, otherwise returns
  a deduplicated, sorted list of CLI tool names.

  ## Examples

      iex> PermissionMapper.capabilities_to_tools(["arbor://fs/read", "arbor://shell/exec"])
      ["Bash", "Glob", "Grep", "Read"]

      iex> PermissionMapper.capabilities_to_tools(["arbor://tool/use"])
      :all

      iex> PermissionMapper.capabilities_to_tools([])
      []
  """
  @spec capabilities_to_tools([String.t()] | [map()]) :: :all | [String.t()]
  def capabilities_to_tools(capabilities) do
    capabilities
    |> Enum.reduce([], fn cap, acc ->
      uri = extract_capability_uri(cap)

      case lookup_tools_for_capability(uri) do
        :all -> throw(:all)
        tools -> tools ++ acc
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  catch
    :throw, :all -> :all
  end

  @doc """
  Look up the capability URI required for a given CLI tool name.

  ## Examples

      iex> PermissionMapper.tool_to_capability_uri("Bash")
      {:ok, "arbor://shell/exec"}

      iex> PermissionMapper.tool_to_capability_uri("Unknown")
      {:ok, "arbor://tool/use"}
  """
  @spec tool_to_capability_uri(String.t()) :: {:ok, String.t()}
  def tool_to_capability_uri(tool_name) do
    case Map.get(@tool_to_capability, tool_name) do
      nil -> {:ok, "arbor://tool/use"}
      uri -> {:ok, uri}
    end
  end

  @doc """
  Returns the static capability-to-tools mapping.
  """
  @spec capability_mapping() :: %{String.t() => [String.t()] | :all}
  def capability_mapping, do: @capability_to_tools

  @doc """
  Returns the static tool-to-capability mapping.
  """
  @spec tool_mapping() :: %{String.t() => String.t()}
  def tool_mapping, do: @tool_to_capability

  # -- Private --

  # Look up tools for a capability URI. Supports both exact and prefix matching.
  defp lookup_tools_for_capability(uri) do
    case Map.get(@capability_to_tools, uri) do
      nil -> lookup_by_prefix(uri)
      result -> result
    end
  end

  # Prefix match: "arbor://fs/read/some/path" matches "arbor://fs/read"
  defp lookup_by_prefix(uri) do
    Enum.find_value(@capability_to_tools, [], fn {prefix, tools} ->
      if String.starts_with?(uri, prefix <> "/") do
        tools
      end
    end)
  end

  # Extract URI string from various capability formats
  defp extract_capability_uri(cap) when is_binary(cap), do: cap

  defp extract_capability_uri(%{resource: resource}) when is_binary(resource), do: resource

  defp extract_capability_uri(%{"resource" => resource}) when is_binary(resource), do: resource

  defp extract_capability_uri(_), do: ""

  # Runtime bridge to Arbor.Security.list_capabilities/2
  defp list_agent_capabilities(agent_id) do
    if Code.ensure_loaded?(Arbor.Security) do
      try do
        case apply(Arbor.Security, :list_capabilities, [agent_id, []]) do
          {:ok, caps} -> {:ok, caps}
          caps when is_list(caps) -> {:ok, caps}
          other -> {:error, {:unexpected_result, other}}
        end
      catch
        :exit, _ -> {:error, :security_unavailable}
      end
    else
      {:error, :security_not_loaded}
    end
  end
end
