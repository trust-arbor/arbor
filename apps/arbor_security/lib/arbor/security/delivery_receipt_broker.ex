defmodule Arbor.Security.DeliveryReceiptBroker do
  @moduledoc false

  # Private one-use delivery-receipt broker. Callers outside arbor_security must
  # use Arbor.Security facades. Intentionally ephemeral: restart loses every
  # outstanding receipt. No persistence, signals, or cluster sync.

  use GenServer

  alias Arbor.Contracts.Security.DeliveryReceipt

  @token_bytes 32
  @default_ttl_ms 30_000
  @default_max_entries 4_096
  @default_cleanup_interval_ms 5_000
  @max_token_attempts 8

  @type issue_error :: :broker_full | :receipt_issue_failed | :broker_unavailable
  @type consume_error :: :invalid_receipt | :broker_unavailable

  # ---------------------------------------------------------------------------
  # Client API (internal — not a public library facade)
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec issue(String.t(), String.t(), atom() | nil) ::
          {:ok, DeliveryReceipt.t()} | {:error, issue_error()}
  def issue(principal_id, resource_uri, action)
      when is_binary(principal_id) and is_binary(resource_uri) do
    issue(__MODULE__, principal_id, resource_uri, action)
  end

  @doc false
  @spec issue(GenServer.server(), String.t(), String.t(), atom() | nil) ::
          {:ok, DeliveryReceipt.t()} | {:error, issue_error()}
  def issue(server, principal_id, resource_uri, action)
      when is_binary(principal_id) and is_binary(resource_uri) do
    safe_call(server, {:issue, principal_id, resource_uri, action})
  end

  @doc false
  @spec consume(binary(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, consume_error()}
  def consume(token, resource_uri, action)
      when is_binary(token) and is_binary(resource_uri) do
    consume(__MODULE__, token, resource_uri, action)
  end

  @doc false
  @spec consume(GenServer.server(), binary(), String.t(), atom() | nil) ::
          {:ok, String.t()} | {:error, consume_error()}
  def consume(server, token, resource_uri, action)
      when is_binary(token) and is_binary(resource_uri) do
    safe_call(server, {:consume, token, resource_uri, action})
  end

  @doc false
  @spec discard(binary()) :: :ok | {:error, :broker_unavailable}
  def discard(token) when is_binary(token) do
    discard(__MODULE__, token)
  end

  @doc false
  @spec discard(GenServer.server(), binary()) :: :ok | {:error, :broker_unavailable}
  def discard(server, token) when is_binary(token) do
    case safe_call(server, {:discard, token}) do
      :ok -> :ok
      {:error, :broker_unavailable} = err -> err
      _ -> :ok
    end
  end

  @doc false
  @spec stats() :: map() | {:error, :broker_unavailable}
  def stats, do: stats(__MODULE__)

  @doc false
  @spec stats(GenServer.server()) :: map() | {:error, :broker_unavailable}
  def stats(server) do
    safe_call(server, :stats)
  end

  defp safe_call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, _ -> {:error, :broker_unavailable}
  end

  # ---------------------------------------------------------------------------
  # Server
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    ttl_ms = positive_int(Keyword.get(opts, :ttl_ms), @default_ttl_ms)
    max_entries = positive_int(Keyword.get(opts, :max_entries), @default_max_entries)

    cleanup_interval_ms =
      positive_int(Keyword.get(opts, :cleanup_interval_ms), @default_cleanup_interval_ms)

    clock = Keyword.get(opts, :clock, &System.monotonic_time/1)
    clock_fun = normalize_clock(clock)

    schedule_cleanup(cleanup_interval_ms)

    {:ok,
     %{
       entries: %{},
       ttl_ms: ttl_ms,
       max_entries: max_entries,
       cleanup_interval_ms: cleanup_interval_ms,
       clock: clock_fun,
       stats: %{
         issued: 0,
         consumed: 0,
         discarded: 0,
         expired: 0,
         rejected_full: 0,
         rejected_issue: 0,
         rejected_consume: 0
       }
     }}
  end

  @impl true
  def handle_call({:issue, principal_id, resource_uri, action}, _from, state) do
    # Skip O(n) expiry prune while under capacity; prune once at capacity and
    # re-check before returning :broker_full. Periodic cleanup still runs.
    state =
      if map_size(state.entries) >= state.max_entries do
        prune_expired(state)
      else
        state
      end

    now = state.clock.()

    cond do
      map_size(state.entries) >= state.max_entries ->
        state = bump(state, :rejected_full)
        {:reply, {:error, :broker_full}, state}

      true ->
        case mint_receipt(state, principal_id, resource_uri, action, now) do
          {:ok, receipt, state} ->
            {:reply, {:ok, receipt}, bump(state, :issued)}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:consume, token, resource_uri, action}, _from, state) do
    now = state.clock.()
    {entry, entries} = Map.pop(state.entries, token)
    state = %{state | entries: entries}

    case entry do
      nil ->
        state = bump(state, :rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}

      %{expires_at_ms: exp} when exp <= now ->
        state = bump(state, :expired) |> bump(:rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}

      %{resource_uri: ^resource_uri, action: ^action, principal_id: principal_id} ->
        state = bump(state, :consumed)
        {:reply, {:ok, principal_id}, state}

      _mismatch ->
        # Token already removed — cannot retry against another target.
        state = bump(state, :rejected_consume)
        {:reply, {:error, :invalid_receipt}, state}
    end
  end

  def handle_call({:discard, token}, _from, state) do
    {entry, entries} = Map.pop(state.entries, token)
    state = %{state | entries: entries}

    state =
      if is_nil(entry) do
        state
      else
        bump(state, :discarded)
      end

    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active: map_size(state.entries)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = prune_expired(state)
    schedule_cleanup(state.cleanup_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def format_status(status) when is_map(status) do
    redacted =
      status
      |> Map.put(:message, :redacted)
      |> Map.put(:state, %{delivery_receipt_broker: :redacted})

    maybe_redact_status_field(redacted, :reason)
    |> maybe_redact_status_field(:log)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp mint_receipt(state, principal_id, resource_uri, action, now) do
    do_mint(state, principal_id, resource_uri, action, now, @max_token_attempts)
  end

  defp do_mint(state, _principal_id, _resource_uri, _action, _now, 0) do
    {:error, :receipt_issue_failed, bump(state, :rejected_issue)}
  end

  defp do_mint(state, principal_id, resource_uri, action, now, attempts_left) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    cond do
      Map.has_key?(state.entries, token) ->
        do_mint(state, principal_id, resource_uri, action, now, attempts_left - 1)

      true ->
        case DeliveryReceipt.new(token: token) do
          {:ok, receipt} ->
            entry = %{
              principal_id: principal_id,
              resource_uri: resource_uri,
              action: action,
              expires_at_ms: now + state.ttl_ms
            }

            state = put_in(state, [:entries, token], entry)
            {:ok, receipt, state}

          {:error, _reason} ->
            do_mint(state, principal_id, resource_uri, action, now, attempts_left - 1)
        end
    end
  end

  defp prune_expired(state) do
    now = state.clock.()

    {kept, expired_count} =
      Enum.reduce(state.entries, {%{}, 0}, fn {token, entry}, {acc, count} ->
        if entry.expires_at_ms <= now do
          {acc, count + 1}
        else
          {Map.put(acc, token, entry), count}
        end
      end)

    state = %{state | entries: kept}

    if expired_count > 0 do
      update_in(state, [:stats, :expired], &(&1 + expired_count))
    else
      state
    end
  end

  defp bump(state, key) do
    update_in(state, [:stats, key], &(&1 + 1))
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp normalize_clock(fun) when is_function(fun, 0), do: fun

  defp normalize_clock(fun) when is_function(fun, 1) do
    fn -> fun.(:millisecond) end
  end

  defp normalize_clock(_), do: fn -> System.monotonic_time(:millisecond) end

  defp maybe_redact_status_field(status, key) do
    if Map.has_key?(status, key), do: Map.put(status, key, :redacted), else: status
  end
end
