defmodule Arbor.Agent.Lifecycle do
  @moduledoc """
  Orchestrates the full agent lifecycle: create, restore, start, stop, destroy.

  This is the primary API for agent management. It coordinates identity,
  security, memory, and execution into a single flow — the trust-arbor
  equivalent of old arbor's `Arbor.Seed.new("id", template: CodeCompanion)`.

  ## Examples

      # From template (first arg is display name, not agent_id)
      {:ok, profile} = Lifecycle.create("Scout", template: Arbor.Agent.Templates.Scout)
      profile.agent_id  #=> "agent_a4f2..."  (crypto-derived)
      profile.display_name  #=> "Scout"

      # From options (inline character)
      {:ok, profile} = Lifecycle.create("My Agent",
        character: Character.new(name: "My Agent", values: ["helpfulness"]),
        trust_tier: :probationary,
        initial_goals: [%{type: :achieve, description: "Complete the review"}],
        capabilities: [%{resource: "arbor://fs/read/**"}]
      )

      # Restore from disk
      {:ok, profile} = Lifecycle.restore("scout-1")

      # List all agents
      profiles = Lifecycle.list_agents()
  """

  alias Arbor.Agent.{
    BranchSupervisor,
    Character,
    Executor,
    Profile,
    ProfileStore,
    SessionConfig,
    SessionManager,
    TemplateStore
  }

  alias Arbor.Contracts.Memory.Goal

  require Logger

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
  """
  @spec create(String.t(), keyword()) :: {:ok, Profile.t()} | {:error, term()}
  def create(display_name, opts \\ []) do
    with {:ok, character, opts} <- resolve_template(opts),
         {:ok, identity} <- generate_identity(display_name),
         :ok <- register_identity(identity),
         {:ok, endorsement} <- endorse_identity(identity),
         keychain <- create_keychain(identity),
         agent_id = identity.agent_id,
         :ok <- persist_signing_key(agent_id, identity),
         :ok <- grant_capabilities(agent_id, opts[:capabilities] || []),
         :ok <- grant_workspace_capabilities(agent_id, opts),
         :ok <- maybe_delegate_from_parent(agent_id, opts),
         {:ok, _pid} <- init_memory(agent_id, opts[:memory_opts] || []),
         :ok <- set_initial_goals(agent_id, opts[:initial_goals] || []),
         :ok <- seed_template_identity(agent_id, character, opts) do
      profile =
        build_profile(agent_id, display_name, identity, endorsement, keychain, character, opts)

      case persist_profile(profile) do
        :ok ->
          ensure_trust_profile(agent_id, opts)
          emit_created_signal(profile)
          {:ok, profile}

        {:error, reason} ->
          {:error, {:persist_failed, reason}}
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
        ensure_identity_and_capabilities(profile)
        {:ok, agent_id}

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
    # Idempotent: if branch supervisor already running, return it
    case BranchSupervisor.whereis(agent_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        do_start(agent_id, opts)
    end
  end

  defp do_start(agent_id, opts) do
    case restore(agent_id) do
      {:ok, profile} ->
        # Re-register identity and capabilities (ETS-only, lost on restart)
        ensure_identity_and_capabilities(profile)

        # Re-initialize memory (knowledge graph ETS, index supervisor)
        init_memory(agent_id, [])

        # Reload persisted goals and intents into ETS
        reload_persisted_memory(agent_id)

        # Build child opts for the BranchSupervisor
        host_opts = build_host_opts(agent_id, profile, opts)
        executor_opts = build_executor_opts(agent_id, profile, opts)
        session_opts = build_branch_session_opts(agent_id, profile, opts)
        start_session = Keyword.get(opts, :start_session, true)

        branch_opts = [
          agent_id: agent_id,
          host_opts: host_opts,
          executor_opts: executor_opts,
          session_opts: session_opts,
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
      get_in(opts, [:tenant_context, :principal_id])
  end

  defp user_supervisor_available? do
    Process.whereis(Arbor.Agent.UserSupervisor) != nil
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
      backend: :api,
      started_at: System.system_time(:millisecond)
    }

    metadata =
      case Map.get(profile.metadata || %{}, :created_by) do
        nil -> metadata
        created_by -> Map.put(metadata, :created_by, created_by)
      end

    Arbor.Agent.Registry.register(agent_id, sup_pid, metadata)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp extract_model_config(profile, opts) do
    Keyword.get(opts, :model_config) ||
      get_in(profile.metadata || %{}, [:last_model_config]) ||
      %{}
  end

  # Build opts for the APIAgent host child
  defp build_host_opts(agent_id, profile, opts) do
    [
      id: agent_id,
      display_name: profile.display_name || agent_id,
      model: Keyword.get_lazy(opts, :model, fn -> Arbor.Agent.LLMDefaults.default_model() end),
      provider:
        Keyword.get_lazy(opts, :provider, fn -> Arbor.Agent.LLMDefaults.default_provider() end)
    ]
  end

  # Build opts for the Executor child
  defp build_executor_opts(agent_id, _profile, opts) do
    Keyword.merge(opts,
      agent_id: agent_id,
      trust_tier: Keyword.get(opts, :trust_tier, :established)
    )
  end

  # Build session opts for the BranchSupervisor (or nil to skip session).
  defp build_branch_session_opts(agent_id, profile, opts) do
    mode = Application.get_env(:arbor_agent, :session_execution_mode, :session)

    if mode in [:session, :graph] do
      tools = Keyword.get(opts, :tools)

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
          trust_tier: profile.trust_tier,
          tools: tools,
          system_prompt: system_prompt,
          start_heartbeat: Keyword.get(opts, :start_heartbeat, true),
          signer: signer
        )

      session_opts = merge_template_opts(session_opts, template_meta, opts)

      # Single shared builder for session init opts
      SessionConfig.build(agent_id, session_opts)
    else
      nil
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
  Delete an agent and all its data.
  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(agent_id) do
    # Stop executor if running
    Executor.stop(agent_id)

    # Clean up memory
    Arbor.Memory.cleanup_for_agent(agent_id)

    # Clean up signing key
    Arbor.Security.delete_signing_key(agent_id)

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

    if Code.ensure_loaded?(Arbor.AI) and
         function_exported?(Arbor.AI, :build_stable_system_prompt, 2) do
      try do
        apply(Arbor.AI, :build_stable_system_prompt, [agent_id, prompt_opts])
      rescue
        _ -> fallback_system_prompt(profile)
      catch
        :exit, _ -> fallback_system_prompt(profile)
      end
    else
      fallback_system_prompt(profile)
    end
  end

  defp fallback_system_prompt(profile) do
    name = profile.display_name || profile.character.name || "Agent"
    desc = profile.character.description || ""
    "You are #{name}. #{desc}"
  end

  # Extract metadata from the template module (if available).
  # Template metadata may include :context_management, :model, :provider.
  defp extract_template_metadata(profile) do
    case profile.template do
      nil ->
        %{}

      name when is_binary(name) ->
        case TemplateStore.get(name) do
          {:ok, data} ->
            meta = data["metadata"] || %{}
            # Convert string keys to atom keys for compatibility
            Map.new(meta, fn
              {k, v} when is_binary(k) ->
                try do
                  {String.to_existing_atom(k), v}
                rescue
                  ArgumentError -> {k, v}
                end

              {k, v} ->
                {k, v}
            end)

          {:error, _} ->
            %{}
        end

      module when is_atom(module) ->
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
  end

  # Merge template-derived options into session_opts.
  # Explicit caller opts take precedence over template defaults.
  defp merge_template_opts(session_opts, template_meta, caller_opts) do
    template_keys = [
      {:context_management, :context_management},
      {:model, :model},
      {:provider, :provider}
    ]

    Enum.reduce(template_keys, session_opts, fn {meta_key, opt_key}, acc ->
      if Keyword.has_key?(caller_opts, opt_key) do
        acc
      else
        case Map.get(template_meta, meta_key) do
          nil -> acc
          value -> Keyword.put_new(acc, opt_key, value)
        end
      end
    end)
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
              |> Keyword.put_new(:trust_tier, kw[:trust_tier])
              |> Keyword.put_new(:initial_goals, kw[:initial_goals])
              |> Keyword.put_new(:capabilities, kw[:required_capabilities])
              |> Keyword.put(:template, template_name)
              |> Keyword.put(:template_data, data)

            {:ok, character, opts}

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
              |> Keyword.put_new(:trust_tier, kw[:trust_tier])
              |> Keyword.put_new(:initial_goals, kw[:initial_goals])
              |> Keyword.put_new(:capabilities, kw[:required_capabilities])
              |> Keyword.put(:template, name)
              |> Keyword.put(:template_data, data)
              |> Keyword.put_new(:template_module, template_mod)

            {:ok, character, opts}

          {:error, :not_found} ->
            # Direct module fallback for backward compatibility
            if Code.ensure_loaded?(template_mod) and
                 function_exported?(template_mod, :character, 0) do
              character = template_mod.character()

              opts =
                opts
                |> Keyword.put_new(:trust_tier, template_mod.trust_tier())
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

  defp grant_capabilities(_agent_id, []), do: :ok

  defp grant_capabilities(agent_id, capabilities) do
    # Check which capabilities the agent already has to avoid duplicates
    existing_uris =
      case Arbor.Security.CapabilityStore.list_for_principal(agent_id) do
        {:ok, caps} -> MapSet.new(caps, & &1.resource_uri)
        _ -> MapSet.new()
      end

    results =
      Enum.map(capabilities, fn cap ->
        resource = cap[:resource] || cap["resource"]

        if MapSet.member?(existing_uris, resource) do
          :skipped
        else
          case Arbor.Security.grant(principal: agent_id, resource: resource) do
            {:ok, _cap} ->
              :ok

            {:error, reason} ->
              Logger.warning("Failed to grant capability #{resource}: #{inspect(reason)}",
                agent_id: agent_id
              )

              {:error, reason}
          end
        end
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

  # Grant workspace-scoped fs capabilities when tenant_context provides a workspace root.
  # This ensures agents can access their user's workspace directory.
  defp grant_workspace_capabilities(agent_id, opts) do
    tenant_context = Keyword.get(opts, :tenant_context)

    workspace_root =
      if tenant_context && Code.ensure_loaded?(Arbor.Contracts.TenantContext) do
        apply(Arbor.Contracts.TenantContext, :effective_workspace_root, [tenant_context])
      end

    if workspace_root do
      principal_id =
        apply(Arbor.Contracts.TenantContext, :principal_id, [tenant_context])

      for op <- [:read, :write, :list] do
        resource = "arbor://fs/#{op}/#{String.trim_leading(workspace_root, "/")}"

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

  # Delegate capabilities from a parent (human or agent) to the newly created agent.
  # Non-fatal: logs warnings on failure, always returns :ok for backwards compat.
  defp maybe_delegate_from_parent(agent_id, opts) do
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

  defp reload_persisted_memory(agent_id) do
    Arbor.Memory.GoalStore.reload_for_agent(agent_id)
    Arbor.Memory.IntentStore.reload_for_agent(agent_id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
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

        type_atom =
          if is_binary(type), do: String.to_existing_atom(type), else: type

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
      trust_tier: Keyword.get(opts, :trust_tier, :untrusted),
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
    base = Keyword.get(opts, :metadata, %{})

    # Inject created_by from tenant_context if present
    case Keyword.get(opts, :tenant_context) do
      nil ->
        base

      ctx ->
        principal_id =
          if Code.ensure_loaded?(Arbor.Contracts.TenantContext) do
            apply(Arbor.Contracts.TenantContext, :principal_id, [ctx])
          end

        if principal_id, do: Map.put(base, :created_by, principal_id), else: base
    end
  end

  # Re-register identity and capabilities on resume.
  # ETS-based stores lose state on restart, so we re-grant from the profile.
  defp ensure_identity_and_capabilities(%Profile{} = profile) do
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

              {:error, reason} ->
                Logger.warning("Failed to re-register identity: #{inspect(reason)}",
                  agent_id: agent_id
                )
            end

          :error ->
            Logger.warning("Invalid public key hex in profile", agent_id: agent_id)
        end

      _ ->
        :ok
    end

    # Re-grant capabilities from template or stored list
    # Filter out actions/execute/* — facade auth replaced action-level auth
    capabilities =
      resolve_capabilities_for_regrant(profile)
      |> Enum.reject(fn cap ->
        resource = cap[:resource] || cap["resource"] || ""
        String.starts_with?(resource, "arbor://actions/execute/")
      end)

    grant_capabilities(agent_id, capabilities)
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

  # Create a trust profile for the agent if the Trust system is available.
  # If the template module exports trust_preset/0, apply those rules after creation.
  defp ensure_trust_profile(agent_id, opts) do
    trust = Arbor.Trust

    if Code.ensure_loaded?(trust) and function_exported?(trust, :create_trust_profile, 1) do
      case apply(trust, :get_trust_profile, [agent_id]) do
        {:ok, _} -> :ok
        {:error, :not_found} -> apply(trust, :create_trust_profile, [agent_id])
      end

      # Apply template-specific trust preset if available
      apply_template_trust_preset(agent_id, opts)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # If the template module exports trust_preset/0, override the default trust profile
  # with the template's custom rules. This allows templates like CouncilEvaluator
  # to define restrictive read-only profiles.
  defp apply_template_trust_preset(agent_id, opts) do
    template_mod = Keyword.get(opts, :template_module)
    store = Arbor.Trust.Store

    if template_mod && Code.ensure_loaded?(template_mod) &&
         function_exported?(template_mod, :trust_preset, 0) do
      preset = template_mod.trust_preset()
      baseline = Map.get(preset, :baseline, :block)
      rules = Map.get(preset, :rules, %{})

      if Code.ensure_loaded?(store) and function_exported?(store, :update_profile, 2) do
        apply(store, :update_profile, [
          agent_id,
          fn profile -> %{profile | baseline: baseline, rules: rules} end
        ])
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp emit_created_signal(%Profile{} = profile) do
    dual_emit_lifecycle(:created, %{
      agent_id: profile.agent_id,
      name: profile.character.name,
      template: profile.template,
      trust_tier: profile.trust_tier
    })
  end

  # Emit durable lifecycle signal via centralized Signals.durable_emit/4.
  # This handles: signal bus emit + EventLog ETS write + async Postgres write.
  # Falls back to plain emit if durable_emit is not yet available.
  @lifecycle_stream_id "agent:lifecycle"

  defp dual_emit_lifecycle(event_type, data) do
    if function_exported?(Arbor.Signals, :durable_emit, 4) do
      Arbor.Signals.durable_emit(:agent, event_type, data, stream_id: @lifecycle_stream_id)
    else
      Arbor.Signals.emit(:agent, event_type, data)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
