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

  @default_agent_id "chat-primary"

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start an agent under the Arbor.Agent.Supervisor.

  Builds module-specific start opts from the model config, starts via
  `Supervisor.start_child/1`, and broadcasts the lifecycle event.

  Returns `{:ok, agent_id, pid}` or `{:error, reason}`.
  """
  @spec start_agent(map(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  def start_agent(model_config, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)
    {module, start_opts} = build_start_opts(agent_id, model_config)

    case Arbor.Agent.Supervisor.start_child(
           agent_id: agent_id,
           module: module,
           start_opts: start_opts,
           metadata: %{
             model_config: model_config,
             backend: model_config[:backend] || model_config.backend,
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

  @doc """
  Stop a running agent by ID.

  Uses `Supervisor.stop_agent_by_id/1` and broadcasts the event.
  """
  @spec stop_agent(String.t()) :: :ok | {:error, :not_found}
  def stop_agent(agent_id \\ @default_agent_id) do
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
  def find_agent(agent_id \\ @default_agent_id) do
    case Arbor.Agent.Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.pid, entry.metadata}
      {:error, :not_found} -> :not_found
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

  @doc "The deterministic default agent ID."
  @spec default_agent_id() :: String.t()
  def default_agent_id, do: @default_agent_id

  @doc """
  Send a message to the agent and broadcast the conversation to the chat UI.

  This allows external callers (e.g., Claude Code via Tidewave) to have
  conversations with the agent that are visible in the ChatLive UI.

  The `sender` label identifies who sent the message (e.g., "Opus", "Hysun").
  """
  @spec chat(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(input, sender \\ "Opus", opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)

    case find_agent(agent_id) do
      {:ok, pid, metadata} ->
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

  # ── Private ─────────────────────────────────────────────────────────

  defp build_start_opts(agent_id, %{backend: :cli} = config) do
    model_atom =
      case config.id do
        id when is_atom(id) -> id
        id when is_binary(id) -> String.to_existing_atom(id)
      end

    {Claude, [id: agent_id, model: model_atom, capture_thinking: true]}
  end

  defp build_start_opts(agent_id, %{backend: :api} = config) do
    {APIAgent,
     [
       id: agent_id,
       model: config.id,
       provider: config.provider,
       model_id: config.id
     ]}
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end
end
