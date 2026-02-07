defmodule Arbor.Agent.CheckpointManager do
  @moduledoc """
  Unified checkpoint management for all agent types.

  Consolidates checkpoint logic that was previously scattered across:
  - `Agent.Server` (Jido agent checkpointing)
  - `ClaudeCheckpoint` (Seed-based checkpointing)
  - `AgentSeed.capture_seed_on_terminate` (context window serialization)

  ## Agent Types

  - `:seed` — Agents using `AgentSeed` mixin (full Seed capture/restore)
  - `:jido` — Agents using `Agent.Server` wrapping a Jido agent
  - `:unknown` — Fallback for unrecognized state shapes

  ## Usage

      # Save a checkpoint (auto-detects agent type)
      :ok = CheckpointManager.save_checkpoint(state)

      # Load a checkpoint
      {:ok, data} = CheckpointManager.load_checkpoint("agent-1")

      # Apply checkpoint data onto a fresh state
      state = CheckpointManager.apply_checkpoint(state, data)

      # Schedule periodic checkpoints
      ref = CheckpointManager.schedule_checkpoint()

  ## Configuration

  Application env under `:arbor_agent`:

  - `:checkpoint_store` — Storage backend (default: `Arbor.Checkpoint.Store.ETS`)
  - `:checkpoint_interval_ms` — Auto-checkpoint interval (default: 300_000)
  - `:checkpoint_enabled` — Enable checkpointing (default: true)
  - `:checkpoint_query_threshold` — Query count delta for seed agents (default: 5)
  """

  require Logger

  alias Arbor.Agent.Seed
  alias Arbor.Memory.ContextWindow

  # ============================================================================
  # Save
  # ============================================================================

  @doc """
  Save a checkpoint for the given agent state.

  Detects agent type from state shape and extracts appropriate data.

  ## Options

  - `:store` — Override the checkpoint store backend
  - `:async` — If true, wraps save in a `Task.start` (default: false)
  - `:reason` — Capture reason for seed agents (default: `:checkpoint`)
  """
  @spec save_checkpoint(map(), keyword()) :: :ok | {:error, term()}
  def save_checkpoint(state, opts \\ []) do
    if Keyword.get(opts, :async, false) do
      Task.start(fn -> do_save_checkpoint(state, opts) end)
      :ok
    else
      do_save_checkpoint(state, opts)
    end
  end

  @doc """
  Save a pre-captured Seed directly to the configured store.
  """
  @spec save_seed_checkpoint(Seed.t(), keyword()) :: :ok | {:error, term()}
  def save_seed_checkpoint(%Seed{} = seed, opts \\ []) do
    store = resolve_store(opts)
    data = Seed.to_map(seed)

    case safe_call(fn -> Arbor.Checkpoint.save(seed.agent_id, data, store) end) do
      :ok ->
        Logger.debug("Seed checkpoint saved for #{seed.agent_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Seed checkpoint save failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  # ============================================================================
  # Load / Restore
  # ============================================================================

  @doc """
  Load a checkpoint from the configured store.

  ## Options

  - `:store` — Override the checkpoint store backend
  - `:retries` — Number of retry attempts (default: 1)
  """
  @spec load_checkpoint(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_checkpoint(agent_id, opts \\ []) do
    store = resolve_store(opts)
    retries = Keyword.get(opts, :retries, 1)

    case safe_call(fn -> Arbor.Checkpoint.load(agent_id, store, retries: retries) end) do
      {:ok, data} when is_map(data) ->
        Logger.info("Checkpoint loaded for #{agent_id}")
        {:ok, data}

      {:error, :not_found} ->
        Logger.debug("No checkpoint found for #{agent_id}")
        {:error, :not_found}

      {:error, reason} = error ->
        Logger.warning("Checkpoint load failed: #{inspect(reason)}")
        error

      nil ->
        {:error, :checkpoint_unavailable}
    end
  end

  @doc """
  Apply checkpoint data onto a fresh agent state.

  Detects agent type and applies the appropriate restoration logic.
  """
  @spec apply_checkpoint(map(), map()) :: map()
  def apply_checkpoint(state, checkpoint_data) do
    case agent_type(state) do
      :seed -> apply_seed_checkpoint(state, checkpoint_data)
      :jido -> apply_jido_checkpoint(state, checkpoint_data)
      :unknown -> state
    end
  end

  # ============================================================================
  # Scheduling
  # ============================================================================

  @doc """
  Schedule a `:checkpoint` message to `self()` after the configured interval.

  ## Options

  - `:interval_ms` — Override interval (default: from application config)
  """
  @spec schedule_checkpoint(keyword()) :: reference()
  def schedule_checkpoint(opts \\ []) do
    interval = Keyword.get(opts, :interval_ms) || checkpoint_config(:checkpoint_interval_ms)
    Process.send_after(self(), :checkpoint, interval)
  end

  @doc """
  Cancel a scheduled checkpoint timer.
  """
  @spec cancel_checkpoint(reference() | nil) :: :ok
  def cancel_checkpoint(nil), do: :ok

  def cancel_checkpoint(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  # ============================================================================
  # Threshold
  # ============================================================================

  @doc """
  Check if enough state has changed to warrant a checkpoint.

  For seed agents: returns true when query_count has increased by at
  least `checkpoint_query_threshold` since the last checkpoint.
  For jido agents: always true (timer-based).
  """
  @spec should_checkpoint?(map()) :: boolean()
  def should_checkpoint?(state) do
    case agent_type(state) do
      :seed ->
        last_count = Map.get(state, :last_checkpoint_query_count, 0)
        current_count = Map.get(state, :query_count, 0)
        threshold = checkpoint_config(:checkpoint_query_threshold)
        current_count - last_count >= threshold

      :jido ->
        true

      :unknown ->
        true
    end
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Get merged checkpoint configuration.

  Per-agent opts override application config, which has sensible defaults.
  """
  @spec config(keyword()) :: map()
  def config(opts \\ []) do
    %{
      store: resolve_store(opts),
      interval_ms: Keyword.get(opts, :interval_ms) || checkpoint_config(:checkpoint_interval_ms),
      enabled: Keyword.get(opts, :enabled) || checkpoint_config(:checkpoint_enabled),
      query_threshold:
        Keyword.get(opts, :query_threshold) || checkpoint_config(:checkpoint_query_threshold)
    }
  end

  # ============================================================================
  # Private — Save Implementation
  # ============================================================================

  defp do_save_checkpoint(state, opts) do
    case agent_type(state) do
      :seed -> save_seed_state(state, opts)
      :jido -> save_jido_state(state, opts)
      :unknown -> :ok
    end
  end

  defp save_seed_state(state, opts) do
    agent_id = state[:id] || state[:agent_id]
    store = resolve_store(opts)

    checkpoint_data = extract_seed_state(state, opts)

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

  defp save_jido_state(%{checkpoint_storage: nil}, _opts), do: :ok

  defp save_jido_state(state, opts) do
    store = Keyword.get(opts, :store) || state.checkpoint_storage
    data = extract_jido_state(state)

    case Arbor.Checkpoint.save(state.agent_id, data, store) do
      :ok ->
        Logger.debug("Checkpoint saved for agent #{state.agent_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to save checkpoint for #{state.agent_id}: #{inspect(reason)}")
        error
    end
  end

  # ============================================================================
  # Private — State Extraction
  # ============================================================================

  defp extract_seed_state(state, opts) do
    agent_id = state[:id] || state[:agent_id]
    reason = Keyword.get(opts, :reason, :checkpoint)

    context_window_map =
      if state[:context_window] do
        safe_call(fn -> serialize_context_window(state.context_window) end)
      end

    capture_opts = [
      reason: reason,
      name: state[:name],
      context_window: context_window_map,
      metadata: %{
        query_count: state[:query_count] || 0,
        heartbeat_count: state[:heartbeat_count] || 0,
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

  defp extract_jido_state(state) do
    %{
      agent_id: state.agent_id,
      agent_module: state.agent_module,
      jido_state: get_jido_agent_state(state.jido_agent),
      metadata: state.metadata,
      extracted_at: System.system_time(:millisecond)
    }
  end

  defp get_jido_agent_state(agent) do
    Map.get(agent, :state, %{})
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

  # ============================================================================
  # Private — Apply Checkpoint
  # ============================================================================

  defp apply_seed_checkpoint(state, checkpoint_data) do
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

  defp apply_jido_checkpoint(state, checkpoint_data) do
    jido_state = Map.get(checkpoint_data, :jido_state, %{})
    agent_module = state.agent_module

    Code.ensure_loaded(agent_module)
    opts = %{id: state.agent_id, state: jido_state}

    case safe_call(fn -> agent_module.new(opts) end) do
      nil ->
        Logger.warning("Failed to restore agent from checkpoint")
        state

      restored_agent ->
        %{
          state
          | jido_agent: restored_agent,
            metadata: Map.put(state.metadata, :restored_at, System.system_time(:millisecond))
        }
    end
  end

  # ============================================================================
  # Private — Context Window
  # ============================================================================

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

  # ============================================================================
  # Private — Agent Type Detection
  # ============================================================================

  defp agent_type(state) do
    cond do
      # Seed-based: has AgentSeed fields (memory_initialized, context_window)
      Map.has_key?(state, :memory_initialized) -> :seed
      # Jido-based: has jido_agent and agent_module
      Map.has_key?(state, :jido_agent) -> :jido
      # Fallback
      true -> :unknown
    end
  end

  # ============================================================================
  # Private — Metadata Helpers
  # ============================================================================

  # Get a value from metadata supporting both string and atom keys.
  # Uses explicit nil checks to handle false values correctly.
  defp meta_get(meta, atom_key, default \\ nil) do
    string_key = Atom.to_string(atom_key)

    case Map.get(meta, atom_key) do
      nil ->
        case Map.get(meta, string_key) do
          nil -> default
          val -> val
        end

      val ->
        val
    end
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

  # ============================================================================
  # Private — Config & Safety
  # ============================================================================

  defp resolve_store(opts) do
    Keyword.get(opts, :store) ||
      Application.get_env(:arbor_agent, :checkpoint_store, Arbor.Checkpoint.Store.ETS)
  end

  defp checkpoint_config(:checkpoint_interval_ms) do
    Application.get_env(:arbor_agent, :checkpoint_interval_ms, 300_000)
  end

  defp checkpoint_config(:checkpoint_enabled) do
    Application.get_env(:arbor_agent, :checkpoint_enabled, true)
  end

  defp checkpoint_config(:checkpoint_query_threshold) do
    Application.get_env(:arbor_agent, :checkpoint_query_threshold, 5)
  end

  defp safe_call(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("CheckpointManager safe_call rescued: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("CheckpointManager safe_call caught exit: #{inspect(reason)}")
      nil
  end
end
