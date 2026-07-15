defmodule Arbor.Shell.ExecutionRegistryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.ExecutionRegistry

  test "register/get/list expose only redacted public projections" do
    {:ok, id} = ExecutionRegistry.register("echo test", sandbox: :strict, cwd: "/tmp")
    :ok = ExecutionRegistry.mark_running(id)

    result = %{exit_code: 0, pid: self(), nested: %{port: open_test_port()}}
    :ok = ExecutionRegistry.finish(id, result)

    assert {:ok, execution} = ExecutionRegistry.get(id)
    assert execution.id == id
    assert execution.status == :completed
    assert execution.terminal_source == :owner_published
    assert execution.result.pid == :redacted
    assert execution.result.nested.port == :redacted
    assert execution.sandbox == :strict
    assert execution.cwd == "/tmp"

    refute Map.has_key?(execution, :owner_pid)
    refute Map.has_key?(execution, :owner_ref)
    refute Map.has_key?(execution, :controller_pid)
    refute Map.has_key?(execution, :pid)
    refute Map.has_key?(execution, :port)

    assert {:ok, listed} = ExecutionRegistry.list(status: :completed)
    assert Enum.any?(listed, &(&1.id == id))
    refute contains_process_handle?(listed)
  end

  test "terminal_source is nil while pending/running and owner-published on finish/fail" do
    {:ok, pending_id} = ExecutionRegistry.register("echo pending")

    assert {:ok, %{status: :pending, terminal_source: nil, result: nil}} =
             ExecutionRegistry.get(pending_id)

    :ok = ExecutionRegistry.mark_running(pending_id)

    assert {:ok, %{status: :running, terminal_source: nil, result: nil}} =
             ExecutionRegistry.get(pending_id)

    :ok = ExecutionRegistry.finish(pending_id, %{exit_code: 0})

    assert {:ok, %{status: :completed, terminal_source: :owner_published}} =
             ExecutionRegistry.get(pending_id)

    {:ok, fail_id} = ExecutionRegistry.register("echo fail")
    :ok = ExecutionRegistry.mark_running(fail_id)
    :ok = ExecutionRegistry.fail(fail_id, :boom)

    assert {:ok, %{status: :failed, terminal_source: :owner_published, result: %{error: :boom}}} =
             ExecutionRegistry.get(fail_id)

    {:ok, killed_id} = ExecutionRegistry.register("echo killed")
    :ok = ExecutionRegistry.mark_running(killed_id)

    :ok =
      ExecutionRegistry.finish(killed_id, %{
        exit_code: 137,
        killed: true,
        cancelled: true,
        timed_out: false
      })

    assert {:ok, %{status: :killed, terminal_source: :owner_published}} =
             ExecutionRegistry.get(killed_id)

    {:ok, timeout_id} = ExecutionRegistry.register("echo timeout")
    :ok = ExecutionRegistry.mark_running(timeout_id)
    :ok = ExecutionRegistry.finish(timeout_id, %{exit_code: nil, timed_out: true, killed: false})

    assert {:ok, %{status: :timed_out, terminal_source: :owner_published}} =
             ExecutionRegistry.get(timeout_id)
  end

  test "security regression: foreign callers cannot forge lifecycle mutations" do
    {:ok, id} = ExecutionRegistry.register("sleep 5")

    foreign_results =
      Task.async(fn ->
        [
          ExecutionRegistry.mark_running(id),
          ExecutionRegistry.finish(id, %{exit_code: 0}),
          ExecutionRegistry.fail(id, :forged),
          ExecutionRegistry.adopt(id, self()),
          ExecutionRegistry.request_cancel(id)
        ]
      end)
      |> Task.await()

    assert foreign_results == [
             {:error, :owner_mismatch},
             {:error, :owner_mismatch},
             {:error, :owner_mismatch},
             {:error, :owner_mismatch},
             {:error, :not_owner}
           ]

    assert {:ok, %{status: :pending, result: nil}} = ExecutionRegistry.get(id)
  end

  test "security regression: raw GenServer mutation tuples cannot assert an owner or terminal result" do
    {:ok, id} = ExecutionRegistry.register("echo protected")
    registry = Process.whereis(ExecutionRegistry)
    parent = self()

    attacker =
      spawn(fn ->
        terminal = raw_call(registry, {:owner_finish, id, %{exit_code: 0}})
        asserted = raw_call(registry, {:attach_port, id, parent, :copyable_handle})
        transition = raw_call(registry, {:transition_status, id, [:pending], :completed, %{}})
        send(parent, {:raw_results, terminal, asserted, transition})
      end)

    assert is_pid(attacker)

    assert_receive {:raw_results, {:error, :invalid_caller},
                    {:error, :unsupported_registry_request},
                    {:error, :unsupported_registry_request}}

    alias_ref = Process.alias()

    send(
      registry,
      {:"$gen_call", {self(), [:alias | alias_ref]}, {:owner_finish, id, %{exit_code: 0}}}
    )

    Process.sleep(20)
    Process.unalias(alias_ref)
    assert {:ok, %{status: :pending, result: nil}} = ExecutionRegistry.get(id)
  end

  test "only the original controller can cancel an adopted execution" do
    {:ok, id} = ExecutionRegistry.register("sleep 5")
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:cancel_shell_execution, ^id} ->
            send(parent, :owner_cancelled)

            ExecutionRegistry.finish(id, %{
              exit_code: 137,
              killed: true,
              cancelled: true,
              timed_out: false
            })
        end
      end)

    assert :ok = ExecutionRegistry.adopt(id, owner)

    assert {:error, :not_owner} =
             Task.async(fn -> ExecutionRegistry.request_cancel(id) end) |> Task.await()

    refute_received :owner_cancelled

    assert :ok = ExecutionRegistry.request_cancel(id)
    assert_receive :owner_cancelled
    assert eventually?(fn -> match?({:ok, %{status: :killed}}, ExecutionRegistry.get(id)) end)
  end

  test "owner death makes a running entry terminal and cleanup remains bounded" do
    {:ok, id} = ExecutionRegistry.register("sleep 5")
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ok = ExecutionRegistry.adopt(id, owner)
    Process.exit(owner, :kill)

    assert eventually?(fn ->
             match?(
               {:ok, %{status: :failed, terminal_source: :owner_down}},
               ExecutionRegistry.get(id)
             )
           end)

    assert {:ok, %{terminal_source: :owner_down, result: %{error: error}}} =
             ExecutionRegistry.get(id)

    # sanitize_public projects nested tuples as lists; provenance is the contract.
    assert error == [:execution_owner_down, :killed] or
             match?({:execution_owner_down, _}, error)

    ExecutionRegistry.cleanup(0)
    assert eventually?(fn -> ExecutionRegistry.get(id) == {:error, :not_found} end)
  end

  test "controller cancel remains nil provenance; later owner death is owner_down" do
    {:ok, id} = ExecutionRegistry.register("sleep 5")
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:cancel_shell_execution, ^id} ->
            send(parent, :owner_saw_cancel)
            Process.sleep(:infinity)
        end
      end)

    :ok = ExecutionRegistry.adopt(id, owner)
    :ok = ExecutionRegistry.request_cancel(id)
    assert_receive :owner_saw_cancel

    assert {:ok, %{status: :cancelling, terminal_source: nil, completed_at: nil}} =
             ExecutionRegistry.get(id)

    Process.exit(owner, :kill)

    assert eventually?(fn ->
             match?(
               {:ok, %{status: :killed, terminal_source: :owner_down}},
               ExecutionRegistry.get(id)
             )
           end)

    assert {:ok, %{terminal_source: :owner_down, result: %{killed: true, cancelled: true}}} =
             ExecutionRegistry.get(id)
  end

  defp raw_call(registry, request) do
    ref = make_ref()
    send(registry, {:"$gen_call", {self(), ref}, request})

    receive do
      {^ref, reply} -> reply
    after
      500 -> :no_reply
    end
  end

  defp open_test_port do
    port = Port.open({:spawn_executable, ~c"/bin/cat"}, [:binary])
    Port.close(port)
    port
  end

  defp contains_process_handle?(value)
       when is_pid(value) or is_port(value) or is_reference(value),
       do: true

  defp contains_process_handle?(%DateTime{}), do: false

  defp contains_process_handle?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      contains_process_handle?(key) or contains_process_handle?(nested)
    end)
  end

  defp contains_process_handle?(value) when is_list(value),
    do: Enum.any?(value, &contains_process_handle?/1)

  defp contains_process_handle?(_value), do: false

  defp eventually?(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_eventually(fun, deadline)
    end
  end
end
