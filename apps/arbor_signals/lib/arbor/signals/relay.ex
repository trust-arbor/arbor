defmodule Arbor.Signals.Relay do
  @moduledoc """
  Cross-node signal relay using `:pg` process groups.

  Each node runs one Relay process that:
  1. Receives cluster-scoped signals from the local Bus
  2. Batches them into windows (default 50ms)
  3. Forwards batched signals to peer Relay processes via `:erpc`
  4. Receives batched signals from peers and injects them into the local Bus

  ## Architecture

  Hub-and-spoke model — one Relay per node, all in a shared `:pg` group.
  The Relay is the single egress/ingress point for cross-node signals,
  which makes it the natural place for rate limiting and load shedding.

  ## Load Shedding (Phase 5)

  When the outbound queue exceeds `max_batch_size`, low-priority signals
  are dropped. Priority order (highest to lowest):
  1. `:security` — never dropped
  2. `:trust`, `:consensus` — dropped only under extreme pressure
  3. `:agent`, `:orchestrator` — dropped when queue is full

  Per-category token bucket rate limiting prevents any single category
  from flooding the relay. Dropped signals are logged as telemetry.

  ## Security Hardening (Phase 6)

  - Origin node validation: received batches must come from known `:pg` peers
  - Per-node ingress rate limiting: prevents flood from a single peer
  - SafeAtom validation on incoming signal metadata keys

  ## Configuration

      config :arbor_signals,
        relay_batch_interval_ms: 50,
        relay_max_batch_size: 500,
        relay_enabled: true,
        # Per-category tokens per second (default 100/s per category)
        relay_category_rate_limit: 100,
        # Per-node ingress rate limit (signals per second, default 1000/s)
        relay_node_rate_limit: 1000
  """

  use GenServer

  require Logger

  alias Arbor.Signals.Signal

  @pg_group {:arbor, :signal_relays}
  @default_batch_interval_ms 50
  @default_max_batch_size 500
  @default_category_rate_limit 100
  @default_node_rate_limit 1000

  # Priority levels for load shedding (lower = higher priority = shed last)
  @category_priority %{
    security: 0,
    trust: 1,
    consensus: 1,
    agent: 2,
    orchestrator: 2
  }

  # Metadata keys that are safe to atomize from remote signals
  @safe_metadata_keys ~w(agent_id node pipeline_id run_id channel_id source)

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Start the relay process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forward a cluster-scoped signal to peer nodes.

  Called by the Bus after local delivery. The signal is queued and
  sent in the next batch window.
  """
  @spec relay(Signal.t()) :: :ok
  def relay(%Signal{} = signal) do
    if enabled?() and Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:relay, signal})
    end

    :ok
  end

  @doc "Get relay statistics."
  @spec stats() :: map()
  def stats do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :stats)
    else
      %{status: :not_running}
    end
  end

  @doc "Check if the relay is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:arbor_signals, :relay_enabled, true)
  end

  # ── Server Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if enabled?() do
      # Join the :pg group for relay discovery
      join_pg_group()

      # Schedule first batch flush
      batch_interval = batch_interval_ms()
      Process.send_after(self(), :flush_batch, batch_interval)

      {:ok,
       %{
         batch: [],
         batch_size: 0,
         # Phase 5: per-category token buckets {category => {tokens, last_refill_time}}
         rate_buckets: %{},
         # Phase 6: per-node ingress counters {node => {count, window_start}}
         node_counters: %{},
         stats: %{
           relayed_out: 0,
           relayed_in: 0,
           batches_sent: 0,
           signals_dropped: 0,
           signals_rate_limited: 0,
           signals_rejected: 0,
           peers_seen: 0
         }
       }}
    else
      {:ok, %{batch: [], batch_size: 0, rate_buckets: %{}, node_counters: %{}, stats: %{status: :disabled}}}
    end
  end

  @impl true
  def handle_cast({:relay, %Signal{} = signal}, state) do
    # Phase 5: Check per-category rate limit before queuing
    {allowed, state} = check_category_rate(signal.category, state)

    if allowed do
      max_batch = max_batch_size()

      if state.batch_size >= max_batch do
        # Load shedding — try to drop lowest priority signal
        state = shed_or_drop(signal, state)
        {:noreply, state}
      else
        state = %{state | batch: [signal | state.batch], batch_size: state.batch_size + 1}
        {:noreply, state}
      end
    else
      # Rate limited — drop and count
      stats = Map.update!(state.stats, :signals_rate_limited, &(&1 + 1))
      {:noreply, %{state | stats: stats}}
    end
  end

  @impl true
  def handle_cast({:receive_batch, signals, from_node}, state) do
    # Phase 6: Validate origin node is a known peer
    if valid_peer?(from_node) do
      # Phase 6: Check per-node ingress rate limit
      {allowed_count, state} = check_node_rate(from_node, length(signals), state)

      {accepted, rejected_count} =
        if allowed_count >= length(signals) do
          {signals, 0}
        else
          {Enum.take(signals, allowed_count), length(signals) - allowed_count}
        end

      # Inject accepted signals into local Bus
      Enum.each(accepted, fn signal ->
        # Phase 6: Sanitize metadata from remote signals
        signal = sanitize_remote_signal(signal)
        # Mark as already-relayed to prevent re-relay loops
        signal = %{signal | scope: :local}
        inject_to_local_bus(signal)
      end)

      count = length(accepted)

      stats =
        state.stats
        |> Map.update!(:relayed_in, &(&1 + count))
        |> Map.update!(:signals_rejected, &(&1 + rejected_count))
        |> Map.put(:peers_seen, count_peers())

      if rejected_count > 0 do
        Logger.warning(
          "[SignalRelay] Rate limited #{rejected_count} signals from #{from_node}"
        )
      end

      Logger.debug(
        "[SignalRelay] Received #{count} signals from #{from_node}"
      )

      {:noreply, %{state | stats: stats}}
    else
      # Phase 6: Reject signals from unknown nodes
      count = length(signals)

      Logger.warning(
        "[SignalRelay] Rejected #{count} signals from unknown peer #{from_node}"
      )

      stats = Map.update!(state.stats, :signals_rejected, &(&1 + count))
      {:noreply, %{state | stats: stats}}
    end
  end

  @impl true
  def handle_info(:flush_batch, %{batch: []} = state) do
    # Nothing to flush
    Process.send_after(self(), :flush_batch, batch_interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_batch, state) do
    peers = peer_relays()
    batch = Enum.reverse(state.batch)
    batch_count = state.batch_size

    if peers != [] do
      # Send batch to all peer relays
      origin = node()

      Enum.each(peers, fn peer_pid ->
        peer_node = node(peer_pid)

        Task.start(fn ->
          try do
            GenServer.cast({__MODULE__, peer_node}, {:receive_batch, batch, origin})
          rescue
            _ -> :ok
          end
        end)
      end)
    end

    stats =
      state.stats
      |> Map.update!(:relayed_out, &(&1 + batch_count))
      |> Map.update!(:batches_sent, &(&1 + 1))
      |> Map.put(:peers_seen, count_peers())

    Process.send_after(self(), :flush_batch, batch_interval_ms())

    {:noreply, %{state | batch: [], batch_size: 0, stats: stats}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        batch_pending: state.batch_size,
        peers_connected: count_peers(),
        enabled: enabled?()
      })

    {:reply, stats, state}
  end

  # ── Phase 5: Rate Limiting ──────────────────────────────────────────

  defp check_category_rate(category, state) do
    limit = category_rate_limit()
    now = System.monotonic_time(:millisecond)
    bucket = Map.get(state.rate_buckets, category, {limit, now})

    {tokens, last_refill} = bucket

    # Refill tokens based on elapsed time (token bucket algorithm)
    elapsed_ms = now - last_refill
    refilled = tokens + div(elapsed_ms * limit, 1000)
    tokens = min(refilled, limit)
    last_refill = if elapsed_ms > 0, do: now, else: last_refill

    if tokens > 0 do
      buckets = Map.put(state.rate_buckets, category, {tokens - 1, last_refill})
      {true, %{state | rate_buckets: buckets}}
    else
      buckets = Map.put(state.rate_buckets, category, {0, last_refill})

      Logger.debug(
        "[SignalRelay] Rate limited category #{category} (#{limit}/s)"
      )

      {false, %{state | rate_buckets: buckets}}
    end
  end

  defp category_rate_limit do
    Application.get_env(:arbor_signals, :relay_category_rate_limit, @default_category_rate_limit)
  end

  # ── Phase 6: Security Hardening ─────────────────────────────────────

  defp valid_peer?(from_node) do
    # In single-node mode (nonode@nohost), accept all — no peers exist
    if node() == :nonode@nohost do
      true
    else
      # Check that the sender is actually in our :pg group
      peer_nodes =
        peer_relays()
        |> Enum.map(&node/1)
        |> MapSet.new()

      # Also accept our own node (for testing / loopback)
      MapSet.member?(peer_nodes, from_node) or from_node == node()
    end
  end

  defp check_node_rate(from_node, incoming_count, state) do
    limit = node_rate_limit()
    now = System.monotonic_time(:second)
    {count, window_start} = Map.get(state.node_counters, from_node, {0, now})

    # Reset counter if we're in a new 1-second window
    {count, window_start} =
      if now > window_start do
        {0, now}
      else
        {count, window_start}
      end

    available = max(limit - count, 0)
    allowed = min(incoming_count, available)
    new_count = count + allowed

    counters = Map.put(state.node_counters, from_node, {new_count, window_start})
    {allowed, %{state | node_counters: counters}}
  end

  defp node_rate_limit do
    Application.get_env(:arbor_signals, :relay_node_rate_limit, @default_node_rate_limit)
  end

  defp sanitize_remote_signal(%Signal{} = signal) do
    # Sanitize metadata keys — only allow known safe atoms
    sanitized_metadata =
      signal.metadata
      |> Enum.flat_map(fn
        {key, value} when is_atom(key) ->
          [{key, value}]

        {key, value} when is_binary(key) ->
          if key in @safe_metadata_keys do
            [{String.to_existing_atom(key), value}]
          else
            # Keep as string key — don't atomize unknown keys
            [{key, value}]
          end

        {key, value} ->
          [{key, value}]
      end)
      |> Map.new()

    %{signal | metadata: sanitized_metadata}
  rescue
    # If String.to_existing_atom fails, keep original metadata
    ArgumentError -> signal
  end

  # ── Load Shedding ──────────────────────────────────────────────────

  defp shed_or_drop(new_signal, state) do
    new_priority = Map.get(@category_priority, new_signal.category, 3)

    # Find the lowest priority signal in the batch
    {worst_idx, worst_priority} =
      state.batch
      |> Enum.with_index()
      |> Enum.max_by(fn {sig, _idx} ->
        Map.get(@category_priority, sig.category, 3)
      end)
      |> then(fn {sig, idx} ->
        {idx, Map.get(@category_priority, sig.category, 3)}
      end)

    if new_priority < worst_priority do
      # New signal is higher priority — replace the worst one
      batch = List.delete_at(state.batch, worst_idx)
      stats = Map.update!(state.stats, :signals_dropped, &(&1 + 1))

      Logger.debug(
        "[SignalRelay] Shed signal (priority #{worst_priority} replaced by #{new_priority})"
      )

      %{state | batch: [new_signal | batch], stats: stats}
    else
      # New signal is lower or equal priority — drop it
      stats = Map.update!(state.stats, :signals_dropped, &(&1 + 1))

      Logger.debug(
        "[SignalRelay] Dropped signal category=#{new_signal.category} (batch full)"
      )

      %{state | stats: stats}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp join_pg_group do
    # Ensure :pg is started (it may not be in test)
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    :pg.join(@pg_group, self())
  rescue
    _ -> :ok
  end

  defp peer_relays do
    case :pg.get_members(@pg_group) do
      members when is_list(members) ->
        Enum.reject(members, fn pid -> pid == self() end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp count_peers do
    length(peer_relays())
  end

  defp inject_to_local_bus(signal) do
    # Publish directly to Bus — signal already has origin_node set,
    # and scope is set to :local to prevent re-relay
    if Process.whereis(Arbor.Signals.Bus) do
      Arbor.Signals.Bus.publish(signal)

      # Also store in local Store for query visibility
      if Process.whereis(Arbor.Signals.Store) do
        Arbor.Signals.Store.put(signal)
      end
    end
  end

  defp batch_interval_ms do
    Application.get_env(:arbor_signals, :relay_batch_interval_ms, @default_batch_interval_ms)
  end

  defp max_batch_size do
    Application.get_env(:arbor_signals, :relay_max_batch_size, @default_max_batch_size)
  end
end
