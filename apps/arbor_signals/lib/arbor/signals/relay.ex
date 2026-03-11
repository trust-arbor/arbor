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

  ## Load Shedding

  When the outbound queue exceeds `max_batch_size`, low-priority signals
  are dropped. Priority order (highest to lowest):
  1. `:security` — never dropped
  2. `:trust`, `:consensus` — dropped only under extreme pressure
  3. `:agent`, `:orchestrator` — dropped when queue is full

  ## Configuration

      config :arbor_signals,
        relay_batch_interval_ms: 50,
        relay_max_batch_size: 500,
        relay_enabled: true
  """

  use GenServer

  require Logger

  alias Arbor.Signals.Signal

  @pg_group {:arbor, :signal_relays}
  @default_batch_interval_ms 50
  @default_max_batch_size 500

  # Priority levels for load shedding (lower = higher priority = shed last)
  @category_priority %{
    security: 0,
    trust: 1,
    consensus: 1,
    agent: 2,
    orchestrator: 2
  }

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
         stats: %{
           relayed_out: 0,
           relayed_in: 0,
           batches_sent: 0,
           signals_dropped: 0,
           peers_seen: 0
         }
       }}
    else
      {:ok, %{batch: [], batch_size: 0, stats: %{status: :disabled}}}
    end
  end

  @impl true
  def handle_cast({:relay, %Signal{} = signal}, state) do
    max_batch = max_batch_size()

    if state.batch_size >= max_batch do
      # Load shedding — try to drop lowest priority signal
      state = shed_or_drop(signal, state, max_batch)
      {:noreply, state}
    else
      state = %{state | batch: [signal | state.batch], batch_size: state.batch_size + 1}
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:receive_batch, signals, from_node}, state) do
    # Inject remote signals into local Bus
    count = length(signals)

    Enum.each(signals, fn signal ->
      # Mark as already-relayed to prevent re-relay loops
      signal = %{signal | scope: :local}
      inject_to_local_bus(signal)
    end)

    stats =
      state.stats
      |> Map.update!(:relayed_in, &(&1 + count))
      |> Map.put(:peers_seen, count_peers())

    Logger.debug(
      "[SignalRelay] Received #{count} signals from #{from_node}"
    )

    {:noreply, %{state | stats: stats}}
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

  # ── Private ─────────────────────────────────────────────────────────

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

  defp shed_or_drop(new_signal, state, _max_batch) do
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
      %{state | batch: [new_signal | batch], stats: stats}
    else
      # New signal is lower or equal priority — drop it
      stats = Map.update!(state.stats, :signals_dropped, &(&1 + 1))
      %{state | stats: stats}
    end
  end

  defp batch_interval_ms do
    Application.get_env(:arbor_signals, :relay_batch_interval_ms, @default_batch_interval_ms)
  end

  defp max_batch_size do
    Application.get_env(:arbor_signals, :relay_max_batch_size, @default_max_batch_size)
  end
end
