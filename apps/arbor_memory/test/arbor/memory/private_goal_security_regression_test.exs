Code.require_file(Path.expand("../../support/private_snapshot_fixture.ex", __DIR__))

defmodule Arbor.Memory.PrivateGoalSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory
  alias Arbor.Memory.{GoalStore, MemoryStore, MutationAdmission}
  alias Arbor.Memory.Test.PrivateSnapshotFixture, as: Fixture
  alias Arbor.Persistence
  alias Arbor.Security

  @moduletag :fast
  @moduletag :integration
  @store :arbor_memory_durable

  defmodule FaultBackend do
    alias Arbor.Memory.Test.PrivateSnapshotFixture.DiskBackend
    alias Arbor.Security.Store.JSONFile

    def put(key, value, opts), do: JSONFile.put(key, value, opts)
    def delete(key, opts), do: JSONFile.delete(key, opts)
    def list(opts), do: JSONFile.list(opts)
    def query(filter, opts), do: DiskBackend.query(filter, opts)

    def compare_and_delete(key, expected, opts),
      do: JSONFile.compare_and_delete(key, expected, opts)

    def durability_class(opts), do: JSONFile.durability_class(opts)

    def get(key, opts) do
      case Agent.get(__MODULE__, & &1) do
        :read_failure -> {:error, :unavailable}
        _ -> JSONFile.get(key, opts)
      end
    end

    def compare_and_swap(key, expected, replacement, opts) do
      case Agent.get(__MODULE__, & &1) do
        :conflict ->
          {:error, :conflict}

        :write_failure ->
          {:error, :unavailable}

        {:block_cas, observer} ->
          Agent.update(__MODULE__, fn _ -> :ok end)
          send(observer, {:private_cas_blocked, self()})

          receive do
            :continue_private_cas -> JSONFile.compare_and_swap(key, expected, replacement, opts)
          end

        _ ->
          JSONFile.compare_and_swap(key, expected, replacement, opts)
      end
    end
  end

  setup do
    start_supervised!(%{
      id: FaultBackend,
      start: {Agent, :start_link, [fn -> :ok end, [name: FaultBackend]]}
    })

    # The backend executes in the BufferedStore owner; the registered test
    # control avoids relying on the test process's mailbox or process dictionary.
    fixture = Fixture.start!(backend: FaultBackend)
    owner = Fixture.owner!()
    %{fixture: fixture, owner: owner, admission: Fixture.admission!(owner)}
  end

  test "private goal security regression: acknowledged goals survive cold storage and root restart but stay out of legacy readers",
       ctx do
    assert {:ok, "notebook"} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    original = stored!(ctx.owner)
    assert original.data["snapshot_revision"] == 1
    assert Memory.get_active_goals(ctx.owner.agent.agent_id) == []
    assert Memory.get_all_goals(ctx.owner.agent.agent_id) == []
    assert {:error, :not_found} = Memory.get_goal(ctx.owner.agent.agent_id, "notebook")
    assert :ok = Security.close_private_memory_admission(ctx.admission)

    Fixture.restart_store!(ctx.fixture)
    Fixture.restart_root!(ctx.fixture)

    fresh =
      Fixture.admission!(ctx.owner,
        engagement_id: "engagement-later",
        session_id: "session-later"
      )

    assert {:ok, [%{"id" => "notebook", "description" => "Complete the lunar field notebook"}]} =
             Memory.get_private_active_goals(fresh)

    assert stored!(ctx.owner) == original
    assert {:ok, section} = Memory.private_goal_context(fresh, "unknown-test-model")
    assert section =~ "Complete the lunar field notebook"
  end

  test "private goal security regression: same-agent other-human and forged scope never expose or update an owned snapshot",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    other = Fixture.owner!(ctx.owner.agent)
    other_admission = Fixture.admission!(other)
    assert {:ok, []} = Memory.get_private_active_goals(other_admission)

    assert {:error, _} =
             Memory.put_private_goal(
               other_admission,
               "notebook",
               Map.put(goal(), "human_id", ctx.owner.human.agent_id)
             )

    assert {:error, _} =
             Memory.get_private_active_goals(%{
               agent_id: ctx.owner.agent.agent_id,
               human_id: ctx.owner.human.agent_id
             })

    assert {:error, _} =
             Task.async(fn -> Memory.get_private_active_goals(ctx.admission) end) |> Task.await()

    assert {:ok, [%{"description" => "Complete the lunar field notebook"}]} =
             Memory.get_private_active_goals(ctx.admission)
  end

  test "private goal security regression: recomputed unkeyed provenance cannot forge the signed body or owner",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    original = stored!(ctx.owner)

    for mutate <- [
          fn body ->
            put_in(body, ["goals", Access.at(0), "description"], "offline replacement")
          end,
          fn body -> put_in(body, ["scope", "human_id"], "human_forged") end,
          fn body -> Map.put(body, "snapshot_revision", 999) end,
          fn body -> Map.put(body, "public", true) end
        ] do
      current = stored!(ctx.owner)

      assert {:ok, _} =
               MemoryStore.compare_and_swap_tainted(
                 "private_goals",
                 key(ctx.owner),
                 current,
                 mutate.(original.data),
                 taint: TaintEnvelope.missing_fallback()
               )

      assert {:error, _} = Memory.get_private_active_goals(ctx.admission)
    end
  end

  test "private goal security regression: moving a valid signed body to another pair's physical key fails",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    other = Fixture.owner!(ctx.owner.agent)
    body = stored!(ctx.owner).data

    assert {:ok, _} =
             MemoryStore.compare_and_swap_tainted("private_goals", key(other), :not_found, body,
               taint: TaintEnvelope.missing_fallback()
             )

    assert {:error, _} = Memory.get_private_active_goals(Fixture.admission!(other))
  end

  test "private goal security regression: an authentic body does not authorize a caller-selected public taint",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    original = stored!(ctx.owner)

    {:ok, weakened} =
      Arbor.Contracts.Security.Taint.new(%{
        level: :trusted,
        sensitivity: :public,
        sanitizations: 0,
        confidence: :unverified,
        source: nil,
        chain: []
      })

    assert {:ok, _} =
             MemoryStore.compare_and_swap_tainted(
               "private_goals",
               key(ctx.owner),
               original,
               original.data,
               taint: weakened
             )

    assert {:error, _} = Memory.get_private_active_goals(ctx.admission)
  end

  test "updates replace the one named goal, advance logical revision, and omit completed goals",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    revised = %{goal() | "description" => "Submit the lunar field notebook", "progress" => 0.75}
    assert {:ok, "notebook"} = Memory.put_private_goal(ctx.admission, "notebook", revised)
    assert stored!(ctx.owner).data["snapshot_revision"] == 2
    assert {:ok, [^revised]} = Memory.get_private_active_goals(ctx.admission) |> without_ids()

    assert {:ok, _} =
             Memory.put_private_goal(ctx.admission, "notebook", %{
               revised
               | "status" => "achieved"
             })

    assert {:ok, []} = Memory.get_private_active_goals(ctx.admission)
    assert length(stored!(ctx.owner).data["goals"]) == 1
  end

  test "private goal security regression: read and write revocation reject valid old admissions",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    original = stored!(ctx.owner)
    assert :ok = Security.revoke(ctx.owner.write_cap.id)

    assert {:error, _} =
             Memory.put_private_goal(ctx.admission, "notebook", goal("must not persist"))

    assert stored!(ctx.owner) == original
    assert :ok = Security.revoke(ctx.owner.read_cap.id)
    assert {:error, _} = Memory.get_private_active_goals(ctx.admission)
  end

  test "payload bounds and closed attributes reject before any snapshot mutation", ctx do
    for attrs <- [
          Map.put(goal(), "description", String.duplicate("x", 4097)),
          Map.put(goal(), "metadata", %{"owner" => "caller"}),
          Map.put(goal(), "priority", 101),
          Map.put(goal(), "progress", -1)
        ] do
      assert {:error, _} = Memory.put_private_goal(ctx.admission, "notebook", attrs)
    end

    assert {:error, :not_found} =
             Persistence.buffered_store_authoritative_get(@store, physical(ctx.owner))

    for index <- 1..50 do
      assert {:ok, _} = Memory.put_private_goal(ctx.admission, "goal-#{index}", goal())
    end

    original = stored!(ctx.owner)
    assert {:error, _} = Memory.put_private_goal(ctx.admission, "goal-51", goal())
    assert stored!(ctx.owner) == original
  end

  test "the total canonical payload cap applies even when every individual description fits",
       ctx do
    # JSON escaping expands each valid 4096-byte description to over 24KB.
    description = String.duplicate(<<0>>, 4096)

    for index <- 1..10 do
      assert {:ok, _} =
               Memory.put_private_goal(ctx.admission, "escaped-#{index}", goal(description))
    end

    original = stored!(ctx.owner)
    assert {:error, _} = Memory.put_private_goal(ctx.admission, "escaped-11", goal(description))
    assert stored!(ctx.owner) == original
  end

  test "storage failures and conflicts cannot claim success or fall back to a warm snapshot",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    original = stored!(ctx.owner)
    Agent.update(FaultBackend, fn _ -> :conflict end)
    assert {:error, _} = Memory.put_private_goal(ctx.admission, "notebook", goal("conflicting"))
    Agent.update(FaultBackend, fn _ -> :write_failure end)

    assert {:error, :outcome_unknown} =
             Memory.put_private_goal(ctx.admission, "notebook", goal("unacknowledged"))

    Agent.update(FaultBackend, fn _ -> :read_failure end)
    assert {:error, _} = Memory.get_private_active_goals(ctx.admission)
    Agent.update(FaultBackend, fn _ -> :ok end)
    assert stored!(ctx.owner) == original
  end

  test "a fresh signed snapshot remains valid after backend delete and reinsert changes its physical incarnation",
       ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    first = stored!(ctx.owner)
    # Fixture-owned storage intervention preserves the backend tombstone. This
    # is not a request to revive an agent whose mutation gate is destroyed.
    assert :ok =
             Persistence.buffered_store_acknowledged_compare_and_delete(@store, first.key, first)

    assert {:ok, _} =
             Memory.put_private_goal(ctx.admission, "notebook", goal("Fresh incarnation"))

    next = stored!(ctx.owner)
    assert next.generation > first.generation
    assert next.data["snapshot_revision"] == 1

    assert {:ok, [%{"description" => "Fresh incarnation"}]} =
             Memory.get_private_active_goals(ctx.admission)
  end

  test "private goal destruction includes all verified pairs of the drained agent and preserves another agent",
       ctx do
    same_agent = Fixture.owner!(ctx.owner.agent)
    other_agent = Fixture.owner!()

    for {owner, admission} <- [
          {ctx.owner, ctx.admission},
          {same_agent, Fixture.admission!(same_agent)},
          {other_agent, Fixture.admission!(other_agent)}
        ] do
      assert {:ok, _} = Memory.put_private_goal(admission, "goal", goal(owner.human.agent_id))
    end

    assert {:ok, false} = GoalStore.agent_content_absent?(ctx.owner.agent.agent_id)
    assert {:ok, _fence} = MutationAdmission.drain(ctx.owner.agent.agent_id)
    assert :ok = GoalStore.delete_agent_content(ctx.owner.agent.agent_id)
    assert {:ok, true} = GoalStore.agent_content_absent?(ctx.owner.agent.agent_id)
    assert {:ok, [_]} = Memory.get_private_active_goals(Fixture.admission!(other_agent))
    assert {:error, _} = Memory.put_private_goal(ctx.admission, "new", goal())
  end

  test "destruction refuses malformed private inventory before deleting verified rows", ctx do
    assert {:ok, _} = Memory.put_private_goal(ctx.admission, "notebook", goal())
    other = Fixture.owner!()

    assert {:ok, _} =
             MemoryStore.compare_and_swap_tainted(
               "private_goals",
               key(other),
               :not_found,
               %{"scope" => %{"agent_id" => other.agent.agent_id}},
               taint: TaintEnvelope.missing_fallback()
             )

    original = stored!(ctx.owner)
    assert {:ok, _} = MutationAdmission.drain(ctx.owner.agent.agent_id)
    assert {:error, _} = GoalStore.delete_agent_content(ctx.owner.agent.agent_id)
    assert {:error, _} = GoalStore.agent_content_absent?(ctx.owner.agent.agent_id)
    assert stored!(ctx.owner) == original
  end

  test "private goal destruction orders behind an already submitted CAS even when its admitted caller dies",
       ctx do
    # Capture the test PID, not the Agent process executing its update callback.
    observer = self()
    Agent.update(FaultBackend, fn _ -> {:block_cas, observer} end)

    writer =
      spawn(fn ->
        admission = Fixture.admission!(ctx.owner)
        Memory.put_private_goal(admission, "orphan-check", goal())
      end)

    assert_receive {:private_cas_blocked, store}, 5_000

    try do
      monitor = Process.monitor(writer)
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^writer, _}, 5_000

      cleanup =
        Task.async(fn ->
          assert {:ok, _} = MutationAdmission.drain(ctx.owner.agent.agent_id)
          GoalStore.delete_agent_content(ctx.owner.agent.agent_id)
        end)

      ref = cleanup.ref
      refute_receive {^ref, _}, 30
      send(store, :continue_private_cas)
      assert :ok = Task.await(cleanup, 10_000)
      assert {:ok, true} = GoalStore.agent_content_absent?(ctx.owner.agent.agent_id)
    after
      send(store, :continue_private_cas)
      if Process.alive?(writer), do: Process.exit(writer, :kill)
    end
  end

  defp without_ids({:ok, goals}), do: {:ok, Enum.map(goals, &Map.delete(&1, "id"))}

  defp goal(description \\ "Complete the lunar field notebook"),
    do: %{
      "description" => description,
      "priority" => 70,
      "progress" => 0.25,
      "status" => "active"
    }

  defp physical(owner), do: "private_goals:" <> key(owner)

  defp key(owner) do
    {:ok, bytes} = TaintEnvelope.canonical_json([owner.agent.agent_id, owner.human.agent_id])
    Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp stored!(owner) do
    assert {:ok, record} = Persistence.buffered_store_authoritative_get(@store, physical(owner))
    record
  end
end
