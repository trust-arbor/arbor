defmodule Arbor.LLM.OAuth.RecoveryProofStore do
  @moduledoc false

  # Request-scoped, one-shot recovery leases for ordinary Arbor-owned 401
  # recovery. Owns no ETS table and never writes the durable OAuth token
  # store. Records hold HMAC metadata only — never raw access/refresh
  # tokens or account-id strings.
  #
  # Restart empties state and rotates the HMAC key (fail closed). Absence
  # or crash of this process makes issue/take fail closed; discard is
  # always :ok. The issuing pid is monitored so Deadline kills and caller
  # crashes release the per-provider cap.

  use GenServer

  @max_entries_per_provider 256
  @max_proof_ttl_ms 900_000
  @handle_bytes 32
  @sweep_interval_ms 60_000
  @handle_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @providers [:openai, :xai]
  @hmac_key_bytes 32

  @type provider :: :openai | :xai

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc false
  @spec issue(term(), term(), term(), term(), term(), atom()) ::
          {:ok, String.t()}
          | {:error,
             :oauth_recovery_lease_unavailable
             | :oauth_recovery_proofs_exhausted
             | :invalid_recovery_proof_request}
  def issue(provider, account_id, generation, access_token, deadline_ms, name \\ __MODULE__)

  def issue(provider, account_id, generation, access_token, deadline_ms, name)
      when provider in @providers and is_integer(generation) and generation >= 0 and
             is_binary(access_token) and byte_size(access_token) > 0 and
             is_integer(deadline_ms) do
    call_store(
      name,
      {:issue, provider, account_id, generation, access_token, deadline_ms}
    )
  end

  def issue(_provider, _account_id, _generation, _access_token, _deadline_ms, _name),
    do: {:error, :invalid_recovery_proof_request}

  @doc false
  @spec take(term(), term(), map(), atom()) ::
          {:ok, :matched}
          | {:error,
             :not_found
             | :expired
             | :oauth_arbor_owned_proof_mismatch
             | :oauth_recovery_lease_unavailable}
  def take(provider, handle, used, name \\ __MODULE__)

  def take(provider, handle, used, name)
      when provider in @providers and is_binary(handle) and is_map(used) do
    if valid_handle?(handle) do
      call_store(name, {:take, provider, handle, used})
    else
      {:error, :not_found}
    end
  end

  def take(_provider, _handle, _used, _name), do: {:error, :not_found}

  @doc false
  @spec discard(term(), term(), atom()) :: :ok
  def discard(provider, handle, name \\ __MODULE__)

  def discard(provider, handle, name)
      when provider in @providers and is_binary(handle) do
    if valid_handle?(handle) do
      _ = call_store(name, {:discard, provider, handle})
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  def discard(_provider, _handle, _name), do: :ok

  @doc false
  @spec live_count(term(), atom()) :: non_neg_integer()
  def live_count(provider, name \\ __MODULE__)

  def live_count(provider, name) when provider in @providers do
    case call_store(name, {:live_count, provider}) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  def live_count(_provider, _name), do: 0

  @doc false
  @spec valid_handle?(term()) :: boolean()
  def valid_handle?(handle) when is_binary(handle) do
    byte_size(handle) == 43 and Regex.match?(@handle_pattern, handle)
  end

  def valid_handle?(_handle), do: false

  @impl true
  def init(:ok) do
    schedule_sweep()

    {:ok,
     %{
       key: :crypto.strong_rand_bytes(@hmac_key_bytes),
       openai: %{},
       xai: %{},
       owners: %{},
       refs: %{}
     }}
  end

  @impl true
  def handle_call(
        {:issue, provider, account_id, generation, access_token, deadline_ms},
        {pid, _tag},
        state
      )
      when provider in @providers do
    now = monotonic_ms()
    swept = sweep_state(state, now)
    max_deadline = now + @max_proof_ttl_ms

    cond do
      not (deadline_ms > now and deadline_ms <= max_deadline) ->
        {:reply, {:error, :invalid_recovery_proof_request}, swept}

      map_size(Map.fetch!(swept, provider)) >= @max_entries_per_provider ->
        {:reply, {:error, :oauth_recovery_proofs_exhausted}, swept}

      true ->
        handle = mint_handle(Map.fetch!(swept, provider))

        record = %{
          deadline_ms: deadline_ms,
          generation: generation,
          token_mac: token_mac(swept.key, provider, account_id, generation, access_token),
          account_mac: account_mac(swept.key, provider, account_id),
          owner_pid: pid
        }

        {:reply, {:ok, handle}, put_record(swept, provider, handle, record, pid)}
    end
  end

  def handle_call({:take, provider, handle, used}, _from, state)
      when provider in @providers do
    {entry, remaining} = Map.pop(Map.fetch!(state, provider), handle)
    next = forget_handle(Map.put(state, provider, remaining), provider, handle, entry)

    case take_reply(entry, state.key, provider, used) do
      {:ok, :matched} = reply ->
        {:reply, reply, next}

      error ->
        {:reply, error, next}
    end
  end

  def handle_call({:discard, provider, handle}, _from, state)
      when provider in @providers do
    {entry, remaining} = Map.pop(Map.fetch!(state, provider), handle)
    {:reply, :ok, forget_handle(Map.put(state, provider, remaining), provider, handle, entry)}
  end

  def handle_call({:live_count, provider}, _from, state) when provider in @providers do
    {:reply, map_size(Map.fetch!(state, provider)), state}
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :invalid_recovery_proof_request}, state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep_expired, state) do
    next = sweep_state(state, monotonic_ms())
    schedule_sweep()
    {:noreply, next}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_owner(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Redacts :state, :message, :reason, and :log from ordinary :sys.get_status
  # and crash-report formatting. :sys.get_state/1 bypasses this callback.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} ->
        {:state, redact_state(state)}

      {key, _value} when key in [:message, :reason, :log] ->
        {key, "#Arbor.LLM.OAuth.RecoveryProofStore<redacted>"}

      key_value ->
        key_value
    end)
  end

  defp call_store(name, request) do
    GenServer.call(name, request)
  catch
    :exit, _reason -> {:error, :oauth_recovery_lease_unavailable}
  end

  defp take_reply(nil, _key, _provider, _used), do: {:error, :not_found}

  defp take_reply(%{deadline_ms: deadline_ms} = entry, key, provider, used) do
    cond do
      monotonic_ms() >= deadline_ms ->
        {:error, :expired}

      matching_macs?(key, provider, entry, used) ->
        {:ok, :matched}

      true ->
        {:error, :oauth_arbor_owned_proof_mismatch}
    end
  end

  defp matching_macs?(key, provider, entry, used) do
    account_id = Map.get(used, :account_id)
    generation = Map.get(used, :generation)
    access_token = Map.get(used, :access_token)

    mac_match?(
      entry.token_mac,
      token_mac(key, provider, account_id, generation, access_token)
    ) and mac_match?(entry.account_mac, account_mac(key, provider, account_id))
  end

  defp token_mac(key, provider, account_id, generation, access_token) do
    :crypto.mac(
      :hmac,
      :sha256,
      key,
      :erlang.term_to_binary({:v1, provider, "arbor_owned", account_id, generation, access_token})
    )
  end

  defp account_mac(key, provider, account_id) do
    :crypto.mac(
      :hmac,
      :sha256,
      key,
      :erlang.term_to_binary({:v1, :account, provider, account_id})
    )
  end

  defp mac_match?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp mac_match?(_left, _right), do: false

  defp put_record(state, provider, handle, record, pid) do
    refs =
      case Map.fetch(state.refs, pid) do
        {:ok, _ref} ->
          state.refs

        :error ->
          Map.put(state.refs, pid, Process.monitor(pid))
      end

    owners =
      Map.update(state.owners, pid, MapSet.new([{provider, handle}]), fn set ->
        MapSet.put(set, {provider, handle})
      end)

    state
    |> Map.put(provider, Map.put(Map.fetch!(state, provider), handle, record))
    |> Map.put(:owners, owners)
    |> Map.put(:refs, refs)
  end

  defp forget_handle(state, _provider, _handle, nil), do: state

  defp forget_handle(state, provider, handle, %{owner_pid: pid}) do
    remaining =
      state.owners
      |> Map.get(pid, MapSet.new())
      |> MapSet.delete({provider, handle})

    if MapSet.size(remaining) == 0 do
      demonitor_owner(state, pid)
    else
      %{state | owners: Map.put(state.owners, pid, remaining)}
    end
  end

  defp forget_handle(state, _provider, _handle, _entry), do: state

  defp drop_owner(state, pid) do
    handles = Map.get(state.owners, pid, MapSet.new())

    Enum.reduce(handles, demonitor_owner(state, pid), fn {provider, handle}, acc ->
      remaining = Map.delete(Map.fetch!(acc, provider), handle)
      Map.put(acc, provider, remaining)
    end)
  end

  defp demonitor_owner(state, pid) do
    case Map.pop(state.refs, pid) do
      {ref, refs} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | refs: refs, owners: Map.delete(state.owners, pid)}

      {_, refs} ->
        %{state | refs: refs, owners: Map.delete(state.owners, pid)}
    end
  end

  defp sweep_state(state, now) do
    Enum.reduce(@providers, state, fn provider, acc ->
      {kept, dropped} =
        acc
        |> Map.fetch!(provider)
        |> Enum.split_with(fn {_handle, %{deadline_ms: deadline_ms}} -> deadline_ms >= now end)

      next = Map.put(acc, provider, Map.new(kept))

      Enum.reduce(dropped, next, fn {handle, entry}, dropped_acc ->
        forget_handle(dropped_acc, provider, handle, entry)
      end)
    end)
  end

  defp redact_state(%{openai: openai, xai: xai}) when is_map(openai) and is_map(xai) do
    %{openai: map_size(openai), xai: map_size(xai), records: :redacted}
  end

  defp redact_state(_state), do: %{openai: 0, xai: 0, records: :redacted}

  defp schedule_sweep, do: Process.send_after(self(), :sweep_expired, @sweep_interval_ms)

  defp mint_handle(existing_map) do
    handle = Base.url_encode64(:crypto.strong_rand_bytes(@handle_bytes), padding: false)
    if Map.has_key?(existing_map, handle), do: mint_handle(existing_map), else: handle
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
