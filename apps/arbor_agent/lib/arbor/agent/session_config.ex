defmodule Arbor.Agent.SessionConfig do
  @moduledoc """
  Shared session configuration builder.

  Single source of truth for building the keyword list that
  `Arbor.Orchestrator.Session.init/1` expects. Used by both
  `Lifecycle.start` (BranchSupervisor path) and `SessionManager`
  (legacy path).
  """

  @doc """
  Build session init options from agent opts.

  Resolves tool names, builds LLM config, sets DOT paths,
  and optionally adds compactor and checkpoint recovery.

  ## Options

  - `:trust_tier` — agent trust tier (default: :established)
  - `:provider` — LLM provider atom
  - `:model` — LLM model string
  - `:system_prompt` — system prompt for the session
  - `:tools` — list of tool name strings or action modules
  - `:start_heartbeat` — whether to start heartbeat (default: true)
  - `:signer` — signing function for tool calls
  - `:tenant_context` — multi-user context
  - `:context_management` — :none, :heuristic, or :full (default: :full)
  - `:heartbeat_dot` — override heartbeat DOT path
  - `:recover_session` — whether to load saved session entries (default: false)
  """
  @spec build(String.t(), keyword()) :: keyword()
  def build(agent_id, opts) do
    trust_tier = Keyword.get(opts, :trust_tier, :established)
    provider = Keyword.get(opts, :provider)

    tool_names = resolve_tool_names(Keyword.get(opts, :tools))

    llm_config =
      %{}
      |> maybe_put("llm_provider", if(provider, do: to_string(provider)))
      |> maybe_put("llm_model", Keyword.get(opts, :model))
      |> maybe_put("system_prompt", Keyword.get(opts, :system_prompt))
      |> maybe_put("tools", tool_names)

    base = [
      session_id: "agent-session-#{agent_id}",
      agent_id: agent_id,
      trust_tier: trust_tier,
      adapters: %{},
      turn_dot: turn_dot_path(),
      heartbeat_dot: Keyword.get(opts, :heartbeat_dot, heartbeat_dot_path()),
      start_heartbeat: Keyword.get(opts, :start_heartbeat, true),
      execution_mode: :session,
      signer: Keyword.get(opts, :signer),
      config: llm_config,
      tenant_context: Keyword.get(opts, :tenant_context)
    ]

    # Add compactor config if context management is enabled
    base =
      case build_compactor_config(opts) do
        nil -> base
        config -> Keyword.put(base, :compactor, config)
      end

    # Optionally recover saved session entries from Postgres
    if Keyword.get(opts, :recover_session, false) do
      session_id = "agent-session-#{agent_id}"
      recover_session(base, session_id)
    else
      base
    end
  end

  # ── Tool name resolution ─────────────────────────────────────────

  defp resolve_tool_names(nil), do: nil

  defp resolve_tool_names(tools) when is_list(tools) do
    Enum.map(tools, fn
      mod when is_atom(mod) ->
        if function_exported?(mod, :name, 0), do: mod.name(), else: inspect(mod)

      name when is_binary(name) ->
        name
    end)
  end

  # ── DOT path resolution ──────────────────────────────────────────

  defp turn_dot_path do
    Application.get_env(:arbor_ai, :session_turn_dot, default_turn_dot())
  end

  defp heartbeat_dot_path do
    Application.get_env(:arbor_ai, :session_heartbeat_dot, default_heartbeat_dot())
  end

  defp default_turn_dot do
    Path.join([orchestrator_app_dir(), "specs", "pipelines", "session", "turn.dot"])
  end

  defp default_heartbeat_dot do
    Path.join([orchestrator_app_dir(), "specs", "pipelines", "session", "heartbeat.dot"])
  end

  defp orchestrator_app_dir do
    cwd = File.cwd!()

    candidates = [
      Path.join([cwd, "apps", "arbor_orchestrator"]),
      Path.join([cwd, "..", "arbor_orchestrator"]) |> Path.expand(),
      cwd
    ]

    case Enum.find(candidates, fn path ->
           File.dir?(path) and File.exists?(Path.join(path, "specs"))
         end) do
      nil ->
        case :code.priv_dir(:arbor_orchestrator) do
          {:error, _} -> List.first(candidates)
          priv_dir -> Path.dirname(to_string(priv_dir))
        end

      path ->
        path
    end
  end

  # ── Compactor config ─────────────────────────────────────────────

  defp build_compactor_config(opts) do
    context_management = Keyword.get(opts, :context_management, :full)

    if context_management != :none do
      compactor_module = Arbor.Agent.ContextCompactor

      if Code.ensure_loaded?(compactor_module) do
        compactor_opts = [
          effective_window: Keyword.get(opts, :effective_window, 75_000),
          model: Keyword.get(opts, :model),
          enable_llm_compaction: context_management == :full
        ]

        {compactor_module, compactor_opts}
      else
        nil
      end
    else
      nil
    end
  end

  # ── Session recovery ─────────────────────────────────────────────

  defp recover_session(base, session_id) do
    session_store = Arbor.Agent.SessionStore

    if Code.ensure_loaded?(session_store) and
         function_exported?(session_store, :load_entries, 1) do
      case apply(session_store, :load_entries, [session_id]) do
        {:ok, entries} when entries != [] ->
          Keyword.put(base, :checkpoint, %{messages: entries})

        _ ->
          base
      end
    else
      base
    end
  rescue
    _ -> base
  catch
    :exit, _ -> base
  end

  # ── Helpers ──────────────────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
