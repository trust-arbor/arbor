defmodule Arbor.Memory.MutationAdmissionSupervisionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmissionCore, as: Core
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1A"

  @shell_id :ma_sup_shell
  @namespace :memory_mutation_admission

  setup do
    agent_name = :"ma_sup_fake_#{System.unique_integer([:positive])}"
    registry = :"ma_sup_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ma_sup_ds_#{System.unique_integer([:positive])}"
    server = :"ma_sup_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: :ma_sup_guardian_sup,
      start:
        {DynamicSupervisor, :start_link,
         [[name: sup_name, strategy: :one_for_one, max_children: 4096]]}
    })

    {:ok, _} = Fake.start_link(agent_name: agent_name)

    runtime_fp =
      Base.encode16(:crypto.hash(:sha256, "sup-runtime-#{agent_name}"), case: :lower)

    node_fp =
      Base.encode16(:crypto.hash(:sha256, "sup-node-#{agent_name}"), case: :lower)

    shell_pid =
      start_shell!(server, registry, sup_name, agent_name, runtime_fp, node_fp)

    on_exit(fn -> Fake.stop(agent_name) end)

    {:ok,
     server: server,
     shell_pid: shell_pid,
     agent_name: agent_name,
     registry: registry,
     sup: sup_name,
     runtime_fp: runtime_fp,
     node_fp: node_fp}
  end

  defp start_shell!(server, registry, sup, agent_name, runtime_fp, node_fp) do
    pid =
      start_supervised!(
        {MutationAdmission,
         [
           name: server,
           registry: registry,
           guardian_supervisor: sup,
           target: %{
             namespace: @namespace,
             backend: Fake,
             opts: [agent_name: agent_name]
           },
           runtime_fp: runtime_fp,
           node_fp: node_fp
         ]},
        id: @shell_id,
        restart: :temporary
      )

    pid
  end

  defp stop_shell! do
    case stop_supervised(@shell_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp lease_hash(token) do
    :crypto.hash(:sha256, "arbor.memory.mutation_admission.lease:v1" <> token)
    |> Base.encode16(case: :lower)
  end

  defp storage_key(agent_id) do
    Base.encode16(:crypto.hash(:sha256, agent_id), case: :lower)
  end

  defp stop_all_guardians!(sup) do
    children = DynamicSupervisor.which_children(sup)

    Enum.each(children, fn {_id, child, _type, _mods} ->
      case child do
        pid when is_pid(pid) ->
          ref = Process.monitor(pid)
          DynamicSupervisor.terminate_child(sup, pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            2_000 -> flunk("guardian #{inspect(pid)} did not terminate")
          end

        :restarting ->
          :ok

        :undefined ->
          :ok
      end
    end)

    assert DynamicSupervisor.which_children(sup) == []
  end

  @tag packet: "VP-05D2C3I1A"
  test "shell-only restart keeps same runtime_fp and guardian blocker", ctx do
    assert {:ok, lease} =
             MutationAdmission.acquire("sup_a", server: ctx.server)

    hash = lease_hash(lease.token)
    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})
    assert Process.alive?(gpid)

    # Crash only the shell (ExUnit-supervised, not linked to the test process).
    shell = ctx.shell_pid
    shell_ref = Process.monitor(shell)
    stop_shell!()
    assert_receive {:DOWN, ^shell_ref, :process, ^shell, _}, 2_000

    # Guardian and durable root remain blockers under the same BEAM runtime.
    assert Process.alive?(gpid)
    assert [{^gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})
    assert %Record{data: data} = Fake.peek(ctx.agent_name, storage_key("sup_a"))
    assert map_size(data["roots"]) == 1
    assert data["roots"][hash]["runtime_fp"] == ctx.runtime_fp

    # Restart shell with the same runtime_fp — must not reconcile away live blockers.
    _shell2 =
      start_shell!(
        ctx.server,
        ctx.registry,
        ctx.sup,
        ctx.agent_name,
        ctx.runtime_fp,
        ctx.node_fp
      )

    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status("sup_a", server: ctx.server)

    assert Process.alive?(gpid)
    assert :ok = MutationAdmission.release(lease, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1A"
  test "holder death after shell-only restart releases via reconnected admission", ctx do
    parent = self()

    holder_pid =
      spawn(fn ->
        assert {:ok, lease} =
                 MutationAdmission.acquire("sup_holder_death", server: ctx.server)

        send(parent, {:lease, lease, self()})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:lease, lease, ^holder_pid}, 1_000
    hash = lease_hash(lease.token)
    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})

    # Shell-only restart: guardian survives with a stale admission pid until reconnect.
    shell_ref = Process.monitor(ctx.shell_pid)
    stop_shell!()
    assert_receive {:DOWN, ^shell_ref, :process, _, _}, 2_000
    assert Process.alive?(gpid)

    _shell2 =
      start_shell!(
        ctx.server,
        ctx.registry,
        ctx.sup,
        ctx.agent_name,
        ctx.runtime_fp,
        ctx.node_fp
      )

    # Reconnect is continue-handled on init; status runs after continue.
    assert {:ok, %{active_roots: 1}} =
             MutationAdmission.status("sup_holder_death", server: ctx.server)

    shell2 = Process.whereis(ctx.server)
    assert is_pid(shell2)
    {:ok, info} = Arbor.Memory.MutationAdmission.Guardian.info(gpid)
    assert info.admission == shell2

    href = Process.monitor(holder_pid)
    Process.exit(holder_pid, :kill)
    assert_receive {:DOWN, ^href, :process, ^holder_pid, _}, 2_000

    # Root must release via reconnected shell — not strand.
    assert wait_until(fn ->
             match?(
               {:ok, %{active_roots: 0}},
               MutationAdmission.status("sup_holder_death", server: ctx.server)
             )
           end)
  end

  @tag packet: "VP-05D2C3I1A"
  test "missing guardian evidence remains blocked after guardian death", ctx do
    assert {:ok, lease} =
             MutationAdmission.acquire("sup_b", server: ctx.server)

    hash = lease_hash(lease.token)
    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})

    gref = Process.monitor(gpid)
    # Terminate via supervisor (unlinked from test), await monitor — no sleep.
    assert :ok = DynamicSupervisor.terminate_child(ctx.sup, gpid)
    assert_receive {:DOWN, ^gref, :process, ^gpid, _}, 2_000
    assert Registry.lookup(ctx.registry, {:guardian, hash}) == []

    # Durable root remains; no guardian — release fails; drain cannot finish.
    assert {:error, :invalid_lease} =
             MutationAdmission.release(lease, server: ctx.server)

    assert {:error, :drain_timeout} =
             MutationAdmission.drain("sup_b", server: ctx.server, timeout_ms: 80)

    assert {:ok, %{gate: :draining, active_roots: 1}} =
             MutationAdmission.status("sup_b", server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1A"
  test "new runtime: terminate full old subtree then reconcile prior-local roots only", ctx do
    agent_id = "sup_c"
    assert {:ok, lease} = MutationAdmission.acquire(agent_id, server: ctx.server)
    hash = lease_hash(lease.token)

    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})
    key = storage_key(agent_id)
    assert %Record{data: data} = Fake.peek(ctx.agent_name, key)
    assert data["roots"][hash]["runtime_fp"] == ctx.runtime_fp
    assert data["roots"][hash]["node_fp"] == ctx.node_fp

    # Simulate new BEAM runtime: tear down complete admission subtree (shell +
    # all guardians). No live holders may remain when the new runtime starts.
    shell_ref = Process.monitor(ctx.shell_pid)
    stop_shell!()
    assert_receive {:DOWN, ^shell_ref, :process, _, _}, 2_000

    gref = Process.monitor(gpid)
    stop_all_guardians!(ctx.sup)
    # Guardian may already be down from stop_all; drain any DOWN.
    receive do
      {:DOWN, ^gref, :process, _, _} -> :ok
    after
      100 ->
        refute Process.alive?(gpid)
    end

    assert Registry.lookup(ctx.registry, {:guardian, hash}) == []
    assert DynamicSupervisor.which_children(ctx.sup) == []
    # Durable prior-runtime root remains without live processes.
    assert %Record{data: still} = Fake.peek(ctx.agent_name, key)
    assert map_size(still["roots"]) == 1

    new_rt =
      Base.encode16(:crypto.hash(:sha256, "new-runtime-#{System.unique_integer()}"),
        case: :lower
      )

    refute new_rt == ctx.runtime_fp

    start_shell!(
      ctx.server,
      ctx.registry,
      ctx.sup,
      ctx.agent_name,
      new_rt,
      ctx.node_fp
    )

    # Reconcile drops prior-local (same node, prior runtime) roots only.
    assert {:ok, fence} =
             MutationAdmission.drain(agent_id, server: ctx.server, timeout_ms: 500)

    assert {:ok, %{active_roots: 0, gate: :draining}} =
             MutationAdmission.status(agent_id, server: ctx.server)

    assert :ok = MutationAdmission.mark_destroyed(fence, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1A"
  test "new runtime: seeded prior-runtime root without live processes is reconciled; foreign remains",
       ctx do
    # No live acquire — seed durable state only (models post-BEAM-restart disk).
    stop_shell!()
    stop_all_guardians!(ctx.sup)

    prior_rt =
      Base.encode16(:crypto.hash(:sha256, "prior-rt-#{System.unique_integer()}"), case: :lower)

    foreign_node =
      Base.encode16(:crypto.hash(:sha256, "foreign-node"), case: :lower)

    prior_hash =
      Base.encode16(:crypto.hash(:sha256, "prior-lease"), case: :lower)

    foreign_hash =
      Base.encode16(:crypto.hash(:sha256, "foreign-lease"), case: :lower)

    agent_id = "sup_seed"
    key = storage_key(agent_id)

    {:ok, core} = Core.new(nil)

    {:ok, core} =
      Core.acquire_new(core, prior_hash, prior_hash, ctx.node_fp, prior_rt, %{
        max_active_roots: 64
      })

    {:ok, core} =
      Core.acquire_new(core, foreign_hash, foreign_hash, foreign_node, prior_rt, %{
        max_active_roots: 64
      })

    record = Record.new(key, Core.to_data(core))

    assert {:ok, _} =
             Persistence.compare_and_swap(
               @namespace,
               Fake,
               key,
               :not_found,
               record,
               agent_name: ctx.agent_name
             )

    new_rt =
      Base.encode16(:crypto.hash(:sha256, "seed-new-rt-#{System.unique_integer()}"),
        case: :lower
      )

    start_shell!(
      ctx.server,
      ctx.registry,
      ctx.sup,
      ctx.agent_name,
      new_rt,
      ctx.node_fp
    )

    # status/reconcile drops prior-local only; foreign-node root remains a blocker.
    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status(agent_id, server: ctx.server)

    assert %Record{data: after_rec} = Fake.peek(ctx.agent_name, key)
    refute Map.has_key?(after_rec["roots"], prior_hash)
    assert Map.has_key?(after_rec["roots"], foreign_hash)

    assert {:error, :drain_timeout} =
             MutationAdmission.drain(agent_id, server: ctx.server, timeout_ms: 80)

    assert {:ok, %{gate: :draining, active_roots: 1}} =
             MutationAdmission.status(agent_id, server: ctx.server)
  end

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
