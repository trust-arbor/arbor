defmodule Arbor.Agent.ClaudeCheckpoint do
  @moduledoc """
  State checkpoint/restore for the Claude agent.

  Delegates state capture to `Arbor.Agent.Seed` for comprehensive snapshots
  that include all memory subsystems. Agent-specific timing state (timestamps,
  query count) is stored in the seed's metadata field.

  Uses `Arbor.Checkpoint` with the ETS store by default; can be
  configured with any `Arbor.Checkpoint.Store` implementation.

  ## Auto-checkpointing

  When enabled, sends `:checkpoint` messages at configurable intervals
  (default: 5 minutes) to trigger periodic saves. The agent handles
  these in `handle_info`.

  ## Storage

  Checkpoints are stored via the configured store backend. The default
  ETS store keeps data in-memory (lost on restart). For persistence
  across restarts, configure a file-based or DETS store.
  """

  require Logger

  alias Arbor.Agent.Seed
  alias Arbor.Memory.ContextWindow

  @doc """
  Save the agent's current state as a checkpoint.

  Captures a full Seed snapshot via `Seed.capture/2` and persists
  via `Arbor.Checkpoint.save/3`.
  """
  @spec save_state(map()) :: :ok | {:error, term()}
  def save_state(state) do
    agent_id = state[:id] || state[:agent_id]
    store = checkpoint_store()

    checkpoint_data = extract_state(state)

    case safe_call(fn -> Arbor.Checkpoint.save(agent_id, checkpoint_data, store) end) do
      :ok ->
        Logger.debug("Checkpoint saved for #{agent_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Checkpoint save failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  @doc """
  Attempt to restore agent state from a checkpoint.

  Returns `{:ok, checkpoint_data}` if found, `{:error, :not_found}` if
  no checkpoint exists, or `{:error, reason}` on failure.
  """
  @spec restore_state(String.t()) :: {:ok, map()} | {:error, term()}
  def restore_state(agent_id) do
    store = checkpoint_store()

    case safe_call(fn -> Arbor.Checkpoint.load(agent_id, store, retries: 1) end) do
      {:ok, data} when is_map(data) ->
        Logger.info("Checkpoint restored for #{agent_id}")
        {:ok, data}

      {:error, :not_found} ->
        Logger.debug("No checkpoint found for #{agent_id}")
        {:error, :not_found}

      {:error, reason} = error ->
        Logger.warning("Checkpoint restore failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  @doc """
  Apply restored checkpoint data onto a fresh agent state.

  Reconstructs a Seed from the checkpoint data, restores subsystem state
  (working memory, knowledge graph, preferences, goals) via `Seed.restore/2`,
  and merges timing fields back into the agent state.
  """
  @spec apply_checkpoint(map(), map()) :: map()
  def apply_checkpoint(state, checkpoint_data) do
    agent_id = state[:id] || state[:agent_id]

    case Seed.from_map(checkpoint_data) do
      {:ok, seed} ->
        # Restore subsystem state (WM, KG, Preferences, Goals)
        Seed.restore(seed, emit_signals: false)

        # Extract timing fields from seed metadata
        meta = seed.metadata || %{}

        state =
          Map.merge(state, %{
            last_user_message_at: parse_datetime(meta_get(meta, :last_user_message_at)),
            last_assistant_output_at:
              parse_datetime(meta_get(meta, :last_assistant_output_at)),
            responded_to_last_user_message:
              meta_get(meta, :responded_to_last_user_message, true),
            query_count: meta_get(meta, :query_count, 0)
          })

        # Restore context window if present in seed
        state = maybe_restore_context_window(state, seed.context_window)

        Logger.info("Checkpoint applied for #{agent_id}",
          seed_id: seed.id,
          goals: length(seed.goals),
          query_count: state.query_count
        )

        state

      {:error, reason} ->
        Logger.warning("Failed to reconstruct Seed from checkpoint: #{inspect(reason)}")
        state
    end
  end

  @doc """
  Check if enough state has changed to warrant a checkpoint.

  Returns true if the query count has increased by at least
  `checkpoint_query_threshold` since the last checkpoint.
  """
  @spec auto_checkpoint?(map()) :: boolean()
  def auto_checkpoint?(state) do
    last_count = Map.get(state, :last_checkpoint_query_count, 0)
    current_count = Map.get(state, :query_count, 0)
    threshold = config(:checkpoint_query_threshold, 5)

    current_count - last_count >= threshold
  end

  @doc """
  Schedule the next auto-checkpoint message.
  """
  @spec schedule_checkpoint(pos_integer()) :: reference()
  def schedule_checkpoint(interval_ms \\ nil) do
    interval = interval_ms || config(:checkpoint_interval_ms, 300_000)
    Process.send_after(self(), :checkpoint, interval)
  end

  # -- Private: State Extraction (delegates to Seed) --

  defp extract_state(state) do
    agent_id = state[:id] || state[:agent_id]

    context_window_map =
      if state[:context_window] do
        safe_call(fn -> serialize_context_window(state.context_window) end)
      end

    capture_opts = [
      reason: :checkpoint,
      name: state[:name],
      context_window: context_window_map,
      metadata: %{
        query_count: state[:query_count] || 0,
        last_user_message_at: format_datetime(state[:last_user_message_at]),
        last_assistant_output_at: format_datetime(state[:last_assistant_output_at]),
        responded_to_last_user_message: state[:responded_to_last_user_message]
      }
    ]

    case Seed.capture(agent_id, capture_opts) do
      {:ok, seed} -> Seed.to_map(seed)
      {:error, _} -> fallback_extract_state(state, agent_id)
    end
  end

  # Fallback if Seed capture fails — minimal checkpoint with timing only
  defp fallback_extract_state(state, agent_id) do
    %{
      "agent_id" => agent_id,
      "metadata" => %{
        "query_count" => state[:query_count] || 0,
        "last_user_message_at" => format_datetime(state[:last_user_message_at]),
        "last_assistant_output_at" => format_datetime(state[:last_assistant_output_at]),
        "responded_to_last_user_message" => state[:responded_to_last_user_message]
      },
      "seed_version" => 1,
      "version" => 0
    }
  end

  # -- Private: Context Window --

  defp serialize_context_window(window) do
    if Code.ensure_loaded?(ContextWindow) and
         function_exported?(ContextWindow, :serialize, 1) do
      ContextWindow.serialize(window)
    else
      window
    end
  rescue
    _ -> nil
  end

  defp maybe_restore_context_window(state, nil), do: state

  defp maybe_restore_context_window(state, cw_map) when map_size(cw_map) == 0, do: state

  defp maybe_restore_context_window(state, cw_map) do
    if Code.ensure_loaded?(ContextWindow) and
         function_exported?(ContextWindow, :deserialize, 1) do
      restored = ContextWindow.deserialize(cw_map)
      %{state | context_window: restored}
    else
      state
    end
  rescue
    _ -> state
  end

  # -- Private: Metadata Helpers --

  # Get a value from metadata supporting both string and atom keys
  defp meta_get(meta, atom_key, default \\ nil) do
    string_key = Atom.to_string(atom_key)
    meta[atom_key] || meta[string_key] || default
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(s) when is_binary(s), do: s

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # -- Private: Config & Safety --

  defp checkpoint_store do
    Application.get_env(:arbor_agent, :checkpoint_store, Arbor.Checkpoint.Store.ETS)
  end

  defp config(key, default) do
    Application.get_env(:arbor_agent, key, default)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("ClaudeCheckpoint safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("ClaudeCheckpoint safe_call caught exit: #{inspect(reason)}")
      nil
  end
end
