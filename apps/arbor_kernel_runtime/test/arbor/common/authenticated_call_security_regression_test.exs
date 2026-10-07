defmodule Arbor.Common.AuthenticatedCallSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "SSEC-004"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Common.AuthenticatedCall

  @protocol :"$arbor_authenticated_call"

  defmodule TestServer do
    use GenServer

    alias Arbor.Common.AuthenticatedCall

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.flag(:sensitive, true)

      {:ok,
       %{
         authenticated_calls: AuthenticatedCall.new_custody(),
         sentinel: :ets.new(__MODULE__, [:set, :private]),
         applied: 0
       }}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply,
       %{
         applied: state.applied,
         pending: :ets.info(state.authenticated_calls, :size),
         custody: state.authenticated_calls,
         sentinel: state.sentinel
       }, state}
    end

    def handle_call(_request, _from, state),
      do: {:reply, {:error, :unauthorized}, state}

    @impl true
    def handle_info(message, state) do
      case AuthenticatedCall.handle(message, state.authenticated_calls) do
        {:authenticated, _caller_pid, :increment, reply_to} ->
          :ok = AuthenticatedCall.reply(reply_to, :ok)
          {:noreply, %{state | applied: state.applied + 1}}

        result when result in [:pending, :expired, :rejected, :unrecognized] ->
          {:noreply, state}
      end
    end
  end

  test "authenticated call applies exactly once" do
    {:ok, server} = TestServer.start_link()

    assert :ok = AuthenticatedCall.call(server, :increment)
    assert %{applied: 1, pending: 0} = GenServer.call(server, :snapshot)
  end

  @tag spec: "SSEC-004"
  test "security regression: custody cannot authenticate a forged self-call or be expired" do
    {:ok, server} = TestServer.start_link()
    %{custody: custody} = GenServer.call(server, :snapshot)
    request_ref = make_ref()
    reply_alias = :erlang.alias()

    on_exit(fn -> :erlang.unalias(reply_alias) end)

    send(
      server,
      {@protocol, :begin, server, request_ref, reply_alias, custody, :increment, 20}
    )

    assert_receive {@protocol, :reply, ^server, ^request_ref, {:error, :unauthorized}}
    Process.sleep(30)

    assert :ets.info(custody, :owner) == server
    assert %{applied: 0, pending: 0, custody: ^custody} = GenServer.call(server, :snapshot)
    assert :ok = AuthenticatedCall.call(server, :increment)
    assert %{applied: 1, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: raw ETS transfer tuples cannot delete server-owned tables" do
    {:ok, server} = TestServer.start_link()
    %{custody: custody, sentinel: sentinel} = GenServer.call(server, :snapshot)

    send(
      server,
      {:"ETS-TRANSFER", custody, self(), {@protocol, :proof, make_ref(), make_ref()}}
    )

    send(server, {:"ETS-TRANSFER", sentinel, self(), :malformed_gift})

    send(
      server,
      {:"ETS-TRANSFER", sentinel, self(), {@protocol, :proof, make_ref(), make_ref()}}
    )

    Process.sleep(20)

    assert :ets.info(custody, :owner) == server
    assert :ets.info(sentinel, :owner) == server
    assert Process.alive?(server)
    assert :ok = AuthenticatedCall.call(server, :increment)
    assert %{applied: 1, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: replacing state with transferred fake custody cannot impersonate a caller" do
    {:ok, server} = TestServer.start_link()
    %{custody: original_custody} = GenServer.call(server, :snapshot)
    request_ref = make_ref()
    transfer_ref = make_ref()
    expiry_ref = make_ref()
    challenge = :crypto.strong_rand_bytes(32)
    reply_alias = :erlang.alias()
    timer_ref = Process.send_after(self(), :discard_hostile_timer, 60_000)
    hostile_proof = :ets.new(__MODULE__, [:set, :private])
    hostile_custody = :ets.new(__MODULE__, [:set, :private])

    on_exit(fn ->
      Process.cancel_timer(timer_ref)
      :erlang.unalias(reply_alias)
    end)

    true = :ets.insert(hostile_proof, {request_ref, challenge, transfer_ref})

    true =
      :ets.insert(
        hostile_custody,
        {request_ref, self(), hostile_proof, challenge, transfer_ref, reply_alias, :increment,
         timer_ref, expiry_ref}
      )

    true = :ets.give_away(hostile_custody, server, :hostile_custody)
    true = :ets.give_away(hostile_proof, server, :hostile_proof)

    assert eventually(fn ->
             :ets.info(hostile_custody, :owner) == server and
               :ets.info(hostile_proof, :owner) == server
           end)

    :sys.replace_state(server, &Map.put(&1, :authenticated_calls, hostile_custody))

    send(
      server,
      {:"ETS-TRANSFER", hostile_proof, self(), {@protocol, :proof, request_ref, transfer_ref}}
    )

    Process.sleep(20)
    assert Process.alive?(server)
    assert :ets.info(original_custody, :owner) == server
    assert %{applied: 0} = GenServer.call(server, :snapshot)

    assert :ok = AuthenticatedCall.call(server, :increment)
    assert %{applied: 1} = GenServer.call(server, :snapshot)
  end

  test "security regression: call hides its mailbox during the exchange and restores the flag" do
    test_pid = self()

    server =
      spawn(fn ->
        receive do
          {@protocol, :begin, caller, request_ref, reply_alias, caller_proof, :probe, _ttl} ->
            challenge = :crypto.strong_rand_bytes(32)
            transfer_ref = make_ref()

            send(
              caller,
              {@protocol, :challenge, self(), request_ref, challenge, transfer_ref}
            )

            receive do
              {:"ETS-TRANSFER", ^caller_proof, ^caller,
               {@protocol, :proof, ^request_ref, ^transfer_ref}} ->
                assert :ets.info(caller_proof, :owner) == self()

                assert [{^request_ref, ^challenge, ^transfer_ref}] =
                         :ets.lookup(caller_proof, request_ref)

                send(test_pid, {:caller_waiting_for_reply, caller})

                receive do
                  :release_reply ->
                    send(reply_alias, {@protocol, :reply, self(), request_ref, :ok})
                    :ets.delete(caller_proof)
                end
            end
        end
      end)

    caller =
      spawn(fn ->
        result = AuthenticatedCall.call(server, :probe)
        send(test_pid, {:call_finished, result, Process.info(self(), :messages)})
      end)

    assert_receive {:caller_waiting_for_reply, ^caller}
    send(caller, :mailbox_probe)
    assert {:messages, []} = Process.info(caller, :messages)

    send(server, :release_reply)
    assert_receive {:call_finished, :ok, {:messages, [:mailbox_probe]}}
  end

  test "security regression: a sensitive claimed caller hides the challenge from a raw spoofer" do
    {:ok, server} = TestServer.start_link()
    victim = sensitive_idle_process()
    caller_proof = transferred_proof_table(victim)
    reply_alias = :erlang.alias()
    request_ref = make_ref()

    on_exit(fn ->
      Process.exit(victim, :kill)
      :erlang.unalias(reply_alias)
    end)

    send(
      server,
      {@protocol, :begin, victim, request_ref, reply_alias, caller_proof, :increment, 100}
    )

    assert eventually(fn -> GenServer.call(server, :snapshot).pending == 1 end)
    assert {:messages, []} = Process.info(victim, :messages)

    send(
      server,
      {:"ETS-TRANSFER", caller_proof, victim, {@protocol, :proof, request_ref, make_ref()}}
    )

    assert_receive {@protocol, :reply, ^server, ^request_ref, {:error, :unauthorized}}
    assert %{applied: 0, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: a scraped challenge cannot replace caller-owned write custody" do
    {:ok, server} = TestServer.start_link()
    victim = idle_process()
    caller_proof = transferred_proof_table(victim)
    reply_alias = :erlang.alias()
    request_ref = make_ref()

    on_exit(fn ->
      Process.exit(victim, :kill)
      :erlang.unalias(reply_alias)
    end)

    send(
      server,
      {@protocol, :begin, victim, request_ref, reply_alias, caller_proof, :increment, 1_000}
    )

    assert eventually(fn -> GenServer.call(server, :snapshot).pending == 1 end)

    assert {:messages, messages} = Process.info(victim, :messages)

    assert {@protocol, :challenge, ^server, ^request_ref, _challenge, transfer_ref} =
             Enum.find(messages, fn
               {@protocol, :challenge, ^server, ^request_ref, _challenge, _transfer_ref} -> true
               _other -> false
             end)

    assert_raise ArgumentError, fn ->
      :ets.lookup(caller_proof, request_ref)
    end

    send(
      server,
      {:"ETS-TRANSFER", caller_proof, victim, {@protocol, :proof, request_ref, transfer_ref}}
    )

    assert_receive {@protocol, :reply, ^server, ^request_ref, {:error, :unauthorized}}

    assert %{applied: 0, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: a polling process cannot read or transfer a live caller proof" do
    {:ok, server} = TestServer.start_link()
    test_pid = self()
    request_ref = make_ref()
    reply_alias = :erlang.alias()

    victim =
      spawn(fn ->
        Process.flag(:sensitive, true)
        caller_proof = :ets.new(__MODULE__, [:set, :private])
        send(test_pid, {:private_proof_ready, self(), caller_proof})

        send(
          server,
          {@protocol, :begin, self(), request_ref, reply_alias, caller_proof, :increment, 500}
        )

        receive do
          {@protocol, :challenge, ^server, ^request_ref, challenge, transfer_ref} ->
            true = :ets.insert(caller_proof, {request_ref, challenge, transfer_ref})
            send(test_pid, {:private_proof_written, self()})

            receive do
              :transfer_proof ->
                true =
                  :ets.give_away(
                    caller_proof,
                    server,
                    {@protocol, :proof, request_ref, transfer_ref}
                  )
            end
        end
      end)

    on_exit(fn ->
      if Process.alive?(victim), do: Process.exit(victim, :kill)
      :erlang.unalias(reply_alias)
    end)

    assert_receive {:private_proof_ready, ^victim, caller_proof}
    assert_receive {:private_proof_written, ^victim}
    assert :ets.info(caller_proof, :protection) == :private

    observations =
      Task.async(fn ->
        Enum.map(1..50, fn _attempt ->
          try do
            {:readable, :ets.lookup(caller_proof, request_ref)}
          rescue
            ArgumentError -> :private
          end
        end)
      end)
      |> Task.await()

    assert Enum.uniq(observations) == [:private]

    assert_raise ArgumentError, fn ->
      :ets.give_away(caller_proof, server, :forged_transfer)
    end

    send(victim, :transfer_proof)
    assert_receive {@protocol, :reply, ^server, ^request_ref, :ok}
    assert %{applied: 1, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: a wrong challenge clears its record and timer" do
    {:ok, server} = TestServer.start_link()
    reply_alias = :erlang.alias()
    request_ref = make_ref()
    caller_proof = client_proof_table()

    on_exit(fn ->
      delete_table(caller_proof)
      :erlang.unalias(reply_alias)
    end)

    send(
      server,
      {@protocol, :begin, self(), request_ref, reply_alias, caller_proof, :increment, 100}
    )

    assert_receive {@protocol, :challenge, ^server, ^request_ref, _challenge, transfer_ref}

    true =
      :ets.insert(
        caller_proof,
        {request_ref, :crypto.strong_rand_bytes(32), transfer_ref}
      )

    true =
      :ets.give_away(
        caller_proof,
        server,
        {@protocol, :proof, request_ref, transfer_ref}
      )

    assert_receive {@protocol, :reply, ^server, ^request_ref, {:error, :unauthorized}}
    assert %{applied: 0, pending: 0} = GenServer.call(server, :snapshot)

    Process.sleep(120)
    assert Process.alive?(server)
    assert %{applied: 0, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: random and deactivated reply references cannot crash the server" do
    {:ok, server} = TestServer.start_link()

    for reply_reference <- [make_ref(), deactivated_alias()] do
      request_ref = make_ref()
      caller_proof = client_proof_table()

      send(
        server,
        {@protocol, :begin, self(), request_ref, reply_reference, caller_proof, :increment, 100}
      )

      assert_receive {@protocol, :challenge, ^server, ^request_ref, challenge, transfer_ref}
      true = :ets.insert(caller_proof, {request_ref, challenge, transfer_ref})

      true =
        :ets.give_away(
          caller_proof,
          server,
          {@protocol, :proof, request_ref, transfer_ref}
        )

      assert eventually(fn -> GenServer.call(server, :snapshot).pending == 0 end)
      assert Process.alive?(server)
      delete_table(caller_proof)
    end

    assert %{applied: 2, pending: 0} = GenServer.call(server, :snapshot)
  end

  test "security regression: expiry removes custody and rejects a late replay" do
    {:ok, server} = TestServer.start_link()
    reply_alias = :erlang.alias()
    request_ref = make_ref()
    caller_proof = client_proof_table()

    on_exit(fn ->
      delete_table(caller_proof)
      :erlang.unalias(reply_alias)
    end)

    send(
      server,
      {@protocol, :begin, self(), request_ref, reply_alias, caller_proof, :increment, 20}
    )

    assert_receive {@protocol, :challenge, ^server, ^request_ref, challenge, transfer_ref}

    assert_receive {@protocol, :reply, ^server, ^request_ref,
                    {:error, :authenticated_call_timeout}},
                   500

    true = :ets.insert(caller_proof, {request_ref, challenge, transfer_ref})

    true =
      :ets.give_away(
        caller_proof,
        server,
        {@protocol, :proof, request_ref, transfer_ref}
      )

    Process.sleep(20)

    assert Process.alive?(server)
    assert eventually(fn -> :ets.info(caller_proof) == :undefined end)
    assert %{applied: 0, pending: 0} = GenServer.call(server, :snapshot)
  end

  defp deactivated_alias do
    alias_ref = :erlang.alias()
    true = :erlang.unalias(alias_ref)
    alias_ref
  end

  defp client_proof_table do
    :ets.new(__MODULE__, [:set, :private])
  end

  defp transferred_proof_table(new_owner) do
    table = client_proof_table()
    true = :ets.give_away(table, new_owner, :authenticated_call_test)
    assert :ets.info(table, :owner) == new_owner
    table
  end

  defp sensitive_idle_process do
    test_pid = self()

    pid =
      spawn(fn ->
        Process.flag(:sensitive, true)
        send(test_pid, {:sensitive_ready, self()})
        idle_loop()
      end)

    assert_receive {:sensitive_ready, ^pid}
    pid
  end

  defp idle_process, do: spawn(&idle_loop/0)

  defp idle_loop do
    receive do
      :stop -> :ok
    end
  end

  defp delete_table(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
