defmodule Arbor.Orchestrator.Session.ToolDisclosure do
  @moduledoc """
  Progressive tool disclosure for agent sessions.

  Instead of loading all ~149 action tools into the LLM context at once,
  sessions start with a small core tool set (~12-15 tools) plus a `tool_find_tools`
  meta-tool. Agents discover additional tools on demand via `find_tools(query)`,
  which are then available for the rest of the session.

  ## Tool Visibility

  When the trust profile system is available, tool visibility is derived from
  the agent's trust profile via `profile_tools/1`. Tools where the profile mode
  is `:block` are hidden; tools where mode is `:ask` are annotated. Falls back
  to tier-based `core_tools/1` when Trust is unavailable.

  ## Authorization

  With `PolicyEnforcer` enabled, capabilities are granted JIT on first use —
  no upfront `ensure_tool_capabilities` call needed. The security layer
  auto-grants session-scoped capabilities based on the trust profile.

  ## Session Persistence

  Discovered tools are stored in `state.discovered_tools` (MapSet of tool name
  strings) and merged with core tools on each turn. A cap of 40 prevents
  context re-bloat.
  """

  require Logger

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

  When `agent_id` is provided and Trust profiles are available, derives
  tool visibility from the profile (hiding :block tools, annotating :ask).
  Falls back to tier-based core tools when Trust is unavailable.

  Priority:
  1. If `config["tools"]` is explicitly set, use it (backward compat) but
     ensure `find_tools` is included.
  2. If agent_id provided and Trust available, use profile_tools.
  3. Otherwise, merge core tools with discovered tools.
  """
  @spec resolve_tools(map(), atom(), MapSet.t(), keyword()) :: [String.t()]
  def resolve_tools(config, trust_tier, discovered_tools, opts \\ []) do
    explicit = config["tools"] || config[:tools]

    if is_list(explicit) and explicit != [] do
      explicit
    else
      agent_id = Keyword.get(opts, :agent_id)

      core =
        case agent_id do
          nil ->
            core_tools(trust_tier)

          aid ->
            case profile_tools(aid) do
              {:ok, tools} -> tools
              :fallback -> core_tools(trust_tier)
            end
        end

      discovered = MapSet.to_list(discovered_tools || MapSet.new())
      Enum.uniq(core ++ discovered)
    end
  end

  @doc """
  Derive tool visibility from the agent's trust profile.

  Queries the profile for all known tool URIs and returns tool names
  where the effective mode is not `:block`. Returns `:fallback` when
  the Trust system is unavailable.
  """
  @spec profile_tools(String.t()) :: {:ok, [String.t()]} | :fallback
  def profile_tools(agent_id) do
    actions_mod = Module.concat([:Arbor, :Actions])

    if trust_policy_available?() and
         Code.ensure_loaded?(actions_mod) and
         function_exported?(actions_mod, :all_actions, 0) do
      all_actions = apply(actions_mod, :all_actions, [])

      tools =
        all_actions
        |> Enum.map(fn action_mod ->
          # Get tool name from the action module
          name =
            if function_exported?(action_mod, :name, 0) do
              action_mod.name()
            else
              nil
            end

          uri =
            if name && function_exported?(actions_mod, :tool_name_to_canonical_uri, 1) do
              case apply(actions_mod, :tool_name_to_canonical_uri, [to_string(name)]) do
                {:ok, u} -> u
                _ -> nil
              end
            end

          {name, uri}
        end)
        |> Enum.reject(fn {name, uri} -> is_nil(name) or is_nil(uri) end)
        |> Enum.filter(fn {_name, uri} ->
          mode = get_effective_mode(agent_id, uri)
          mode != :block
        end)
        |> Enum.map(fn {name, _uri} -> to_string(name) end)

      # Include find_tools only if the profile allows it
      discover_mode = get_effective_mode(agent_id, "arbor://agent/discover_tools")

      tools =
        if discover_mode != :block do
          ensure_find_tools(tools)
        else
          tools
        end

      {:ok, tools}
    else
      :fallback
    end
  rescue
    e ->
      Logger.debug("ToolDisclosure.profile_tools failed: #{inspect(e)}")
      :fallback
  catch
    :exit, _ -> :fallback
  end

  @doc """
  Get tools that require approval (`:ask` mode) for annotation purposes.

  Returns a MapSet of tool names where the profile mode is `:ask`.
  These can be annotated in the LLM context to let agents know
  approval is required before use.
  """
  @spec ask_mode_tools(String.t()) :: MapSet.t()
  def ask_mode_tools(agent_id) do
    actions_mod = Module.concat([:Arbor, :Actions])

    if trust_policy_available?() and
         Code.ensure_loaded?(actions_mod) and
         function_exported?(actions_mod, :all_actions, 0) do
      all_actions = apply(actions_mod, :all_actions, [])

      all_actions
      |> Enum.filter(fn action_mod ->
        name =
          if function_exported?(action_mod, :name, 0),
            do: action_mod.name(),
            else: nil

        uri =
          if name && function_exported?(actions_mod, :tool_name_to_canonical_uri, 1) do
            case apply(actions_mod, :tool_name_to_canonical_uri, [to_string(name)]) do
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
    else
      MapSet.new()
    end
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

  Deprecated: With PolicyEnforcer enabled, capabilities are granted JIT
  on first use. This function is retained for backward compatibility when
  PolicyEnforcer is disabled.
  """
  @spec ensure_tool_capabilities(String.t(), [String.t()]) :: :ok
  def ensure_tool_capabilities(agent_id, tool_names) do
    # Skip if PolicyEnforcer is enabled — JIT grants handle this
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
  catch
    :exit, _ -> :ok
  end

  defp get_effective_mode(agent_id, resource_uri) do
    if Code.ensure_loaded?(Arbor.Trust.Policy) and
         function_exported?(Arbor.Trust.Policy, :effective_mode, 3) do
      apply(Arbor.Trust.Policy, :effective_mode, [agent_id, resource_uri, []])
    else
      :allow
    end
  rescue
    _ -> :allow
  catch
    :exit, _ -> :allow
  end

  defp trust_policy_available? do
    Code.ensure_loaded?(Arbor.Trust.Policy) and
      function_exported?(Arbor.Trust.Policy, :effective_mode, 3)
  end

  defp policy_enforcer_enabled? do
    if Code.ensure_loaded?(Arbor.Security.Config) and
         function_exported?(Arbor.Security.Config, :policy_enforcer_enabled?, 0) do
      apply(Arbor.Security.Config, :policy_enforcer_enabled?, [])
    else
      false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
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
