defmodule Arbor.Security.Identity.NonceCache do
  @moduledoc """
  Nonce cache for SignedRequest replay-attack prevention.

  Tracks recently seen nonces and rejects duplicates within the TTL window.
  Expired nonces are cleaned up periodically to prevent unbounded growth.

  ## Cluster distribution

  Remote `security.nonce_seen` apply is retained so a later authenticated
  security-sync transport can reuse it. Unauthenticated `nonce_seen` is not
  an authoritative cluster replay defense; multi-node signed-request
  acceptance fails closed until authenticated transport exists (see
  `Arbor.Security.Identity.Verifier`).

  A residual race remains for *simultaneous* delivery of the same nonce to
  two nodes within signal-propagation latency — closing that fully needs
  atomic cluster-wide check-and-record (consistent hashing or a shared
  store), tracked as a follow-up.

  Follows the same GenServer pattern as `CapabilityStore`.
  """

  use GenServer

  require Logger

  alias Arbor.Security.Config
  alias Arbor.Security.SignalSync
  alias Arbor.Security.SupervisedOwner

  @cleanup_interval_ms 60_000
  @nonce_bytes 16
  @signal_type "nonce_seen"
  @signal_events [:nonce_seen]

  # Client API

  @doc """
  Start the nonce cache.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a nonce has been seen before, and record it if not.

  Returns `:ok` for fresh nonces, `{:error, :replayed_nonce}` for duplicates.
  """
  @spec check_and_record(binary(), pos_integer()) ::
          :ok | {:error, :replayed_nonce | :verification_unavailable}
  def check_and_record(nonce, ttl_seconds) when is_binary(nonce) and is_integer(ttl_seconds) do
    owner_call({:check_and_record, nonce, ttl_seconds}, {:error, :verification_unavailable})
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    owner_call(:stats, %{total_checked: 0, total_rejected: 0, active_nonces: 0})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    schedule_cleanup()

    {:ok,
     %{
       nonces: %{},
       signal_sync: nil,
       stats: %{total_checked: 0, total_rejected: 0}
     }, {:continue, :establish_signal_sync}}
  end

  @impl true
  def handle_continue(:establish_signal_sync, state) do
    case subscribe_to_distributed_signals() do
      {:ok, signal_sync} ->
        {:noreply, %{state | signal_sync: signal_sync}}

      {:error, reason} ->
        {:stop, {:security_sync_subscription_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:check_and_record, nonce, ttl_seconds}, _from, state) do
    now = System.system_time(:second)
    state = update_in(state, [:stats, :total_checked], &(&1 + 1))

    if Map.has_key?(state.nonces, nonce) do
      state = update_in(state, [:stats, :total_rejected], &(&1 + 1))
      {:reply, {:error, :replayed_nonce}, state}
    else
      expiry = now + ttl_seconds
      state = put_in(state, [:nonces, nonce], expiry)
      # Propagate to peer nodes so the nonce can't be replayed elsewhere.
      emit_nonce_seen(nonce, expiry)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_nonces: map_size(state.nonces)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_request}, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # A peer node recorded a nonce — record it locally so a replay aimed at
  # THIS node is rejected. Never re-emits (no propagation loop).
  def handle_info({:signal_received, delivery_ref, signal}, state) do
    if SignalSync.authenticated_delivery?(state.signal_sync, delivery_ref) do
      {:noreply, record_remote_nonce(signal, state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(message, state) do
    case SignalSync.handle_info(message, state.signal_sync) do
      {:ok, signal_sync} ->
        {:noreply, %{state | signal_sync: signal_sync}}

      {:stop, reason, signal_sync} ->
        {:stop, reason, %{state | signal_sync: signal_sync}}

      :unhandled ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    SignalSync.release(Map.get(state, :signal_sync))
  end

  # Private

  defp subscribe_to_distributed_signals do
    SignalSync.establish(:nonce_cache, @signal_events, Config.distributed_signals_enabled?())
  end

  defp emit_nonce_seen(nonce, expiry) do
    if Config.distributed_signals_enabled?() do
      Arbor.Signals.emit(
        :security,
        @signal_type,
        %{
          # hex-encode so the binary nonce survives any signal serialization
          nonce_hex: Base.encode16(nonce, case: :lower),
          expiry: expiry,
          origin_node: node()
        },
        scope: :cluster
      )
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp record_remote_nonce(signal, state) do
    data = Map.get(signal, :data, %{})
    origin_node = data[:origin_node] || data["origin_node"]

    if origin_node in [node(), Atom.to_string(node())] do
      # Our own signal echoed back — ignore.
      state
    else
      nonce_hex = data[:nonce_hex] || data["nonce_hex"] || ""

      case Base.decode16(to_string(nonce_hex), case: :mixed) do
        {:ok, nonce} when byte_size(nonce) == @nonce_bytes ->
          now = System.system_time(:second)
          supplied_expiry = data[:expiry] || data["expiry"]

          case bounded_remote_expiry(supplied_expiry, now) do
            {:ok, expiry} -> put_in(state, [:nonces, nonce], expiry)
            :discard -> state
          end

        _ ->
          state
      end
    end
  catch
    _, reason ->
      Logger.warning("[NonceCache] failed to record remote nonce: #{inspect(reason)}")
      state
  end

  defp bounded_remote_expiry(expiry, now) when is_integer(expiry) and expiry > now do
    max_ttl = Config.nonce_ttl_seconds()

    if is_integer(max_ttl) and max_ttl >= 0 do
      {:ok, min(expiry, now + max_ttl)}
    else
      :discard
    end
  end

  defp bounded_remote_expiry(_expiry, _now), do: :discard

  defp cleanup_expired(state) do
    now = System.system_time(:second)

    expired_nonces =
      state.nonces
      |> Enum.filter(fn {_nonce, expiry} -> expiry <= now end)
      |> Enum.map(fn {nonce, _expiry} -> nonce end)

    if expired_nonces == [] do
      state
    else
      update_in(state, [:nonces], fn nonces ->
        Enum.reduce(expired_nonces, nonces, &Map.delete(&2, &1))
      end)
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp owner_call(request, unavailable) do
    case SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) do
      pid when is_pid(pid) -> GenServer.call(pid, request)
      nil -> unavailable
    end
  rescue
    _ -> unavailable
  catch
    :exit, _ -> unavailable
  end
end
