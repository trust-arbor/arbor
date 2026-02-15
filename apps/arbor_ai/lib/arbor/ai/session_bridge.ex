defmodule Arbor.AI.SessionBridge do
  @moduledoc """
  Strangler fig bridge: routes generate_text_with_tools through Session when available.

  When `:arbor_ai, :session_enabled` is true and the orchestrator is available,
  this module starts an ephemeral Session, runs the user's prompt through the
  turn graph, and converts the result to the CallWithTools response format.

  Falls through to `{:unavailable, reason}` on any failure — the caller
  (generate_text_with_tools) catches this and falls back to CallWithTools.

  ## Session Lifecycle

  Currently uses ephemeral sessions (start → use → stop per query). This
  validates the Session path without requiring a persistent session registry.
  Evolution to per-agent persistent sessions is planned for Phase 4.

  ## Configuration

      config :arbor_ai,
        session_enabled: true,
        session_turn_dot: "path/to/turn.dot",
        session_heartbeat_dot: "path/to/heartbeat.dot"
  """

  require Logger

  @session_module Arbor.Orchestrator.Session
  @adapters_module Arbor.Orchestrator.Session.Adapters
  @tool_module Arbor.Orchestrator.UnifiedLLM.Tool

  @doc """
  Try the Session path for a tool-calling query.

  Returns `{:ok, response}` on success or `{:unavailable, reason}` if the
  Session path can't be used. Never returns `{:error, _}` — all errors
  become `:unavailable` to trigger CallWithTools fallback.
  """
  @spec try_session_call(String.t(), keyword()) :: {:ok, map()} | {:unavailable, term()}
  def try_session_call(prompt, opts) do
    if enabled?() and orchestrator_available?() do
      run_session(prompt, opts)
    else
      {:unavailable, :session_disabled}
    end
  end

  @doc """
  Check whether the Session path is enabled and available.
  """
  @spec available?() :: boolean()
  def available? do
    enabled?() and orchestrator_available?()
  end

  @session_manager_module Arbor.Agent.SessionManager

  # ── Session execution ────────────────────────────────────────────

  defp run_session(prompt, opts) do
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)

    case find_persistent_session(agent_id) do
      {:ok, session_pid} ->
        run_persistent_session(session_pid, prompt, provider, model)

      :no_session ->
        run_ephemeral_session(prompt, opts)
    end
  rescue
    e ->
      Logger.warning("[SessionBridge] Unexpected error: #{Exception.message(e)}")
      {:unavailable, {:exception, Exception.message(e)}}
  end

  defp find_persistent_session(agent_id) do
    if Code.ensure_loaded?(@session_manager_module) do
      case apply(@session_manager_module, :get_session, [agent_id]) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} -> :no_session
      end
    else
      :no_session
    end
  rescue
    _ -> :no_session
  end

  defp run_persistent_session(session_pid, prompt, provider, model) do
    case send_message(session_pid, prompt) do
      {:ok, text} ->
        state = get_state(session_pid)
        {:ok, build_response(text, state, provider, model)}

      {:error, reason} ->
        {:unavailable, {:session_error, reason}}
    end
  end

  defp run_ephemeral_session(prompt, opts) do
    agent_id = Keyword.get(opts, :agent_id, "anonymous")
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)
    trust_tier = Keyword.get(opts, :trust_tier, :established)
    system_prompt = Keyword.get(opts, :system_prompt)

    # Convert Jido action modules to orchestrator Tool structs
    action_modules = Keyword.get(opts, :tools, [])
    tools = convert_action_modules(action_modules)

    # Build adapters using the orchestrator's adapter factory
    adapters = build_adapters(agent_id, trust_tier, provider, model, system_prompt, tools)

    # Start ephemeral Session (no heartbeat, no name registration)
    session_opts = [
      session_id: "bridge-#{:erlang.unique_integer([:positive])}",
      agent_id: agent_id,
      trust_tier: trust_tier,
      adapters: adapters,
      turn_dot: turn_dot_path(),
      heartbeat_dot: heartbeat_dot_path(),
      start_heartbeat: false,
      execution_mode: :session
    ]

    case start_session(session_opts) do
      {:ok, pid} ->
        try do
          case send_message(pid, prompt) do
            {:ok, text} ->
              state = get_state(pid)
              {:ok, build_response(text, state, provider, model)}

            {:error, reason} ->
              {:unavailable, {:session_error, reason}}
          end
        after
          stop_session(pid)
        end

      {:error, reason} ->
        {:unavailable, {:session_start_failed, reason}}
    end
  end

  # ── Response format bridge ───────────────────────────────────────
  #
  # Converts Session result to the format that generate_text_with_tools
  # expects (matching CallWithTools output via format_tools_response).

  defp build_response(text, session_state, provider, model) do
    %{
      text: text || "",
      thinking: nil,
      # TODO: Thread usage through Session adapters (format_llm_response enrichment)
      usage: %{},
      model: to_string(model || ""),
      provider: to_string(provider || ""),
      # Session handles tool calls internally via the turn graph cycle
      tool_calls: [],
      turns: Map.get(session_state, :turn_count, 1),
      type: :session
    }
  end

  # ── Tool conversion ──────────────────────────────────────────────
  #
  # Convert Jido Action modules to orchestrator Tool structs at runtime.
  # Uses struct/2 to create Tool structs without compile-time dependency.

  defp convert_action_modules(action_modules) when is_list(action_modules) do
    if Code.ensure_loaded?(@tool_module) do
      action_modules
      |> Enum.map(&convert_one_action/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp convert_action_modules(_), do: []

  defp convert_one_action(action_module) when is_atom(action_module) do
    if Code.ensure_loaded?(action_module) and function_exported?(action_module, :to_tool, 0) do
      spec = action_module.to_tool()

      struct(@tool_module,
        name: spec[:name] || Map.get(spec, :name, ""),
        description: spec[:description] || Map.get(spec, :description),
        input_schema: spec[:parameters_schema] || Map.get(spec, :parameters_schema, %{})
      )
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp convert_one_action(_), do: nil

  # ── Runtime bridges to arbor_orchestrator ────────────────────────

  defp orchestrator_available? do
    Code.ensure_loaded?(@session_module) and
      Code.ensure_loaded?(@adapters_module)
  end

  defp build_adapters(agent_id, trust_tier, provider, model, system_prompt, tools) do
    apply(@adapters_module, :build, [
      [
        agent_id: agent_id,
        trust_tier: trust_tier,
        llm_provider: provider,
        llm_model: model,
        system_prompt: system_prompt,
        tools: tools
      ]
    ])
  end

  defp start_session(opts) do
    # Use GenServer.start (not start_link) to avoid EXIT propagation.
    # Bridge manages lifecycle explicitly via stop_session/1 in after block.
    GenServer.start(@session_module, opts)
  end

  defp send_message(pid, prompt) do
    apply(@session_module, :send_message, [pid, prompt])
  end

  defp get_state(pid) do
    apply(@session_module, :get_state, [pid])
  end

  defp stop_session(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _ -> :ok
  end

  # ── Configuration ────────────────────────────────────────────────

  defp enabled? do
    Application.get_env(:arbor_ai, :session_enabled, false)
  end

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
    case :code.priv_dir(:arbor_orchestrator) do
      {:error, _} ->
        # Dev mode — find relative to project root
        Path.join([File.cwd!(), "apps", "arbor_orchestrator"])

      priv_dir ->
        Path.dirname(priv_dir)
    end
  end
end
