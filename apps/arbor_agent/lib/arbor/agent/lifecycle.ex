defmodule Arbor.Agent.Lifecycle do
  @moduledoc """
  Orchestrates the full agent lifecycle: create, restore, start, stop, destroy.

  This is the primary API for agent management. It coordinates identity,
  security, memory, and execution into a single flow — the trust-arbor
  equivalent of old arbor's `Arbor.Seed.new("id", template: CodeCompanion)`.

  ## Examples

      # From template (first arg is display name, not agent_id)
      {:ok, profile} = Lifecycle.create("Scout", template: "scout")
      profile.agent_id  #=> "agent_a4f2..."  (crypto-derived)
      profile.display_name  #=> "Scout"

      # From options (inline character)
      {:ok, profile} = Lifecycle.create("My Agent",
        character: Character.new(name: "My Agent", values: ["helpfulness"]),
        initial_goals: [%{type: :achieve, description: "Complete the review"}],
        capabilities: [%{resource: "arbor://fs/read/repo"}]
      )

      # Restore from disk
      {:ok, profile} = Lifecycle.restore("scout-1")

      # List all agents
      profiles = Lifecycle.list_agents()
  """

  alias Arbor.Agent.{
    BranchSupervisor,
    Character,
    ExactTemplatePolicy,
    Executor,
    Profile,
    ProfileStore,
    SessionConfig,
    SessionManager,
    TemplateStore
  }

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Memory.Goal

  require Logger

  @session_turn_capability_uris [
    "arbor://orchestrator/execute",
    "arbor://orchestrator/execute/exec",
    "arbor://orchestrator/execute/compute",
    "arbor://orchestrator/execute/transform",
    "arbor://orchestrator/execute/unknown"
  ]

  @doc """
  Create a new agent from a template or options.

  The first argument is the human-readable display name (e.g., "Claude").
  The cryptographic identity generates the actual agent_id ("agent_<hex>").

  ## Steps

  1. Resolve template → character + security opts
  2. Generate cryptographic identity (derives agent_id from public key)
  3. Register identity (public key only)
  4. System authority endorses the identity
  5. Create keychain
  6. Grant initial capabilities
  7. Initialize memory
  8. Set initial goals
  9. Build and persist profile
  10. Emit creation signal

  ## Options of note

  - `:return_identity` — when `true`, returns `{:ok, profile, identity}` with
    the in-memory `Identity` struct **including the freshly-generated private
    key**. Required for external-agent registration flows where the caller
    (e.g., a dashboard event handler) must hand the private key to the external
    tool exactly once. Defaults to `false`; when omitted, the standard
    `{:ok, profile}` shape is returned and the private key is only stored in
    encrypted at-rest form via SigningKeyStore.
  """
  @spec create(String.t(), keyword()) ::
          {:ok, Profile.t()}
          | {:ok, Profile.t(), Arbor.Contracts.Security.Identity.t()}
          | {:error, term()}
  def create(display_name, opts \\ []) do
    with {:ok, character, opts} <- resolve_template(opts),
         {:ok, identity} <- generate_identity(display_name) do
      case run_creation(display_name, character, identity, opts) do
        {:ok, _profile} = success ->
          success

        {:ok, _profile, _identity} = success ->
          success

        {:error, _reason} = error ->
          rollback_failed_creation(identity.agent_id)
          error
      end
    end
  end

  defp run_creation(display_name, character, identity, opts) do
    do_create(display_name, character, identity, opts)
  rescue
    error -> {:error, {:creation_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:creation_exit, reason}}
    kind, reason -> {:error, {:creation_failure, kind, reason}}
  end

  defp do_create(display_name, character, identity, opts) do
    with :ok <- register_identity(identity),
         {:ok, endorsement} <- endorse_identity(identity),
         keychain <- create_keychain(identity),
         agent_id = identity.agent_id,
         :ok <- persist_signing_key(agent_id, identity),
         :ok <- grant_initial_capabilities(agent_id, opts),
         :ok <- grant_workspace_capabilities(agent_id, opts),
         :ok <- maybe_delegate_from_parent(agent_id, opts),
         {:ok, _pid} <- init_memory(agent_id, opts[:memory_opts] || []),
         :ok <- set_initial_goals(agent_id, opts[:initial_goals] || []),
         :ok <- seed_template_identity(agent_id, character, opts) do
      profile =
        build_profile(agent_id, display_name, identity, endorsement, keychain, character, opts)

      case ensure_trust_profile(agent_id, opts) do
        :ok ->
          # Trust profile setup can asynchronously synchronize capabilities.
          # Reconcile after it so exact authority is the final creation state.
          persistence_result =
            with :ok <- reconcile_exact_authority_after_trust(agent_id, opts) do
              persist_profile(profile)
            end

          case persistence_result do
            :ok ->
              unless Keyword.has_key?(opts, :exact_template_policy) do
                grant_owner_chat_capability(agent_id, opts)
              end

              emit_created_signal(profile)

              if Keyword.get(opts, :return_identity, false) do
                {:ok, profile, identity}
              else
                {:ok, profile}
              end

            {:error, reason} ->
              {:error, {:persist_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:trust_profile_failed, reason}}
      end
    end
  end

  @doc """
  Ensure an agent's identity and capabilities are registered without starting
  any processes. Reads the profile from disk, re-registers the identity in the
  security subsystem, and re-grants capabilities from the template.

  Use this when you need an agent's authorization to be active (e.g., for
  orchestrator pipeline execution) without running a full agent process.

  Returns `{:ok, agent_id}` or `{:error, reason}`.
  """
  @spec ensure_identity(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_identity(agent_id) do
    case restore(agent_id) do
      {:ok, profile} ->
        case prepare_and_activate_authority(profile) do
          {:ok, _prepared_profile, _policy_mode} ->
            {:ok, agent_id}

          {:error, _} = error ->
            handle_authority_failure(profile, error)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Build a signer function for an agent.

  Loads the agent's signing private key from encrypted storage and returns
  a function that can produce fresh SignedRequests. The orchestrator receives
  this function — never the raw private key.

  ## Example

      {:ok, signer} = Lifecycle.build_signer(agent_id)
      {:ok, signed} = signer.("arbor://fs/read")
  """
  @spec build_signer(String.t()) ::
          {:ok, (binary() -> {:ok, term()} | {:error, term()})} | {:error, term()}
  def build_signer(agent_id) do
    case Arbor.Security.load_signing_key(agent_id) do
      {:ok, private_key} ->
        {:ok, Arbor.Security.make_signer(agent_id, private_key)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Restore an agent from a persisted profile.
  """
  @spec restore(String.t()) :: {:ok, Profile.t()} | {:error, :not_found | term()}
  def restore(agent_id) do
    case ProfileStore.load_profile(agent_id) do
      {:ok, profile} ->
        dual_emit_lifecycle(:restored, %{
          agent_id: agent_id,
          version: profile.version
        })

        {:ok, profile}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Start an agent's execution via a supervised BranchSupervisor.

  Creates a per-agent supervisor (rest_for_one) containing the APIAgent host,
  Executor, and optionally a Session. All sub-processes are supervised — if any
  crashes, dependent processes are restarted too.

  After the supervisor confirms all children are up, registers the agent in
  Agent.Registry with all child PIDs as metadata.

  Idempotent — calling twice for the same agent returns the existing supervisor.
  """
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(agent_id, opts \\ []) do
    case restore(agent_id) do
      {:ok, profile} ->
        case prepare_and_activate_authority(profile) do
          {:ok, prepared_profile, policy_mode} ->
            result = start_activated_profile(prepared_profile, opts)

            case {result, policy_mode} do
              {{:error, _} = error, {:exact, _envelope}} ->
                handle_authority_failure(prepared_profile, error)

              _ ->
                result
            end

          {:error, _} = error ->
            handle_authority_failure(profile, error)
        end

      {:error, _} = error ->
        error
    end
  end

  defp start_activated_profile(profile, opts) do
    agent_id = profile.agent_id

    # Idempotent process start, but authority was validated and reconciled first.
    case BranchSupervisor.whereis(agent_id) do
      pid when is_pid(pid) ->
        ensure_registered(agent_id, pid, opts)
        {:ok, pid}

      nil ->
        do_start(profile, opts)
    end
  end

  defp do_start(profile, opts) do
    agent_id = profile.agent_id

    # Re-initialize memory + reload persisted goals/intents from Postgres
    init_memory(agent_id, reload_persisted: true)

    # Build child opts for the BranchSupervisor
    host_opts = build_host_opts(agent_id, profile, opts)
    executor_opts = build_executor_opts(agent_id, profile, opts)
    session_opts = build_branch_session_opts(agent_id, profile, opts)
    heartbeat_opts = build_heartbeat_opts(agent_id, profile, opts, session_opts)
    start_session = Keyword.get(opts, :start_session, true)

    branch_opts = [
      agent_id: agent_id,
      host_opts: host_opts,
      executor_opts: executor_opts,
      session_opts: session_opts,
      heartbeat_opts: heartbeat_opts,
      start_session: start_session
    ]

    # Start the branch supervisor under the global DynamicSupervisor
    case start_branch_supervised(agent_id, branch_opts, opts) do
      {:ok, sup_pid} ->
        # Register in Agent.Registry AFTER supervision is confirmed
        register_in_agent_registry(agent_id, sup_pid, profile, opts)
        dual_emit_lifecycle(:started, %{agent_id: agent_id})
        {:ok, sup_pid}

      {:error, {:already_started, sup_pid}} ->
        {:ok, sup_pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Start the BranchSupervisor under the appropriate DynamicSupervisor
  # (UserSupervisor for multi-user, global Supervisor otherwise).
  defp start_branch_supervised(agent_id, branch_opts, opts) do
    child_spec = %{
      id: {:branch, agent_id},
      start: {BranchSupervisor, :start_link, [branch_opts]},
      restart: :transient,
      type: :supervisor
    }

    principal_id = extract_principal_id(opts)

    result =
      if principal_id && user_supervisor_available?() do
        try do
          apply(Arbor.Agent.UserSupervisor, :start_child_spec, [principal_id, child_spec])
        rescue
          _ -> :fallback
        catch
          :exit, _ -> :fallback
        end
      else
        :fallback
      end

    case result do
      :fallback -> DynamicSupervisor.start_child(Arbor.Agent.Supervisor, child_spec)
      other -> other
    end
  end

  defp extract_principal_id(opts) do
    Keyword.get(opts, :principal_id) ||
      case Keyword.get(opts, :tenant_context) do
        %{principal_id: pid} when is_binary(pid) -> pid
        _ -> nil
      end
  end

  defp user_supervisor_available? do
    Process.whereis(Arbor.Agent.UserSupervisor) != nil
  end

  # Ensure an already-running agent is in the Registry (idempotent path).
  # Handles the case where supervision survived but Registry entry was lost
  # (e.g., hot code reload cleared ETS, or initial registration failed).
  defp ensure_registered(agent_id, sup_pid, opts) do
    case Arbor.Agent.Registry.lookup(agent_id) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        Logger.info("[Lifecycle] Re-registering already-running agent #{agent_id}")

        case restore(agent_id) do
          {:ok, profile} -> register_in_agent_registry(agent_id, sup_pid, profile, opts)
          _ -> :ok
        end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Register the agent and all its child PIDs in the discovery registry.
  # This happens AFTER supervision is confirmed — no zombie entries.
  defp register_in_agent_registry(agent_id, sup_pid, profile, opts) do
    child_pids = BranchSupervisor.child_pids(agent_id)

    metadata = %{
      host_pid: child_pids.host,
      executor_pid: child_pids.executor,
      session_pid: child_pids.session,
      supervisor_pid: sup_pid,
      display_name: profile.display_name,
      model_config: extract_model_config(profile, opts),
      runtime: resolve_agent_runtime(profile, opts),
      started_at: System.system_time(:millisecond)
    }

    metadata =
      case Map.get(profile.metadata || %{}, :created_by) do
        nil -> metadata
        created_by -> Map.put(metadata, :created_by, created_by)
      end

    Arbor.Agent.Registry.register(agent_id, sup_pid, metadata)
  rescue
    e ->
      Logger.warning(
        "[Lifecycle] Registry registration failed for #{agent_id}: #{Exception.message(e)}"
      )
  catch
    :exit, reason ->
      Logger.warning("[Lifecycle] Registry registration exit for #{agent_id}: #{inspect(reason)}")
  end

  defp extract_model_config(profile, opts) do
    meta = profile.metadata || %{}

    # Reloaded-from-JSON profiles string-key this (it's not a known-atom key).
    Keyword.get(opts, :model_config) ||
      Map.get(meta, :last_model_config) ||
      Map.get(meta, "last_model_config") ||
      %{}
  end

  @doc false
  # Per-agent runtime resolution for the heartbeat + chat paths. Mirrors
  # the resolution order used by `Manager.dispatch_query/4` so the value
  # stored in Agent.Registry metadata matches what the chat-time reader
  # would pick if it had to re-resolve.
  #
  # Order (first non-nil wins):
  #   1. Explicit `opts[:runtime]` from the caller
  #   2. `opts[:model_config][:runtime]` — the bundled-config shape
  #      that Manager.{query_agent,resume_agent} use
  #   3. Persisted `profile.metadata[:last_model_config][:runtime]`
  #      for restored/resumed agents
  #   4. Default `:arbor`
  #
  # Exposed under @doc false so unit tests can pin the resolution chain
  # without spinning up a full BranchSupervisor.
  @spec resolve_agent_runtime(map(), keyword()) :: atom()
  def resolve_agent_runtime(profile, opts) do
    metadata = Map.get(profile, :metadata) || %{}
    template_meta = extract_template_metadata(profile)
    template_runtime = normalize_template_runtime(metadata_value(template_meta, :runtime))

    if exact_template_policy?(template_meta, :runtime_policy) do
      template_runtime || :arbor
    else
      Keyword.get(opts, :runtime) ||
        get_in(opts, [:model_config, :runtime]) ||
        get_in(metadata, [:last_model_config, :runtime]) ||
        get_in(metadata, ["last_model_config", "runtime"]) ||
        template_runtime ||
        :arbor
    end
  end

  @doc false
  @spec resolve_agent_tools(map(), keyword()) :: list() | nil
  def resolve_agent_tools(profile, opts) do
    template_meta = extract_template_metadata(profile)
    template_tools = normalize_template_tools(metadata_value(template_meta, :tools))

    if exact_template_policy?(template_meta, :tool_policy) do
      template_tools || []
    else
      Keyword.get(opts, :tools) || template_tools
    end
  end

  @doc false
  @spec resolve_agent_sandbox_level(map(), keyword()) ::
          Arbor.Contracts.Security.SandboxLevel.t()
  def resolve_agent_sandbox_level(profile, opts) do
    template_meta = extract_template_metadata(profile)
    template_level = extract_template_sandbox_level(profile)

    level =
      if exact_template_policy?(template_meta, :sandbox_policy) do
        template_level || Map.get(profile, :sandbox_level)
      else
        Keyword.get(opts, :sandbox_level) || Map.get(profile, :sandbox_level) || template_level
      end

    Arbor.Contracts.Security.SandboxLevel.coerce(level)
  end

  @doc false
  # Per-agent fallback chain resolution — same pattern as
  # `resolve_agent_runtime/2`. The chain is an ordered list of override
  # maps consumed by `Arbor.AI.Runtime.Dispatch.dispatch/2` when the
  # primary call fails with a fallback-eligible error (Phase 4+ commit
  # c12bf750). Each entry can override :runtime, :provider, and/or
  # :model; omitted fields inherit from the original request/policy.
  #
  # Persisted entries arrive with string keys when loaded from Postgres
  # (`%{"runtime" => "acp"}`); this helper normalizes them to atom keys
  # so Dispatch sees the typed shape regardless of storage origin.
  # String values for known fields (:runtime, :provider) are atomized via
  # `String.to_existing_atom/1` so a malicious / typo'd value can't
  # create arbitrary atoms.
  @spec resolve_fallback_chain(map(), keyword()) :: [map()]
  def resolve_fallback_chain(profile, opts) do
    metadata = Map.get(profile, :metadata) || %{}
    template_meta = extract_template_metadata(profile)

    raw =
      if exact_template_policy?(template_meta, :runtime_policy) do
        metadata_value(template_meta, :fallback_chain) || []
      else
        Keyword.get(opts, :fallback_chain) ||
          get_in(opts, [:model_config, :fallback_chain]) ||
          get_in(metadata, [:last_model_config, :fallback_chain]) ||
          get_in(metadata, ["last_model_config", "fallback_chain"]) ||
          []
      end

    normalize_fallback_chain(raw)
  end

  defp normalize_fallback_chain(chain) when is_list(chain) do
    chain
    |> Enum.map(&normalize_fallback_entry/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_fallback_chain(_), do: []

  defp normalize_fallback_entry(entry) when is_map(entry) do
    %{}
    |> maybe_put_atom(entry, :runtime)
    |> maybe_put_atom(entry, :provider)
    |> maybe_put_string(entry, :model)
  end

  defp normalize_fallback_entry(_), do: %{}

  defp maybe_put_atom(acc, source, key) do
    case Map.get(source, key) || Map.get(source, to_string(key)) do
      nil -> acc
      atom when is_atom(atom) -> Map.put(acc, key, atom)
      str when is_binary(str) -> safe_put_atom(acc, key, str)
      _ -> acc
    end
  end

  defp safe_put_atom(acc, key, str) do
    Map.put(acc, key, String.to_existing_atom(str))
  rescue
    ArgumentError -> acc
  end

  defp maybe_put_string(acc, source, key) do
    case Map.get(source, key) || Map.get(source, to_string(key)) do
      nil -> acc
      str when is_binary(str) -> Map.put(acc, key, str)
      _ -> acc
    end
  end

  # Build opts for the APIAgent host child
  defp build_host_opts(agent_id, profile, opts) do
    template_meta = extract_template_metadata(profile)

    [
      id: agent_id,
      display_name: profile.display_name || agent_id,
      model:
        exact_template_value(template_meta, :model) ||
          Keyword.get_lazy(opts, :model, fn -> Arbor.Agent.LLMDefaults.default_model() end),
      provider:
        exact_template_value(template_meta, :provider) ||
          Keyword.get_lazy(opts, :provider, fn -> Arbor.Agent.LLMDefaults.default_provider() end)
    ]
  end

  # Build opts for the Executor child
  defp build_executor_opts(agent_id, profile, opts) do
    Keyword.merge(opts,
      agent_id: agent_id,
      sandbox_level: resolve_agent_sandbox_level(profile, opts)
    )
  end

  # Build session opts for the BranchSupervisor (or nil to skip session).
  defp build_branch_session_opts(agent_id, profile, opts) do
    mode = Application.get_env(:arbor_agent, :session_execution_mode, :session)

    if mode in [:session, :graph] do
      tools = resolve_agent_tools(profile, opts)

      system_prompt =
        Keyword.get_lazy(opts, :system_prompt, fn ->
          build_session_system_prompt(agent_id, profile, opts)
        end)

      template_meta = extract_template_metadata(profile)

      signer =
        case build_signer(agent_id) do
          {:ok, signer_fn} -> signer_fn
          {:error, _} -> nil
        end

      session_opts =
        Keyword.merge(opts,
          tools: tools,
          system_prompt: system_prompt,
          start_heartbeat: Keyword.get(opts, :start_heartbeat, true),
          signer: signer,
          # Per-agent runtime flows to SessionConfig → state.config →
          # ContextBuilder → "session.llm_runtime" → LlmHandler. Without
          # this, heartbeats default to :arbor even for agents configured
          # with :acp at create/resume time.
          runtime: resolve_agent_runtime(profile, opts),
          # Per-agent fallback chain flows the same path: SessionConfig →
          # state.config → ContextBuilder → "session.llm_fallback_chain"
          # → LlmHandler → policy.fallback_chain on Dispatcher.dispatch.
          # See `Arbor.AI.Runtime.Dispatch`'s fallback eligibility docs.
          fallback_chain: resolve_fallback_chain(profile, opts)
        )

      session_opts = merge_template_opts(session_opts, template_meta, opts)

      # Single shared builder for session init opts
      SessionConfig.build(agent_id, session_opts)
    else
      nil
    end
  end

  # Build opts for the HeartbeatService child (optional).
  # Returns nil if heartbeats are disabled or session_opts is nil.
  defp build_heartbeat_opts(_agent_id, _profile, _opts, nil), do: nil

  defp build_heartbeat_opts(agent_id, profile, opts, session_opts) when is_list(session_opts) do
    # Check if heartbeats should start (default: true, same as Session's start_heartbeat)
    start_heartbeat = Keyword.get(opts, :start_heartbeat, true)

    if start_heartbeat do
      # Extract heartbeat config from template if available
      heartbeat_config = extract_heartbeat_config(profile, opts)

      if Map.get(heartbeat_config, :enabled, true) do
        # HeartbeatService receives the same agent_id and signer as Session
        signer =
          case build_signer(agent_id) do
            {:ok, signer_fn} -> signer_fn
            {:error, _} -> nil
          end

        [
          agent_id: agent_id,
          signer: signer,
          heartbeat_config: heartbeat_config,
          heartbeat_dot: Keyword.get(session_opts, :heartbeat_dot)
        ]
      else
        nil
      end
    else
      nil
    end
  end

  defp extract_heartbeat_config(profile, _opts) do
    # Try to get heartbeat config from the template module
    metadata = profile.metadata || %{}
    template_mod = Map.get(metadata, :template_module) || Map.get(metadata, "template_module")

    if template_mod && is_atom(template_mod) &&
         Code.ensure_loaded?(template_mod) &&
         function_exported?(template_mod, :heartbeat, 0) do
      try do
        template_mod.heartbeat()
      rescue
        _ -> %{enabled: true, interval: 30_000, graph: "heartbeat.dot"}
      end
    else
      # Default heartbeat config when template doesn't define one
      %{enabled: true, interval: 30_000, graph: "heartbeat.dot"}
    end
  end

  @doc """
  Stop an agent cleanly.

  If a BranchSupervisor is running, stops the entire supervised tree.
  Falls back to stopping individual processes for backward compatibility.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(agent_id) do
    # Try stopping via BranchSupervisor first (new path)
    case BranchSupervisor.whereis(agent_id) do
      sup_pid when is_pid(sup_pid) ->
        # Unregister from Agent.Registry before stopping
        Arbor.Agent.Registry.unregister(agent_id)

        # Stop the supervisor — this terminates all children (host, executor, session)
        try do
          Supervisor.stop(sup_pid, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end

      nil ->
        # Fallback: stop individual processes (legacy path)
        stop_individual_processes(agent_id)
    end

    dual_emit_lifecycle(:stopped, %{agent_id: agent_id, reason: :normal})
    :ok
  end

  defp stop_individual_processes(agent_id) do
    try do
      SessionManager.stop_session(agent_id)
    catch
      :exit, _ -> :ok
    end

    try do
      case Registry.lookup(Arbor.Agent.ExecutorRegistry, {:host, agent_id}) do
        [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
        [] -> :ok
      end
    catch
      :exit, _ -> :ok
    end

    Executor.stop(agent_id)
  end

  @doc """
  Get the APIAgent host pid for an agent, if running.
  """
  @spec get_host(String.t()) :: {:ok, pid()} | {:error, :no_host}
  def get_host(agent_id) do
    case Registry.lookup(Arbor.Agent.ExecutorRegistry, {:host, agent_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :no_host}
    end
  end

  @doc """
  List all known agent profiles.
  """
  @spec list_agents() :: [Profile.t()]
  def list_agents do
    ProfileStore.list_profiles()
  end

  @doc """
  Rename an agent's display name.

  Loads the profile from disk, updates only the `display_name` field, and
  persists it back. The cryptographic identity (`agent_id`, public key,
  endorsement, signing key) is unchanged — display name is purely for
  human-readable presentation in dashboards and listings.

  Returns the updated profile.
  """
  @spec rename(String.t(), String.t()) :: {:ok, Profile.t()} | {:error, term()}
  def rename(agent_id, new_display_name)
      when is_binary(agent_id) and is_binary(new_display_name) do
    trimmed = String.trim(new_display_name)

    cond do
      trimmed == "" ->
        {:error, :empty_display_name}

      String.length(trimmed) > 200 ->
        {:error, :display_name_too_long}

      true ->
        with {:ok, profile} <- restore(agent_id),
             updated = %{profile | display_name: trimmed},
             :ok <- persist_profile(updated) do
          dual_emit_lifecycle(:renamed, %{
            agent_id: agent_id,
            display_name: trimmed
          })

          {:ok, updated}
        end
    end
  end

  @doc """
  Delete an agent and all its data.
  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(agent_id) do
    # Terminate the whole supervision tree FIRST. stop/1 shuts down the BranchSupervisor and ALL its
    # children — host, executor, session, AND HeartbeatService. Previously destroy only stopped the
    # Executor and left the BranchSupervisor running, so the HeartbeatService kept beating on the
    # identity that deregister_identity (below) then removed → orphaned {:unauthorized,
    # :unknown_identity} heartbeats flooding the orchestrator (2026-07-04 node crash). Ordering is
    # load-bearing: kill the heartbeat BEFORE deregistering its identity, else it beats identity-less.
    stop(agent_id)

    # Clean up memory
    Arbor.Memory.cleanup_for_agent(agent_id)

    # Clean up signing key
    Arbor.Security.delete_signing_key(agent_id)

    # Remove identity from registry
    Arbor.Security.deregister_identity(agent_id)

    # Remove profile from store (and legacy JSON)
    ProfileStore.delete_profile(agent_id)

    dual_emit_lifecycle(:destroyed, %{agent_id: agent_id})
    :ok
  end

  # -- Private helpers --

  # Build a system prompt for Session LLM calls via Arbor.AI runtime bridge.
  # Falls back to template/character-based prompt if Arbor.AI is unavailable.
  defp build_session_system_prompt(agent_id, profile, opts) do
    prompt_opts = [
      state: %{id: agent_id},
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider)
    ]

    Arbor.AI.build_stable_system_prompt(agent_id, prompt_opts)
  rescue
    _ -> fallback_system_prompt(profile)
  catch
    :exit, _ -> fallback_system_prompt(profile)
  end

  defp fallback_system_prompt(profile) do
    name = profile.display_name || profile.character.name || "Agent"
    desc = profile.character.description || ""
    "You are #{name}. #{desc}"
  end

  # Extract metadata from the template module (if available).
  # Template metadata may include :context_management, :model, :provider.
  defp extract_template_metadata(profile) do
    case exact_policy_snapshot(profile) do
      {:ok, snapshot} ->
        snapshot
        |> ExactTemplatePolicy.template_metadata()
        |> atomize_known_template_metadata()

      {:error, _reason} ->
        fail_closed_exact_metadata()

      :not_marked ->
        load_template_metadata(Map.get(profile, :template))
    end
  end

  defp extract_template_sandbox_level(profile) do
    case exact_policy_snapshot(profile) do
      {:ok, snapshot} -> ExactTemplatePolicy.sandbox_level(snapshot)
      {:error, _reason} -> :strict
      :not_marked -> load_template_sandbox_level(Map.get(profile, :template))
    end
  end

  defp exact_policy_snapshot(profile) do
    case ExactTemplatePolicy.from_metadata(Map.get(profile, :metadata) || %{}) do
      {:ok, envelope} -> {:ok, ExactTemplatePolicy.snapshot(envelope)}
      :not_marked -> :not_marked
      {:error, _} = error -> error
    end
  end

  defp fail_closed_exact_metadata do
    %{
      capability_policy: :exact,
      runtime_policy: :exact,
      runtime: :arbor,
      sandbox_policy: :exact,
      tool_policy: :exact,
      tools: [],
      trust_preset_policy: :exact
    }
  end

  defp load_template_metadata(nil), do: %{}

  defp load_template_metadata(name) when is_binary(name) do
    case TemplateStore.get(name) do
      {:ok, data} -> atomize_known_template_metadata(data["metadata"] || %{})
      {:error, _} -> %{}
    end
  end

  defp load_template_metadata(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 0) do
      try do
        module.metadata()
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp atomize_known_template_metadata(metadata) do
    Map.new(metadata, fn
      {key, value} when is_binary(key) ->
        case Arbor.Common.SafeAtom.to_existing(key) do
          {:ok, atom} -> {atom, value}
          {:error, _} -> {key, value}
        end

      pair ->
        pair
    end)
  end

  defp load_template_sandbox_level(name) when is_binary(name) do
    case TemplateStore.get(name) do
      {:ok, data} -> data["sandbox_level"]
      {:error, _} -> nil
    end
  end

  defp load_template_sandbox_level(_template), do: nil

  defp exact_template_policy?(metadata, key) do
    metadata_value(metadata, key) in [:exact, "exact"]
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp template_metadata_from_opts(opts) do
    case Keyword.get(opts, :template_data) do
      data when is_map(data) -> Map.get(data, "metadata") || Map.get(data, :metadata) || %{}
      _ -> %{}
    end
  end

  defp normalize_template_runtime(runtime) when runtime in [:arbor, "arbor"], do: :arbor
  defp normalize_template_runtime(runtime) when runtime in [:acp, "acp"], do: :acp
  defp normalize_template_runtime(_runtime), do: nil

  defp normalize_template_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1), do: tools, else: nil
  end

  defp normalize_template_tools(_tools), do: nil

  # Merge template-derived options into session opts. Exact policy values are
  # persisted authority, so they intentionally override caller-provided values.
  defp merge_template_opts(session_opts, template_meta, caller_opts) do
    template_keys = [
      {:context_management, :context_management},
      {:model, :model},
      {:provider, :provider}
    ]

    exact_runtime? = exact_template_policy?(template_meta, :runtime_policy)

    Enum.reduce(template_keys, session_opts, fn {meta_key, opt_key}, acc ->
      case metadata_value(template_meta, meta_key) do
        nil ->
          acc

        value ->
          cond do
            exact_runtime? -> Keyword.put(acc, opt_key, value)
            not Keyword.has_key?(caller_opts, opt_key) -> Keyword.put_new(acc, opt_key, value)
            true -> acc
          end
      end
    end)
  end

  defp exact_template_value(template_meta, key) do
    if exact_template_policy?(template_meta, :runtime_policy) do
      metadata_value(template_meta, key)
    end
  end

  defp resolve_template(opts) do
    case Keyword.get(opts, :template) do
      nil ->
        case Keyword.fetch(opts, :character) do
          {:ok, %Character{} = char} ->
            {:ok, char, opts}

          :error ->
            {:error, :missing_character_or_template}
        end

      template_name when is_binary(template_name) ->
        case TemplateStore.resolve(template_name) do
          {:ok, data} ->
            kw = TemplateStore.to_keyword(data)
            character = kw[:character]

            opts =
              opts
              |> Keyword.put_new(:initial_goals, kw[:initial_goals])
              |> put_template_capabilities(data, kw[:required_capabilities])
              |> put_template_trust_preset(data, kw[:trust_preset])
              |> put_template_sandbox_level(data, kw[:sandbox_level])
              |> Keyword.put(:template, template_name)
              |> Keyword.put(:template_data, data)
              |> put_template_source(data)

            with {:ok, opts} <- put_exact_template_policy(opts, template_name, data) do
              {:ok, character, opts}
            end

          {:error, _} = error ->
            error
        end

      template_mod when is_atom(template_mod) ->
        # Try TemplateStore first (file-backed), fall back to direct module call
        name = TemplateStore.module_to_name(template_mod)

        case TemplateStore.resolve(template_mod) do
          {:ok, data} ->
            kw = TemplateStore.to_keyword(data)
            character = kw[:character]

            opts =
              opts
              |> Keyword.put_new(:initial_goals, kw[:initial_goals])
              |> put_template_capabilities(data, kw[:required_capabilities])
              |> put_template_trust_preset(data, kw[:trust_preset])
              |> put_template_sandbox_level(data, kw[:sandbox_level])
              |> Keyword.put(:template, name)
              |> Keyword.put(:template_data, data)
              |> Keyword.put_new(:template_module, template_mod)
              |> put_template_source(data)

            with {:ok, opts} <- put_exact_template_policy(opts, name, data) do
              {:ok, character, opts}
            end

          {:error, :not_found} ->
            # Direct module fallback for backward compatibility
            if Code.ensure_loaded?(template_mod) and
                 function_exported?(template_mod, :character, 0) do
              character = template_mod.character()

              opts =
                opts
                |> Keyword.put_new(:initial_goals, template_mod.initial_goals())
                |> Keyword.put_new(:capabilities, template_mod.required_capabilities())
                |> Keyword.put(:template, name)
                |> Keyword.put_new(:template_module, template_mod)

              {:ok, character, opts}
            else
              {:error, :not_found}
            end
        end
    end
  end

  defp put_exact_template_policy(opts, template_name, data) do
    if ExactTemplatePolicy.exact?(data) do
      with {:ok, repo_root} <- exact_repo_root_for_capabilities() do
        case ExactTemplatePolicy.build(template_name, data, repo_root: repo_root) do
          {:ok, envelope} -> {:ok, Keyword.put(opts, :exact_template_policy, envelope)}
          :not_exact -> {:ok, opts}
          {:error, _} = error -> error
        end
      end
    else
      {:ok, opts}
    end
  end

  defp put_template_sandbox_level(opts, data, sandbox_level) do
    metadata = data["metadata"] || %{}

    if exact_template_policy?(metadata, :sandbox_policy) do
      Keyword.put(
        opts,
        :sandbox_level,
        Arbor.Contracts.Security.SandboxLevel.coerce(sandbox_level)
      )
    else
      Keyword.put_new(opts, :sandbox_level, sandbox_level)
    end
  end

  defp put_template_capabilities(opts, data, capabilities) do
    metadata = data["metadata"] || %{}

    if exact_template_policy?(metadata, :capability_policy) do
      Keyword.put(opts, :capabilities, capabilities)
    else
      Keyword.put_new(opts, :capabilities, capabilities)
    end
  end

  defp put_template_trust_preset(opts, data, trust_preset) do
    metadata = data["metadata"] || %{}

    if exact_template_policy?(metadata, :trust_preset_policy) do
      Keyword.put(opts, :trust_preset, trust_preset)
    else
      Keyword.put_new(opts, :trust_preset, trust_preset)
    end
  end

  # Carry template provenance (set by TemplateStore.resolve/1) through opts so
  # build_profile_metadata/1 can persist it onto profile.metadata.
  defp put_template_source(opts, %{"template_source" => %{} = source}) do
    Keyword.put(opts, :template_source, source)
  end

  defp put_template_source(opts, _data), do: opts

  defp generate_identity(display_name) do
    Arbor.Security.generate_identity(name: display_name)
  end

  defp register_identity(identity) do
    Arbor.Security.register_identity(identity)
  end

  defp endorse_identity(identity) do
    Arbor.Security.endorse_agent(identity)
  end

  defp create_keychain(identity) do
    Arbor.Security.new_keychain(identity.agent_id)
  end

  # Persist the signing private key for later use in signing ceremonies.
  # Gracefully degrades if the signing key store is not available.
  defp persist_signing_key(agent_id, identity) do
    case identity.private_key do
      nil ->
        Logger.warning("No private key to persist for agent #{agent_id}")
        :ok

      private_key ->
        case Arbor.Security.store_signing_key(agent_id, private_key) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to persist signing key: #{inspect(reason)}",
              agent_id: agent_id
            )

            # Don't fail agent creation over signing key persistence
            :ok
        end
    end
  end

  # Owner-scoped chat: the human who created this agent may chat with it
  # (`arbor://chat/agent/<agent_id>`), gating the Gateway chat API at attach. The
  # cap is scoped to THIS agent, so it's multi-user-safe (you chat with your own
  # agents, not everyone's). Best-effort — never fails agent creation; an
  # auto/system-spawned agent with no creator principal gets no chat grant.
  defp grant_owner_chat_capability(agent_id, opts) do
    case extract_principal_id(opts) do
      creator when is_binary(creator) ->
        case Arbor.Security.grant(principal: creator, resource: "arbor://chat/agent/#{agent_id}") do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[Lifecycle] owner chat grant failed for #{agent_id}: #{inspect(reason)}"
            )

            :ok
        end

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning("[Lifecycle] owner chat grant raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp grant_initial_capabilities(agent_id, opts) do
    case Keyword.get(opts, :exact_template_policy) do
      %{} = envelope ->
        reconcile_exact_capabilities(agent_id, envelope)

      _other ->
        grant_capabilities(
          agent_id,
          opts[:capabilities] || [],
          template_metadata_from_opts(opts)
        )
    end
  end

  defp reconcile_exact_authority_after_trust(agent_id, opts) do
    case Keyword.get(opts, :exact_template_policy) do
      %{} = envelope -> reconcile_exact_capabilities(agent_id, envelope)
      _ -> :ok
    end
  end

  defp grant_capabilities(_agent_id, [], _template_metadata), do: :ok

  defp grant_capabilities(agent_id, capabilities, template_metadata) do
    # Check which capabilities the agent already has to avoid duplicates
    existing_uris =
      case Arbor.Security.list_capabilities(agent_id) do
        {:ok, caps} -> MapSet.new(caps, & &1.resource_uri)
        _ -> MapSet.new()
      end

    {results, _existing_uris} =
      Enum.reduce(capabilities, {[], existing_uris}, fn cap, {results, existing_uris} ->
        # Self-scoped (`/self/`) URIs resolve to the agent's id, and constraint
        # keys are atomized — so a template can declare a constrained self-cap
        # (e.g. `code/write/self/sandbox/*` with `rate_limit: 10`) and it grants
        # identically to how the trust system grants the baseline.
        resources =
          (cap[:resource] || cap["resource"])
          |> resolve_self_uri(agent_id)
          |> expand_runtime_capability_uris(template_metadata)

        constraints = normalize_capability_constraints(cap[:constraints] || cap["constraints"])

        Enum.reduce(resources, {results, existing_uris}, fn resource, {results, existing_uris} ->
          cond do
            is_nil(resource) ->
              {[:skipped | results], existing_uris}

            MapSet.member?(existing_uris, resource) ->
              {[:skipped | results], existing_uris}

            true ->
              case Arbor.Security.grant(
                     principal: agent_id,
                     resource: resource,
                     constraints: constraints
                   ) do
                {:ok, _cap} ->
                  {[:ok | results], MapSet.put(existing_uris, resource)}

                {:error, reason} ->
                  Logger.warning("Failed to grant capability #{resource}: #{inspect(reason)}",
                    agent_id: agent_id
                  )

                  {[{:error, reason} | results], existing_uris}
              end
          end
        end)
      end)

    granted = Enum.count(results, &(&1 == :ok))
    skipped = Enum.count(results, &(&1 == :skipped))

    if granted > 0 do
      Logger.info("Granted #{granted} capabilities (#{skipped} already existed)",
        agent_id: agent_id
      )
    end

    :ok
  end

  defp reconcile_exact_capabilities(agent_id, envelope) do
    snapshot = ExactTemplatePolicy.snapshot(envelope)
    digest = ExactTemplatePolicy.digest(envelope)

    with {:ok, desired_specs} <- exact_capability_specs(agent_id, snapshot),
         {:ok, current_caps} <- Arbor.Security.list_capabilities(agent_id),
         {:ok, retained_keys} <-
           revoke_stale_exact_capabilities(current_caps, desired_specs, digest),
         :ok <- grant_missing_exact_capabilities(agent_id, desired_specs, retained_keys, digest),
         :ok <- verify_exact_capabilities(agent_id, desired_specs, digest) do
      :ok
    else
      {:error, reason} -> {:error, {:exact_capability_reconcile_failed, reason}}
      other -> {:error, {:exact_capability_reconcile_failed, {:unexpected_result, other}}}
    end
  end

  defp exact_capability_specs(agent_id, snapshot) do
    specs =
      snapshot
      |> ExactTemplatePolicy.capabilities()
      |> Enum.map(fn capability ->
        resource = capability["resource"] |> resolve_self_uri(agent_id)
        constraints = normalize_capability_constraints(capability["constraints"])

        %{resource: resource, constraints: constraints}
      end)
      |> Enum.uniq_by(&exact_capability_key/1)

    if Enum.all?(specs, &(is_binary(&1.resource) and &1.resource != "")) do
      {:ok, specs}
    else
      {:error, :invalid_desired_capability}
    end
  end

  defp revoke_stale_exact_capabilities(current_caps, desired_specs, digest) do
    desired_by_key = Map.new(desired_specs, &{exact_capability_key(&1), &1})

    {retained, stale} =
      Enum.reduce(current_caps, {MapSet.new(), []}, fn cap, {retained, stale} ->
        key = exact_capability_key(cap)
        desired = Map.get(desired_by_key, key)

        if desired && not MapSet.member?(retained, key) &&
             exact_capability_matches?(cap, desired, digest) do
          {MapSet.put(retained, key), stale}
        else
          {retained, [cap | stale]}
        end
      end)

    case revoke_capabilities(stale) do
      :ok -> {:ok, retained}
      {:error, _} = error -> error
    end
  end

  defp grant_missing_exact_capabilities(agent_id, desired_specs, retained_keys, digest) do
    desired_specs
    |> Enum.reject(&MapSet.member?(retained_keys, exact_capability_key(&1)))
    |> Enum.reduce_while(:ok, fn spec, :ok ->
      case Arbor.Security.grant(
             principal: agent_id,
             resource: spec.resource,
             constraints: spec.constraints,
             metadata: %{
               source: :exact_template_policy,
               template_digest: digest
             }
           ) do
        {:ok, _capability} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_failed, spec.resource, reason}}}
      end
    end)
  end

  defp verify_exact_capabilities(agent_id, desired_specs, digest) do
    with {:ok, caps} <- Arbor.Security.list_capabilities(agent_id) do
      desired_by_key = Map.new(desired_specs, &{exact_capability_key(&1), &1})

      valid? =
        length(caps) == length(desired_specs) and
          Enum.all?(caps, fn cap ->
            case Map.get(desired_by_key, exact_capability_key(cap)) do
              nil -> false
              desired -> exact_capability_matches?(cap, desired, digest)
            end
          end)

      if valid?, do: :ok, else: {:error, :post_reconcile_verification_failed}
    end
  end

  defp exact_capability_matches?(cap, desired, digest) do
    cap.resource_uri == desired.resource and
      cap.constraints == desired.constraints and
      is_nil(cap.expires_at) and
      is_nil(cap.not_before) and
      is_nil(cap.parent_capability_id) and
      is_nil(cap.max_uses) and
      is_nil(cap.session_id) and
      is_nil(cap.task_id) and
      is_nil(cap.principal_scope) and
      exact_capability_metadata?(cap.metadata, digest)
  end

  defp exact_capability_metadata?(metadata, digest) when is_map(metadata) do
    source = Map.get(metadata, :source) || Map.get(metadata, "source")
    stored_digest = Map.get(metadata, :template_digest) || Map.get(metadata, "template_digest")

    source in [:exact_template_policy, "exact_template_policy"] and stored_digest == digest
  end

  defp exact_capability_metadata?(_metadata, _digest), do: false

  defp exact_capability_key(%{resource: resource, constraints: constraints}),
    do: {resource, constraints}

  defp exact_capability_key(%{resource_uri: resource, constraints: constraints}),
    do: {resource, constraints}

  defp revoke_capabilities(capabilities) do
    Enum.reduce_while(capabilities, :ok, fn cap, :ok ->
      case Arbor.Security.revoke(cap.id) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:revoke_failed, cap.id, reason}}}
      end
    end)
  end

  # Expand self-scoped capability URIs to the agent's id. Mirrors the trust
  # system's `resolve_uri/2` so template-declared `/self/` caps grant to the same
  # concrete resource the baseline grant would.
  defp resolve_self_uri(nil, _agent_id), do: nil

  defp resolve_self_uri(uri, agent_id) when is_binary(uri) do
    uri
    |> String.replace("/self/", "/#{agent_id}/")
    |> String.replace(~r"/self$", "/#{agent_id}")
  end

  defp expand_runtime_capability_uris(nil, _template_metadata), do: []

  # Template authors declare the coarse orchestrator execution gate. Runtime
  # middleware checks per-node resources under that gate. Exact templates get
  # only the built-in Session turn node resources; other templates retain the
  # historical subtree expansion needed by arbitrary pipelines.
  defp expand_runtime_capability_uris("arbor://orchestrator/execute", template_metadata) do
    if exact_template_policy?(template_metadata, :capability_policy) do
      @session_turn_capability_uris
    else
      ["arbor://orchestrator/execute/**"]
    end
  end

  # Repo file tools need two resources: the bare action URI for tool exposure /
  # signing, and an absolute repo-root path scope for FileGuard. Preserve
  # explicit `/**` grants as literal broad capability wildcards; `repo` is the
  # least-privilege template shorthand.
  defp expand_runtime_capability_uris(uri, _template_metadata)
       when uri in ["arbor://fs/read", "arbor://fs/read/repo"],
       do: repo_scoped_fs_uris(:read)

  defp expand_runtime_capability_uris(uri, _template_metadata)
       when uri in ["arbor://fs/list", "arbor://fs/list/repo"],
       do: repo_scoped_fs_uris(:list)

  defp expand_runtime_capability_uris(uri, _template_metadata), do: [uri]

  defp repo_scoped_fs_uris(operation) when operation in [:read, :list] do
    op = Atom.to_string(operation)

    repo_root =
      repo_root_for_capabilities()
      |> String.trim_leading("/")

    ["arbor://fs/#{op}", "arbor://fs/#{op}/#{repo_root}/**"]
  end

  defp repo_root_for_capabilities do
    cwd = File.cwd!() |> Path.expand()

    root =
      cwd
      |> ancestor_paths()
      |> Enum.find(&umbrella_root?/1)

    (root || cwd)
    |> String.trim_trailing("/")
  end

  defp exact_repo_root_for_capabilities do
    root = repo_root_for_capabilities()

    case SafePath.resolve_real(root) do
      {:ok, real_root} ->
        if umbrella_root?(real_root) do
          {:ok, String.trim_trailing(real_root, "/")}
        else
          {:error, {:exact_template_policy, {:repo_root_unavailable, root}}}
        end

      _ ->
        {:error, {:exact_template_policy, {:repo_root_unavailable, root}}}
    end
  end

  defp umbrella_root?(path) do
    File.exists?(Path.join(path, "mix.exs")) and File.dir?(Path.join(path, "apps"))
  end

  defp ancestor_paths(path), do: ancestor_paths(path, [])

  defp ancestor_paths(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      ancestor_paths(parent, [path | acc])
    end
  end

  # Atomize the known capability constraint keys (`rate_limit`,
  # `requires_approval`) so constraints declared as strings in template
  # frontmatter enforce identically to atom-keyed constraints. Unknown keys are
  # dropped rather than passed through as un-enforceable string keys.
  defp normalize_capability_constraints(nil), do: %{}

  defp normalize_capability_constraints(constraints) when is_map(constraints) do
    Enum.reduce(constraints, %{}, fn
      {k, v}, acc when k in [:rate_limit, :requires_approval] -> Map.put(acc, k, v)
      {"rate_limit", v}, acc -> Map.put(acc, :rate_limit, v)
      {"requires_approval", v}, acc -> Map.put(acc, :requires_approval, v)
      _other, acc -> acc
    end)
  end

  # Grant workspace-scoped fs capabilities when tenant_context provides a workspace root.
  # This ensures agents can access their user's workspace directory.
  defp grant_workspace_capabilities(agent_id, opts) do
    if exact_template_policy?(template_metadata_from_opts(opts), :capability_policy) do
      :ok
    else
      do_grant_workspace_capabilities(agent_id, opts)
    end
  end

  defp do_grant_workspace_capabilities(agent_id, opts) do
    tenant_context = Keyword.get(opts, :tenant_context)

    workspace_root =
      if tenant_context do
        Arbor.Contracts.TenantContext.effective_workspace_root(tenant_context)
      end

    if workspace_root do
      principal_id =
        Arbor.Contracts.TenantContext.principal_id(tenant_context)

      for op <- workspace_fs_operations(opts) do
        # `/**` so the workspace grant covers files WITHIN the workspace root,
        # not just the root URI itself. Required as of the C8 fix (concrete
        # URIs no longer implicitly grant their subtree).
        resource = "arbor://fs/#{op}/#{String.trim_leading(workspace_root, "/")}/**"

        case Arbor.Security.grant(
               principal: agent_id,
               resource: resource,
               principal_scope: principal_id
             ) do
          {:ok, _cap} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to grant workspace capability #{resource}: #{inspect(reason)}",
              agent_id: agent_id
            )
        end
      end

      :ok
    else
      :ok
    end
  end

  defp workspace_fs_operations(opts) do
    declared_ops =
      (opts[:capabilities] || [])
      |> Enum.flat_map(&capability_fs_operations/1)
      |> MapSet.new()

    if MapSet.size(declared_ops) == 0 do
      [:read, :write, :list]
    else
      Enum.filter([:read, :write, :list], &MapSet.member?(declared_ops, &1))
    end
  end

  defp capability_fs_operations(capability) when is_map(capability) do
    case capability[:resource] || capability["resource"] do
      "arbor://fs/**" -> [:read, :write, :list]
      "arbor://fs/read" <> _ -> [:read]
      "arbor://fs/write" <> _ -> [:write]
      "arbor://fs/list" <> _ -> [:list]
      _ -> []
    end
  end

  defp capability_fs_operations(_capability), do: []

  # Delegate capabilities from a parent (human or agent) to the newly created agent.
  # Non-fatal: logs warnings on failure, always returns :ok for backwards compat.
  defp maybe_delegate_from_parent(agent_id, opts) do
    if Keyword.has_key?(opts, :exact_template_policy) do
      :ok
    else
      do_maybe_delegate_from_parent(agent_id, opts)
    end
  end

  defp do_maybe_delegate_from_parent(agent_id, opts) do
    delegator_id = Keyword.get(opts, :delegator_id)
    delegator_key = Keyword.get(opts, :delegator_private_key)

    if delegator_id && delegator_key do
      resources =
        (opts[:capabilities] || [])
        |> Enum.map(fn cap -> cap[:resource] || cap["resource"] end)
        |> Enum.reject(&is_nil/1)

      {:ok, caps} =
        Arbor.Security.delegate_to_agent(delegator_id, agent_id,
          delegator_private_key: delegator_key,
          resources: resources
        )

      Logger.info(
        "[Lifecycle] Delegated #{length(caps)} capabilities from #{delegator_id} to #{agent_id}"
      )
    end

    :ok
  end

  defp init_memory(agent_id, opts) do
    if Process.whereis(Arbor.Memory.Registry) do
      Arbor.Memory.init_for_agent(agent_id, opts)
    else
      {:ok, :memory_not_available}
    end
  rescue
    e ->
      Logger.warning("Memory init failed for #{agent_id}: #{Exception.message(e)}")
      {:ok, :memory_init_failed}
  catch
    :exit, reason ->
      Logger.warning("Memory init exit for #{agent_id}: #{inspect(reason)}")
      {:ok, :memory_init_failed}
  end

  defp set_initial_goals(_agent_id, []), do: :ok

  defp set_initial_goals(agent_id, goals) do
    # Fetch existing goals to avoid duplicates on restart/re-create
    existing_descriptions =
      agent_id
      |> Arbor.Memory.GoalStore.get_active_goals()
      |> Enum.map(& &1.description)
      |> MapSet.new()

    Enum.each(goals, fn goal_map ->
      description = goal_map[:description] || goal_map["description"] || "Unnamed goal"

      unless MapSet.member?(existing_descriptions, description) do
        type = goal_map[:type] || goal_map["type"] || :achieve

        # Goal types now arrive as strings from data-first template `.md` files
        # (the per-persona modules that used to supply atom literals were removed
        # in the template migration). Convert safely: a string that isn't an
        # existing atom must NOT crash (and must not mint atoms — DoS risk), so
        # fall back to the contract default `:achieve`.
        type_atom =
          case type do
            t when is_atom(t) ->
              t

            t when is_binary(t) ->
              case Arbor.Common.SafeAtom.to_existing(t) do
                {:ok, atom} -> atom
                {:error, _} -> :achieve
              end
          end

        goal = Goal.new(description, type: type_atom)
        Arbor.Memory.add_goal(agent_id, goal)
      end
    end)

    :ok
  end

  @doc """
  Seed template identity data (values, traits, knowledge, thoughts) into memory.

  Idempotent — skips if SelfKnowledge already has values seeded.
  Called automatically during `create/2`, but can also be called manually
  to backfill existing agents created before template seeding was added.
  """
  @spec seed_template_identity(String.t(), Character.t(), keyword()) :: :ok
  def seed_template_identity(agent_id, character, opts) do
    template_mod = Keyword.get(opts, :template_module)
    template_data = Keyword.get(opts, :template_data)

    # Knowledge graph is ETS-only (transient) — always re-seed on startup
    seed_knowledge_graph(agent_id, character)

    # Identity data (values, traits, thoughts) is durably persisted —
    # only seed once (skip if SelfKnowledge already has values)
    sk = Arbor.Memory.get_self_knowledge(agent_id)

    unless sk && sk.values != [] do
      seed_durable_identity(agent_id, character, template_mod, template_data)
    end

    :ok
  rescue
    e ->
      Logger.warning("[Lifecycle] seed_template_identity failed: #{Exception.message(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[Lifecycle] seed_template_identity exit: #{inspect(reason)}")
      :ok
  end

  defp seed_knowledge_graph(agent_id, character) do
    for item <- character.knowledge || [] do
      content = item[:content] || item["content"] || to_string(item)
      category = item[:category] || item["category"] || "general"

      Arbor.Memory.add_knowledge(agent_id, %{
        type: :fact,
        content: content,
        relevance: 0.8,
        metadata: %{category: category, source: :template}
      })
    end
  end

  defp seed_durable_identity(agent_id, character, template_mod, template_data) do
    # Seed values — prefer template data, then module callback, then character
    values =
      cond do
        template_data && is_list(template_data["values"]) ->
          template_data["values"]

        template_mod && Code.ensure_loaded?(template_mod) &&
            function_exported?(template_mod, :values, 0) ->
          template_mod.values()

        true ->
          character.values || []
      end

    for value <- values do
      Arbor.Memory.add_insight(agent_id, to_string(value), :value, confidence: 0.8)
    end

    # Seed personality traits from character
    for trait <- character.traits || [] do
      name = trait[:name] || trait["name"] || to_string(trait)
      intensity = trait[:intensity] || trait["intensity"] || 0.7
      Arbor.Memory.add_insight(agent_id, name, :trait, confidence: intensity)
    end

    # Seed initial thoughts — prefer template data, then module callback
    thoughts =
      cond do
        template_data && is_list(template_data["initial_thoughts"]) ->
          template_data["initial_thoughts"]

        template_mod && Code.ensure_loaded?(template_mod) &&
            function_exported?(template_mod, :initial_thoughts, 0) ->
          template_mod.initial_thoughts()

        true ->
          []
      end

    for thought <- thoughts do
      Arbor.Memory.record_thinking(agent_id, thought)
    end

    # Final sync persist to ensure the complete state reaches Postgres.
    # Each add_insight above fires persist_async, which races — the last
    # Task to finish wins. This sync write guarantees the full ETS state
    # (with all values + traits) is what ends up in Postgres.
    flush_self_knowledge(agent_id)
  end

  defp flush_self_knowledge(agent_id) do
    sk = Arbor.Memory.get_self_knowledge(agent_id)

    if sk do
      Arbor.Memory.MemoryStore.persist(
        "self_knowledge",
        agent_id,
        Arbor.Memory.SelfKnowledge.serialize(sk)
      )
    end
  end

  defp build_profile(agent_id, display_name, identity, endorsement, keychain, character, opts) do
    # Store template as string name (not module atom)
    template =
      case Keyword.get(opts, :template) do
        mod when is_atom(mod) and not is_nil(mod) -> TemplateStore.module_to_name(mod)
        other -> other
      end

    %Profile{
      agent_id: agent_id,
      display_name: display_name,
      character: character,
      sandbox_level:
        Arbor.Contracts.Security.SandboxLevel.coerce(Keyword.get(opts, :sandbox_level)),
      template: template,
      initial_goals: Keyword.get(opts, :initial_goals, []),
      initial_capabilities: Keyword.get(opts, :capabilities, []),
      identity: %{
        agent_id: identity.agent_id,
        public_key: Base.encode16(identity.public_key, case: :lower),
        endorsement: endorsement
      },
      keychain_ref: keychain.agent_id,
      metadata: build_profile_metadata(opts),
      created_at: DateTime.utc_now(),
      version: 1
    }
  end

  defp build_profile_metadata(opts) do
    base =
      opts
      |> Keyword.get(:metadata, %{})
      |> maybe_put_template_source(Keyword.get(opts, :template_source))
      |> maybe_put_model_config(Keyword.get(opts, :model_config))
      |> maybe_put_exact_template_policy(Keyword.get(opts, :exact_template_policy))

    # Inject created_by from tenant_context if present
    case Keyword.get(opts, :tenant_context) do
      nil ->
        base

      ctx ->
        principal_id = Arbor.Contracts.TenantContext.principal_id(ctx)

        if principal_id, do: Map.put(base, :created_by, principal_id), else: base
    end
  end

  # Record where the agent's template came from (user/shipped/legacy_json/module
  # + abs path). Stored string-keyed so it round-trips through JSON profile
  # persistence unchanged.
  # Persist the model_config the agent was created with as `:last_model_config`,
  # so the model is recoverable for display (mix arbor.agent summary/list/status)
  # and for re-registration on a later start. (JSON round-trip string-keys it on
  # reload; readers use Arbor.Agent.model_id_from_metadata/1, which is tolerant.)
  defp maybe_put_model_config(metadata, %{} = mc) when map_size(mc) > 0,
    do: Map.put(metadata, :last_model_config, mc)

  defp maybe_put_model_config(metadata, _), do: metadata

  defp maybe_put_template_source(metadata, %{} = source) when map_size(source) > 0 do
    Map.put(metadata, "template_source", source)
  end

  defp maybe_put_template_source(metadata, _), do: metadata

  defp maybe_put_exact_template_policy(metadata, %{} = envelope) do
    ExactTemplatePolicy.put_metadata(metadata, envelope)
  end

  defp maybe_put_exact_template_policy(metadata, _envelope), do: metadata

  defp prepare_and_activate_authority(%Profile{} = profile) do
    case resolve_exact_profile_policy(profile) do
      {:ok, prepared_profile, envelope} ->
        snapshot = ExactTemplatePolicy.snapshot(envelope)

        with :ok <- register_profile_identity(prepared_profile, :strict),
             :ok <- ensure_exact_trust_profile(prepared_profile.agent_id, snapshot),
             :ok <- reconcile_exact_capabilities(prepared_profile.agent_id, envelope),
             :ok <- ensure_exact_identity_active(prepared_profile.agent_id) do
          {:ok, prepared_profile, {:exact, envelope}}
        end

      :not_exact ->
        with :ok <- ensure_identity_and_capabilities(profile) do
          {:ok, profile, :legacy}
        end

      {:error, _} = error ->
        error
    end
  end

  defp resolve_exact_profile_policy(%Profile{} = profile) do
    metadata = profile.metadata || %{}

    case ExactTemplatePolicy.from_metadata(metadata) do
      {:ok, _envelope} ->
        validate_exact_profile_template(profile)

      :not_marked ->
        if ExactTemplatePolicy.migration_candidate?(profile) do
          migrate_pipeline_architect_policy(profile)
        else
          :not_exact
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_exact_profile_template(%Profile{template: template} = profile)
       when is_binary(template) do
    with {:ok, stored} <- ExactTemplatePolicy.from_metadata(profile.metadata || %{}),
         repo_root = stored |> ExactTemplatePolicy.snapshot() |> ExactTemplatePolicy.repo_root(),
         :ok <- validate_exact_repo_root(repo_root),
         {:ok, data} <- reload_exact_template(template),
         {:ok, envelope} <-
           ExactTemplatePolicy.validate(template, profile.metadata || %{}, data,
             repo_root: repo_root
           ) do
      {:ok, profile, envelope}
    end
  end

  defp validate_exact_profile_template(_profile) do
    {:error, {:exact_template_policy, :template_reference_missing_or_invalid}}
  end

  defp migrate_pipeline_architect_policy(%Profile{template: template} = profile) do
    with {:ok, data} <- reload_exact_template(template),
         {:ok, repo_root} <- exact_repo_root_for_capabilities(),
         {:ok, envelope} <-
           require_exact_policy(ExactTemplatePolicy.build(template, data, repo_root: repo_root)),
         snapshot = ExactTemplatePolicy.snapshot(envelope),
         migrated = %{
           profile
           | metadata: ExactTemplatePolicy.put_metadata(profile.metadata || %{}, envelope),
             initial_capabilities: ExactTemplatePolicy.capabilities(snapshot),
             sandbox_level: ExactTemplatePolicy.sandbox_level(snapshot)
         },
         :ok <- persist_profile(migrated) do
      Logger.info("[Lifecycle] migrated Pipeline Architect exact policy snapshot",
        agent_id: profile.agent_id,
        template_digest: ExactTemplatePolicy.digest(envelope)
      )

      {:ok, migrated, envelope}
    else
      {:error, reason} -> {:error, {:exact_policy_migration_failed, reason}}
      other -> {:error, {:exact_policy_migration_failed, {:unexpected_result, other}}}
    end
  end

  defp reload_exact_template(template) do
    case TemplateStore.reload(template) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:exact_template_unavailable, reason}}
    end
  rescue
    error -> {:error, {:exact_template_unreadable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exact_template_unreadable, {:exit, reason}}}
    kind, reason -> {:error, {:exact_template_unreadable, {kind, reason}}}
  end

  defp require_exact_policy({:ok, envelope}), do: {:ok, envelope}

  defp require_exact_policy(:not_exact),
    do: {:error, {:exact_template_policy, :template_exact_metadata_missing}}

  defp require_exact_policy({:error, _} = error), do: error

  defp validate_exact_repo_root(nil), do: :ok

  defp validate_exact_repo_root(repo_root) when is_binary(repo_root) do
    case SafePath.resolve_real(repo_root) do
      {:ok, ^repo_root} ->
        if Path.type(repo_root) == :absolute and umbrella_root?(repo_root),
          do: :ok,
          else: {:error, {:exact_template_policy, {:repo_root_unavailable, repo_root}}}

      _ ->
        {:error, {:exact_template_policy, {:repo_root_unavailable, repo_root}}}
    end
  end

  defp validate_exact_repo_root(repo_root),
    do: {:error, {:exact_template_policy, {:repo_root_invalid, repo_root}}}

  defp ensure_exact_trust_profile(agent_id, snapshot) do
    %{baseline: baseline, rules: rules} =
      snapshot
      |> ExactTemplatePolicy.trust_preset()
      |> normalize_trust_preset()

    case Arbor.Trust.ensure_trust_profile(agent_id,
           baseline: baseline,
           rules: rules,
           recover_deleted: true
         ) do
      {:ok, _profile} -> :ok
      {:error, reason} -> {:error, {:exact_trust_profile_failed, reason}}
    end
  end

  # Re-register identity and capabilities on resume.
  # ETS-based stores lose state on restart, so we re-grant from the profile.
  defp ensure_identity_and_capabilities(%Profile{} = profile) do
    agent_id = profile.agent_id

    _result = register_profile_identity(profile, :best_effort)

    # Re-grant capabilities from template or stored list
    # Filter out retired plural action grants; action execution now authorizes
    # against facade/resource URIs or singular arbor://action/* URIs.
    capabilities =
      resolve_capabilities_for_regrant(profile)
      |> Enum.reject(fn cap ->
        resource = cap[:resource] || cap["resource"] || ""
        String.starts_with?(resource, "arbor://actions/execute/")
      end)

    grant_capabilities(agent_id, capabilities, extract_template_metadata(profile))
  end

  defp register_profile_identity(%Profile{} = profile, mode) do
    agent_id = profile.agent_id

    # Re-register identity from stored public key
    case profile.identity do
      %{public_key: pub_hex} when is_binary(pub_hex) ->
        case Base.decode16(pub_hex, case: :mixed) do
          {:ok, pub_key} ->
            identity = %Arbor.Contracts.Security.Identity{
              agent_id: agent_id,
              public_key: pub_key,
              name: profile.display_name,
              status: :active,
              created_at: profile.created_at || DateTime.utc_now()
            }

            case Arbor.Security.register_identity(identity) do
              :ok ->
                :ok

              {:error, :already_registered} ->
                :ok

              {:error, {:already_registered, _agent_id}} ->
                :ok

              {:error, reason} ->
                identity_registration_failure(mode, agent_id, reason)
            end

          :error ->
            identity_registration_failure(mode, agent_id, :invalid_public_key)
        end

      _ ->
        identity_registration_failure(mode, agent_id, :identity_metadata_missing)
    end
  end

  defp identity_registration_failure(:strict, _agent_id, reason),
    do: {:error, {:identity_registration_failed, reason}}

  defp identity_registration_failure(:best_effort, agent_id, reason) do
    Logger.warning("Failed to re-register identity: #{inspect(reason)}", agent_id: agent_id)
    :ok
  end

  defp ensure_exact_identity_active(agent_id) do
    case Arbor.Security.identity_status(agent_id) do
      {:ok, :active} -> :ok
      {:ok, :suspended} -> Arbor.Security.resume_identity(agent_id)
      {:ok, status} -> {:error, {:identity_not_activatable, status}}
      {:error, reason} -> {:error, {:identity_status_failed, reason}}
      other -> {:error, {:unexpected_identity_status, other}}
    end
  end

  defp resolve_capabilities_for_regrant(%Profile{} = profile) do
    # Prefer template's current capabilities (may have been updated)
    case profile.template do
      nil ->
        profile.initial_capabilities || []

      name when is_binary(name) ->
        case TemplateStore.get(name) do
          {:ok, data} -> data["required_capabilities"] || profile.initial_capabilities || []
          {:error, _} -> profile.initial_capabilities || []
        end

      template_mod when is_atom(template_mod) ->
        if Code.ensure_loaded?(template_mod) and
             function_exported?(template_mod, :required_capabilities, 0) do
          template_mod.required_capabilities()
        else
          profile.initial_capabilities || []
        end
    end
  end

  defp persist_profile(%Profile{} = profile) do
    ProfileStore.store_profile(profile)
  end

  defp handle_authority_failure(%Profile{} = profile, {:error, reason} = error) do
    if ExactTemplatePolicy.managed_profile?(profile) do
      _ = stop(profile.agent_id)

      results = [
        suspend_exact_identity(profile.agent_id),
        cleanup_agent_authority(profile.agent_id)
      ]

      case Enum.reject(results, &(&1 == :ok)) do
        [] ->
          error

        cleanup_errors ->
          {:error, {:exact_authority_activation_failed, reason, cleanup_errors}}
      end
    else
      error
    end
  end

  defp suspend_exact_identity(agent_id) do
    case Arbor.Security.identity_status(agent_id) do
      {:ok, :active} ->
        safe_cleanup(fn ->
          Arbor.Security.suspend_identity(agent_id, reason: :exact_policy_activation_failed)
        end)

      {:ok, :suspended} ->
        :ok

      {:ok, :revoked} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, {:identity_status_failed, reason}}

      other ->
        {:error, {:unexpected_identity_status, other}}
    end
  rescue
    error -> {:error, {:identity_suspension_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:identity_suspension_exit, reason}}
    kind, reason -> {:error, {:identity_suspension_failure, kind, reason}}
  end

  defp rollback_failed_creation(agent_id) do
    cleanup_results = [
      cleanup_agent_authority(agent_id),
      safe_cleanup(fn -> Arbor.Security.delete_signing_key(agent_id) end),
      safe_cleanup(fn -> Arbor.Security.deregister_identity(agent_id) end),
      safe_cleanup(fn -> ProfileStore.delete_profile(agent_id) end),
      safe_cleanup(fn -> Arbor.Memory.cleanup_for_agent(agent_id) end)
    ]

    errors = Enum.reject(cleanup_results, &(&1 == :ok))

    if errors != [] do
      Logger.error("[Lifecycle] failed creation cleanup was incomplete",
        agent_id: agent_id,
        cleanup_errors: inspect(errors)
      )
    end

    :ok
  end

  defp cleanup_agent_authority(agent_id) do
    results = [
      revoke_all_agent_capabilities(agent_id),
      safe_cleanup(fn -> Arbor.Trust.delete_trust_profile(agent_id) end)
    ]

    case Enum.reject(results, &(&1 == :ok)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp revoke_all_agent_capabilities(agent_id) do
    case Arbor.Security.list_capabilities(agent_id) do
      {:ok, capabilities} -> revoke_capabilities(capabilities)
      {:error, reason} -> {:error, {:capability_list_failed, reason}}
      other -> {:error, {:unexpected_capability_list_result, other}}
    end
  rescue
    error -> {:error, {:capability_cleanup_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:capability_cleanup_exit, reason}}
    kind, reason -> {:error, {:capability_cleanup_failure, kind, reason}}
  end

  defp safe_cleanup(cleanup) when is_function(cleanup, 0) do
    case cleanup.() do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected_cleanup_result, other}}
    end
  rescue
    error -> {:error, {:cleanup_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:cleanup_exit, reason}}
    kind, reason -> {:error, {:cleanup_failure, kind, reason}}
  end

  # Create a trust profile and apply any template preset. A declared preset is a
  # security invariant: creation must fail if the trust subsystem cannot store it.
  # Templates without a preset retain the historical best-effort behavior.
  defp ensure_trust_profile(agent_id, opts) do
    preset_required? = not is_nil(resolve_trust_preset(opts))

    result =
      try do
        do_ensure_trust_profile(agent_id, opts)
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} when preset_required? ->
        Logger.error(
          "[Lifecycle] required template trust preset could not be stored for #{agent_id}: " <>
            inspect(reason)
        )

        {:error, reason}

      {:error, reason} ->
        Logger.warning(
          "[Lifecycle] trust profile setup failed for #{agent_id}; no template preset was " <>
            "declared: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp do_ensure_trust_profile(agent_id, opts) do
    case resolve_trust_preset(opts) do
      nil ->
        case Arbor.Trust.ensure_trust_profile(agent_id) do
          {:ok, _profile} -> :ok
          {:error, _} = error -> error
          other -> {:error, {:unexpected_trust_setup_result, other}}
        end

      %{} = preset ->
        baseline = Map.get(preset, :baseline, :block)
        rules = Map.get(preset, :rules, %{})

        case Arbor.Trust.ensure_trust_profile(agent_id, baseline: baseline, rules: rules) do
          {:ok, %{baseline: ^baseline, rules: ^rules}} ->
            :ok

          {:ok, profile} ->
            {:error, {:trust_preset_mismatch, profile}}

          {:error, reason} ->
            {:error, {:trust_preset_store_failed, reason}}

          other ->
            {:error, {:unexpected_trust_preset_store_result, other}}
        end
    end
  end

  # Resolve a normalized `%{baseline: atom, rules: %{uri => atom}}` preset, or nil.
  # Data-first frontmatter wins over the legacy module callback.
  defp resolve_trust_preset(opts) do
    frontmatter = Keyword.get(opts, :trust_preset)
    mod = Keyword.get(opts, :template_module)

    cond do
      is_map(frontmatter) and map_size(frontmatter) > 0 ->
        normalize_trust_preset(frontmatter)

      mod && Code.ensure_loaded?(mod) && function_exported?(mod, :trust_preset, 0) ->
        mod.trust_preset()

      true ->
        nil
    end
  end

  # Normalize a frontmatter trust_preset (string keys/values from YAML) →
  # `%{baseline: atom, rules: %{uri => atom}}`. Unknown modes default to :block
  # (deny) — fail-closed, since a mis-typed preset must not silently widen trust.
  defp normalize_trust_preset(%{} = preset) do
    baseline = preset |> Map.get("baseline", "block") |> parse_trust_mode()

    rules =
      (preset["rules"] || %{})
      |> Enum.into(%{}, fn {uri, mode} ->
        {normalize_trust_rule_uri(to_string(uri)), parse_trust_mode(mode)}
      end)

    %{baseline: baseline, rules: rules}
  end

  # Trust rules match by URI PREFIX, not glob — a trailing /** is a dead literal that
  # silently never fires (Arbor.Contracts.Security.TrustRule). Warn loudly + canonicalize
  # to the bare prefix so a template's glob rule works instead of vanishing to baseline.
  defp normalize_trust_rule_uri(uri) do
    if Arbor.Contracts.Security.TrustRule.glob?(uri) do
      Logger.warning(
        "[Lifecycle] trust_preset rule #{inspect(uri)} contains a glob (/** or /*); trust rules " <>
          "match by PREFIX not glob, so the glob form never fires. Canonicalizing to the bare " <>
          "prefix — fix the template to use the bare URI."
      )

      Arbor.Contracts.Security.TrustRule.canonicalize(uri)
    else
      uri
    end
  end

  defp parse_trust_mode(mode) when is_atom(mode), do: mode
  defp parse_trust_mode("block"), do: :block
  defp parse_trust_mode("ask"), do: :ask
  defp parse_trust_mode("allow"), do: :allow
  defp parse_trust_mode("auto"), do: :auto
  defp parse_trust_mode(_), do: :block

  defp emit_created_signal(%Profile{} = profile) do
    dual_emit_lifecycle(:created, %{
      agent_id: profile.agent_id,
      name: profile.character.name,
      template: profile.template
    })
  end

  # Emit durable lifecycle signal via centralized Signals.durable_emit/4.
  # This handles: signal bus emit + EventLog ETS write + async Postgres write.
  @lifecycle_stream_id "agent:lifecycle"

  defp dual_emit_lifecycle(event_type, data) do
    Arbor.Signals.durable_emit(:agent, event_type, data, stream_id: @lifecycle_stream_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
