defmodule Arbor.Agent.Manager do
  @moduledoc """
  Stateless coordination for agent lifecycle.

  Wraps `Arbor.Agent.Supervisor` and `Arbor.Agent.Registry` with
  signal emissions so all consumers (dashboard, CLI, gateway) stay in sync.

  No GenServer — just function calls. Nothing to crash.

  ## Signal Events

  All lifecycle events are emitted on the `:agent` signal category:

  - `{:agent, :started}` — agent started with `%{agent_id, model_config}`
  - `{:agent, :stopped}` — agent stopped with `%{agent_id}`
  - `{:agent, :chat_message}` — external chat message with `%{role, content, sender}`

  Consumers subscribe via `Arbor.Signals.subscribe("agent.*", handler)` or
  `Arbor.Web.SignalLive.subscribe_raw(socket, "agent.*")`.
  """

  alias Arbor.Agent.{APIAgent, Claude, GroupChat, Lifecycle, Profile}

  require Logger

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start an agent under the Arbor.Agent.Supervisor.

  Creates a cryptographic identity via `Lifecycle.create/2`, then starts
  the agent process. The agent_id is derived from the Ed25519 public key.

  Returns `{:ok, agent_id, pid}` or `{:error, reason}`.
  """
  @spec start_agent(map(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_agent(model_config, opts \\ []) do
    display_name = Keyword.get(opts, :display_name, default_display_name(model_config))
    template = Keyword.get(opts, :template) || resolve_template(model_config)
    lifecycle_opts = [template: template] ++ Keyword.take(opts, [:capabilities, :initial_goals])

    with {:ok, profile} <- Lifecycle.create(display_name, lifecycle_opts) do
      # Persist model config for resume
      updated_profile = put_in(profile.metadata[:last_model_config], model_config)
      profile_path = Path.join([".arbor", "agents", "#{profile.agent_id}.agent.json"])

      try do
        case Profile.to_json(updated_profile) do
          {:ok, json} -> File.write(profile_path, json)
          _ -> :ok
        end
      rescue
        _ -> :ok
      end

      agent_id = updated_profile.agent_id
      {module, start_opts} = build_start_opts(agent_id, display_name, model_config)

      case Arbor.Agent.Supervisor.start_child(
             agent_id: agent_id,
             module: module,
             start_opts: start_opts,
             metadata: %{
               model_config: model_config,
               backend: model_config[:backend] || model_config.backend,
               display_name: display_name,
               started_at: System.system_time(:millisecond)
             }
           ) do
        {:ok, pid} ->
          # Start lifecycle (executor, session, host) for the new agent
          try do
            Lifecycle.start(
              agent_id,
              Keyword.merge(opts,
                model: model_config[:id] || model_config["id"],
                provider: model_config[:provider] || model_config["provider"]
              )
            )
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end

          safe_emit(:started, %{agent_id: agent_id, pid: pid, model_config: model_config})
          {:ok, agent_id, pid}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Resume a previously created agent from its persisted profile.

  Restores the agent's identity, capabilities, and last model configuration,
  then starts the agent process under supervision.

  Returns `{:ok, agent_id, pid}` or `{:error, reason}`.
  """
  @spec resume_agent(String.t(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def resume_agent(agent_id, opts \\ []) do
    with {:ok, profile} <- Lifecycle.restore(agent_id) do
      # Get model config from profile metadata or opts
      model_config =
        get_in(profile.metadata, [:last_model_config]) ||
          get_in(profile.metadata, ["last_model_config"]) ||
          Keyword.get(opts, :model_config, default_model_config())

      display_name = profile.display_name || profile.character.name || "Agent"
      {module, start_opts} = build_start_opts(agent_id, display_name, model_config)

      # Start the agent under supervision
      case Arbor.Agent.Supervisor.start_child(
             agent_id: agent_id,
             module: module,
             start_opts: start_opts,
             metadata: %{
               model_config: model_config,
               backend: model_config[:backend] || Map.get(model_config, "backend", :api),
               display_name: display_name,
               started_at: System.system_time(:millisecond),
               resumed: true
             }
           ) do
        {:ok, pid} ->
          # Also start the lifecycle (executor, session) if not already running
          try do
            Lifecycle.start(
              agent_id,
              Keyword.merge(opts,
                model: model_config[:id] || model_config["id"],
                provider: model_config[:provider] || model_config["provider"]
              )
            )
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          end

          safe_emit(:started, %{agent_id: agent_id, pid: pid, model_config: model_config})
          {:ok, agent_id, pid}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Start or resume a system agent with stable identity.

  Searches for an existing profile matching `display_name` and `template`.
  If found, resumes that agent. If not found, creates a new identity and starts fresh.

  This is the preferred way to start system agents (like DebugAgent) that need
  stable identity across restarts.

  The `model_config` map must include a `:module` key specifying the GenServer module.

  ## Options

  - `:template` — agent template module (required for identity matching)
  - `:display_name` — display name for the agent (default: from model_config)
  - All other options from `start_agent/2` and `resume_agent/2`

  ## Examples

      Manager.start_or_resume(DebugAgent, "debug-agent",
        template: Diagnostician,
        model_config: %{id: "haiku", provider: :anthropic, backend: :api}
      )
  """
  @spec start_or_resume(module(), String.t(), keyword()) ::
          {:ok, String.t(), pid()} | {:error, term()}
  def start_or_resume(module, display_name, opts \\ []) do
    template = Keyword.get(opts, :template)
    model_config = Keyword.get(opts, :model_config, default_model_config())
    model_config = Map.put(model_config, :module, module)

    case find_existing_profile(display_name, template) do
      {:ok, agent_id} ->
        Logger.info("[Manager] Resuming #{display_name} with identity #{agent_id}")
        resume_agent(agent_id, Keyword.put(opts, :model_config, model_config))

      :not_found ->
        Logger.info("[Manager] Creating new identity for #{display_name}")

        start_agent(
          model_config,
          Keyword.merge(opts, display_name: display_name)
        )
    end
  end

  @doc """
  Stop a running agent by ID.

  Stops the lifecycle (session, executor, host) first, then the supervised process.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    # Stop lifecycle components (session, executor, host) first
    try do
      Lifecycle.stop(agent_id)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    # Then stop the supervised agent process
    Arbor.Agent.Supervisor.stop_agent_by_id(agent_id)

    safe_emit(:stopped, %{agent_id: agent_id})
    :ok
  end

  @doc """
  Find a running agent by ID.

  Returns `{:ok, pid, metadata}` or `:not_found`.
  """
  @spec find_agent(String.t()) :: {:ok, pid(), map()} | :not_found
  def find_agent(agent_id) do
    case Arbor.Agent.Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.pid, entry.metadata}
      {:error, :not_found} -> :not_found
    end
  end

  @doc """
  Find the first running agent (any ID).

  Returns `{:ok, agent_id, pid, metadata}` or `:not_found`.
  """
  @spec find_first_agent() :: {:ok, String.t(), pid(), map()} | :not_found
  def find_first_agent do
    case Arbor.Agent.Registry.list() do
      {:ok, [entry | _]} -> {:ok, entry.agent_id, entry.pid, entry.metadata}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  @doc """
  Send a message to the agent and emit the conversation as signals.

  This allows external callers (e.g., Claude Code via Tidewave) to have
  conversations with the agent that are visible to any signal subscriber.

  The `sender` label identifies who sent the message (e.g., "Opus", "Hysun").
  If no `:agent_id` is provided, uses the first running agent.
  """
  @spec chat(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(input, sender \\ "Opus", opts \\ []) do
    agent_result =
      case Keyword.get(opts, :agent_id) do
        nil ->
          find_first_agent()

        id ->
          case find_agent(id) do
            {:ok, pid, meta} -> {:ok, id, pid, meta}
            :not_found -> :not_found
          end
      end

    case agent_result do
      {:ok, _agent_id, pid, metadata} ->
        safe_emit(:chat_message, %{role: :user, content: input, sender: sender})
        dispatch_query(pid, metadata, input, opts)

      :not_found ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Create a group chat with the given participants.

  ## Participant Specs

  Each participant spec is a map with:
  - `:id` - Unique identifier (agent_id for agents, user_id for humans)
  - `:name` - Display name
  - `:type` - `:agent` or `:human`

  For agent participants, automatically looks up the host_pid via `Lifecycle.get_host/1`.
  """
  @spec create_group(String.t(), [map()]) :: {:ok, pid()} | {:error, term()}
  def create_group(name, participant_specs) do
    # Build participant structs with host_pid lookup for agents
    participants =
      Enum.map(participant_specs, fn spec ->
        host_pid =
          if spec.type == :agent do
            case Lifecycle.get_host(spec.id) do
              {:ok, pid} -> pid
              _ -> nil
            end
          else
            nil
          end

        %{
          id: spec.id,
          name: spec.name,
          type: spec.type,
          host_pid: host_pid
        }
      end)

    GroupChat.create(name, participants: participants)
  end

  @doc """
  Send a message to a group chat.

  The group parameter can be a pid or a via tuple.
  """
  @spec group_send(GenServer.server(), String.t(), String.t(), :agent | :human, String.t()) ::
          :ok
  def group_send(group, sender_id, sender_name, sender_type, content) do
    GroupChat.send_message(group, sender_id, sender_name, sender_type, content)
  end

  @doc """
  List all active group chats.

  Returns a list of `{group_id, pid}` tuples by querying the ExecutorRegistry
  for all entries with `{:group, group_id}` keys.
  """
  @spec list_groups() :: [{String.t(), pid()}]
  def list_groups do
    Registry.select(Arbor.Agent.ExecutorRegistry, [
      {
        {{:group, :"$1"}, :"$2", :_},
        [],
        [{{:"$1", :"$2"}}]
      }
    ])
  rescue
    _ -> []
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp default_model_config do
    %{id: "haiku", label: "Haiku (fast)", provider: :anthropic, backend: :cli}
  end

  defp build_start_opts(agent_id, display_name, %{module: module} = config) do
    extra_opts = Map.get(config, :start_opts, [])

    {module,
     Keyword.merge(
       [id: agent_id, agent_id: agent_id, display_name: display_name, model_config: config],
       extra_opts
     )}
  end

  defp build_start_opts(agent_id, display_name, %{backend: :cli} = config) do
    model_atom =
      case config.id do
        id when is_atom(id) -> id
        id when is_binary(id) -> String.to_existing_atom(id)
      end

    {Claude,
     [id: agent_id, display_name: display_name, model: model_atom, capture_thinking: true]}
  end

  defp build_start_opts(agent_id, display_name, %{backend: :api} = config) do
    {APIAgent,
     [
       id: agent_id,
       display_name: display_name,
       model: config.id,
       provider: config.provider,
       model_id: config.id
     ]}
  end

  defp default_display_name(%{name: name}) when is_binary(name), do: name
  defp default_display_name(%{id: id}) when is_binary(id), do: id
  defp default_display_name(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp default_display_name(_), do: "Agent"

  defp resolve_template(%{backend: :cli}), do: Arbor.Agent.Templates.ClaudeCode
  defp resolve_template(_), do: Arbor.Agent.Templates.ClaudeCode

  defp find_existing_profile(display_name, template) do
    case Lifecycle.list_agents() do
      profiles when is_list(profiles) ->
        match =
          Enum.find(profiles, fn p ->
            name_matches? =
              p.display_name == display_name or
                (p.character && p.character.name == display_name)

            template_matches? = template == nil or p.template == template
            name_matches? and template_matches?
          end)

        if match, do: {:ok, match.agent_id}, else: :not_found

      _ ->
        :not_found
    end
  end

  defp dispatch_query(pid, metadata, input, opts) do
    backend = metadata[:backend] || metadata[:model_config][:backend]

    result = query_backend(backend, pid, input, opts)
    handle_query_result(result)
  end

  defp query_backend(:cli, pid, input, opts) do
    Claude.query(pid, input,
      timeout: Keyword.get(opts, :timeout, :infinity),
      permission_mode: :bypass
    )
  end

  defp query_backend(:api, pid, input, _opts), do: APIAgent.query(pid, input)
  defp query_backend(_, _pid, _input, _opts), do: {:error, :unknown_backend}

  defp handle_query_result({:ok, response}) do
    text = response[:text] || response.text || ""
    safe_emit(:chat_message, %{role: :assistant, content: text, sender: "Agent"})
    {:ok, text}
  end

  defp handle_query_result({:error, _} = error), do: error

  defp safe_emit(type, data) do
    Arbor.Signals.emit(:agent, type, data)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
