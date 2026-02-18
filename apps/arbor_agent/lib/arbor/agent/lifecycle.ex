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

  alias Arbor.Agent.{APIAgent, Character, Executor, Profile, SessionManager}
  alias Arbor.Contracts.Memory.Goal

  require Logger

  @agents_dir ".arbor/agents"

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
         {:ok, _pid} <- init_memory(agent_id, opts[:memory_opts] || []),
         :ok <- set_initial_goals(agent_id, opts[:initial_goals] || []),
         :ok <- seed_template_identity(agent_id, character, opts) do
      profile =
        build_profile(agent_id, display_name, identity, endorsement, keychain, character, opts)

      case persist_profile(profile) do
        :ok ->
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
      {:ok, signed} = signer.("arbor://actions/execute/file_read")
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
    path = profile_path(agent_id)

    case File.read(path) do
      {:ok, json} ->
        case Profile.from_json(json) do
          {:ok, profile} ->
            Arbor.Signals.emit(:agent, :restored, %{
              agent_id: agent_id,
              version: profile.version
            })

            {:ok, profile}

          {:error, reason} ->
            {:error, {:deserialize_failed, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Start an agent's execution (create executor, subscribe to intents).
  """
  @spec start(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(agent_id, opts \\ []) do
    case restore(agent_id) do
      {:ok, profile} ->
        # Re-register identity and capabilities (ETS-only, lost on restart)
        ensure_identity_and_capabilities(profile)

        # Re-initialize memory (knowledge graph ETS, index supervisor)
        # These are in-memory only and lost on restart
        init_memory(agent_id, [])

        executor_opts =
          Keyword.merge(opts,
            agent_id: agent_id,
            trust_tier: profile.trust_tier
          )

        case Executor.start(agent_id, executor_opts) do
          {:ok, pid} ->
            maybe_start_session(agent_id, profile, opts)
            maybe_start_api_agent(agent_id, profile, opts)
            Arbor.Signals.emit(:agent, :started, %{agent_id: agent_id})
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop an agent cleanly.
  """
  @spec stop(String.t()) :: :ok | {:error, term()}
  def stop(agent_id) do
    try do
      SessionManager.stop_session(agent_id)
    catch
      :exit, _ -> :ok
    end

    # Stop APIAgent host if running
    try do
      case Registry.lookup(Arbor.Agent.ExecutorRegistry, {:host, agent_id}) do
        [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
        [] -> :ok
      end
    catch
      :exit, _ -> :ok
    end

    result = Executor.stop(agent_id)

    Arbor.Signals.emit(:agent, :stopped, %{
      agent_id: agent_id,
      reason: :normal
    })

    result
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
  List all known agent profiles from the agents directory.
  """
  @spec list_agents() :: [Profile.t()]
  def list_agents do
    agents_dir = agents_dir()

    case File.ls(agents_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".agent.json"))
        |> Enum.map(fn file ->
          agent_id = String.replace_suffix(file, ".agent.json", "")
          restore(agent_id)
        end)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, profile} -> profile end)

      {:error, _} ->
        []
    end
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

    # Remove profile
    path = profile_path(agent_id)

    case File.rm(path) do
      :ok ->
        Arbor.Signals.emit(:agent, :destroyed, %{agent_id: agent_id})
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private helpers --

  defp maybe_start_session(agent_id, profile, opts) do
    mode = Application.get_env(:arbor_agent, :session_execution_mode, :session)

    if mode in [:session, :graph] do
      # Include all available actions as tools unless explicitly provided
      tools =
        Keyword.get_lazy(opts, :tools, fn ->
          if Code.ensure_loaded?(Arbor.Actions),
            do: apply(Arbor.Actions, :all_actions, []),
            else: []
        end)

      session_opts =
        Keyword.merge(opts,
          trust_tier: profile.trust_tier,
          tools: tools,
          start_heartbeat: true
        )

      case SessionManager.ensure_session(agent_id, session_opts) do
        {:ok, _pid} ->
          Logger.info("Session started for agent #{agent_id}", mode: mode)

        {:error, reason} ->
          Logger.warning(
            "Failed to start session for agent #{agent_id}: #{inspect(reason)}",
            mode: mode
          )
      end
    end
  end

  defp maybe_start_api_agent(agent_id, profile, opts) do
    if Keyword.get(opts, :start_host, true) do
      host_opts = [
        id: agent_id,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:host, agent_id}}},
        display_name: profile.display_name || agent_id,
        model: Keyword.get(opts, :model, "arcee-ai/trinity-large-preview:free"),
        provider: Keyword.get(opts, :provider, :openrouter)
      ]

      case APIAgent.start_link(host_opts) do
        {:ok, _pid} ->
          Logger.info("APIAgent host started for agent #{agent_id}")

        {:error, reason} ->
          Logger.warning(
            "Failed to start APIAgent host for agent #{agent_id}: #{inspect(reason)}"
          )
      end
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

      template_mod when is_atom(template_mod) ->
        character = template_mod.character()

        opts =
          opts
          |> Keyword.put_new(:trust_tier, template_mod.trust_tier())
          |> Keyword.put_new(:initial_goals, template_mod.initial_goals())
          |> Keyword.put_new(:capabilities, template_mod.required_capabilities())
          |> Keyword.put_new(:template_module, template_mod)

        {:ok, character, opts}
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
    results =
      Enum.map(capabilities, fn cap ->
        resource = cap[:resource] || cap["resource"]

        case Arbor.Security.grant(principal: agent_id, resource: resource) do
          {:ok, _cap} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to grant capability #{resource}: #{inspect(reason)}",
              agent_id: agent_id
            )

            {:error, reason}
        end
      end)

    granted = Enum.count(results, &(&1 == :ok))
    Logger.info("Granted #{granted}/#{length(capabilities)} capabilities", agent_id: agent_id)
    :ok
  end

  defp init_memory(agent_id, opts) do
    Arbor.Memory.init_for_agent(agent_id, opts)
  end

  defp set_initial_goals(_agent_id, []), do: :ok

  defp set_initial_goals(agent_id, goals) do
    Enum.each(goals, fn goal_map ->
      description = goal_map[:description] || goal_map["description"] || "Unnamed goal"
      type = goal_map[:type] || goal_map["type"] || :achieve

      type_atom =
        if is_binary(type), do: String.to_existing_atom(type), else: type

      goal = Goal.new(description, type: type_atom)
      Arbor.Memory.add_goal(agent_id, goal)
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

    # Knowledge graph is ETS-only (transient) — always re-seed on startup
    seed_knowledge_graph(agent_id, character)

    # Identity data (values, traits, thoughts) is durably persisted —
    # only seed once (skip if SelfKnowledge already has values)
    sk = Arbor.Memory.get_self_knowledge(agent_id)

    unless sk && sk.values != [] do
      seed_durable_identity(agent_id, character, template_mod)
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

  defp seed_durable_identity(agent_id, character, template_mod) do
    # Seed values from template callback
    for value <- (template_mod && template_mod.values()) || character.values || [] do
      Arbor.Memory.add_insight(agent_id, to_string(value), :value, confidence: 0.8)
    end

    # Seed personality traits from character
    for trait <- character.traits || [] do
      name = trait[:name] || trait["name"] || to_string(trait)
      intensity = trait[:intensity] || trait["intensity"] || 0.7
      Arbor.Memory.add_insight(agent_id, name, :trait, confidence: intensity)
    end

    # Seed initial thoughts from template callback
    if template_mod do
      for thought <- template_mod.initial_thoughts() || [] do
        Arbor.Memory.record_thinking(agent_id, thought)
      end
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
    %Profile{
      agent_id: agent_id,
      display_name: display_name,
      character: character,
      trust_tier: Keyword.get(opts, :trust_tier, :untrusted),
      template: Keyword.get(opts, :template),
      initial_goals: Keyword.get(opts, :initial_goals, []),
      initial_capabilities: Keyword.get(opts, :capabilities, []),
      identity: %{
        agent_id: identity.agent_id,
        public_key: Base.encode16(identity.public_key, case: :lower),
        endorsement: endorsement
      },
      keychain_ref: keychain.agent_id,
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now(),
      version: 1
    }
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
    capabilities = resolve_capabilities_for_regrant(profile)
    grant_capabilities(agent_id, capabilities)
  end

  defp resolve_capabilities_for_regrant(%Profile{} = profile) do
    # Prefer template's current capabilities (may have been updated)
    case profile.template do
      nil ->
        profile.initial_capabilities || []

      template_mod when is_atom(template_mod) ->
        if Code.ensure_loaded?(template_mod) and
             function_exported?(template_mod, :required_capabilities, 0) do
          template_mod.required_capabilities()
        else
          profile.initial_capabilities || []
        end

      template_str when is_binary(template_str) ->
        try do
          mod = String.to_existing_atom("Elixir." <> template_str)

          if function_exported?(mod, :required_capabilities, 0) do
            mod.required_capabilities()
          else
            profile.initial_capabilities || []
          end
        rescue
          ArgumentError -> profile.initial_capabilities || []
        end
    end
  end

  defp persist_profile(%Profile{} = profile) do
    dir = agents_dir()
    File.mkdir_p!(dir)
    path = profile_path(profile.agent_id)

    case Profile.to_json(profile) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_created_signal(%Profile{} = profile) do
    Arbor.Signals.emit(:agent, :created, %{
      agent_id: profile.agent_id,
      name: profile.character.name,
      template: profile.template,
      trust_tier: profile.trust_tier
    })
  end

  defp profile_path(agent_id) do
    Path.join(agents_dir(), "#{agent_id}.agent.json")
  end

  defp agents_dir do
    Path.join(File.cwd!(), @agents_dir)
  end
end
