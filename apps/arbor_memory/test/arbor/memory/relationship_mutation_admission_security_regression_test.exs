defmodule Arbor.Memory.RelationshipMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for RelationshipStore caller-owned admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (row mutation and Signal/Event launch without a root), not a
  compile or setup failure.
  """

  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Config
  alias Arbor.Memory.Events
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Relationship
  alias Arbor.Memory.RelationshipStore
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.TestBootstrap.AdmissionBackend
  alias Arbor.Persistence

  @moduletag :integration
  @moduletag :database
  @moduletag packet: "VP-05D2C3I1B2D"
  @moduletag security_regression: true

  @fake_name :rel_sec_ma_fake
  @signal_absent_timeout 200

  setup do
    {:ok, cell} = Agent.start(fn -> %{subs: [], task: nil, rebound: false} end)

    on_exit(fn ->
      state =
        try do
          Agent.get(cell, & &1)
        catch
          :exit, _ -> %{subs: [], task: nil, rebound: false}
        end

      run_independently([
        {:unsubscribe, fn -> unsubscribe_all(state.subs) end},
        {:release_withheld, &release_withheld/0},
        {:release_sync, &release_fake_sync/0},
        {:stop_task, fn -> stop_live_task(state.task) end},
        {:restore_admission,
         fn ->
           if state.rebound, do: restore_bootstrap_admission(), else: :ok
         end},
        {:stop_fake, fn -> Fake.stop(@fake_name) end},
        {:stop_cell, fn -> stop_agent(cell) end}
      ])
    end)

    {:ok, cell: cell}
  end

  test "post-drain put/update/delete/touch are closed with unchanged rows", %{cell: _cell} do
    agent_id = unique_agent("direct")
    other_id = unique_agent("direct_open")

    put_row = seed_row(agent_id, "PutPeer")
    update_row = seed_row(agent_id, "UpdatePeer")
    delete_row = seed_row(agent_id, "DeletePeer")
    touch_row = seed_row(agent_id, "TouchPeer")
    _other_seed = seed_row(other_id, "OtherPeer")

    before = %{
      put: row_bytes!(agent_id, put_row.id),
      update: row_bytes!(agent_id, update_row.id),
      delete: row_bytes!(agent_id, delete_row.id),
      touch: row_bytes!(agent_id, touch_row.id)
    }

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    put_rel =
      put_row
      |> Relationship.from_map()
      |> Map.put(:relationship_dynamic, "drained-put")

    results = [
      RelationshipStore.put(agent_id, put_rel),
      RelationshipStore.update(agent_id, update_row.id, %{salience: 0.91}),
      RelationshipStore.delete(agent_id, delete_row.id),
      RelationshipStore.touch(agent_id, touch_row.id)
    ]

    assert results == [
             {:error, :store_unavailable},
             {:error, :store_unavailable},
             {:error, :store_unavailable},
             {:error, :store_unavailable}
           ]

    assert row_bytes!(agent_id, put_row.id) == before.put
    assert row_bytes!(agent_id, update_row.id) == before.update
    assert row_bytes!(agent_id, delete_row.id) == before.delete
    assert row_bytes!(agent_id, touch_row.id) == before.touch
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    other_rel = Relationship.new("WritablePeer")
    assert {:ok, saved} = RelationshipStore.put(other_id, other_rel)
    assert {:ok, fetched} = Persistence.fetch_relationship(other_id, saved.id)
    assert fetched.name == "WritablePeer"
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(other_id)
  end

  test "post-drain tracked reads are closed and emit no access signal", %{cell: cell} do
    agent_id = unique_agent("tracked")
    row = seed_row(agent_id, "TrackedPeer", %{salience: 0.95})
    before = Persistence.fetch_relationship(agent_id, row.id)
    before_bytes = row_bytes!(agent_id, row.id)
    remember(cell, :subs, subscribe!([:relationship_accessed]))

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    results = [
      RelationshipStore.get_with_tracking(agent_id, row.id),
      RelationshipStore.get_by_name_with_tracking(agent_id, "TrackedPeer"),
      RelationshipStore.get_primary_with_tracking(agent_id)
    ]

    assert results == [
             {:error, :store_unavailable},
             {:error, :store_unavailable},
             {:error, :store_unavailable}
           ]

    assert Persistence.fetch_relationship(agent_id, row.id) == before
    assert row_bytes!(agent_id, row.id) == before_bytes
    refute_receive {:sig, :relationship_accessed, _}, @signal_absent_timeout
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    assert {:ok, %Relationship{id: id}} = RelationshipStore.get(agent_id, row.id)
    assert id == row.id
    assert {:ok, %Relationship{name: "TrackedPeer"}} =
             RelationshipStore.get_by_name(agent_id, "TrackedPeer")

    assert {:ok, %Relationship{id: ^id}} = RelationshipStore.get_primary(agent_id)
    assert {:ok, [_]} = RelationshipStore.list(agent_id)
    assert {:ok, 1} = RelationshipStore.count(agent_id)
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    other_id = unique_agent("tracked_open")
    other_row = seed_row(other_id, "OpenTrackedPeer")
    caller_id = other_row.id
    assert {:ok, %Relationship{id: ^caller_id}} =
             RelationshipStore.get_with_tracking(other_id, caller_id)

    assert_receive {:sig, :relationship_accessed, accessed_sig}, 2_000
    assert accessed_sig.data.relationship_id == caller_id
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(other_id)
  end

  test "post-drain save and add-moment are closed while an open agent progresses", %{cell: cell} do
    agent_id = unique_agent("compound")
    other_id = unique_agent("compound_open")
    update_row = seed_row(agent_id, "SaveUpdatePeer")
    moment_row = seed_row(agent_id, "MomentPeer")
    other_update = seed_row(other_id, "OpenUpdatePeer")
    other_moment = seed_row(other_id, "OpenMomentPeer")

    before_update = row_bytes!(agent_id, update_row.id)
    before_moment = row_bytes!(agent_id, moment_row.id)
    before_created = event_ids(agent_id, :relationship_created)
    before_moments = event_ids(agent_id, :relationship_moment)

    remember(
      cell,
      :subs,
      subscribe!([:relationship_created, :relationship_updated, :moment_added])
    )

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    create_rel = Relationship.new("SaveCreatePeer")

    update_rel =
      update_row
      |> Relationship.from_map()
      |> Map.put(:relationship_dynamic, "drained-save")

    results = [
      RelationshipStore.save(agent_id, create_rel),
      RelationshipStore.save(agent_id, update_rel),
      RelationshipStore.add_moment(agent_id, moment_row.id, "drained moment")
    ]

    assert results == [
             {:error, :store_unavailable},
             {:error, :store_unavailable},
             {:error, :store_unavailable}
           ]

    assert {:error, :not_found} = Persistence.fetch_relationship(agent_id, create_rel.id)
    assert row_bytes!(agent_id, update_row.id) == before_update
    assert row_bytes!(agent_id, moment_row.id) == before_moment
    refute_receive {:sig, :relationship_created, _}, @signal_absent_timeout
    refute_receive {:sig, :relationship_updated, _}, @signal_absent_timeout
    refute_receive {:sig, :moment_added, _}, @signal_absent_timeout
    assert event_ids(agent_id, :relationship_created) == before_created
    assert event_ids(agent_id, :relationship_moment) == before_moments
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    other_create = Relationship.new("OpenCreatePeer")
    assert {:ok, created} = RelationshipStore.save(other_id, other_create)
    assert_receive {:sig, :relationship_created, created_sig}, 2_000
    assert created_sig.data.relationship_id == created.id
    assert event_ids(other_id, :relationship_created) != []

    other_update_rel =
      other_update
      |> Relationship.from_map()
      |> Map.put(:relationship_dynamic, "open-save")

    assert {:ok, updated} = RelationshipStore.save(other_id, other_update_rel)
    assert updated.relationship_dynamic == "open-save"
    assert_receive {:sig, :relationship_updated, _}, 2_000

    assert {:ok, with_moment} =
             RelationshipStore.add_moment(other_id, other_moment.id, "open moment")

    assert length(with_moment.key_moments) == 1
    assert_receive {:sig, :moment_added, _}, 2_000
    assert event_ids(other_id, :relationship_moment) != []
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(other_id)
  end

  test "save applies the row and parent effects only after acquire acknowledgement", %{
    cell: cell
  } do
    remember(cell, :rebound, true)
    bind_fake_admission!()
    remember(cell, :subs, subscribe!([:relationship_created]))

    agent_id = unique_agent("order")
    rel = Relationship.new("BarrierPeer")

    Fake.arm_withhold_cas_reply(@fake_name)

    task = Task.async(fn -> RelationshipStore.save(agent_id, rel) end)
    remember(cell, :task, task)
    mon = Process.monitor(task.pid)

    receive do
      {:cas_applied, _key, _ref, _stored} ->
        Process.demonitor(mon, [:flush])
        assert {:error, :not_found} = Persistence.fetch_relationship(agent_id, rel.id)
        refute_receive {:sig, :relationship_created, _}, @signal_absent_timeout

        Fake.arm_sync(@fake_name, [:cas], 1)
        Fake.release_withheld_cas_reply(@fake_name)

        assert {:ok, :cas, release_ref} = Fake.await_sync_arrival(2_000)
        assert {:ok, saved} = Persistence.fetch_relationship(agent_id, rel.id)
        assert saved.name == "BarrierPeer"
        assert_receive {:sig, :relationship_created, created_sig}, 2_000
        assert created_sig.data.relationship_id == rel.id
        assert event_ids(agent_id, :relationship_created) != []
        assert admission_root_count(agent_id) == 1

        Fake.release_sync(@fake_name, release_ref)
        assert {:ok, %Relationship{id: id}} = Task.await(task, 2_000)
        assert id == rel.id
        remember(cell, :task, nil)
        assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
        assert {:ok, _fence} = MutationAdmission.drain(agent_id)

      {:DOWN, ^mon, :process, _pid, reason} ->
        flunk(
          "operation completed before acquire ownership acknowledgement: #{inspect(reason)}"
        )
    after
      2_000 ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            flunk("operation completed before acquire barrier: #{inspect(result)}")

          nil ->
            flunk("timed out waiting for acquire CAS apply")
        end
    end
  end

  test "Persistence error under an admitted call releases the root without later effects", %{
    cell: cell
  } do
    agent_id = unique_agent("persist_err")
    remember(cell, :subs, subscribe!([:relationship_created]))
    before_created = event_ids(agent_id, :relationship_created)

    rel = %{Relationship.new("ok") | name: String.duplicate("n", 300)}
    result = RelationshipStore.save(agent_id, rel)

    assert {:error, :invalid_request} = result
    assert {:error, :not_found} = Persistence.fetch_relationship(agent_id, rel.id)
    refute_receive {:sig, :relationship_created, _}, @signal_absent_timeout
    assert event_ids(agent_id, :relationship_created) == before_created
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :not_found} = RelationshipStore.delete(agent_id, "rel_missing_delete")
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  test "delete_all and absence stay usable, exact-agent, and root-free after drain", %{
    cell: _cell
  } do
    agent_id = unique_agent("cleanup_a")
    other_id = unique_agent("cleanup_b")
    seed_row(agent_id, "CleanupA1")
    seed_row(agent_id, "CleanupA2")
    other_row = seed_row(other_id, "CleanupB1")

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, false} = Memory.relationships_absent?(agent_id)
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    assert :ok = Memory.delete_all_relationships(agent_id)
    assert :ok = Memory.delete_all_relationships(agent_id)
    assert {:ok, true} = Memory.relationships_absent?(agent_id)
    assert {:ok, still} = Persistence.fetch_relationship(other_id, other_row.id)
    assert still.id == other_row.id
    assert still.name == "CleanupB1"
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(other_id)
  end

  defp unique_agent(label), do: "rel_sec_#{label}_#{System.unique_integer([:positive])}"

  defp seed_row(agent_id, name, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      Map.merge(
        %{
          id: "rel_" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
          name: name,
          preferred_name: nil,
          background: [],
          values: [],
          connections: [],
          key_moments: [],
          relationship_dynamic: nil,
          personal_details: [],
          current_focus: [],
          uncertainties: [],
          first_encountered: now,
          last_interaction: now,
          salience: 0.5,
          access_count: 0
        },
        overrides
      )

    assert {:ok, plain} = Persistence.put_relationship(agent_id, attrs)
    plain
  end

  defp row_bytes!(agent_id, relationship_id) do
    assert {:ok, plain} = Persistence.fetch_relationship(agent_id, relationship_id)
    :erlang.term_to_binary(plain)
  end

  defp event_ids(agent_id, type) do
    assert {:ok, events} = Events.get_by_type(agent_id, type)
    events |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp subscribe!(types) do
    Enum.map(types, fn type ->
      tester = self()
      pattern = "memory." <> Atom.to_string(type)

      {:ok, sub_id} =
        Arbor.Signals.subscribe(pattern, fn signal ->
          send(tester, {:sig, type, signal})
        end)

      sub_id
    end)
  end

  defp unsubscribe_all(subs) when is_list(subs) do
    Enum.each(subs, fn sub_id ->
      try do
        _ = Arbor.Signals.unsubscribe(sub_id)
      catch
        :exit, _ -> :ok
      end
    end)
  end

  defp unsubscribe_all(_), do: :ok

  defp remember(cell, key, value) do
    Agent.update(cell, &Map.put(&1, key, value))
  end

  defp admission_root_count(agent_id) do
    key = Base.encode16(:crypto.hash(:sha256, agent_id), case: :lower)

    case Fake.peek(@fake_name, key) do
      %{data: data} when is_map(data) ->
        roots = Map.get(data, "roots") || Map.get(data, :roots) || %{}
        map_size(roots)

      _ ->
        0
    end
  end

  defp bind_fake_admission! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    case restart_admission(fake_admission_target()) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        flunk("MutationAdmission still running on the previous backend")

      {:error, reason} ->
        flunk("failed to start MutationAdmission: #{inspect(reason)}")
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp restore_bootstrap_admission do
    case restart_admission(bootstrap_admission_target()) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        raise "MutationAdmission still running on the previous backend"

      {:error, reason} ->
        raise "failed to restore bootstrap MutationAdmission: #{inspect(reason)}"
    end
  end

  defp bootstrap_admission_target do
    %{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: AdmissionBackend,
      opts: [agent_name: AdmissionBackend.name()]
    }
  end

  defp fake_admission_target do
    %{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: Fake,
      opts: [agent_name: @fake_name]
    }
  end

  defp restart_admission(target) do
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, MutationAdmission)

    case Supervisor.delete_child(Arbor.Memory.Supervisor, MutationAdmission) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} -> :ok
    end

    Supervisor.start_child(Arbor.Memory.Supervisor, {MutationAdmission, [target: target]})
  end

  defp release_withheld do
    case Process.whereis(@fake_name) do
      nil -> :ok
      _pid -> Fake.release_withheld_cas_reply(@fake_name)
    end
  catch
    :exit, _ -> :ok
  end

  defp release_fake_sync do
    case Process.whereis(@fake_name) do
      nil -> :ok
      _pid -> Fake.release_sync(@fake_name)
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_live_task(nil), do: :ok

  defp stop_live_task(%Task{pid: pid} = task) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
      _ = Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp stop_live_task(_), do: :ok

  defp stop_agent(cell) do
    try do
      Agent.stop(cell)
    catch
      :exit, _ -> :ok
    end
  end

  defp run_independently(steps) when is_list(steps) do
    case collect_cleanup_failures(steps) do
      [] -> :ok
      failures -> raise "cleanup failed: #{inspect(failures)}"
    end
  end

  defp collect_cleanup_failures(steps) when is_list(steps) do
    Enum.reduce(steps, [], fn {label, fun}, acc ->
      try do
        _ = fun.()
        acc
      rescue
        exception ->
          [{label, {:error, Exception.message(exception)}} | acc]
      catch
        kind, reason ->
          [{label, {kind, inspect(reason)}} | acc]
      end
    end)
    |> Enum.reverse()
  end
end
