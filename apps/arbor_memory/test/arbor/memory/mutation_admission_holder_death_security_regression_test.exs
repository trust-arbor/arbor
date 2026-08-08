defmodule Arbor.Memory.MutationAdmissionHolderDeathSecurityRegressionTest do
  @moduledoc """
  Security regressions for the local mutation-admission authority boundary.

  Holder-death release identity, Guardian mutation ownership, runtime identity,
  and internal wake-up messages must not be caller-forgeable.
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.Guardian
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake

  @runtime_table :arbor_memory_mutation_admission_runtime
  @runtime_key :runtime_fp

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1A"
  @moduletag security_regression: true

  setup do
    agent_name = :"ma_sec_fake_#{System.unique_integer([:positive])}"
    registry = :"ma_sec_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ma_sec_sup_#{System.unique_integer([:positive])}"
    server = :"ma_sec_srv_#{System.unique_integer([:positive])}"
    shell_id = {:ma_sec_shell, server}

    start_supervised!({Registry, keys: :unique, name: registry})

    start_supervised!(%{
      id: sup_name,
      start:
        {DynamicSupervisor, :start_link,
         [[name: sup_name, strategy: :one_for_one, max_children: 4096]]}
    })

    {:ok, _} = Fake.start_link(agent_name: agent_name)

    node_fp =
      Base.encode16(:crypto.hash(:sha256, "sec-node-#{agent_name}"), case: :lower)

    shell_opts = [
      name: server,
      registry: registry,
      guardian_supervisor: sup_name,
      target: %{
        namespace: :memory_mutation_admission,
        backend: Fake,
        opts: [agent_name: agent_name]
      },
      node_fp: node_fp
    ]

    shell_pid = start_shell!(shell_id, shell_opts)

    on_exit(fn -> Fake.stop(agent_name) end)

    {:ok,
     server: server,
     shell_id: shell_id,
     shell_opts: shell_opts,
     shell_pid: shell_pid,
     agent_name: agent_name,
     registry: registry,
     sup: sup_name,
     node_fp: node_fp}
  end

  defp start_shell!(shell_id, shell_opts) do
    start_supervised!({MutationAdmission, shell_opts}, id: shell_id, restart: :temporary)
  end

  defp stop_shell!(shell_id) do
    case stop_supervised(shell_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp lease_hash(token) do
    :crypto.hash(
      :sha256,
      "arbor.memory.mutation_admission.lease:v1" <> token
    )
    |> Base.encode16(case: :lower)
  end

  defp spawn_holder(parent, server, agent) do
    spawn(fn ->
      result = MutationAdmission.acquire(agent, server: server)
      send(parent, {:holder_ready, self(), result})

      receive do
        :release ->
          release_result =
            case result do
              {:ok, lease} -> MutationAdmission.release(lease, server: server)
              _ -> result
            end

          send(parent, {:holder_released, self(), release_result})

        :exit ->
          :ok
      end
    end)
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        20 -> wait_until(fun, attempts - 1)
      end
    end
  end

  defp forged_runtime(original) do
    candidate = String.duplicate("f", 64)
    if candidate == original, do: String.duplicate("e", 64), else: candidate
  end

  @tag packet: "VP-05D2C3I1A"
  test "security regression: forged release casts and Guardian mutators cannot steal live root",
       %{server: server, registry: registry} do
    agent = "sec_forge_live_holder"
    parent = self()
    holder = spawn_holder(parent, server, agent)

    assert_receive {:holder_ready, ^holder, {:ok, %Lease{} = lease}}, 3_000
    hash = lease_hash(lease.token)

    assert [{gpid, _meta}] = Registry.lookup(registry, {:guardian, hash})
    assert Process.alive?(gpid)
    assert Process.alive?(holder)

    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status(agent, server: server)

    attacker = self()

    forged_target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(holder), do: Process.exit(holder, :kill)
      if Process.alive?(forged_target), do: Process.exit(forged_target, :kill)
    end)

    GenServer.cast(server, {:holder_down_release, hash, agent, gpid})
    GenServer.cast(server, {:holder_down_release, hash, "other_agent", gpid})
    GenServer.cast(server, {:holder_down_release, gpid})

    assert {:error, :not_owner} = GenServer.call(gpid, {:release_depth, attacker})
    assert {:error, :not_owner} = GenServer.call(gpid, {:reenter, attacker})

    assert {:error, :not_owner} =
             GenServer.call(gpid, {:begin_handoff, attacker, forged_target})

    assert {:error, :not_owner} =
             GenServer.call(gpid, {:finalize_handoff, attacker, forged_target})

    assert {:error, :not_owner} = GenServer.call(gpid, {:abort_handoff, attacker})
    assert {:error, :not_owner} = GenServer.call(gpid, :claim_release)

    assert {:error, :not_owner} =
             GenServer.call(gpid, {:release_attempt_result, :ok})

    assert {:error, :not_owner} = Guardian.reconnect_admission(gpid, attacker)

    receive do
    after
      50 -> :ok
    end

    assert {:ok, %{active_roots: 1, gate: :open}} =
             MutationAdmission.status(agent, server: server)

    assert Process.alive?(gpid)
    assert [{^gpid, _}] = Registry.lookup(registry, {:guardian, hash})
    assert {:ok, %{phase: :holding, holder: ^holder}} = Guardian.info(gpid)

    send(holder, :release)
    assert_receive {:holder_released, ^holder, :ok}, 3_000

    assert {:ok, %{active_roots: 0, gate: :open}} =
             MutationAdmission.status(agent, server: server)

    send(forged_target, :stop)
  end

  @tag packet: "VP-05D2C3I1A"
  test "security regression: dead admission cannot be replaced by an unregistered caller", ctx do
    agent = "sec_dead_admission_reconnect"
    parent = self()
    holder = spawn_holder(parent, ctx.server, agent)
    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)

    assert_receive {:holder_ready, ^holder, {:ok, %Lease{} = lease}}, 3_000
    hash = lease_hash(lease.token)
    assert [{gpid, _meta}] = Registry.lookup(ctx.registry, {:guardian, hash})

    shell_ref = Process.monitor(ctx.shell_pid)
    stop_shell!(ctx.shell_id)
    assert_receive {:DOWN, ^shell_ref, :process, _, _}, 2_000
    assert Process.whereis(ctx.server) == nil
    assert Process.alive?(gpid)

    attacker_result = Guardian.reconnect_admission(gpid, self())
    shell2 = start_shell!(ctx.shell_id, ctx.shell_opts)

    send(holder, :exit)
    holder_ref = Process.monitor(holder)
    assert_receive {:DOWN, ^holder_ref, :process, ^holder, _}, 2_000

    converged? =
      wait_until(fn ->
        match?(
          {:ok, %{active_roots: 0, gate: :open}},
          MutationAdmission.status(agent, server: ctx.server)
        )
      end)

    assert attacker_result == {:error, :not_owner}
    assert Process.whereis(ctx.server) == shell2
    assert converged?
    refute Process.alive?(gpid)
  end

  @tag packet: "VP-05D2C3I1A"
  test "security regression: runtime identity cannot be rewritten before shell restart", ctx do
    agent = "sec_runtime_identity"
    parent = self()
    holder = spawn_holder(parent, ctx.server, agent)
    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)

    assert_receive {:holder_ready, ^holder, {:ok, %Lease{}}}, 3_000
    assert [{@runtime_key, original}] = :ets.lookup(@runtime_table, @runtime_key)
    forged = forged_runtime(original)

    test_pid = self()

    spawn(fn ->
      result =
        try do
          :ets.insert(@runtime_table, {@runtime_key, forged})
          :inserted
        rescue
          ArgumentError -> :denied
        end

      send(test_pid, {:runtime_attack_result, result})
    end)

    assert_receive {:runtime_attack_result, attack_result}, 1_000

    shell_ref = Process.monitor(ctx.shell_pid)
    stop_shell!(ctx.shell_id)
    assert_receive {:DOWN, ^shell_ref, :process, _, _}, 2_000
    _shell2 = start_shell!(ctx.shell_id, ctx.shell_opts)

    status_after_restart = MutationAdmission.status(agent, server: ctx.server)

    restore_result =
      try do
        :ets.insert(@runtime_table, {@runtime_key, original})
        :restored
      rescue
        ArgumentError -> :denied
      end

    send(holder, :release)
    assert_receive {:holder_released, ^holder, :ok}, 3_000

    assert attack_result == :denied
    assert restore_result == :denied
    assert :ets.info(@runtime_table, :protection) == :protected
    controller = Process.whereis(:application_controller)
    owner = :ets.info(@runtime_table, :owner)
    heir = :ets.info(@runtime_table, :heir)
    assert owner == controller or heir == controller
    assert [{@runtime_key, ^original}] = :ets.lookup(@runtime_table, @runtime_key)

    assert status_after_restart ==
             {:ok, %{active_roots: 1, drain_waiters: 0, gate: :open, gate_generation: 1}}
  end

  @tag packet: "VP-05D2C3I1A"
  test "security regression: retired malformed drain-ready cast cannot crash authority", ctx do
    agent = "sec_malformed_cast"
    parent = self()
    holder = spawn_holder(parent, ctx.server, agent)
    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)

    assert_receive {:holder_ready, ^holder, {:ok, %Lease{}}}, 3_000
    shell_ref = Process.monitor(ctx.shell_pid)

    GenServer.cast(ctx.server, {:check_drain_ready, {:malformed, :agent_id}})

    shell_down? =
      receive do
        {:DOWN, ^shell_ref, :process, _, _} -> true
      after
        500 -> false
      end

    status_after_cast = MutationAdmission.status(agent, server: ctx.server)

    if not shell_down? do
      Process.demonitor(shell_ref, [:flush])
      send(holder, :release)
      assert_receive {:holder_released, ^holder, :ok}, 3_000
    end

    refute shell_down?

    assert status_after_cast ==
             {:ok, %{active_roots: 1, drain_waiters: 0, gate: :open, gate_generation: 1}}
  end
end
