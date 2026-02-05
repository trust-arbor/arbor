defmodule Arbor.Agent.Lifecycle do
  @moduledoc """
  Orchestrates the full agent lifecycle: create, restore, start, stop, destroy.

  This is the primary API for agent management. It coordinates identity,
  security, memory, and execution into a single flow — the trust-arbor
  equivalent of old arbor's `Arbor.Seed.new("id", template: CodeCompanion)`.

  ## Examples

      # From template
      {:ok, profile} = Lifecycle.create("scout-1", template: Arbor.Agent.Templates.Scout)

      # From options (inline character)
      {:ok, profile} = Lifecycle.create("custom-agent",
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

  alias Arbor.Agent.{Character, Executor, Profile}
  alias Arbor.Contracts.Memory.Goal

  require Logger

  @agents_dir ".arbor/agents"

  @doc """
  Create a new agent from a template or options.

  ## Steps

  1. Resolve template → character + security opts
  2. Generate cryptographic identity
  3. Register identity (public key only)
  4. Create keychain
  5. Grant initial capabilities
  6. Initialize memory
  7. Set initial goals
  8. Build and persist profile
  9. Emit creation signal
  """
  @spec create(String.t(), keyword()) :: {:ok, Profile.t()} | {:error, term()}
  def create(agent_id, opts \\ []) do
    with {:ok, character, opts} <- resolve_template(opts),
         {:ok, identity} <- generate_identity(agent_id),
         :ok <- register_identity(identity),
         keychain <- create_keychain(identity),
         :ok <- grant_capabilities(agent_id, opts[:capabilities] || []),
         {:ok, _pid} <- init_memory(agent_id, opts[:memory_opts] || []),
         :ok <- set_initial_goals(agent_id, opts[:initial_goals] || []) do
      profile =
        build_profile(agent_id, identity, keychain, character, opts)

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
        executor_opts =
          Keyword.merge(opts,
            agent_id: agent_id,
            trust_tier: profile.trust_tier
          )

        case Executor.start(agent_id, executor_opts) do
          {:ok, pid} ->
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
    result = Executor.stop(agent_id)

    Arbor.Signals.emit(:agent, :stopped, %{
      agent_id: agent_id,
      reason: :normal
    })

    result
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

        {:ok, character, opts}
    end
  end

  defp generate_identity(agent_id) do
    Arbor.Security.generate_identity(name: agent_id)
  end

  defp register_identity(identity) do
    Arbor.Security.register_identity(identity)
  end

  defp create_keychain(identity) do
    Arbor.Security.new_keychain(identity.agent_id)
  end

  defp grant_capabilities(_agent_id, []), do: :ok

  defp grant_capabilities(agent_id, capabilities) do
    Enum.each(capabilities, fn cap ->
      resource = cap[:resource] || cap["resource"]

      Arbor.Security.grant(
        principal_id: agent_id,
        resource: resource,
        actions: [:read, :execute]
      )
    end)

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

  defp build_profile(agent_id, identity, keychain, character, opts) do
    %Profile{
      agent_id: agent_id,
      character: character,
      trust_tier: Keyword.get(opts, :trust_tier, :untrusted),
      template: Keyword.get(opts, :template),
      initial_goals: Keyword.get(opts, :initial_goals, []),
      initial_capabilities: Keyword.get(opts, :capabilities, []),
      identity: %{agent_id: identity.agent_id},
      keychain_ref: keychain.agent_id,
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: DateTime.utc_now(),
      version: 1
    }
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
