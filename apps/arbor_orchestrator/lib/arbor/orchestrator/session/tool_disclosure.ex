defmodule Arbor.Orchestrator.Session.ToolDisclosure do
  @moduledoc """
  Progressive tool disclosure for agent sessions.

  Instead of loading all ~149 action tools into the LLM context at once,
  sessions start with a small core tool set (~12-15 tools) plus a `tool_find_tools`
  meta-tool. Agents discover additional tools on demand via `find_tools(query)`,
  which are then available for the rest of the session.

  ## Core Tool Sets

  Core tools vary by trust tier — higher tiers get more powerful tools by default.
  All tiers include `find_tools` so agents can always discover more.

  ## Session Persistence

  Discovered tools are stored in `state.discovered_tools` (MapSet of tool name
  strings) and merged with core tools on each turn. A cap of 40 prevents
  context re-bloat.
  """

  @max_discovered 40

  @base_tools ~w(
    file_read file_write file_edit file_list file_search
    memory_recall memory_remember
    skill_search skill_activate
    git_status git_diff
    tool_find_tools
  )

  @established_extras ~w(shell_execute code_compile_and_test ai_generate_text git_commit git_log)

  @trusted_extras ~w(shell_execute_script code_hot_load)

  @doc """
  Return the core tool name list for a given trust tier.

  Higher tiers include progressively more powerful tools. All tiers
  include `find_tools` for on-demand discovery.
  """
  @spec core_tools(atom()) :: [String.t()]
  def core_tools(trust_tier) do
    case trust_tier do
      tier when tier in [:trusted, :full_partner, :system] ->
        @base_tools ++ @established_extras ++ @trusted_extras

      :established ->
        @base_tools ++ @established_extras

      _ ->
        @base_tools
    end
  end

  @doc """
  Maximum number of discovered tools to persist per session.
  """
  @spec max_discovered_tools() :: pos_integer()
  def max_discovered_tools, do: @max_discovered

  @doc """
  Resolve the effective tool list for a session turn.

  Priority:
  1. If `config["tools"]` is explicitly set, use it (backward compat) but
     ensure `find_tools` is included.
  2. Otherwise, merge core tools with discovered tools.
  """
  @spec resolve_tools(map(), atom(), MapSet.t()) :: [String.t()]
  def resolve_tools(config, trust_tier, discovered_tools) do
    explicit = config["tools"] || config[:tools]

    if is_list(explicit) and explicit != [] do
      ensure_find_tools(explicit)
    else
      core = core_tools(trust_tier)
      discovered = MapSet.to_list(discovered_tools || MapSet.new())
      Enum.uniq(core ++ discovered)
    end
  end

  @doc """
  Merge newly discovered tool names into the existing set, respecting the cap.
  """
  @spec merge_discovered(MapSet.t(), [String.t()]) :: MapSet.t()
  def merge_discovered(existing, new_names) do
    merged = Enum.reduce(new_names, existing, &MapSet.put(&2, &1))

    if MapSet.size(merged) > @max_discovered do
      merged
      |> MapSet.to_list()
      |> Enum.take(@max_discovered)
      |> MapSet.new()
    else
      merged
    end
  end

  @doc """
  Ensure the agent has security capabilities for all resolved tools.

  Called once at session start or when tools change. Grants capabilities
  for each tool's canonical URI so the security layer authorizes execution.
  Skips tools that can't be resolved (e.g. custom/external tools).
  """
  @spec ensure_tool_capabilities(String.t(), [String.t()]) :: :ok
  def ensure_tool_capabilities(agent_id, tool_names) do
    actions_mod = Module.concat([:Arbor, :Actions])
    security_mod = Module.concat([:Arbor, :Security])

    if Code.ensure_loaded?(actions_mod) and
         function_exported?(actions_mod, :tool_name_to_canonical_uri, 1) and
         Code.ensure_loaded?(security_mod) and
         function_exported?(security_mod, :grant, 1) do
      tool_names
      |> Enum.each(fn name ->
        with {:ok, uri} <- apply(actions_mod, :tool_name_to_canonical_uri, [name]) do
          apply(security_mod, :grant, [
            [
              principal: agent_id,
              resource: uri,
              constraints: %{},
              metadata: %{source: :progressive_disclosure}
            ]
          ])
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ensure_find_tools(tools) do
    has_find_tools =
      Enum.any?(tools, fn
        t when is_binary(t) -> t in ["find_tools", "tool_find_tools", "tool.find_tools"]
        t when is_atom(t) -> t in [:find_tools, :tool_find_tools]
        _ -> false
      end)

    if has_find_tools, do: tools, else: tools ++ ["tool_find_tools"]
  end
end
