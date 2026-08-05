defmodule Arbor.Memory.ProvenanceTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}
  alias Arbor.Memory.Provenance

  @table :arbor_memory_provenance

  setup do
    agent_id = "agent_provenance_#{System.unique_integer([:positive])}"
    :ok = Provenance.delete_agent(agent_id)
    on_exit(fn -> Provenance.delete_agent(agent_id) end)
    %{agent_id: agent_id}
  end

  test "stores and resolves exact payload provenance", %{agent_id: agent_id} do
    payload = %{"content" => "remember this", "score" => 0.8}
    taint = taint(:untrusted, "voice")

    assert :ok = Provenance.put(:goal, agent_id, "goal-1", payload, taint)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:goal, agent_id, "goal-1", payload)
  end

  test "intent status provenance is closed and bound to its exact payload", %{
    agent_id: agent_id
  } do
    payload = %{
      "intent_id" => "intent-1",
      "status" => "locked",
      "retry_count" => 0
    }

    taint = taint(:trusted, "intent_status")

    assert :intent_status in Provenance.allowed_domains()
    assert :ok = Provenance.put(:intent_status, agent_id, "intent-1", payload, taint)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:intent_status, agent_id, "intent-1", payload)

    assert_invalid(
      Provenance.resolve(
        :intent_status,
        agent_id,
        "intent-1",
        Map.put(payload, "last_failure_reason", "mutated")
      )
    )
  end

  test "overwriting replaces the payload binding and label", %{agent_id: agent_id} do
    old_payload = %{"content" => "old"}
    new_payload = %{"content" => "new"}
    old_taint = taint(:derived, "old")
    new_taint = taint(:hostile, "new")

    assert :ok = Provenance.put(:goal, agent_id, "goal-1", old_payload, old_taint)
    assert :ok = Provenance.put(:goal, agent_id, "goal-1", new_payload, new_taint)

    assert {:ok, ^new_taint, :verified} =
             Provenance.resolve(:goal, agent_id, "goal-1", new_payload)

    assert_invalid(Provenance.resolve(:goal, agent_id, "goal-1", old_payload))
  end

  test "security regression: caller payload mutation resolves as hostile", %{agent_id: agent_id} do
    payload = %{"content" => "original", "nested" => [1, 2, 3]}

    assert :ok =
             Provenance.put(:percept, agent_id, "percept-1", payload, taint(:trusted, "sensor"))

    assert_invalid(
      Provenance.resolve(
        :percept,
        agent_id,
        "percept-1",
        put_in(payload, ["nested"], [1, 2, 4])
      )
    )
  end

  test "malformed sidecar state resolves as hostile", %{agent_id: agent_id} do
    payload = %{"content" => "bound"}
    key = {:intent, agent_id, "intent-1"}

    assert :ok = Provenance.put(:intent, agent_id, "intent-1", payload, taint(:derived, "plan"))

    for malformed <- [%{"version" => 999}, :missing] do
      :sys.replace_state(Provenance, fn state ->
        true = :ets.insert(@table, {key, malformed})
        state
      end)

      assert_invalid(Provenance.resolve(:intent, agent_id, "intent-1", payload))
    end
  end

  test "the ETS table is protected from caller writes", %{agent_id: agent_id} do
    key = {:goal, agent_id, "goal-1"}

    assert_raise ArgumentError, fn ->
      :ets.insert(@table, {key, :forged})
    end

    assert_missing(Provenance.resolve(:goal, agent_id, "goal-1", %{"content" => "absent"}))
  end

  test "entry deletion is idempotent while the owner is running", %{agent_id: agent_id} do
    payload = %{"content" => "temporary"}

    assert :ok =
             Provenance.put(:goal, agent_id, "goal-1", payload, taint(:derived, "temporary"))

    assert :ok = Provenance.delete(:goal, agent_id, "goal-1")
    assert :ok = Provenance.delete(:goal, agent_id, "goal-1")
    assert_missing(Provenance.resolve(:goal, agent_id, "goal-1", payload))
  end

  test "missing state and a crash restart resolve conservatively", %{agent_id: agent_id} do
    payload = %{"content" => "ephemeral"}
    taint = taint(:trusted, "live")

    assert_missing(Provenance.resolve(:proposal, agent_id, "proposal-1", payload))
    assert :ok = Provenance.put(:proposal, agent_id, "proposal-1", payload, taint)

    old_pid = Process.whereis(Provenance)
    old_table = :ets.whereis(@table)
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    new_pid = wait_for_restart(old_pid)
    refute new_pid == old_pid
    refute :ets.whereis(@table) == old_table
    assert_missing(Provenance.resolve(:proposal, agent_id, "proposal-1", payload))
  end

  test "absent process and table keep reads and deletes conservative", %{agent_id: agent_id} do
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Provenance)

    on_exit(fn ->
      if Process.whereis(Provenance) == nil do
        Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
      end
    end)

    assert Process.whereis(Provenance) == nil
    assert :ets.whereis(@table) == :undefined
    assert_missing(Provenance.resolve(:goal, agent_id, "goal-1", %{"content" => "missing"}))

    assert {:error, :provenance_absent} =
             Provenance.put(
               :goal,
               agent_id,
               "goal-1",
               %{"content" => "missing"},
               taint(:untrusted, "missing")
             )

    assert :ok = Provenance.delete(:goal, agent_id, "goal-1")
    assert :ok = Provenance.delete_agent(agent_id)
    assert :ok = Provenance.delete_domain_agent(:goal, agent_id)

    assert {:ok, _pid} = Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance)
  end

  @tag timeout: 10_000
  test "security regression: blocked owner returns only after delete has a definitive outcome", %{
    agent_id: agent_id
  } do
    payload = %{"content" => "blocked-delete"}

    assert :ok =
             Provenance.put(:goal, agent_id, "blocked", payload, taint(:hostile, "blocked"))

    :ok = :sys.suspend(Provenance)

    on_exit(fn ->
      case Process.whereis(Provenance) do
        pid when is_pid(pid) ->
          if Process.alive?(pid), do: :sys.resume(pid)

        nil ->
          :ok
      end
    end)

    task = Task.async(fn -> Provenance.delete(:goal, agent_id, "blocked") end)
    Process.sleep(5_100)

    assert Task.yield(task, 0) == nil
    :ok = :sys.resume(Provenance)
    assert :ok = Task.await(task, 2_000)
    assert_missing(Provenance.resolve(:goal, agent_id, "blocked", payload))
  end

  test "accepts only closed domains and bounded binary identifiers", %{agent_id: agent_id} do
    payload = %{"content" => "bounded"}
    taint = taint(:untrusted, "input")

    assert :goal in Provenance.allowed_domains()
    assert :intent_status in Provenance.allowed_domains()
    assert :thinking_entry in Provenance.allowed_domains()
    assert :code_item in Provenance.allowed_domains()
    assert :self_knowledge in Provenance.allowed_domains()
    assert :working_memory_base in Provenance.allowed_domains()
    assert :working_memory_aggregate in Provenance.allowed_domains()
    assert :working_memory_concern in Provenance.allowed_domains()
    assert :working_memory_curiosity in Provenance.allowed_domains()

    assert :ok =
             Provenance.put(:working_memory_base, agent_id, "base", payload, taint)

    assert :ok =
             Provenance.put(:working_memory_aggregate, agent_id, "aggregate", payload, taint)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:working_memory_base, agent_id, "base", payload)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:working_memory_aggregate, agent_id, "aggregate", payload)

    assert {:error, :invalid_domain} = Provenance.put("goal", agent_id, "one", payload, taint)
    assert {:error, :invalid_domain} = Provenance.put(:unknown, agent_id, "one", payload, taint)
    assert {:error, :invalid_agent_id} = Provenance.put(:goal, " ", "one", payload, taint)

    assert {:error, :invalid_agent_id} =
             Provenance.put(:goal, :not_a_binary, "one", payload, taint)

    assert {:error, :invalid_agent_id} =
             Provenance.put(:goal, String.duplicate("a", 257), "one", payload, taint)

    assert {:error, :invalid_item_id} = Provenance.put(:goal, agent_id, <<255>>, payload, taint)

    assert {:error, :invalid_item_id} =
             Provenance.delete(:goal, agent_id, String.duplicate("i", 257))

    assert {:error, :invalid_domain} = Provenance.delete_domain_agent(:unknown, agent_id)

    assert {:error, :invalid_agent_id} =
             Provenance.delete_domain_agent(:goal, String.duplicate("a", 257))

    assert {:error, :invalid_agent_id} =
             Provenance.delete_agent(String.duplicate("a", 257))

    assert_invalid(Provenance.resolve(:unknown, agent_id, "one", payload))
  end

  test "domain-agent inventory and cleanup stay within the selected domain", %{
    agent_id: agent_id
  } do
    taint = taint(:untrusted, "inventory")

    assert :ok =
             Provenance.put(
               :working_memory_concern,
               agent_id,
               "concern-2",
               "second",
               taint
             )

    assert :ok =
             Provenance.put(
               :working_memory_concern,
               agent_id,
               "concern-1",
               "first",
               taint
             )

    assert :ok =
             Provenance.put(
               :working_memory_curiosity,
               agent_id,
               "curiosity-1",
               "question",
               taint
             )

    assert {:ok, ["concern-1", "concern-2"]} =
             Provenance.list_item_ids(:working_memory_concern, agent_id)

    assert :ok = Provenance.delete_domain_agent(:working_memory_concern, agent_id)
    assert {:ok, []} = Provenance.list_item_ids(:working_memory_concern, agent_id)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(
               :working_memory_curiosity,
               agent_id,
               "curiosity-1",
               "question"
             )
  end

  test "domain-agent capacity is enforced at insertion and recovers after delete", %{
    agent_id: agent_id
  } do
    label = taint(:untrusted, "capacity")

    for index <- 1..512 do
      assert :ok =
               Provenance.put(
                 :working_memory_concern,
                 agent_id,
                 "concern-#{index}",
                 %{"index" => index},
                 label
               )
    end

    assert {:error, :domain_inventory_limit_exceeded} =
             Provenance.put(
               :working_memory_concern,
               agent_id,
               "concern-overflow",
               %{"index" => 513},
               label
             )

    replacement = taint(:hostile, "replacement")

    assert :ok =
             Provenance.put(
               :working_memory_concern,
               agent_id,
               "concern-1",
               %{"index" => "replacement"},
               replacement
             )

    assert :ok =
             Provenance.put(
               :working_memory_curiosity,
               agent_id,
               "curiosity-cross-domain",
               %{"value" => "independent"},
               label
             )

    assert :ok = Provenance.delete(:working_memory_concern, agent_id, "concern-2")

    assert :ok =
             Provenance.put(
               :working_memory_concern,
               agent_id,
               "concern-after-delete",
               %{"index" => 514},
               label
             )

    assert {:ok, concern_ids} =
             Provenance.list_item_ids(:working_memory_concern, agent_id)

    assert length(concern_ids) == 512
    assert "concern-after-delete" in concern_ids
    refute "concern-2" in concern_ids

    assert {:ok, ["curiosity-cross-domain"]} =
             Provenance.list_item_ids(:working_memory_curiosity, agent_id)
  end

  test "owner-indexed list and delete ignore more than 512 entries owned elsewhere", %{
    agent_id: agent_id
  } do
    other_agent = "#{agent_id}_other"
    label = taint(:untrusted, "owner-index")

    on_exit(fn -> Provenance.delete_agent(other_agent) end)

    for index <- 1..512 do
      assert :ok =
               Provenance.put(
                 :working_memory_concern,
                 other_agent,
                 "other-concern-#{index}",
                 %{"index" => index},
                 label
               )
    end

    for index <- 1..8 do
      assert :ok =
               Provenance.put(
                 :working_memory_curiosity,
                 other_agent,
                 "other-curiosity-#{index}",
                 %{"index" => index},
                 label
               )
    end

    assert :ok = Provenance.put(:goal, agent_id, "small-1", %{"value" => 1}, label)
    assert :ok = Provenance.put(:goal, agent_id, "small-2", %{"value" => 2}, label)
    assert {:ok, ["small-1", "small-2"]} = Provenance.list_item_ids(:goal, agent_id)

    assert :ok = Provenance.delete_domain_agent(:goal, agent_id)
    assert {:ok, []} = Provenance.list_item_ids(:goal, agent_id)

    assert {:ok, concern_ids} =
             Provenance.list_item_ids(:working_memory_concern, other_agent)

    assert length(concern_ids) == 512

    assert {:ok, curiosity_ids} =
             Provenance.list_item_ids(:working_memory_curiosity, other_agent)

    assert length(curiosity_ids) == 8
  end

  test "rejects invalid payloads and labels before writing", %{agent_id: agent_id} do
    assert {:error, :unsupported_payload} =
             Provenance.put(:goal, agent_id, "bad-payload", self(), taint(:trusted, "local"))

    assert {:error, :invalid_taint_shape} =
             Provenance.put(:goal, agent_id, "bad-taint", %{"ok" => true}, %{level: :trusted})

    assert_missing(
      Provenance.resolve(:goal, agent_id, "bad-payload", %{"content" => "not written"})
    )

    assert_missing(Provenance.resolve(:goal, agent_id, "bad-taint", %{"ok" => true}))
  end

  test "domain-agent cleanup removes only the targeted closed domain and agent", %{
    agent_id: agent_a
  } do
    agent_b = "#{agent_a}_other"
    payload = %{"content" => "domain cleanup"}
    taint = taint(:hostile, "domain_cleanup")

    on_exit(fn -> Provenance.delete_agent(agent_b) end)

    assert :ok = Provenance.put(:intent, agent_a, "shared", payload, taint)
    assert :ok = Provenance.put(:percept, agent_a, "shared", payload, taint)
    assert :ok = Provenance.put(:intent, agent_b, "shared", payload, taint)

    assert :ok = Provenance.delete_domain_agent(:intent, agent_a)
    assert :ok = Provenance.delete_domain_agent(:intent, agent_a)

    assert_missing(Provenance.resolve(:intent, agent_a, "shared", payload))
    assert {:ok, ^taint, :verified} = Provenance.resolve(:percept, agent_a, "shared", payload)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:intent, agent_b, "shared", payload)
  end

  test "agent cleanup removes only the targeted agent", %{agent_id: agent_a} do
    agent_b = "#{agent_a}_other"
    payload = %{"content" => "shared"}
    status_payload = %{"intent_id" => "intent-1", "status" => "pending", "retry_count" => 0}
    taint = taint(:untrusted, "cleanup")

    on_exit(fn -> Arbor.Memory.cleanup_for_agent(agent_b) end)

    assert :ok = Provenance.put(:knowledge_node, agent_a, "node-1", payload, taint)
    assert :ok = Provenance.put(:knowledge_node, agent_b, "node-1", payload, taint)

    assert :ok =
             Provenance.put(:intent_status, agent_a, "intent-1", status_payload, taint)

    assert :ok =
             Provenance.put(:intent_status, agent_b, "intent-1", status_payload, taint)

    assert :ok = Arbor.Memory.cleanup_for_agent(agent_a)
    assert :ok = Provenance.delete_agent(agent_a)

    assert_missing(Provenance.resolve(:knowledge_node, agent_a, "node-1", payload))

    assert_missing(Provenance.resolve(:intent_status, agent_a, "intent-1", status_payload))

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:knowledge_node, agent_b, "node-1", payload)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:intent_status, agent_b, "intent-1", status_payload)
  end

  test "serializes concurrent writes without losing valid bindings", %{agent_id: agent_id} do
    writes =
      1..100
      |> Task.async_stream(
        fn index ->
          payload = %{"content" => "item-#{index}", "index" => index}
          taint = taint(:derived, "writer-#{index}")

          {index, payload, taint,
           Provenance.put(:index_entry, agent_id, "item-#{index}", payload, taint)}
        end,
        max_concurrency: 20,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(writes, fn {_index, _payload, _taint, result} -> result == :ok end)

    for {index, payload, taint, :ok} <- writes do
      assert {:ok, ^taint, :verified} =
               Provenance.resolve(:index_entry, agent_id, "item-#{index}", payload)
    end
  end

  defp taint(level, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: :restricted,
        sanitizations: 0,
        confidence: :unverified,
        source: source,
        chain: []
      })

    taint
  end

  defp assert_missing(result) do
    assert {:ok, taint, :legacy_unlabeled} = result
    assert taint == TaintEnvelope.missing_fallback()
  end

  defp assert_invalid(result) do
    assert {:ok, taint, :invalid_durable_provenance} = result
    assert taint == TaintEnvelope.invalid_fallback()
  end

  defp wait_for_restart(old_pid, attempts \\ 100)

  defp wait_for_restart(_old_pid, 0), do: flunk("provenance sidecar did not restart")

  defp wait_for_restart(old_pid, attempts) do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)
    end
  end
end
