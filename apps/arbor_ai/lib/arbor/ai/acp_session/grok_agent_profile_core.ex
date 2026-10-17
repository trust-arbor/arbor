defmodule Arbor.AI.AcpSession.GrokAgentProfileCore do
  @moduledoc """
  Pure derivation of the Grok `--agent-profile` YAML from capability URIs.

  Native Grok file tools are enabled only when the agent already holds a
  matching filesystem capability:

  - `read_file`, `grep`, `list_dir` require `arbor://fs/read` (class, path,
    or wildcard)
  - `search_replace` requires `arbor://fs/write`

  Process execution and subagents stay in `disallowedTools` even when the
  agent holds `arbor://shell/exec` or `arbor://agent/spawn`. Those operations
  remain Arbor syscalls (`--deny Bash(*)`, `--no-subagents`); the native Grok
  tools must not become an alternate execution path.
  """

  alias Arbor.Contracts.Security.CapabilityUri

  @always_disallowed ["run_terminal_cmd", "task", "get_task_output", "kill_task"]

  @doc """
  Render the attested agent-profile bytes for `capability_uris`.

  Non-list input and unrecognized URIs fail closed to an empty tool set.
  `run_terminal_cmd` is never emitted under `tools:`.
  """
  @spec render(term()) :: String.t()
  def render(capability_uris) when is_list(capability_uris) do
    read? = holds_fs?(capability_uris, "read")
    write? = holds_fs?(capability_uris, "write")

    tools =
      []
      |> maybe_add(read?, "read_file")
      |> maybe_add(write?, "search_replace")
      |> maybe_add(read?, "grep")
      |> maybe_add(read?, "list_dir")

    """
    ---
    name: arbor-no-shell
    description: Arbor ACP coding profile with native file tools and no process execution.
    prompt_mode: full
    permission_mode: default
    agents_md: true
    #{tools_yaml(tools)}disallowedTools:
    #{yaml_list(@always_disallowed)}---

    Use native file tools for reading and editing.
    Process execution and subagents are unavailable by design.
    """
  end

  def render(_capability_uris), do: render([])

  defp holds_fs?(uris, operation) when operation in ["read", "write"] do
    class = "arbor://fs/#{operation}"

    Enum.any?(uris, fn
      uri when is_binary(uri) ->
        CapabilityUri.prefix_match?(class, uri) or CapabilityUri.capability_match?(uri, class)

      _other ->
        false
    end)
  end

  defp maybe_add(tools, true, name), do: tools ++ [name]
  defp maybe_add(tools, false, _name), do: tools

  defp tools_yaml([]), do: "tools: []\n"

  defp tools_yaml(tools) do
    "tools:\n" <> yaml_list(tools)
  end

  defp yaml_list(names) do
    Enum.map_join(names, "", &"  - #{&1}\n")
  end
end
