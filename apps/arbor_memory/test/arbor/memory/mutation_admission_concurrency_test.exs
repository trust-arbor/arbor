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

  defp cas_ops(agent_name, key) do
    agent_name
    |> Fake.history()
    |> Enum.filter(&(&1.kind == :compare_and_swap and &1.key == key))
  end

  # ---------------------------------------------------------------------------
  # Three required two-authority proofs — barrier-directed, exact outcomes only
  # ---------------------------------------------------------------------------

  @tag packet: "VP-05D2C3I1A"
  test "acquire versus drain: directed acquire-wins exact outcome", ctx do
    agent = "cc_a_acq_wins"
    key = storage_key(agent)
    Fake.clear_history(ctx.agent_name)

    # Directed: s1 acquires first (no race). Then s2 drain must wait / timeout
    # while the durable root remains.
    assert {:ok, %Lease{} = lease} = MutationAdmission.acquire(agent, server: s1(ctx))

    assert {:ok, %{gate: :open, active_roots: 1}} =
             MutationAdmission.status(agent, server: s2(ctx))

    assert {:error, :drain_timeout} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 80)

    assert {:ok, %{gate: :draining, active_roots: 1}} =
             MutationAdmission.status(agent, server: s1(ctx))

    # Exact durable state: one root, draining, no fence issued yet.
    stored = Fake.peek(ctx.agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 1
    assert stored.data["fence_gen"] == 0
    assert stored.data["fence_hash"] == nil

    # CAS history includes acquire + begin_drain; no fence-issuance CAS yet.
    ops = cas_ops(ctx.agent_name, key)
    assert length(ops) >= 2

    refute Enum.any?(ops, fn op ->
             is_map(op.record) and is_binary(op.record.data["fence_hash"])
           end)

    # No fence token was returned; release then fence on the peer.
    assert :ok = MutationAdmission.release(lease, server: s1(ctx))

    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
  end

  @tag packet: "VP-05D2C3I1A"
  test "acquire versus drain: directed drain-first exact outcome", ctx do
    agent = "cc_a_drn_first"
    key = storage_key(agent)
    Fake.clear_history(ctx.agent_name)

    # Directed: s2 drains empty agent first → fence issued. s1 acquire rejected.
    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)

    assert {:error, :draining} = MutationAdmission.acquire(agent, server: s1(ctx))

    assert {:ok, %{gate: :draining, active_roots: 0}} =
             MutationAdmission.status(agent, server: s1(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 0
    assert stored.data["fence_gen"] >= 1
    assert is_binary(stored.data["fence_hash"])

    ops = cas_ops(ctx.agent_name, key)
    # begin_drain (or insert+drain) and fence issuance; no successful acquire root.
    assert Enum.any?(ops, fn op ->
             is_map(op.record) and is_binary(op.record.data["fence_hash"]) and
               op.record.data["fence_gen"] >= 1
           end)

    refute Enum.any?(ops, fn op ->
             is_map(op.record) and map_size(op.record.data["roots"] || %{}) > 0
           end)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
    assert {:error, :destroyed} = MutationAdmission.acquire(agent, server: s1(ctx))
  end

  @tag packet: "VP-05D2C3I1A"
  test "release versus fence: barrier-directed exact fence after zero roots", ctx do
    agent = "cc_b"
    key = storage_key(agent)

    assert {:ok, %Lease{} = lease} = MutationAdmission.acquire(agent, server: s1(ctx))
    Fake.clear_history(ctx.agent_name)

    # Park drain's first CAS (begin_drain) so release can clear the root first.
    Fake.arm_sync(ctx.agent_name, [:cas], 1)

    t_drain =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 2_000)
      end)

    assert :ok = Fake.await_sync(1, 2_000)
    # Root still present while drain is parked pre-CAS.
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent, server: s1(ctx))

    assert :ok = MutationAdmission.release(lease, server: s1(ctx))

    assert {:ok, %{active_roots: 0, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    Fake.release_sync(ctx.agent_name)

    assert {:ok, %DrainFence{} = fence} = Task.await(t_drain, 3_000)

    assert {:ok, %{active_roots: 0, gate: :draining}} =
             MutationAdmission.status(agent, server: s2(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 0
    assert stored.data["fence_gen"] >= 1
    assert is_binary(stored.data["fence_hash"])

    ops = cas_ops(ctx.agent_name, key)
    # release CAS + begin_drain CAS + fence CAS (exact successful fence present)
    assert Enum.any?(ops, fn op ->
             is_map(op.record) and is_binary(op.record.data["fence_hash"]) and
               map_size(op.record.data["roots"] || %{}) == 0
           end)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s1(ctx))
  end

  @tag packet: "VP-05D2C3I1A"
  test "handoff versus holder death: barrier-directed source death exact release", ctx do
    agent = "cc_handoff_death"
    key = storage_key(agent)
    parent = self()

    source =
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

    assert_receive {:lease, _lease, source_pid}, 1_000

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
    assert :ok = Fake.await_sync(1, 2_000)

    # Source dies while transfer CAS is parked — durable release path wins.
    Process.exit(source_pid, :kill)
    sref = Process.monitor(source_pid)
    assert_receive {:DOWN, ^sref, :process, ^source_pid, _}, 1_000
    Fake.release_sync(ctx.agent_name)

    # Directed outcome: source death during handoff → root released (0 roots).
    # Poll only for terminal durable zero (release retry), not to choose a race branch.
    assert wait_roots_zero(s1(ctx), agent)

    assert {:ok, %{active_roots: 0, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    stored = Fake.peek(ctx.agent_name, key)
    assert map_size(stored.data["roots"]) == 0

    ops = cas_ops(ctx.agent_name, key)
    assert length(ops) >= 1
    # Final durable state has no root — release CAS present in history.
    assert Enum.any?(ops, fn op ->
             is_map(op.record) and map_size(op.record.data["roots"] || %{}) == 0
           end)

    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 500)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: s2(ctx))
    Process.exit(target, :kill)
  end

  @tag packet: "VP-05D2C3I1A"
  test "CAS conflict retry never drops a concurrent root", ctx do
    agent = "cc_cas_roots"
    assert {:ok, lease1} = MutationAdmission.acquire(agent, server: s1(ctx))
    Fake.set_conflict_count(ctx.agent_name, 1)
    assert {:ok, lease2} = MutationAdmission.acquire(agent, server: s2(ctx))

    assert {:ok, %{active_roots: 2, gate: :open}} =
             MutationAdmission.status(agent, server: s1(ctx))

    assert :ok = MutationAdmission.release(lease1, server: s1(ctx))
    assert :ok = MutationAdmission.release(lease2, server: s2(ctx))
    assert wait_roots_zero(s1(ctx), agent)
  end

  @tag packet: "VP-05D2C3I1A"
  test "cross-authority release notifies peer drain waiters before deadline", ctx do
    agent = "cc_cross_drain"
    assert {:ok, lease} = MutationAdmission.acquire(agent, server: s1(ctx))

    # Park drain begin_drain CAS, then release root, then unpark so drain sees zero.
    Fake.arm_sync(ctx.agent_name, [:cas], 1)

    drain_task =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: s2(ctx), timeout_ms: 2_000)
      end)

    assert :ok = Fake.await_sync(1, 2_000)
    assert :ok = MutationAdmission.release(lease, server: s1(ctx))
    Fake.release_sync(ctx.agent_name)

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
