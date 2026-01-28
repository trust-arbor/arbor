defmodule Arbor.Security.Identity.NonceCache do
  @moduledoc """
  In-memory nonce cache for replay attack prevention.

  Tracks recently seen nonces and rejects duplicates within the TTL window.
  Expired nonces are cleaned up periodically to prevent unbounded growth.

  Follows the same GenServer pattern as `CapabilityStore`.
  """

  use GenServer

  @cleanup_interval_ms 60_000

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
  @spec check_and_record(binary(), pos_integer()) :: :ok | {:error, :replayed_nonce}
  def check_and_record(nonce, ttl_seconds) when is_binary(nonce) and is_integer(ttl_seconds) do
    GenServer.call(__MODULE__, {:check_and_record, nonce, ttl_seconds})
  end

  @doc """
  Get cache statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    schedule_cleanup()

    {:ok,
     %{
       nonces: %{},
       stats: %{total_checked: 0, total_rejected: 0}
     }}
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
  def handle_info(:cleanup, state) do
    state = cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  # Private

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
end
