defmodule Arbor.Security.NonceSeenSyncTypeSecurityRegressionTest do
  @moduledoc """
  Security regression: NonceCache published its sync event as the string
  `"nonce_seen"` instead of the atom `:nonce_seen`.

  The Signals Bus keys both its security-sync owner check and its
  unencrypted-sync exemption on the atom, while subscription patterns match
  the stringified type. So the string form reached NonceCache's sync
  subscription from any local process, and NonceCache's own nonce_seen was
  topic-encrypted under a node-local key that no peer can decrypt.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Security.Identity.NonceCache
  alias Arbor.Security.SignalSync
  alias Arbor.Signals

  @peer :peer@nonce_seen_sync_type

  setup do
    assert :ok = Signals.restore_runtime_fixture()
    establish_signal_sync(NonceCache, :nonce_cache, [:nonce_seen])
    :ok
  end

  test "security regression: a process other than NonceCache cannot get a nonce_seen recorded" do
    nonce = :crypto.strong_rand_bytes(16)

    data = %{
      nonce_hex: Base.encode16(nonce, case: :lower),
      expiry: System.system_time(:second) + 300,
      origin_node: "forged@nonce_seen_sync_type"
    }

    # The Bus pins the atom sync type to NonceCache.
    assert {:error, :unauthorized} =
             Signals.emit(:security, :nonce_seen, data, scope: :local, async: false)

    # The string type escapes that owner check and still matches NonceCache's
    # "security.nonce_seen" subscription, so NonceCache must not apply it.
    assert :ok = Signals.emit(:security, "nonce_seen", data, scope: :local, async: false)
    _ = :sys.get_state(NonceCache)

    assert :ok = NonceCache.check_and_record(nonce, 300)
  end

  test "security regression: NonceCache's nonce_seen crosses the relay unencrypted and is applied" do
    previous = Application.get_env(:arbor_security, :distributed_signals)
    Application.put_env(:arbor_security, :distributed_signals, true)
    on_exit(fn -> restore_security_env(:distributed_signals, previous) end)

    nonce = :crypto.strong_rand_bytes(16)
    nonce_hex = Base.encode16(nonce, case: :lower)
    seen_ids = nonce_seen_signal_ids()

    assert :ok = NonceCache.check_and_record(nonce, 300)

    # The Store keeps the canonical signal the Bus hands to Relay.relay/2;
    # neither path re-encrypts it, so this is the payload a peer receives.
    assert {:ok, wire_signal} = eventually_new_nonce_seen_signal(seen_ids)
    assert wire_signal.type == :nonce_seen
    assert %{nonce_hex: ^nonce_hex} = wire_signal.data
    refute Map.has_key?(wire_signal.data, :__encrypted__)

    # Model the receiving node, which has not seen this nonce yet.
    :sys.replace_state(NonceCache, fn state ->
      %{state | nonces: Map.delete(state.nonces, nonce)}
    end)

    assert :ok = Signals.receive_relay_batch_fixture([wire_signal], @peer)

    assert eventually(fn -> Map.has_key?(:sys.get_state(NonceCache).nonces, nonce) end)
    assert {:error, :replayed_nonce} = NonceCache.check_and_record(nonce, 300)
  end

  defp nonce_seen_signal_ids do
    {:ok, signals} = Signals.recent(category: :security, limit: 500)

    signals
    |> Enum.filter(&(&1.type in [:nonce_seen, "nonce_seen"]))
    |> MapSet.new(& &1.id)
  end

  defp eventually_new_nonce_seen_signal(seen_ids, attempts \\ 100)
  defp eventually_new_nonce_seen_signal(_seen_ids, 0), do: :error

  defp eventually_new_nonce_seen_signal(seen_ids, attempts) do
    {:ok, signals} = Signals.recent(category: :security, limit: 500)

    case Enum.find(signals, &(&1.type in [:nonce_seen, "nonce_seen"] and &1.id not in seen_ids)) do
      nil ->
        Process.sleep(10)
        eventually_new_nonce_seen_signal(seen_ids, attempts - 1)

      signal ->
        {:ok, signal}
    end
  end

  # Establish NonceCache's real security-sync subscription without restarting
  # the shared, named store. SignalSync.establish/3 runs inside the store
  # process, exactly as its own startup does, so the Bus pins that process as
  # the nonce_seen owner and the delivery ref lands in its private custody.
  defp establish_signal_sync(store, role, events) do
    if is_nil(:sys.get_state(store).signal_sync) do
      :sys.replace_state(store, fn state ->
        {:ok, %SignalSync{} = sync} = SignalSync.establish(role, events, true)
        %{state | signal_sync: sync}
      end)

      on_exit(fn ->
        :sys.replace_state(store, fn state ->
          :ok = SignalSync.release(state.signal_sync)
          %{state | signal_sync: nil}
        end)
      end)
    end

    :ok
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
