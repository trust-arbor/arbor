defmodule Arbor.AI.SessionRegistry do
  @moduledoc """
  Tracks active LLM sessions for multi-turn conversations.

  When a caller needs to maintain context across multiple LLM calls (e.g., a
  consensus council deliberation), they provide a `session_context` identifier.
  The registry tracks which session_id maps to which context for each provider.

  ## Usage

      # First call - creates new session
      {:ok, response} = Arbor.AI.generate_text("Start deliberation",
        session_context: "deliberation_123",
        provider: :anthropic
      )
      # Registry now has: {:anthropic, "deliberation_123"} -> session_id from response

      # Subsequent calls - automatically resumes session
      {:ok, response} = Arbor.AI.generate_text("Continue reasoning",
        session_context: "deliberation_123",
        provider: :anthropic
      )
      # Uses stored session_id automatically

      # Clean up when done
      Arbor.AI.SessionRegistry.clear_context("deliberation_123")

  ## Session Info

  Each session stores:
  - `session_id` - The provider's session identifier
  - `provider` - Which provider owns this session
  - `created_at` - When the session started
  - `last_used_at` - Last activity timestamp
  - `turn_count` - Number of turns in this session
  """

  use GenServer
  require Logger

  @table :arbor_ai_sessions
  # Sessions expire after 1 hour of inactivity
  @default_ttl_ms 3_600_000

  @type session_info :: %{
          session_id: String.t(),
          provider: atom(),
          created_at: DateTime.t(),
          last_used_at: DateTime.t(),
          turn_count: non_neg_integer()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a session for a provider and context.

  Returns `{:ok, session_info}` if found, `:not_found` otherwise.
  """
  @spec lookup(atom(), String.t()) :: {:ok, session_info()} | :not_found
  def lookup(provider, context_key) do
    ensure_started()

    case :ets.lookup(@table, {provider, context_key}) do
      [{_key, info}] ->
        # Check if expired
        if expired?(info) do
          delete(provider, context_key)
          :not_found
        else
          {:ok, info}
        end

      [] ->
        :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Get just the session_id for a provider and context.

  Convenience function that returns `nil` if not found.
  """
  @spec get_session_id(atom(), String.t()) :: String.t() | nil
  def get_session_id(provider, context_key) do
    case lookup(provider, context_key) do
      {:ok, info} -> info.session_id
      :not_found -> nil
    end
  end

  @doc """
  Store or update a session for a provider and context.
  """
  @spec store(atom(), String.t(), String.t()) :: :ok
  def store(provider, context_key, session_id) do
    ensure_started()
    GenServer.cast(__MODULE__, {:store, provider, context_key, session_id})
  end

  @doc """
  Update the last_used_at and increment turn_count for an existing session.
  """
  @spec touch(atom(), String.t()) :: :ok
  def touch(provider, context_key) do
    ensure_started()
    GenServer.cast(__MODULE__, {:touch, provider, context_key})
  end

  @doc """
  Delete a specific session.
  """
  @spec delete(atom(), String.t()) :: :ok
  def delete(provider, context_key) do
    ensure_started()
    GenServer.cast(__MODULE__, {:delete, provider, context_key})
  end

  @doc """
  Clear all sessions for a context (across all providers).

  Use this when a deliberation or conversation is complete.
  """
  @spec clear_context(String.t()) :: :ok
  def clear_context(context_key) do
    ensure_started()
    GenServer.cast(__MODULE__, {:clear_context, context_key})
  end

  @doc """
  List all active sessions.
  """
  @spec list_sessions() :: [{{atom(), String.t()}, session_info()}]
  def list_sessions do
    ensure_started()

    try do
      :ets.tab2list(@table)
      |> Enum.reject(fn {_key, info} -> expired?(info) end)
    rescue
      ArgumentError -> []
    end
  end

  @doc """
  Get session statistics.
  """
  @spec stats() :: map()
  def stats do
    sessions = list_sessions()

    by_provider =
      sessions
      |> Enum.group_by(fn {{provider, _}, _} -> provider end)
      |> Enum.map(fn {provider, items} -> {provider, length(items)} end)
      |> Map.new()

    %{
      total_sessions: length(sessions),
      by_provider: by_provider,
      ttl_ms: ttl_ms()
    }
  end

  @doc """
  Get the session TTL in milliseconds.
  """
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    Application.get_env(:arbor_ai, :session_ttl_ms, @default_ttl_ms)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("SessionRegistry starting")
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:store, provider, context_key, session_id}, state) do
    now = DateTime.utc_now()

    info = %{
      session_id: session_id,
      provider: provider,
      created_at: now,
      last_used_at: now,
      turn_count: 1
    }

    :ets.insert(@table, {{provider, context_key}, info})

    Logger.debug("Session stored",
      provider: provider,
      context: context_key,
      session_id: truncate(session_id)
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:touch, provider, context_key}, state) do
    case :ets.lookup(@table, {provider, context_key}) do
      [{key, info}] ->
        updated = %{
          info
          | last_used_at: DateTime.utc_now(),
            turn_count: info.turn_count + 1
        }

        :ets.insert(@table, {key, updated})

      [] ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:delete, provider, context_key}, state) do
    :ets.delete(@table, {provider, context_key})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_context, context_key}, state) do
    # Find and delete all sessions with this context
    pattern = {{:_, context_key}, :_}

    :ets.match_delete(@table, pattern)

    Logger.debug("Cleared sessions for context", context: context_key)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Remove expired sessions
    now = DateTime.utc_now()
    ttl = ttl_ms()

    expired =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_key, info} ->
        age_ms = DateTime.diff(now, info.last_used_at, :millisecond)
        age_ms > ttl
      end)

    expired_count =
      Enum.reduce(expired, 0, fn {key, _info}, count ->
        :ets.delete(@table, key)
        count + 1
      end)

    if expired_count > 0 do
      Logger.debug("Cleaned up expired sessions", count: expired_count)
    end

    schedule_cleanup()
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _} = start_link()
      _pid -> :ok
    end
  end

  defp expired?(info) do
    age_ms = DateTime.diff(DateTime.utc_now(), info.last_used_at, :millisecond)
    age_ms > ttl_ms()
  end

  defp schedule_cleanup do
    # Cleanup every 5 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(5))
  end

  defp truncate(str) when is_binary(str) do
    if String.length(str) > 12 do
      String.slice(str, 0, 12) <> "..."
    else
      str
    end
  end

  defp truncate(nil), do: "nil"
end
