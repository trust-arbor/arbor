defmodule Arbor.Memory.MutationAdmissionConcurrencyTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.DrainFence
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1A"

  setup do
    agent_name = :"ma_cc_fake_#{System.unique_integer([:positive])}"
    {:ok, _} = Fake.start_link(agent_name: agent_name)

    # Same-BEAM authorities must share one runtime_fp. Distinct injected fps would
    # let authority 2 classify authority 1's live root as prior-runtime and
    # reconcile it away (unsafe; also made acquire+fence look legal).
    runtime_fp =
      Base.encode16(:crypto.hash(:sha256, "cc-shared-rt-#{agent_name}"), case: :lower)

    node_fp =
      Base.encode16(:crypto.hash(:sha256, "cc-shared-node-#{agent_name}"), case: :lower)

    servers =
      for i <- 1..2 do
        registry = :"ma_cc_reg_#{i}_#{System.unique_integer([:positive])}"
        sup = :"ma_cc_sup_#{i}_#{System.unique_integer([:positive])}"
        server = :"ma_cc_srv_#{i}_#{System.unique_integer([:positive])}"

        start_supervised!({Registry, keys: :unique, name: registry},
          id: {:ma_cc_reg, i, registry}
        )

        start_supervised!(%{
          id: {:ma_cc_gsup, i, sup},
          start:
            {DynamicSupervisor, :start_link,
             [[name: sup, strategy: :one_for_one, max_children: 4096]]}
        })

        # Explicit unique ExUnit child id — production child_spec id stays the module.
        start_supervised!(
          {MutationAdmission,
           [
             name: server,
             registry: registry,
             guardian_supervisor: sup,
             target: %{
               namespace: :memory_mutation_admission,
               backend: Fake,
               opts: [agent_name: agent_name]
             },
             runtime_fp: runtime_fp,
             node_fp: node_fp
           ]},
          id: {:ma_cc_shell, i, server}
        )

        %{server: server, registry: registry, sup: sup}
      end

    on_exit(fn -> Fake.stop(agent_name) end)

    {:ok, servers: servers, agent_name: agent_name, runtime_fp: runtime_fp, node_fp: node_fp}
  end

  defp s1(ctx), do: hd(ctx.servers).server
  defp s2(ctx), do: Enum.at(ctx.servers, 1).server

  defp storage_key(agent),
    do: Base.encode16(:crypto.hash(:sha256, agent), case: :lower)

  # ---------------------------------------------------------------------------
  # Two-authority proofs — shared-snapshot barrier, winner-completion first
  # ---------------------------------------------------------------------------

  defp successful_cas(agent_name, key) do
    agent_name
    |> Fake.history()
    |> Enum.filter(fn op ->
      op.kind == :compare_and_swap and op.key == key and is_map(op.record)
    end)
  end

  defp cas_data(op), do: op.record.data

  # Dedicated acquire holder: stays alive until test releases it (Task would exit).
  defp spawn_acquire_holder(agent, server) do
    parent = self()

    spawn(fn ->
      result = MutationAdmission.acquire(agent, server: server)
      send(parent, {:acquire_result, self(), result})

      receive do
        :release_and_exit ->
          case result do
            {:ok, lease} -> _ = MutationAdmission.release(lease, server: server)
            _ -> :ok
          end

        :exit ->
          :ok
      end
    end)
  end

  @tag packet: "VP-05D2C3I1A"
  test "acquire versus drain: shared-snapshot acquire-first exact outcome", ctx do
    agent = "cc_a_acq_wins"
    key = storage_key(agent)
    Fake.clear_history(ctx.agent_name)
    Fake.arm_sync(ctx.agent_name, [:cas], 2)

    # Park acquire pre-CAS first, then drain, while durable revision unchanged.
    holder = spawn_acquire_holder(agent, s1(ctx))
    assert {:ok, :cas, ref_acq} = Fake.await_sync_arrival(2_000)
    assert Fake.peek(ctx.agent_name, key) == nil

    drain_task =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)
      end)

    assert {:ok, :cas, ref_drn} = Fake.await_sync_arrival(2_000)
    assert Fake.peek(ctx.agent_name, key) == nil

    # Winner-completion barrier: wake acquire only; await public Lease while holder lives.
    Fake.release_sync(ctx.agent_name, ref_acq)

    assert_receive {:acquire_result, ^holder, {:ok, %Lease{}}}, 3_000
    assert Process.alive?(holder)

    stored_mid = Fake.peek(ctx.agent_name, key)
    assert stored_mid.data["gate"] == "open"
    assert map_size(stored_mid.data["roots"]) == 1
    assert stored_mid.data["fence_gen"] == 0
    assert stored_mid.data["fence_hash"] == nil

    mid_ops = successful_cas(ctx.agent_name, key)
    assert length(mid_ops) == 1
    assert cas_data(hd(mid_ops))["gate"] == "open"
    assert map_size(cas_data(hd(mid_ops))["roots"]) == 1
    assert cas_data(hd(mid_ops))["fence_hash"] == nil

    # Only then wake drain loser.
    Fake.release_sync(ctx.agent_name, ref_drn)
    assert {:error, :drain_timeout} = Task.await(drain_task, 3_000)

    # Pre-cleanup exact history: acquire root + begin_drain; no fence CAS yet.
    success = successful_cas(ctx.agent_name, key)
    assert length(success) == 2

    [w1, w2] = success
    assert cas_data(w1)["gate"] == "open"
    assert map_size(cas_data(w1)["roots"]) == 1
    assert cas_data(w1)["fence_gen"] == 0
    assert cas_data(w1)["fence_hash"] == nil

    assert cas_data(w2)["gate"] == "draining"
    assert map_size(cas_data(w2)["roots"]) == 1
    assert cas_data(w2)["fence_gen"] == 0
    assert cas_data(w2)["fence_hash"] == nil

    assert {:ok, %{gate: :draining, active_roots: 1}} =
             MutationAdmission.status(agent, server: s1(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 1
    assert stored.data["fence_gen"] == 0
    assert stored.data["fence_hash"] == nil

    # Cleanup after pre-cleanup proofs (holder still owned the lease).
    send(holder, :release_and_exit)
    href = Process.monitor(holder)
    assert_receive {:DOWN, ^href, :process, ^holder, _}, 3_000

    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
  end

  @tag packet: "VP-05D2C3I1A"
  test "acquire versus drain: shared-snapshot drain-first exact outcome", ctx do
    agent = "cc_a_drn_first"
    key = storage_key(agent)
    Fake.clear_history(ctx.agent_name)
    Fake.arm_sync(ctx.agent_name, [:cas], 2)

    # Park drain pre-CAS first, then acquire, while durable revision unchanged.
    drain_task =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 2_000)
      end)

    assert {:ok, :cas, ref_drn} = Fake.await_sync_arrival(2_000)
    assert Fake.peek(ctx.agent_name, key) == nil

    holder = spawn_acquire_holder(agent, s1(ctx))
    assert {:ok, :cas, ref_acq} = Fake.await_sync_arrival(2_000)
    assert Fake.peek(ctx.agent_name, key) == nil

    # Winner-completion: wake drain only; await public fence before waking acquire.
    Fake.release_sync(ctx.agent_name, ref_drn)
    assert {:ok, %DrainFence{} = fence} = Task.await(drain_task, 3_000)

    # Exact begin_drain/fence writes before acquire is unparked.
    pre_acq = successful_cas(ctx.agent_name, key)
    assert length(pre_acq) == 2

    [d1, d2] = pre_acq
    # First write opens-as-draining or begins drain with zero roots, no fence yet
    # or already fenced on second write. Empty-agent path: insert draining then fence.
    assert cas_data(d1)["gate"] == "draining"
    assert map_size(cas_data(d1)["roots"]) == 0
    assert cas_data(d1)["fence_hash"] == nil
    assert cas_data(d1)["fence_gen"] == 0

    assert cas_data(d2)["gate"] == "draining"
    assert map_size(cas_data(d2)["roots"]) == 0
    assert cas_data(d2)["fence_gen"] == 1
    assert is_binary(cas_data(d2)["fence_hash"])

    stored_mid = Fake.peek(ctx.agent_name, key)
    assert stored_mid.data["gate"] == "draining"
    assert map_size(stored_mid.data["roots"]) == 0
    assert stored_mid.data["fence_gen"] == 1
    assert is_binary(stored_mid.data["fence_hash"])

    # Only then wake acquire loser.
    Fake.release_sync(ctx.agent_name, ref_acq)
    assert_receive {:acquire_result, ^holder, {:error, :draining}}, 3_000

    assert {:ok, %{gate: :draining, active_roots: 0}} =
             MutationAdmission.status(agent, server: s1(ctx))

    # No acquire root ever admitted.
    success = successful_cas(ctx.agent_name, key)
    assert length(success) == 2
    assert Enum.all?(success, fn op -> map_size(cas_data(op)["roots"]) == 0 end)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
    assert {:error, :destroyed} = MutationAdmission.acquire(agent, server: s1(ctx))
    send(holder, :exit)
  end

  @tag packet: "VP-05D2C3I1A"
  test "release versus fence: barrier-directed exact fence after zero roots", ctx do
    agent = "cc_b"
    key = storage_key(agent)
    parent = self()

    # Live holder for the lease (must not exit before release).
    holder =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: s1(ctx))
        send(parent, {:lease, self(), lease})

        receive do
          :release ->
            assert :ok = MutationAdmission.release(lease, server: s1(ctx))
            send(parent, :released)

            receive do
              :exit -> :ok
            end
        end
      end)

    assert_receive {:lease, ^holder, %Lease{} = _lease}, 2_000
    Fake.clear_history(ctx.agent_name)

    # Park drain's first CAS (begin_drain) so release can clear the root first.
    Fake.arm_sync(ctx.agent_name, [:cas], 1)

    t_drain =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 2_000)
      end)

    assert {:ok, :cas, ref_drn} = Fake.await_sync_arrival(2_000)
    # Root still present while drain is parked pre-CAS.
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent, server: s1(ctx))

    send(holder, :release)
    assert_receive :released, 2_000

    assert {:ok, %{active_roots: 0, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    Fake.release_sync(ctx.agent_name, ref_drn)

    assert {:ok, %DrainFence{} = fence} = Task.await(t_drain, 3_000)

    assert {:ok, %{active_roots: 0, gate: :draining}} =
             MutationAdmission.status(agent, server: s2(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 0
    assert stored.data["fence_gen"] == 1
    assert is_binary(stored.data["fence_hash"])

    success = successful_cas(ctx.agent_name, key)
    # release (roots empty, open) + begin_drain + fence — exact shapes.
    assert length(success) == 3

    [r1, r2, r3] = success
    assert map_size(cas_data(r1)["roots"]) == 0
    assert cas_data(r1)["gate"] == "open"
    assert cas_data(r1)["fence_hash"] == nil

    assert cas_data(r2)["gate"] == "draining"
    assert map_size(cas_data(r2)["roots"]) == 0
    assert cas_data(r2)["fence_hash"] == nil

    assert cas_data(r3)["gate"] == "draining"
    assert map_size(cas_data(r3)["roots"]) == 0
    assert cas_data(r3)["fence_gen"] == 1
    assert is_binary(cas_data(r3)["fence_hash"])

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s1(ctx))
    send(holder, :exit)
  end

  @tag packet: "VP-05D2C3I1A"
  test "handoff versus holder death: barrier-directed source death exact release", ctx do
    agent = "cc_handoff_death"
    key = storage_key(agent)
    parent = self()

    source_pid =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: s1(ctx))
        send(parent, {:lease, lease, self()})

        receive do
          {:handoff_to, target} ->
            result = MutationAdmission.handoff(lease, target, server: s1(ctx))
            send(parent, {:handoff_result, result})

            receive do
              :done -> :ok
            end
        end
      end)

    assert_receive {:lease, _lease, ^source_pid}, 1_000

    target =
      spawn(fn ->
        receive do
          :block -> :ok
        end
      end)

    Fake.clear_history(ctx.agent_name)
    # Park handoff transfer CAS after begin_handoff installs monitors.
    Fake.arm_sync(ctx.agent_name, [:cas], 1)
    send(source_pid, {:handoff_to, target})
    assert {:ok, :cas, ref_ho} = Fake.await_sync_arrival(2_000)

    # Source dies while transfer CAS is parked — durable release path wins.
    Process.exit(source_pid, :kill)
    sref = Process.monitor(source_pid)
    assert_receive {:DOWN, ^sref, :process, ^source_pid, _}, 1_000
    Fake.release_sync(ctx.agent_name, ref_ho)

    # Directed outcome: source death during handoff → root released (0 roots).
    assert wait_roots_zero(s1(ctx), agent)

    assert {:ok, %{active_roots: 0, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert map_size(stored.data["roots"]) == 0

    success = successful_cas(ctx.agent_name, key)
    # Final durable empty roots must appear as an exact successful write.
    assert success != []
    assert map_size(cas_data(List.last(success))["roots"]) == 0
    assert Enum.count(success, fn op -> map_size(cas_data(op)["roots"]) == 0 end) == 1

    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
    Process.exit(target, :kill)
  end

  @tag packet: "VP-05D2C3I1A"
  test "CAS conflict retry never drops a concurrent root", ctx do
    agent = "cc_cas_roots"
    parent = self()

    h1 =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: s1(ctx))
        send(parent, {:l1, self(), lease})

        receive do
          :rel ->
            assert :ok = MutationAdmission.release(lease, server: s1(ctx))
            send(parent, :r1)
        end
      end)

    assert_receive {:l1, ^h1, _}, 2_000
    Fake.set_conflict_count(ctx.agent_name, 1)

    h2 =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: s2(ctx))
        send(parent, {:l2, self(), lease})

        receive do
          :rel ->
            assert :ok = MutationAdmission.release(lease, server: s2(ctx))
            send(parent, :r2)
        end
      end)

    assert_receive {:l2, ^h2, _}, 2_000

    assert {:ok, %{active_roots: 2, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    send(h1, :rel)
    send(h2, :rel)
    assert_receive :r1, 2_000
    assert_receive :r2, 2_000
    assert wait_roots_zero(s1(ctx), agent)
  end

  @tag packet: "VP-05D2C3I1A"
  test "cross-authority release notifies peer drain waiters before deadline", ctx do
    agent = "cc_cross_drain"
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: s1(ctx))
        send(parent, {:ready, self(), lease})

        receive do
          :rel ->
            assert :ok = MutationAdmission.release(lease, server: s1(ctx))
            send(parent, :released)
        end
      end)

    assert_receive {:ready, ^holder, _lease}, 2_000

    # Park drain begin_drain CAS, then release root, then unpark so drain sees zero.
    Fake.arm_sync(ctx.agent_name, [:cas], 1)

    drain_task =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 2_000)
      end)

    assert {:ok, :cas, ref_drn} = Fake.await_sync_arrival(2_000)
    send(holder, :rel)
    assert_receive :released, 2_000
    Fake.release_sync(ctx.agent_name, ref_drn)

    assert {:ok, %DrainFence{} = fence} = Task.await(drain_task, 3_000)

    assert {:ok, %{active_roots: 0, gate: :draining}} =
             MutationAdmission.status(agent, server: s2(ctx))

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
  end

  # Only used for asynchronous guardian release settlement — not race direction.
  defp wait_roots_zero(server, agent, attempts \\ 50) do
    case MutationAdmission.status(agent, server: server) do
      {:ok, %{active_roots: 0}} ->
        true

      _ when attempts > 0 ->
        receive do
        after
          20 -> :ok
        end

        wait_roots_zero(server, agent, attempts - 1)

      _ ->
        flunk("roots did not reach zero for #{inspect(agent)}")
    end
  end
end
