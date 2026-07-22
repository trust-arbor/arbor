defmodule Arbor.AI.AcpManagedSessionInventoryTest do
  use ExUnit.Case, async: false

  alias Arbor.AI
  alias Arbor.AI.AcpManaged.SessionRegistry

  @moduletag :fast

  setup_all do
    previous_signal_start_children = Application.get_env(:arbor_signals, :start_children)
    previous_start_children = Application.get_env(:arbor_security, :start_children)

    _ = Application.stop(:arbor_security)
    _ = Application.stop(:arbor_signals)
    Application.put_env(:arbor_signals, :start_children, true)
    Application.put_env(:arbor_security, :start_children, true)

    on_exit(fn ->
      _ = Application.stop(:arbor_security)
      _ = Application.stop(:arbor_signals)
      Application.put_env(:arbor_signals, :start_children, previous_signal_start_children)
      Application.put_env(:arbor_security, :start_children, previous_start_children)
    end)

    {:ok, _started_signals} = Application.ensure_all_started(:arbor_signals)
    {:ok, _started} = Application.ensure_all_started(:arbor_security)

    {:ok, registry} = SessionRegistry.start_link([])
    on_exit(fn -> Process.exit(registry, :shutdown) end)

    :ok
  end

  test "pure projection is JSON-clean, sorted, bounded, and redacted" do
    live_session = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(live_session, :kill) end)

    entry = fn worker_id, provider_session_id, task_id ->
      %{
        worker_session_id: worker_id,
        session_pid: live_session,
        session_ref: make_ref(),
        session_module: __MODULE__,
        pool_module: nil,
        owner_pid: self(),
        owner_ref: make_ref(),
        provider: :test,
        model: "model",
        session_id: provider_session_id,
        status: "ready",
        pooled: false,
        return_to_pool: false,
        task_id: task_id,
        principal_id: "principal-a",
        options: %{secret: "redact"},
        prompt: "redact"
      }
    end

    state = %{
      sessions: %{
        "worker-b" => entry.("worker-b", "provider-b", "task-b"),
        "worker-a" => entry.("worker-a", "provider-a", "task-a"),
        "worker-duplicate" => entry.("worker-duplicate", "provider-a", "task-a"),
        "worker-malformed" => %{worker_session_id: "worker-malformed"}
      },
      closures: %{
        "worker-closing" => %{entry: entry.("worker-closing", "provider-c", "task-c")}
      },
      by_ref: %{}
    }

    inventory =
      SessionRegistry.inventory_projection(
        state,
        %{task_id: nil, principal_id: nil},
        2,
        %{
          "worker-a" => %{owner_present: true, owner_alive: true, session_alive: true},
          "worker-b" => %{owner_present: true, owner_alive: false, session_alive: true},
          "worker-closing" => %{owner_present: true, owner_alive: true, session_alive: true}
        }
      )

    assert match?({:ok, _}, Jason.encode(inventory))

    assert Enum.map(inventory["sessions"], & &1["worker_session_id"]) == [
             "worker-b",
             "worker-closing"
           ]

    assert inventory["sessions"] |> Enum.at(0) |> Map.fetch!("owner_alive") == false
    assert inventory["sessions"] |> Enum.at(1) |> Map.fetch!("close_cleanup_in_progress")
    assert inventory["counts"]["duplicates"] == 2
    assert inventory["counts"]["malformed"] == 1
    assert inventory["counts"]["quarantined"] == 3
    assert inventory["truncated"]
    refute contains_forbidden_term?(inventory)
    refute Enum.any?(inventory["sessions"], &Map.has_key?(&1, "options"))
  end

  test "security regression: inventory read is read-only and rejects forged selector messages" do
    before = :sys.get_state(SessionRegistry)

    assert {:error, :invalid_session_inventory_message} =
             GenServer.call(SessionRegistry, {:inventory, %{}, 10, __MODULE__})

    assert before == :sys.get_state(SessionRegistry)
    refute_received :evil_projection_executed
  end

  test "security regression: public inventory rejects missing caller and option injection" do
    assert {:error, :invalid_session_inventory_options} = AI.acp_managed_session_inventory([])

    for opts <- [
          [caller_id: "operator", server: self()],
          [caller_id: "operator", projection: __MODULE__],
          [caller_id: "operator", runner: fn -> :evil end],
          [{:caller_id, "operator"}, {:caller_id, "other"}],
          %{"caller_id" => "operator"},
          [caller_id: self()],
          [caller_id: "operator", max_items: 0]
        ] do
      assert {:error, :invalid_session_inventory_options} =
               AI.acp_managed_session_inventory(opts)
    end
  end

  test "security regression: no capability denies and scoped task capability cannot read unfiltered" do
    caller_id = "agent_inventory_#{System.unique_integer([:positive])}"

    assert {:error, {:unauthorized, :task_read_required}} =
             AI.acp_managed_session_inventory(caller_id: caller_id)

    {:ok, capability} =
      Arbor.Security.grant(
        principal: caller_id,
        resource: "arbor://agent/task/read/task-inventory-scope"
      )

    on_exit(fn -> Arbor.Security.revoke(capability.id) end)

    assert {:error, {:unauthorized, :task_read_required}} =
             AI.acp_managed_session_inventory(caller_id: caller_id, max_items: 1)
  end

  test "security regression: scoped capability returns only the exact task" do
    task_id = "task_inventory_#{System.unique_integer([:positive])}"
    other_task_id = "task_inventory_other_#{System.unique_integer([:positive])}"
    caller_id = "agent_inventory_scope_#{System.unique_integer([:positive])}"
    session_pids = for _ <- 1..2, do: spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn -> Enum.each(session_pids, &Process.exit(&1, :kill)) end)

    for {session_pid, registered_task_id} <- Enum.zip(session_pids, [task_id, other_task_id]) do
      assert {:ok, _meta} =
               SessionRegistry.register(%{
                 session_pid: session_pid,
                 provider: :test,
                 model: "model",
                 session_id: "provider-#{registered_task_id}",
                 status: "ready",
                 pooled: false,
                 return_to_pool: false,
                 task_id: registered_task_id,
                 principal_id: caller_id
               })
    end

    {:ok, capability} =
      Arbor.Security.grant(
        principal: caller_id,
        resource: "arbor://agent/task/read/#{task_id}"
      )

    on_exit(fn -> Arbor.Security.revoke(capability.id) end)

    assert {:ok, inventory} =
             AI.acp_managed_session_inventory(caller_id: caller_id, task_id: task_id)

    assert Enum.map(inventory["sessions"], & &1["task_id"]) == [task_id]

    assert {:error, {:unauthorized, :task_read_required}} =
             AI.acp_managed_session_inventory(caller_id: caller_id, task_id: other_task_id)
  end

  defp contains_forbidden_term?(term)
       when is_pid(term) or is_reference(term) or is_function(term),
       do: true

  defp contains_forbidden_term?(%_{} = struct),
    do: contains_forbidden_term?(Map.from_struct(struct))

  defp contains_forbidden_term?(map) when is_map(map),
    do:
      Enum.any?(map, fn {key, value} ->
        contains_forbidden_term?(key) or contains_forbidden_term?(value)
      end)

  defp contains_forbidden_term?(list) when is_list(list),
    do: Enum.any?(list, &contains_forbidden_term?/1)

  defp contains_forbidden_term?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> contains_forbidden_term?()

  defp contains_forbidden_term?(_term), do: false
end
