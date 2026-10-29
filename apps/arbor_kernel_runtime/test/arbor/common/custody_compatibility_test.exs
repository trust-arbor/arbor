defmodule Arbor.Common.CustodyCompatibilityTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common
  alias Arbor.Common.AuthenticatedCall, as: LegacyCall
  alias Arbor.Custody

  @protocol :"$arbor_authenticated_call"

  defmodule LegacyOwner do
    @moduledoc false
    use GenServer

    alias Arbor.Common
    alias Arbor.Common.AuthenticatedCall, as: LegacyCall
    alias Arbor.Common.ProcessPrivateState, as: LegacyPrivateState
    alias Arbor.Custody

    @anchor {__MODULE__, :credential}
    @schema :credential_v1
    @call_seal {Arbor.Common.AuthenticatedCall, :sealed_custody}
    @private_seal {{Arbor.Common.ProcessPrivateState, :sealed}, @anchor}
    @protocol :"$arbor_authenticated_call"

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)

      # Construct the actual table shapes and dictionary identities written by
      # the previous implementation, before calling either new facade or shim.
      calls = :ets.new(Arbor.Common.AuthenticatedCall, [:set, :private])
      private_state = :ets.new(Arbor.Common.ProcessPrivateState, [:set, :private])
      Process.put(@call_seal, calls)
      true = :ets.insert(private_state, {@schema, :original})
      Process.put(@private_seal, private_state)

      {:ok, %{custody: calls, dispatch: :package}}
    end

    @impl true
    def handle_call(:metadata, _from, state) do
      calls = Process.get(@call_seal)
      private_state = Process.get(@private_seal)

      {:reply,
       %{
         calls: calls,
         private_state: private_state,
         calls_name: :ets.info(calls, :name),
         private_state_name: :ets.info(private_state, :name),
         package_custody: Custody.new_authenticated_call_custody(),
         facade_custody: Common.new_authenticated_call_custody(),
         shim_custody: LegacyCall.new_custody(),
         pending: :ets.info(calls, :size)
       }, state}
    end

    def handle_call({:dispatch, api}, _from, state) when api in [:package, :facade, :shim],
      do: {:reply, :ok, %{state | dispatch: api}}

    def handle_call({:clear, api}, _from, state) do
      :ok = clear(api, state.custody)
      {:reply, :ok, state}
    end

    def handle_call({:legacy_pending, caller, proof, reply_alias, request_ref}, _from, state) do
      challenge = :crypto.strong_rand_bytes(32)
      transfer_ref = make_ref()
      expiry_ref = make_ref()

      timer =
        Process.send_after(self(), {@protocol, :expire, request_ref, expiry_ref}, 1_000)

      # This is the previous implementation's exact pending record, inserted
      # without invoking the extracted protocol engine. It qualifies the data
      # identity, not an unsupported live code-swap operation.
      true =
        :ets.insert(
          Process.get(@call_seal),
          {request_ref, caller, proof, challenge, transfer_ref, reply_alias, {:read, :facade},
           timer, expiry_ref}
        )

      {:reply, {challenge, transfer_ref}, state}
    end

    @impl true
    def handle_info(message, state) do
      case admit(state.dispatch, message, state.custody) do
        {:authenticated, caller, {:read, api}, reply_to} ->
          result = {caller, self(), fetch(api)}
          :ok = reply(state.dispatch, reply_to, result)
          {:noreply, state}

        {:authenticated, _caller, {:replace, api, value}, reply_to} ->
          :ok = reply(state.dispatch, reply_to, replace(api, value))
          {:noreply, state}

        {:authenticated, _caller, {:close, api}, reply_to} ->
          :ok = reply(state.dispatch, reply_to, close(api))
          {:noreply, state}

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, state}
      end
    end

    defp admit(:package, message, custody),
      do: Custody.handle_authenticated_call(message, custody)

    defp admit(:facade, message, custody), do: Common.handle_authenticated_call(message, custody)
    defp admit(:shim, message, custody), do: LegacyCall.handle(message, custody)

    defp reply(:package, target, result), do: Custody.reply_authenticated_call(target, result)
    defp reply(:facade, target, result), do: Common.reply_authenticated_call(target, result)
    defp reply(:shim, target, result), do: LegacyCall.reply(target, result)

    defp clear(:package, custody), do: Custody.clear_authenticated_call_custody(custody)
    defp clear(:facade, custody), do: Common.clear_authenticated_call_custody(custody)
    defp clear(:shim, custody), do: LegacyCall.clear(custody)

    defp fetch(:package), do: Custody.fetch_process_private_state(@anchor, @schema, &valid?/1)
    defp fetch(:facade), do: Common.fetch_process_private_state(@anchor, @schema, &valid?/1)
    defp fetch(:shim), do: LegacyPrivateState.fetch(@anchor, @schema, &valid?/1)

    defp replace(:package, value),
      do: Custody.replace_process_private_state(@anchor, @schema, value, &valid?/1)

    defp replace(:facade, value),
      do: Common.replace_process_private_state(@anchor, @schema, value, &valid?/1)

    defp replace(:shim, value), do: LegacyPrivateState.replace(@anchor, @schema, value, &valid?/1)

    defp close(:package), do: Custody.close_process_private_state(@anchor)
    defp close(:facade), do: Common.close_process_private_state(@anchor)
    defp close(:shim), do: LegacyPrivateState.close(@anchor)

    defp valid?(value), do: value in [:original, :rotated]
  end

  test "security regression: package and compatibility entry points share real legacy custody" do
    owner = start_supervised!(LegacyOwner)
    caller = self()
    before = GenServer.call(owner, :metadata)

    assert before.calls == before.package_custody
    assert before.calls == before.facade_custody
    assert before.calls == before.shim_custody
    assert before.calls_name == Arbor.Common.AuthenticatedCall
    assert before.private_state_name == Arbor.Common.ProcessPrivateState
    assert :ets.info(before.calls, :protection) == :private
    assert :ets.info(before.private_state, :protection) == :private
    assert_raise ArgumentError, fn -> :ets.tab2list(before.calls) end
    assert_raise ArgumentError, fn -> :ets.tab2list(before.private_state) end
    assert Process.info(owner, :dictionary) == {:dictionary, []}
    assert :sys.get_state(owner) == %{custody: before.calls, dispatch: :package}

    for dispatch <- [:package, :facade, :shim] do
      assert :ok = GenServer.call(owner, {:dispatch, dispatch})

      for client <- callers(), private_api <- [:package, :facade, :shim] do
        assert {^caller, ^owner, {:ok, :original}} = client.(owner, {:read, private_api}, 1_000)
      end
    end

    assert :ok = Common.authenticated_call(owner, {:replace, :shim, :rotated})

    assert {^caller, ^owner, {:ok, :rotated}} =
             Custody.authenticated_call(owner, {:read, :package})

    after_calls = GenServer.call(owner, :metadata)
    assert after_calls.calls == before.calls
    assert after_calls.private_state == before.private_state
    assert after_calls.pending == 0

    assert :ok = LegacyCall.call(owner, {:close, :facade})

    assert {^caller, ^owner, {:error, :invalid_private_state}} =
             Custody.authenticated_call(owner, {:read, :shim})
  end

  test "security regression: compatibility wrappers cannot select replaceable fake call custody" do
    owner = start_supervised!(LegacyOwner)
    caller = self()
    before = GenServer.call(owner, :metadata)
    fake = :ets.new(__MODULE__, [:set, :private])
    true = :ets.give_away(fake, owner, :replaceable_fake_custody)

    :sys.replace_state(owner, &Map.put(&1, :custody, fake))

    for dispatch <- [:package, :facade, :shim] do
      assert :ok = GenServer.call(owner, {:dispatch, dispatch})

      assert {^caller, ^owner, {:ok, :original}} =
               Custody.authenticated_call(owner, {:read, :package})
    end

    after_calls = GenServer.call(owner, :metadata)
    assert after_calls.calls == before.calls
    assert after_calls.pending == 0
    assert :ets.info(before.calls, :owner) == owner
  end

  test "security regression: compatibility clear retires pending calls in the original seal" do
    owner = start_supervised!(LegacyOwner)
    proof = :ets.new(__MODULE__, [:set, :private])
    request_ref = make_ref()
    reply_alias = :erlang.alias()

    try do
      send(
        owner,
        {@protocol, :begin, self(), request_ref, reply_alias, proof, {:read, :package}, 1_000}
      )

      assert_receive {@protocol, :challenge, ^owner, ^request_ref, challenge, transfer_ref}
      assert %{pending: 1} = GenServer.call(owner, :metadata)
      assert :ok = GenServer.call(owner, {:clear, :facade})
      assert %{pending: 0} = GenServer.call(owner, :metadata)

      true = :ets.insert(proof, {request_ref, challenge, transfer_ref})
      true = :ets.give_away(proof, owner, {@protocol, :proof, request_ref, transfer_ref})
      assert %{pending: 0} = GenServer.call(owner, :metadata)
      refute_receive {@protocol, :reply, ^owner, ^request_ref, _result}, 20

      assert :ok = GenServer.call(owner, {:clear, :shim})
      caller = self()

      assert {^caller, ^owner, {:ok, :original}} =
               LegacyCall.call(owner, {:read, :facade})
    after
      :erlang.unalias(reply_alias)
    end
  end

  test "security regression: the new facade consumes an actual legacy pending proof exactly once" do
    owner = start_supervised!(LegacyOwner)
    caller = self()
    proof = :ets.new(Arbor.Common.AuthenticatedCall, [:set, :private])
    request_ref = make_ref()
    reply_alias = :erlang.alias()

    try do
      {challenge, transfer_ref} =
        GenServer.call(owner, {:legacy_pending, caller, proof, reply_alias, request_ref})

      assert %{pending: 1} = GenServer.call(owner, :metadata)
      true = :ets.insert(proof, {request_ref, challenge, transfer_ref})
      gift = {@protocol, :proof, request_ref, transfer_ref}
      true = :ets.give_away(proof, owner, gift)

      assert_receive {@protocol, :reply, ^owner, ^request_ref,
                      {^caller, ^owner, {:ok, :original}}}

      assert :ets.info(proof) == :undefined
      assert %{pending: 0} = GenServer.call(owner, :metadata)
      send(owner, {:"ETS-TRANSFER", proof, caller, gift})
      assert %{pending: 0} = GenServer.call(owner, :metadata)
      refute_receive {@protocol, :reply, ^owner, ^request_ref, _result}, 20
    after
      :erlang.unalias(reply_alias)
    end
  end

  test "security regression: every call entry point preserves the legacy failure origin" do
    for client <- callers() do
      assert catch_exit(client.(:registered_names_are_not_authority, :request, 20)) ==
               {:noproc,
                {Arbor.Common.AuthenticatedCall, :call, [:registered_names_are_not_authority]}}

      pid = self()

      assert catch_exit(client.(pid, :request, 0)) ==
               {:badarg, {Arbor.Common.AuthenticatedCall, :call, [pid]}}
    end
  end

  defp callers do
    [
      &Custody.authenticated_call/3,
      &Common.authenticated_call/3,
      &LegacyCall.call/3
    ]
  end
end
