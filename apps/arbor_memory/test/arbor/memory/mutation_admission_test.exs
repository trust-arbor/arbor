defmodule Arbor.Memory.MutationAdmissionTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.DrainFence
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.Test.MutationAdmissionNoCasBackend
  alias Arbor.Memory.Test.MutationAdmissionNoDurabilityBackend
  alias Arbor.Memory.Test.MutationAdmissionWeakDurabilityBackend

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1A"

  setup do
    agent_name = :"ma_fake_#{System.unique_integer([:positive])}"
    registry = :"ma_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ma_sup_#{System.unique_integer([:positive])}"
    server = :"ma_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: sup_name,
      start:
        {DynamicSupervisor, :start_link,
         [[name: sup_name, strategy: :one_for_one, max_children: 4096]]}
    })

    {:ok, _} = Fake.start_link(agent_name: agent_name)

    runtime_fp =
      Base.encode16(:crypto.hash(:sha256, "test-runtime-#{agent_name}"), case: :lower)

    node_fp =
      Base.encode16(:crypto.hash(:sha256, "test-node-#{agent_name}"), case: :lower)

    start_supervised!(
      {MutationAdmission,
       [
         name: server,
         registry: registry,
         guardian_supervisor: sup_name,
         target: %{
           namespace: :memory_mutation_admission,
           backend: Fake,
           opts: [agent_name: agent_name]
         },
         runtime_fp: runtime_fp,
         node_fp: node_fp
       ]},
      id: {:ma_owner_shell, server}
    )

    on_exit(fn -> Fake.stop(agent_name) end)

    {:ok,
     server: server,
     agent_name: agent_name,
     registry: registry,
     sup: sup_name,
     runtime_fp: runtime_fp,
     node_fp: node_fp}
  end

  defp acq(server, agent, opts \\ []) do
    MutationAdmission.acquire(agent, Keyword.put(opts, :server, server))
  end

  defp st(server, agent) do
    MutationAdmission.status(agent, server: server)
  end

  defp rel(server, lease), do: MutationAdmission.release(lease, server: server)
  defp hof(server, lease, target), do: MutationAdmission.handoff(lease, target, server: server)

  defp drn(server, agent, opts \\ []),
    do: MutationAdmission.drain(agent, Keyword.put(opts, :server, server))

  defp mdest(server, fence), do: MutationAdmission.mark_destroyed(fence, server: server)

  @tag packet: "VP-05D2C3I1A"
  test "readiness and open acquire/release", %{server: server, agent_name: agent_name} do
    assert {:ok, %{durability: :node_restart}} =
             MutationAdmission.readiness(server: server)

    assert {:ok, %Lease{} = lease} = acq(server, "agent_a")
    assert {:ok, %{gate: :open, active_roots: 1}} = st(server, "agent_a")
    assert :ok = rel(server, lease)
    Process.sleep(20)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_a")
    assert Fake.history(agent_name) != []
  end

  @tag packet: "VP-05D2C3I1A"
  test "caller binding and forged/wrong-owner rejection", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_b")

    task =
      Task.async(fn ->
        rel(server, lease)
      end)

    assert {:error, :not_owner} = Task.await(task)
    assert :ok = rel(server, lease)
  end

  @tag packet: "VP-05D2C3I1A"
  test "same-process nesting reenter", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_c")
    assert {:ok, ^lease} = acq(server, "agent_c", lease: lease)
    assert :ok = rel(server, lease)
    assert :ok = rel(server, lease)
    Process.sleep(20)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_c")
  end

  @tag packet: "VP-05D2C3I1A"
  test "local handoff moves ownership", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_d")
    parent = self()

    target =
      spawn(fn ->
        receive do
          :go ->
            assert :ok = rel(server, lease)
            send(parent, :released)
        end
      end)

    assert {:ok, ^lease} = hof(server, lease, target)
    assert {:error, :not_owner} = rel(server, lease)
    send(target, :go)
    assert_receive :released, 1_000
    Process.sleep(30)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_d")
  end

  @tag packet: "VP-05D2C3I1A"
  test "target death after handoff releases root", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_e")

    target =
      spawn(fn ->
        receive do
          :block -> :ok
        end
      end)

    assert {:ok, ^lease} = hof(server, lease, target)
    Process.exit(target, :kill)
    Process.sleep(50)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_e")
  end

  @tag packet: "VP-05D2C3I1A"
  test "source death before handoff releases root", %{server: server} do
    parent = self()

    source =
      spawn(fn ->
        assert {:ok, lease} = acq(server, "agent_f")
        send(parent, {:lease, lease})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:lease, _lease}, 1_000
    Process.exit(source, :kill)
    Process.sleep(50)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_f")
  end

  @tag packet: "VP-05D2C3I1A"
  test "source death after handoff leaves target as owner", %{server: server} do
    parent = self()

    source =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire("agent_f3", server: server)
        send(parent, {:lease, lease, self()})

        receive do
          {:do_handoff, target} ->
            assert {:ok, _} = MutationAdmission.handoff(lease, target, server: server)
            send(parent, :handed)

            receive do
              :die -> :ok
            end
        end
      end)

    assert_receive {:lease, lease, source_pid}, 1_000

    target =
      spawn(fn ->
        receive do
          :release ->
            assert :ok = MutationAdmission.release(lease, server: server)
            send(parent, :target_released)
        end
      end)

    send(source_pid, {:do_handoff, target})
    assert_receive :handed, 1_000
    Process.exit(source_pid, :kill)
    Process.sleep(30)
    assert {:ok, %{active_roots: 1}} = st(server, "agent_f3")
    send(target, :release)
    assert_receive :target_released, 1_000
    Process.sleep(30)
    assert {:ok, %{active_roots: 0}} = st(server, "agent_f3")
  end

  @tag packet: "VP-05D2C3I1A"
  test "double release fails closed", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_g")
    assert :ok = rel(server, lease)
    Process.sleep(30)
    assert {:error, reason} = rel(server, lease)
    assert reason in [:invalid_lease, :stale_lease, :not_owner]
  end

  @tag packet: "VP-05D2C3I1A"
  test "bounded CAS contention returns busy", %{server: server, agent_name: agent_name} do
    Fake.set_conflict_count(agent_name, 100)

    assert {:error, :busy} = acq(server, "agent_h")
  end

  @tag packet: "VP-05D2C3I1A"
  test "drain timeout remains draining", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_i")

    task =
      Task.async(fn ->
        drn(server, "agent_i", timeout_ms: 50)
      end)

    assert {:error, :drain_timeout} = Task.await(task, 2_000)
    assert {:ok, %{gate: :draining, active_roots: 1}} = st(server, "agent_i")
    assert {:error, :draining} = acq(server, "agent_i")
    assert :ok = rel(server, lease)
  end

  @tag packet: "VP-05D2C3I1A"
  test "drain issues fence when empty; mark_destroyed idempotent", %{server: server} do
    assert {:ok, fence} = drn(server, "agent_j", timeout_ms: 500)
    assert %DrainFence{} = fence
    assert {:ok, %{gate: :draining, active_roots: 0}} = st(server, "agent_j")
    assert :ok = mdest(server, fence)
    assert :ok = mdest(server, fence)
    assert {:ok, %{gate: :destroyed}} = st(server, "agent_j")
    assert {:error, :destroyed} = acq(server, "agent_j")
  end

  @tag packet: "VP-05D2C3I1A"
  test "lost-reply fence rotation makes prior fence stale", %{server: server} do
    assert {:ok, fence1} = drn(server, "agent_k")
    assert {:ok, fence2} = drn(server, "agent_k")
    assert fence1.token != fence2.token
    assert {:error, :stale_fence} = mdest(server, fence1)
    assert :ok = mdest(server, fence2)
  end

  @tag packet: "VP-05D2C3I1A"
  test "status and inspect are redacted", %{server: server} do
    assert {:ok, lease} = acq(server, "agent_l")
    assert {:ok, status} = st(server, "agent_l")

    assert Map.keys(status) |> Enum.sort() ==
             [:active_roots, :drain_waiters, :gate, :gate_generation]

    inspected = inspect(lease)
    assert inspected =~ "[REDACTED]"
    refute inspected =~ lease.token
    assert :ok = rel(server, lease)
  end

  @tag packet: "VP-05D2C3I1A"
  test "rejects per-call backend opts", %{server: server} do
    assert {:error, :invalid_request} =
             MutationAdmission.acquire("agent_m",
               server: server,
               backend: Fake
             )
  end

  @tag packet: "VP-05D2C3I1A"
  test "startup-injected target works while Application Config is disabled" do
    # Config.mutation_admission_backend/0 is :disabled in test — inject only via start_link.
    assert {:error, :disabled} = Arbor.Memory.Config.mutation_admission_backend()

    agent_name = :"ma_inj_#{System.unique_integer([:positive])}"
    registry = :"ma_inj_reg_#{System.unique_integer([:positive])}"
    sup = :"ma_inj_sup_#{System.unique_integer([:positive])}"
    server = :"ma_inj_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: sup,
      start: {DynamicSupervisor, :start_link, [[name: sup, strategy: :one_for_one]]}
    })

    {:ok, _} = Fake.start_link(agent_name: agent_name)
    on_exit(fn -> Fake.stop(agent_name) end)

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
         }
       ]},
      id: {:ma_inj_shell, server}
    )

    assert {:ok, %{durability: :node_restart}} =
             MutationAdmission.readiness(server: server)

    assert {:ok, lease} = MutationAdmission.acquire("inj_agent", server: server)
    assert :ok = MutationAdmission.release(lease, server: server)
  end

  @tag packet: "VP-05D2C3I1A"
  test "disabled unsupported weak unavailable never admit a lease or report drain", %{} do
    # Sequence-6: weak/missing authority never admits a lease or reports drain success.
    server = :"ma_dis_#{System.unique_integer([:positive])}"
    registry = :"ma_reg_d_#{System.unique_integer([:positive])}"
    sup = :"ma_sup_d_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry}, id: {:ma_dis_reg, registry})

    start_supervised!(%{
      id: {:ma_dis_sup, sup},
      start: {DynamicSupervisor, :start_link, [[name: sup, strategy: :one_for_one]]}
    })

    start_supervised!(
      {MutationAdmission, [name: server, registry: registry, guardian_supervisor: sup]},
      id: {:ma_dis_shell, server}
    )

    assert {:error, :disabled} = MutationAdmission.readiness(server: server)
    assert {:error, :disabled} = MutationAdmission.acquire("a", server: server)
    assert {:error, :disabled} = MutationAdmission.drain("a", server: server, timeout_ms: 50)

    for {mod, err} <- [
          {MutationAdmissionNoCasBackend, :unsupported},
          {MutationAdmissionNoDurabilityBackend, :unsupported},
          {MutationAdmissionWeakDurabilityBackend, :insufficient_durability}
        ] do
      s = :"ma_x_#{System.unique_integer([:positive])}"
      r = :"ma_r_#{System.unique_integer([:positive])}"
      sp = :"ma_s_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: r}, id: {:ma_x_reg, r})

      start_supervised!(%{
        id: {:ma_x_sup, sp},
        start: {DynamicSupervisor, :start_link, [[name: sp, strategy: :one_for_one]]}
      })

      start_supervised!(
        {MutationAdmission,
         [
           name: s,
           registry: r,
           guardian_supervisor: sp,
           target: %{namespace: :memory_mutation_admission, backend: mod, opts: []}
         ]},
        id: {:ma_x_shell, s}
      )

      assert {:error, ^err} = MutationAdmission.readiness(server: s)
      assert {:error, ^err} = MutationAdmission.acquire("a", server: s)
      # Never report drain success under weak/unsupported authority.
      assert {:error, ^err} = MutationAdmission.drain("a", server: s, timeout_ms: 50)
    end
  end

  @tag packet: "VP-05D2C3I1A"
  test "malformed get path never admits a lease or reports drain", %{
    server: server,
    agent_name: agent_name
  } do
    Fake.fail_next(agent_name, :get, :boom)
    assert {:error, :unavailable} = acq(server, "agent_n")
    Fake.fail_next(agent_name, :get, :boom)
    assert {:error, :unavailable} = drn(server, "agent_n", timeout_ms: 50)
  end

  @tag packet: "VP-05D2C3I1A"
  test "target death before handoff begin rejects with exact :invalid_target", %{
    server: server
  } do
    assert {:ok, lease} = acq(server, "agent_handoff_die")

    target =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    Process.exit(target, :kill)
    # Ensure DOWN is delivered before handoff validates aliveness.
    ref = Process.monitor(target)
    assert_receive {:DOWN, ^ref, :process, ^target, _}, 1_000

    assert {:error, :invalid_target} = hof(server, lease, target)
    assert :ok = rel(server, lease)
  end

  @tag packet: "VP-05D2C3I1A"
  test "holder death retries durable release without stranding root", %{
    server: server,
    agent_name: agent_name
  } do
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, _lease} = MutationAdmission.acquire("agent_retry_rel", server: server)
        send(parent, :held)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :held, 1_000

    # Force temporary CAS failures so first release attempts retry
    Fake.set_conflict_count(agent_name, 3)
    Process.exit(holder, :kill)

    # Eventually root is released despite transient conflicts
    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, st(server, "agent_retry_rel"))
           end)
  end

  @tag packet: "VP-05D2C3I1A"
  test "acquire rejects unhonored timeout_ms option", %{server: server} do
    assert {:error, :invalid_request} =
             MutationAdmission.acquire("no_timeout", server: server, timeout_ms: 100)
  end

  @tag packet: "VP-05D2C3I1A"
  test "shared drain waiter cohort receives one fence", %{server: server} do
    assert {:ok, lease} = acq(server, "cohort_agent")

    t1 =
      Task.async(fn ->
        MutationAdmission.drain("cohort_agent", server: server, timeout_ms: 2_000)
      end)

    t2 =
      Task.async(fn ->
        MutationAdmission.drain("cohort_agent", server: server, timeout_ms: 2_000)
      end)

    assert wait_until(fn ->
             match?(
               {:ok, %{drain_waiters: n}} when n >= 2,
               st(server, "cohort_agent")
             )
           end)

    assert :ok = rel(server, lease)

    r1 = Task.await(t1, 3_000)
    r2 = Task.await(t2, 3_000)

    assert {:ok, %DrainFence{} = f1} = r1
    assert {:ok, %DrainFence{} = f2} = r2
    assert f1.token == f2.token
    assert f1.fence_generation == f2.fence_generation
    assert :ok = mdest(server, f1)
    assert :ok = mdest(server, f2)
  end

  @tag packet: "VP-05D2C3I1A"
  test "post-CAS guardian start failure returns indeterminate and retains root" do
    agent_name = :"ma_gfail_#{System.unique_integer([:positive])}"
    registry = :"ma_gfail_reg_#{System.unique_integer([:positive])}"
    # max_children: 0 — DynamicSupervisor refuses guardian starts
    sup = :"ma_gfail_sup_#{System.unique_integer([:positive])}"
    server = :"ma_gfail_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: sup,
      start:
        {DynamicSupervisor, :start_link, [[name: sup, strategy: :one_for_one, max_children: 0]]}
    })

    {:ok, _} = Fake.start_link(agent_name: agent_name)
    on_exit(fn -> Fake.stop(agent_name) end)

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
         }
       ]},
      id: {:ma_gfail_shell, server}
    )

    assert {:error, :indeterminate} =
             MutationAdmission.acquire("gfail_agent", server: server)

    key = Base.encode16(:crypto.hash(:sha256, "gfail_agent"), case: :lower)
    assert %_{data: data} = Fake.peek(agent_name, key)
    assert map_size(data["roots"]) == 1

    # Drain cannot finish while durable root remains a blocker — never drain success.
    assert {:error, :drain_timeout} =
             MutationAdmission.drain("gfail_agent", server: server, timeout_ms: 80)
  end

  @tag packet: "VP-05D2C3I1A"
  test "frozen config target drift fails closed" do
    agent_name = :"ma_drift_#{System.unique_integer([:positive])}"
    registry = :"ma_drift_reg_#{System.unique_integer([:positive])}"
    sup = :"ma_drift_sup_#{System.unique_integer([:positive])}"
    server = :"ma_drift_srv_#{System.unique_integer([:positive])}"

    {:ok, _} = Fake.start_link(agent_name: agent_name)

    prev_backend = Application.get_env(:arbor_memory, :mutation_admission_backend)
    prev_opts = Application.get_env(:arbor_memory, :mutation_admission_backend_opts)

    Application.put_env(:arbor_memory, :mutation_admission_backend, Fake)
    Application.put_env(:arbor_memory, :mutation_admission_backend_opts, agent_name: agent_name)

    on_exit(fn ->
      restore_env(:mutation_admission_backend, prev_backend)
      restore_env(:mutation_admission_backend_opts, prev_opts)
      Fake.stop(agent_name)
    end)

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: sup,
      start: {DynamicSupervisor, :start_link, [[name: sup, strategy: :one_for_one]]}
    })

    # No :target inject → target_source :config freezes current Config.
    start_supervised!(
      {MutationAdmission, [name: server, registry: registry, guardian_supervisor: sup]},
      id: {:ma_drift_shell, server}
    )

    assert {:ok, _} = MutationAdmission.readiness(server: server)

    # Drift production Config under the running authority.
    Application.put_env(:arbor_memory, :mutation_admission_backend_opts, agent_name: :other)

    assert {:error, :invalid_config} = MutationAdmission.readiness(server: server)

    assert {:error, :invalid_config} =
             MutationAdmission.acquire("drift_agent", server: server)
  end

  @tag packet: "VP-05D2C3I1A"
  test "production runtime resolver: concurrent authorities converge and keep peer roots" do
    # No runtime_fp inject — production path uses Application-owned ETS identity.
    agent_name = :"ma_rt_#{System.unique_integer([:positive])}"
    {:ok, _} = Fake.start_link(agent_name: agent_name)
    on_exit(fn -> Fake.stop(agent_name) end)

    shells =
      for i <- 1..2 do
        registry = :"ma_rt_reg_#{i}_#{System.unique_integer([:positive])}"
        sup = :"ma_rt_sup_#{i}_#{System.unique_integer([:positive])}"
        server = :"ma_rt_srv_#{i}_#{System.unique_integer([:positive])}"

        start_supervised!({Registry, keys: :unique, name: registry},
          id: {:ma_rt_reg, i, registry}
        )

        start_supervised!(%{
          id: {:ma_rt_gsup, i, sup},
          start: {DynamicSupervisor, :start_link, [[name: sup, strategy: :one_for_one]]}
        })

        # Explicit unique ExUnit child ids for the two authorities.
        pid =
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
               }
             ]},
            id: {:ma_rt_shell, i, server}
          )

        {server, pid}
      end

    [{s1, p1}, {s2, p2}] = shells
    st1 = :sys.get_state(p1)
    st2 = :sys.get_state(p2)

    # Production resolver converges on one persistent BEAM runtime identity.
    assert st1.runtime_fp == st2.runtime_fp
    assert byte_size(st1.runtime_fp) == 64
    assert st1.node_fp == st2.node_fp

    # Peer authority must not classify the other's live root as prior-runtime.
    assert {:ok, lease} = MutationAdmission.acquire("rt_peer_agent", server: s1)

    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status("rt_peer_agent", server: s2)

    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status("rt_peer_agent", server: s1)

    assert :ok = MutationAdmission.release(lease, server: s1)
  end

  @tag packet: "VP-05D2C3I1A"
  test "opts-bearing APIs reject malformed/duplicate/unknown opts before server" do
    # No server process needed — validation is pre-call (finding 2).
    assert {:error, :invalid_request} =
             MutationAdmission.readiness(server: :no_such, unknown: true)

    assert {:error, :invalid_request} =
             MutationAdmission.acquire("a", server: :no_such, backend: Fake)

    assert {:error, :invalid_request} =
             MutationAdmission.acquire("a", server: :no_such, server: :dup)

    assert {:error, :invalid_request} =
             MutationAdmission.handoff(
               %Lease{token: <<0::256>>, agent_id: "a", admitted_gate_gen: 1},
               self(),
               server: :no_such,
               timeout_ms: 1
             )

    assert {:error, :invalid_request} =
             MutationAdmission.release(
               %Lease{token: <<0::256>>, agent_id: "a", admitted_gate_gen: 1},
               server: :no_such,
               lease: :bad
             )

    assert {:error, :invalid_request} =
             MutationAdmission.mark_destroyed(
               %DrainFence{token: <<0::256>>, agent_id: "a", fence_generation: 1},
               server: :no_such,
               foo: 1
             )

    assert {:error, :invalid_request} =
             MutationAdmission.status("a", server: :no_such, limit: 1)
  end

  @tag packet: "VP-05D2C3I1A"
  test "invalid drain timeout bounds fail with no stored record" do
    # Finding 7: bounds fail even when backend has no record and server is absent.
    assert {:error, :invalid_request} =
             MutationAdmission.drain("never_written", server: :no_such, timeout_ms: 0)

    assert {:error, :invalid_request} =
             MutationAdmission.drain("never_written",
               server: :no_such,
               timeout_ms: 60_001
             )

    assert {:error, :invalid_request} =
             MutationAdmission.drain("never_written",
               server: :no_such,
               timeout_ms: -1
             )

    assert {:error, :invalid_request} =
             MutationAdmission.acquire("", server: :no_such)
  end

  @insert_receipt_corruptions [
    :bad_revision,
    :wrong_revision,
    :wrong_generation,
    :wrong_id,
    :wrong_key,
    :wrong_data,
    :nonempty_metadata,
    :wrong_metadata,
    :oversized_id,
    :invalid_timestamps,
    :retrograde_timestamps,
    :not_a_record
  ]

  @tag packet: "VP-05D2C3I1A"
  test "insert CAS receipt corruptions are indeterminate with durable apply and no lease", %{
    server: server,
    agent_name: agent_name
  } do
    Enum.each(@insert_receipt_corruptions, fn mode ->
      agent = "ins_corr_#{mode}"
      key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
      Fake.corrupt_next(agent_name, :compare_and_swap, mode)

      assert {:error, :indeterminate} = acq(server, agent),
             "expected indeterminate for insert corruption #{inspect(mode)}"

      # Applied-but-malformed: durable write present; never a usable public lease.
      assert Fake.peek(agent_name, key) != nil,
             "expected durable apply for insert corruption #{inspect(mode)}"
    end)
  end

  @update_receipt_corruptions [
    :bad_revision,
    :wrong_revision,
    :wrong_generation,
    :wrong_id,
    :wrong_key,
    :wrong_data,
    :nonempty_metadata,
    :wrong_metadata,
    :oversized_id,
    :invalid_timestamps,
    :retrograde_timestamps,
    :inserted_at_mismatch,
    :not_a_record
  ]

  @tag packet: "VP-05D2C3I1A"
  test "update CAS receipt corruptions are indeterminate with durable apply", %{
    server: server,
    agent_name: agent_name
  } do
    Enum.each(@update_receipt_corruptions, fn mode ->
      agent = "upd_corr_#{mode}"
      key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
      assert {:ok, lease} = acq(server, agent)
      before = Fake.peek(agent_name, key)
      assert map_size(before.data["roots"]) == 1

      Fake.corrupt_next(agent_name, :compare_and_swap, mode)
      # Outermost release performs an update CAS — applied then corrupt receipt.
      assert {:error, :indeterminate} = rel(server, lease),
             "expected indeterminate for update corruption #{inspect(mode)}"

      after_rec = Fake.peek(agent_name, key)
      assert after_rec != nil
      # Durable apply of release: roots cleared even though public result failed.
      assert map_size(after_rec.data["roots"]) == 0,
             "expected durable release apply for #{inspect(mode)}"
    end)
  end

  @load_record_corruptions [
    :wrong_key,
    :empty_id,
    :oversized_id,
    :nonempty_metadata,
    :wrong_generation,
    :wrong_revision,
    :invalid_timestamps,
    :retrograde_timestamps,
    :not_a_record
  ]

  @tag packet: "VP-05D2C3I1A"
  test "malformed loaded Record fields are indeterminate and never admit", %{
    server: server,
    agent_name: agent_name
  } do
    Enum.each(@load_record_corruptions, fn mode ->
      agent = "load_corr_#{mode}"
      # Seed a durable open record so the next op loads rather than :not_found.
      assert {:ok, lease} = acq(server, agent)
      assert :ok = rel(server, lease)

      Fake.corrupt_next(agent_name, :get, mode)

      assert {:error, :indeterminate} = acq(server, agent),
             "expected indeterminate for load corruption #{inspect(mode)}"
    end)
  end

  @tag packet: "VP-05D2C3I1A"
  test "insert CAS accepts generation > 1 reinsert with revision 1", %{
    server: server,
    agent_name: agent_name
  } do
    # Record contract: reinsert after hidden tombstone may return generation > 1.
    Fake.set_next_insert_generation(agent_name, 4)
    Fake.clear_history(agent_name)

    assert {:ok, %Lease{} = lease} = acq(server, "agent_reinsert_gen")

    key = Base.encode16(:crypto.hash(:sha256, "agent_reinsert_gen"), case: :lower)
    stored = Fake.peek(agent_name, key)
    assert %_{generation: 4, revision: 1, metadata: %{}} = stored
    assert is_binary(stored.id) and byte_size(stored.id) > 0 and byte_size(stored.id) <= 128

    cas_ops =
      agent_name
      |> Fake.history()
      |> Enum.filter(&(&1.kind == :compare_and_swap and &1.key == key))

    assert length(cas_ops) == 1
    assert hd(cas_ops).record.generation == 4
    assert hd(cas_ops).record.revision == 1
    assert :ok = rel(server, lease)
  end

  @tag packet: "VP-05D2C3I1A"
  test "unapplied CAS error never admits a lease", %{server: server, agent_name: agent_name} do
    Fake.fail_next(agent_name, :compare_and_swap, :boom)
    assert {:error, :unavailable} = acq(server, "agent_unapplied_cas")

    key = Base.encode16(:crypto.hash(:sha256, "agent_unapplied_cas"), case: :lower)
    assert Fake.peek(agent_name, key) == nil
  end

  @tag packet: "VP-05D2C3I1A"
  test "malformed get receipt is indeterminate and never admits", %{
    server: server,
    agent_name: agent_name
  } do
    Fake.corrupt_next(agent_name, :get)
    assert {:error, :indeterminate} = acq(server, "agent_bad_get")
  end

  @tag packet: "VP-05D2C3I1A"
  test "pre-dispatch CAS hang times out without durable admit", %{
    server: server,
    agent_name: agent_name
  } do
    agent = "agent_cas_pre_hang"
    key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
    Fake.clear_history(agent_name)
    # Sleep before do_cas — no durable write. Shell maps CAS timeout → :indeterminate.
    Fake.hang_next(agent_name, :compare_and_swap, 3_500)

    assert {:error, :indeterminate} = acq(server, agent)
    assert Fake.peek(agent_name, key) == nil

    cas_ops =
      agent_name
      |> Fake.history()
      |> Enum.filter(&(&1.kind == :compare_and_swap and &1.key == key))

    assert cas_ops == []
  end

  @tag packet: "VP-05D2C3I1A"
  test "post-dispatch CAS withhold: durable apply then :indeterminate without lease", %{
    server: server,
    agent_name: agent_name
  } do
    agent = "agent_cas_post_withhold"
    key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
    Fake.clear_history(agent_name)
    # Apply CAS, signal tester, withhold reply past shell deadline (2s).
    Fake.arm_withhold_cas_reply(agent_name)

    task =
      Task.async(fn ->
        MutationAdmission.acquire(agent, server: server)
      end)

    assert_receive {:cas_applied, ^key, _ref, %_{} = stored}, 2_000
    # Durable state changed before any public reply.
    assert map_size(stored.data["roots"]) == 1
    assert Fake.peek(agent_name, key) != nil
    assert map_size(Fake.peek(agent_name, key).data["roots"]) == 1

    cas_ops =
      agent_name
      |> Fake.history()
      |> Enum.filter(&(&1.kind == :compare_and_swap and &1.key == key))

    assert length(cas_ops) == 1
    assert hd(cas_ops).record != nil

    # Shell kills the unlinked worker past bounded op deadline → no lease/fence.
    assert {:error, :indeterminate} = Task.await(task, 5_000)
    # Root remains a durable blocker (applied effect, no public handle).
    assert Fake.peek(agent_name, key) != nil
    assert map_size(Fake.peek(agent_name, key).data["roots"]) == 1

    # Sequence-6: indeterminate authority never reports drain success either.
    assert {:error, :drain_timeout} = drn(server, agent, timeout_ms: 80)
  end

  @tag packet: "VP-05D2C3I1A"
  test "no-waiter drain notification does not mint fence; later drain rotates", %{
    server: server,
    agent_name: agent_name
  } do
    agent = "agent_nowaiter"
    key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
    assert {:ok, lease} = acq(server, agent)

    # Force draining while a root exists, then timeout the only waiter.
    t =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: server, timeout_ms: 80)
      end)

    assert wait_until(fn ->
             match?(
               {:ok, %{gate: :draining, drain_waiters: n}} when n >= 1,
               st(server, agent)
             )
           end)

    assert {:error, :drain_timeout} = Task.await(t, 2_000)
    assert {:ok, %{gate: :draining, drain_waiters: 0, active_roots: 1}} = st(server, agent)

    Fake.clear_history(agent_name)

    # Release last root with no waiters — must not mint an undeliverable fence.
    assert :ok = rel(server, lease)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0, gate: :draining}}, st(server, agent))
           end)

    # Immediate durable proof: still no fence issuance after no-waiter release.
    stored = Fake.peek(agent_name, key)
    assert stored.data["gate"] == "draining"
    assert map_size(stored.data["roots"]) == 0
    assert stored.data["fence_gen"] == 0
    assert stored.data["fence_hash"] == nil

    fence_cas =
      agent_name
      |> Fake.history()
      |> Enum.filter(fn op ->
        op.kind == :compare_and_swap and op.key == key and is_map(op.record) and
          is_binary(op.record.data["fence_hash"])
      end)

    assert fence_cas == []

    # Later drain observes draining+zero roots and issues a fence (rotation from none).
    assert {:ok, %DrainFence{} = fence} =
             MutationAdmission.drain(agent, server: server, timeout_ms: 500)

    assert fence.fence_generation >= 1
    stored2 = Fake.peek(agent_name, key)
    assert stored2.data["fence_gen"] >= 1
    assert is_binary(stored2.data["fence_hash"])
    assert :ok = mdest(server, fence)
  end

  @tag packet: "VP-05D2C3I1A"
  test "dead handoff target after parked CAS yields exact :invalid_target and :releasing", %{
    server: server,
    registry: registry,
    agent_name: agent_name
  } do
    agent = "agent_releasing_barrier"
    key = Base.encode16(:crypto.hash(:sha256, agent), case: :lower)
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, lease} = MutationAdmission.acquire(agent, server: server)
        send(parent, {:lease, lease})

        target =
          spawn(fn ->
            receive do
              :block -> :ok
            end
          end)

        send(parent, {:target, target})

        receive do
          :do_handoff -> :ok
        end

        result = MutationAdmission.handoff(lease, target, server: server)
        send(parent, {:handoff_result, result})

        receive do
          :done -> :ok
        end
      end)

    assert_receive {:lease, lease}, 1_000
    assert_receive {:target, target}, 1_000

    # Barrier window starts after acquire. Budget 1: handoff CAS succeeds;
    # durable release CAS conflicts so the root stays a blocker while we assert.
    Fake.clear_history(agent_name)
    Fake.set_cas_success_budget(agent_name, 1)
    Fake.arm_sync(agent_name, [:cas], 1)
    send(holder, :do_handoff)
    assert :ok = Fake.await_sync(1, 2_000)
    Process.exit(target, :kill)
    tref = Process.monitor(target)
    assert_receive {:DOWN, ^tref, :process, ^target, _}, 1_000
    Fake.release_sync(agent_name)
    assert_receive {:handoff_result, result}, 3_000

    # Exact reachable outcome for parked-CAS + dead target + release.
    assert result == {:error, :invalid_target}

    lease_hash =
      :crypto.hash(
        :sha256,
        "arbor.memory.mutation_admission.lease:v1" <> lease.token
      )
      |> Base.encode16(case: :lower)

    assert [{gpid, _}] = Registry.lookup(registry, {:guardian, lease_hash})
    assert Process.alive?(gpid)

    assert {:ok, %{phase: :releasing}} =
             Arbor.Memory.MutationAdmission.Guardian.info(gpid)

    # Durable root remains a blocker until release convergence is allowed.
    assert {:ok, %{active_roots: 1, gate: :open}} = st(server, agent)
    stored = Fake.peek(agent_name, key)
    assert stored != nil
    assert map_size(stored.data["roots"]) == 1

    cas_history =
      agent_name
      |> Fake.history()
      |> Enum.filter(&(&1.kind == :compare_and_swap and &1.key == key))

    # Exactly one successful handoff CAS in the barrier window (update, not insert).
    assert length(cas_history) == 1
    assert match?({:value, %_{}}, hd(cas_history).cas_expected)
    assert hd(cas_history).record != nil

    # Converge: clear budget so guardian release retries can finish.
    Fake.clear_cas_success_budget(agent_name)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, st(server, agent))
           end)

    Process.exit(holder, :kill)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_memory, key)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_memory, key)

  defp restore_env(key, value), do: Application.put_env(:arbor_memory, key, value)

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
