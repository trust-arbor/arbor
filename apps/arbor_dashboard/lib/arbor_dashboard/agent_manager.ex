defmodule Arbor.Dashboard.AgentManager do
  @moduledoc """
  Stateless coordination for agent lifecycle in the dashboard.

  Wraps `Arbor.Agent.Supervisor` and `Arbor.Agent.Registry` with
  PubSub broadcasts so multiple LiveView instances stay in sync.

  No GenServer — just function calls. Nothing to crash.
  """

  alias Arbor.Agent.APIAgent
  alias Arbor.Agent.Claude

  require Logger

  @pubsub Arbor.Dashboard.PubSub
  @topic "dashboard:agent"

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
    template = resolve_template(model_config)
    lifecycle_opts = [template: template] ++ Keyword.take(opts, [:capabilities, :initial_goals])

    with {:ok, profile} <- Arbor.Agent.Lifecycle.create(display_name, lifecycle_opts) do
      agent_id = profile.agent_id
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
          broadcast({:agent_started, agent_id, pid, model_config})
          {:ok, agent_id, pid}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Stop a running agent by ID.

  Uses `Supervisor.stop_agent_by_id/1` and broadcasts the event.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id) do
    result = Arbor.Agent.Supervisor.stop_agent_by_id(agent_id)

    case result do
      :ok -> broadcast({:agent_stopped, agent_id})
      _ -> :ok
    end

    result
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
  Subscribe the calling process to agent lifecycle PubSub events.

  Events:
  - `{:agent_started, agent_id, pid, model_config}`
  - `{:agent_stopped, agent_id}`
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Send a message to the agent and broadcast the conversation to the chat UI.

  This allows external callers (e.g., Claude Code via Tidewave) to have
  conversations with the agent that are visible in the ChatLive UI.

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
        broadcast({:chat_message, %{role: :user, content: input, sender: sender}})
        dispatch_query(pid, metadata, input, opts)

      :not_found ->
        {:error, :agent_not_found}
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
    broadcast({:chat_message, %{role: :assistant, content: text, sender: "Agent"}})
    {:ok, text}
  end

  defp handle_query_result({:error, _} = error), do: error

  @doc """
  Create a group chat with the given participants.

  ## Participant Specs

  Each participant spec is a map with:
  - `:id` - Unique identifier (agent_id for agents, user_id for humans)
  - `:name` - Display name
  - `:type` - `:agent` or `:human`

  For agent participants, automatically looks up the host_pid via `Lifecycle.get_host/1`.

  ## Example

      participant_specs = [
        %{id: "agent_abc123", name: "Alice", type: :agent},
        %{id: "agent_def456", name: "Bob", type: :agent},
        %{id: "hysun", name: "Hysun", type: :human}
      ]
      {:ok, group_pid} = AgentManager.create_group("brainstorm", participant_specs)
  """
  @spec create_group(String.t(), [map()]) :: {:ok, pid()} | {:error, term()}
  def create_group(name, participant_specs) do
    # Build participant structs with host_pid lookup for agents
    participants =
      Enum.map(participant_specs, fn spec ->
        host_pid =
          if spec.type == :agent do
            case Arbor.Agent.Lifecycle.get_host(spec.id) do
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

    Arbor.Agent.GroupChat.create(name, participants: participants)
  end

  @doc """
  Send a message to a group chat.

  The group parameter can be a pid or a via tuple.
  """
  @spec group_send(GenServer.server(), String.t(), String.t(), :agent | :human, String.t()) ::
          :ok
  def group_send(group, sender_id, sender_name, sender_type, content) do
    Arbor.Agent.GroupChat.send_message(group, sender_id, sender_name, sender_type, content)
  end

  @doc """
  List all active group chats.

  Returns a list of `{group_id, pid}` tuples by querying the ExecutorRegistry
  for all entries with `{:group, group_id}` keys.
  """
  @spec list_groups() :: [{String.t(), pid()}]
  def list_groups do
    # Query ExecutorRegistry for all {:group, group_id} entries
    # Match pattern: {{:group, group_id}, pid, _value}
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

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end
end
