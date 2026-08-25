defmodule Arbor.Orchestrator.Session.ToolDisclosure do
  @moduledoc """
  Progressive tool disclosure for agent sessions.

  Instead of loading all ~150 action tools into the LLM context at once,
  sessions start with a small floor (`core_tools/0`) plus the tools the agent
  holds capabilities for. Agents discover additional tools on demand via
  `find_tools(query)`, which are then available for the rest of the session.

  ## Tool Visibility

  When the trust profile system is available, `profile_tools/1` discloses:

      disclosed = core_tools()  (the universal floor)
                ∪ tools whose capability the agent HOLDS
                ∪ session-discovered tools

  Tools the trust profile would merely auto-mint on first use are NOT shown by
  default; they stay reachable through `tool_find_tools`, which searches the
  full catalog. Before 2026-08-25 mintable tools were disclosed too, and a
  conversationalist holding 12 capabilities was shown 120 tools (151 before the
  cap) — exposure is now gated on held capability, while execution is still
  gated exactly as before. Tools where the profile mode is `:block` are hidden
  even when held or in the floor; `:ask` tools are annotated. Falls back to
  `core_tools/0` when Trust is unavailable.

  "Holds" is matched on parsed URI segments in both directions, because real
  grants come in three shapes: exact (`arbor://fs/read`), ancestor wildcard
  (`arbor://fs/**`), and scoped descendant (`arbor://fs/read/<dir>/**`,
  `arbor://code/read/<agent>/*`). An exact match would silently drop the third
  shape — which is what ACP and self-memory grants look like — and a raw
  `String.starts_with?/2` would match siblings (`arbor://fs/reader`).

  ## Authorization

  With the trust-layer `PolicyEnforcer` enabled, capabilities are granted JIT on
  first use through `Arbor.Trust.authorize/4` — no upfront
  `ensure_tool_capabilities` call needed. The security layer itself only checks
  held capabilities.

  ## Session Persistence

  Discovered tools are stored in `state.discovered_tools` (MapSet of tool name
  strings) and merged with core tools on each turn. A cap of 40 prevents
  context re-bloat.
  """

  require Logger

  @max_discovered 40
  # Most models cap at 128 tools. Truncate to stay under the limit.
  # Priority: core tools first, then discovered tools fill remaining slots.
  @max_tools_for_llm 120

  # The UNIVERSAL floor: what any agent needs to function at all, regardless of
  # what it is for. Memory is here because remembering and recalling is
  # foundational to being an agent — the closest counter-case, a deliberately
  # ephemeral agent, is expressed by giving it an empty memory store, not by
  # hiding the verbs.
  @base_tools ~w(
    memory_recall memory_remember
    skill_search skill_activate
    tool_find_tools
    ai_generate_text
  )

  # Development tooling. This used to sit in @base_tools, so EVERY agent carried
  # a coding agent's toolkit as its permanent floor — 13 of the 19 base entries
  # were dev tools, and a conversationalist was handed shell_execute, git_commit
  # and code_hot_load it had no use for (measured 2026-08-25). Granted as a
  # collection instead: an agent that should write code holds these capabilities
  # and sees them; one that should not, does not.
  #
  # `code_pattern_*` belongs here rather than with memory. It is memory-BACKED
  # (arbor://memory/write) but it is a code-snippet library, so it is useful to
  # exactly the agents that hold the rest of this collection.
  @coding_tools ~w(
    file_read file_write file_edit file_list file_search file_exists file_glob
    git_status git_diff git_commit git_log
    shell_execute shell_execute_script
    code_compile_and_test code_hot_load
    code_pattern_store code_pattern_list code_pattern_view code_pattern_delete
  )

  @doc """
  The universal floor: always disclosed (unless the profile blocks a tool), and
  the whole tool set when Trust is unavailable.

  Everything beyond the floor is disclosed only when the agent HOLDS the
  capability — see `profile_tools/1`. Always includes `find_tools` for
  on-demand discovery.
  """
  @spec core_tools() :: [String.t()]
  def core_tools, do: @base_tools

  @doc """
  Development tooling, granted as a collection rather than carried by every
  agent. See `@coding_tools`.
  """
  @spec coding_tools() :: [String.t()]
  def coding_tools, do: @coding_tools

  @doc """
  Maximum number of discovered tools to persist per session.
  """
  @spec max_discovered_tools() :: pos_integer()
  def max_discovered_tools, do: @max_discovered

  @doc """
  Resolve the effective tool list for a session turn.

  When `agent_id` is provided and Trust profiles are available, discloses the
  floor plus held capabilities (hiding :block tools, annotating :ask).
  Falls back to `core_tools/0` when Trust is unavailable.

  Priority:
  1. If `config["tools"]` is explicitly set, use it (backward compat) but
     ensure `find_tools` is included.
  2. If agent_id provided and Trust available, use profile_tools.
  3. Otherwise, merge core tools with discovered tools.
  """
  @spec resolve_tools(map(), MapSet.t(), keyword()) :: [String.t()]
  def resolve_tools(config, discovered_tools, opts \\ []) do
    explicit = config["tools"] || config[:tools]

    if is_list(explicit) and explicit != [] do
      explicit
    else
      agent_id = Keyword.get(opts, :agent_id)

      core =
        case agent_id do
          nil ->
            core_tools()

          aid ->
            case profile_tools(aid) do
              {:ok, tools} -> tools
              :fallback -> core_tools()
            end
        end

      discovered = MapSet.to_list(discovered_tools || MapSet.new())
      all_tools = Enum.uniq(core ++ discovered)

      cap_tools_for_llm(all_tools, core, discovered)
    end
  end

  @doc """
  Derive tool visibility from the agent's trust profile: the floor plus every
  tool whose capability the agent holds.

  Read-only — nothing is minted. Policy-mintable tools the agent does not hold
  are deliberately left out; `tool_find_tools` surfaces them on demand.
  Returns `:fallback` when the Trust system is unavailable.
  """
  @spec profile_tools(String.t()) :: {:ok, [String.t()]} | :fallback
  def profile_tools(agent_id) do
    # arbor_security/arbor_trust are hard deps; the rescue/catch below degrades
    # to :fallback if either subsystem's process is down.
    uri_to_tool_names = build_uri_to_tool_names_map()
    {:ok, snapshot} = Arbor.Trust.enumerate_authority(agent_id, Map.keys(uri_to_tool_names))

    entries_by_uri = Map.new(snapshot.candidate_entries, &{&1.uri, &1})
    held_uris = snapshot.held_uris

    {blocked, unblocked} =
      Enum.split_with(uri_to_tool_names, fn {uri, _names} ->
        match?(%{mode: :block}, Map.get(entries_by_uri, uri))
      end)

    blocked_tools = Enum.flat_map(blocked, fn {_uri, names} -> names end)

    held_tools =
      unblocked
      |> Enum.filter(fn {uri, _names} ->
        holds_for_disclosure?(Map.get(entries_by_uri, uri), uri, held_uris)
      end)
      |> Enum.flat_map(fn {_uri, names} -> names end)

    tools = Enum.uniq((@base_tools -- blocked_tools) ++ held_tools)

    # Include find_tools only if the profile allows it
    discover_mode = get_effective_mode(agent_id, "arbor://agent/discover_tools")

    tools =
      if discover_mode != :block do
        ensure_find_tools(tools)
      else
        tools
      end

    hidden_mintable =
      Enum.count(unblocked, fn {uri, _names} ->
        entry = Map.get(entries_by_uri, uri)

        match?(%{policy_mintable: true}, entry) and
          not holds_for_disclosure?(entry, uri, held_uris)
      end)

    Logger.debug(
      "[ToolDisclosure] profile_tools for #{agent_id}: #{length(tools)} tools " <>
        "(floor=#{length(@base_tools)}, held=#{length(held_tools)} from " <>
        "#{length(snapshot.held_capabilities)} held capabilities; " <>
        "#{hidden_mintable} policy-mintable URIs left to discovery)"
    )

    {:ok, tools}
  rescue
    e ->
      Logger.debug("ToolDisclosure.profile_tools failed: #{inspect(e)}")
      :fallback
  catch
    :exit, _ -> :fallback
  end

  # Does the agent hold authority over the tool's canonical URI, for the
  # purpose of SHOWING the tool? Two directions, both segment-aware:
  #
  #   * `entry.held` — Trust already ran `Security.capability_authorizes?/3`
  #     for the canonical URI, so exact grants and ancestor wildcards
  #     (`arbor://fs/**` ⊇ `arbor://fs/read`) are covered.
  #   * a held URI UNDER the canonical one — a scoped grant such as
  #     `arbor://fs/read/<dir>/**` does not authorize the bare `arbor://fs/read`
  #     resource (that is correct for execution), but the agent plainly holds
  #     file_read authority for some paths and should see the tool. Matched with
  #     `CapabilityUri.prefix_match?/2` so `arbor://fs/reader/x` cannot match.
  #
  # Verified against the three grant shapes present on the live node 2026-08-25.
  defp holds_for_disclosure?(%{held: true}, _canonical_uri, _held_uris), do: true

  defp holds_for_disclosure?(_entry, canonical_uri, held_uris) do
    Enum.any?(held_uris, &Arbor.Contracts.Security.CapabilityUri.prefix_match?(canonical_uri, &1))
  end

  # Build a reverse lookup: canonical_uri -> tool names from EXPOSED actions.
  # `exposed_actions/0`, not `all_actions/0`: pipeline_internal graph syscalls
  # (session_memory_*, session_goals_*, …) live under arbor://orchestrator/**,
  # which ordinary agents hold, and the LLM handler resolves disclosed names
  # through the registry with no further filter — so `all_actions/0` here put
  # 15 graph syscalls in a conversationalist's chat menu (seen live 2026-08-25;
  # the APIAgent path `Actions.tool_modules_for_agent/1` already excluded them).
  defp build_uri_to_tool_names_map do
    Arbor.Actions.exposed_actions()
    |> Enum.flat_map(fn action_mod ->
      name = if function_exported?(action_mod, :name, 0), do: action_mod.name(), else: nil

      if name do
        tool_name = to_string(name)
        [{Arbor.Actions.canonical_uri_for(action_mod, %{}), tool_name}]
      else
        []
      end
    end)
    |> Enum.reduce(%{}, fn {uri, tool_name}, acc ->
      Map.update(acc, uri, [tool_name], &[tool_name | &1])
    end)
    |> Map.new(fn {uri, names} -> {uri, names |> Enum.reverse() |> Enum.uniq()} end)
  end

  @doc """
  Get tools that require approval (`:ask` mode) for annotation purposes.

  Returns a MapSet of tool names where the profile mode is `:ask`.
  These can be annotated in the LLM context to let agents know
  approval is required before use.
  """
  @spec ask_mode_tools(String.t()) :: MapSet.t()
  def ask_mode_tools(agent_id) do
    # arbor_trust is a hard dep; the rescue/catch degrades to an empty set if
    # the trust subsystem is down.
    Arbor.Actions.exposed_actions()
    |> Enum.filter(fn action_mod ->
      name =
        if function_exported?(action_mod, :name, 0),
          do: action_mod.name(),
          else: nil

      uri =
        if name do
          case Arbor.Actions.tool_name_to_canonical_uri(to_string(name)) do
            {:ok, u} -> u
            _ -> nil
          end
        end

      name != nil and uri != nil and get_effective_mode(agent_id, uri) == :ask
    end)
    |> Enum.map(fn action_mod ->
      to_string(action_mod.name())
    end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
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

  Deprecated: with the trust-layer PolicyEnforcer enabled, capabilities are
  granted JIT on first use. This function is retained for backward
  compatibility when PolicyEnforcer is disabled.
  """
  @spec ensure_tool_capabilities(String.t(), [String.t()]) :: :ok
  def ensure_tool_capabilities(agent_id, tool_names) do
    # Skip if trust-layer PolicyEnforcer is enabled — JIT grants handle this.
    if policy_enforcer_enabled?() do
      :ok
    else
      do_ensure_tool_capabilities(agent_id, tool_names)
    end
  end

  # ===========================================================================
  # Internals
  # ===========================================================================

  defp do_ensure_tool_capabilities(agent_id, tool_names) do
    # arbor_security is a hard dep — Arbor.Security.grant/1 is called directly.
    tool_names
    |> Enum.each(fn name ->
      with {:ok, uri} <- Arbor.Actions.tool_name_to_canonical_uri(name) do
        Arbor.Security.grant(
          principal: agent_id,
          resource: uri,
          constraints: %{},
          metadata: %{source: :progressive_disclosure}
        )
      end
    end)

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp get_effective_mode(agent_id, resource_uri) do
    # arbor_trust is a hard dep — Arbor.Trust.effective_mode/3 is called directly.
    Arbor.Trust.effective_mode(agent_id, resource_uri, [])
  rescue
    _ -> :allow
  catch
    :exit, _ -> :allow
  end

  defp policy_enforcer_enabled? do
    # arbor_trust is a hard dep — Arbor.Trust.Config is called directly.
    Arbor.Trust.Config.policy_enforcer_enabled?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Cap the total tool list to stay under model limits.
  # Priority: core tools first (profile-derived), then discovered fill remaining slots.
  # If core alone exceeds the cap, truncate core but always keep tool_find_tools.
  defp cap_tools_for_llm(all_tools, _core, _discovered)
       when length(all_tools) <= @max_tools_for_llm,
       do: all_tools

  defp cap_tools_for_llm(_all_tools, core, discovered) do
    Logger.debug(
      "[ToolDisclosure] Truncating tools to #{@max_tools_for_llm} " <>
        "(core=#{length(core)}, discovered=#{length(discovered)})"
    )

    capped_core = core |> prioritize_base_tools() |> Enum.take(@max_tools_for_llm)
    remaining = @max_tools_for_llm - length(capped_core)

    result = capped_core ++ Enum.take(discovered, max(remaining, 0))
    ensure_find_tools(Enum.uniq(result))
  end

  # `core` arrives in `snapshot.candidate_entries` order, which comes from
  # `Map.keys(uri_to_tool_names)` — arbitrary map ordering, with no notion of
  # which tools matter. Truncating that directly drops tools by POSITION: an
  # agent authorized for 142 tools against a 120 cap loses 22 of them at random,
  # and whether `memory_recall` survives is luck (measured 2026-08-25: 142 vs
  # 120). `@base_tools` already names the ones an agent needs for ordinary work,
  # but it was only consulted as a fallback for when Trust is unavailable, so it
  # never influenced this path. Float those to the front so the curated set is
  # never the part that gets cut, while leaving the rest of the order untouched.
  @doc """
  Order a tool list so the curated `core_tools/0` come first.

  Public because it is the guard for a silent failure: truncation cuts by
  POSITION, so without this the tools an agent needs for ordinary work can be
  dropped purely because of where they landed in an unordered map.
  """
  @spec prioritize_base_tools([String.t() | atom()]) :: [String.t() | atom()]
  def prioritize_base_tools(core) do
    {base, rest} = Enum.split_with(core, &(to_string(&1) in @base_tools))
    {coding, other} = Enum.split_with(rest, &(to_string(&1) in @coding_tools))
    base ++ coding ++ other
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
