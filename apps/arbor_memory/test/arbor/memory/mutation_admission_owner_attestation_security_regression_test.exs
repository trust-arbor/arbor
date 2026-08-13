defmodule Arbor.Memory.MutationAdmissionOwnerAttestationSecurityRegressionTest do
  @moduledoc """
  Security regression for MutationAdmission.assert_owner/2 (VP-05D2C3I1B1F0).

  Compiles against parent d33717894. Candidate behavior is gated by
  function_exported?/3 so the parent fails the assertion rather than
  setup or compilation.
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory.Config
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.MutationAdmission.Guardian
  alias Arbor.Memory.MutationAdmission.Lease
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1F0"
  @moduletag security_regression: true

  setup do
    agent_name = :"ma_own_fake_#{System.unique_integer([:positive])}"
    {:ok, _} = Fake.start_link(agent_name: agent_name)

    runtime_fp =
      Base.encode16(:crypto.hash(:sha256, "own-runtime-#{agent_name}"), case: :lower)

    node_fp =
      Base.encode16(:crypto.hash(:sha256, "own-node-#{agent_name}"), case: :lower)

    auth = start_authority(agent_name, runtime_fp, node_fp)

    on_exit(fn -> Fake.stop(agent_name) end)

    {:ok,
     server: auth.server,
     registry: auth.registry,
     agent_name: agent_name,
     runtime_fp: runtime_fp,
     node_fp: node_fp}
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "exact holder succeeds on open and draining; other process is not_owner", ctx do
    require_assert_owner!()
    agent = "own_open_drain"
    key = storage_key(agent)
    assert {:ok, %Lease{} = lease} = acq(ctx, agent)
    hash = lease_hash(lease.token)
    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})
    assert {:ok, %{depth: 1, phase: :holding}} = Guardian.info(gpid)
    assert :ok = ao(lease, server: ctx.server)

    assert {:ok, ^lease} = acq(ctx, agent, lease: lease)
    assert {:ok, %{depth: 2, phase: :holding}} = Guardian.info(gpid)
    before = snapshot(ctx.agent_name, key, ctx.registry, hash)
    assert before.info.depth == 2
    assert before.root_count == 1
    assert :ok = ao(lease, server: ctx.server)
    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before

    assert {:error, :not_owner} =
             Task.await(Task.async(fn -> ao(lease, server: ctx.server) end), 3_000)

    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before

    drain_task =
      Task.async(fn ->
        MutationAdmission.drain(agent, server: ctx.server, timeout_ms: 50)
      end)

    assert {:error, :drain_timeout} = Task.await(drain_task, 3_000)

    assert {:ok, %{gate: :draining, active_roots: 1}} =
             MutationAdmission.status(agent, server: ctx.server)

    assert :ok = ao(lease, server: ctx.server)
    assert {:ok, %{depth: 2, phase: :holding}} = Guardian.info(gpid)

    assert {:error, :not_owner} =
             Task.await(Task.async(fn -> ao(lease, server: ctx.server) end), 3_000)

    assert {:ok, %{depth: 2, phase: :holding}} = Guardian.info(gpid)
    assert map_size(Fake.peek(ctx.agent_name, key).data["roots"]) == 1
    assert :ok = MutationAdmission.release(lease, server: ctx.server)
    assert :ok = MutationAdmission.release(lease, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "handoff transfers attestation and handoff back reverses it without depth change", ctx do
    require_assert_owner!()
    agent = "own_handoff"
    source = spawn_peer()
    target = spawn_peer()

    on_exit(fn ->
      if Process.alive?(source), do: Process.exit(source, :kill)
      if Process.alive?(target), do: Process.exit(target, :kill)
    end)

    assert {:ok, %Lease{} = lease} = ask_peer(source, fn -> acq(ctx, agent) end)
    hash = lease_hash(lease.token)
    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})

    assert {:ok, ^lease} =
             ask_peer(source, fn ->
               MutationAdmission.handoff(lease, target, server: ctx.server)
             end)

    assert {:error, :not_owner} = ask_peer(source, fn -> ao(lease, server: ctx.server) end)
    assert :ok = ask_peer(target, fn -> ao(lease, server: ctx.server) end)
    assert {:ok, %{depth: 1, phase: :holding, holder: ^target}} = Guardian.info(gpid)

    assert {:ok, ^lease} =
             ask_peer(target, fn ->
               MutationAdmission.handoff(lease, source, server: ctx.server)
             end)

    assert :ok = ask_peer(source, fn -> ao(lease, server: ctx.server) end)
    assert {:error, :not_owner} = ask_peer(target, fn -> ao(lease, server: ctx.server) end)
    assert {:ok, %{depth: 1, phase: :holding, holder: ^source}} = Guardian.info(gpid)
    assert :ok = ask_peer(source, fn -> MutationAdmission.release(lease, server: ctx.server) end)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "malformed opts and lease shape fail before any server or backend work", ctx do
    require_assert_owner!()
    agent = "own_shape"
    key = storage_key(agent)
    max_agent_bytes = Config.mutation_admission_max_agent_id_bytes()
    assert {:ok, %Lease{} = good} = acq(ctx, agent)
    before = Fake.peek(ctx.agent_name, key)
    Fake.clear_history(ctx.agent_name)

    assert {:error, :invalid_request} = ao(good, server: ctx.server, backend: Fake)
    assert {:error, :invalid_request} = ao(good, server: ctx.server, server: ctx.server)
    assert {:error, :invalid_request} = apply(MutationAdmission, :assert_owner, [good, :not_kw])

    bad_leases = [
      %Lease{token: nil, agent_id: agent, admitted_gate_gen: good.admitted_gate_gen},
      %Lease{token: <<1, 2, 3>>, agent_id: agent, admitted_gate_gen: good.admitted_gate_gen},
      %Lease{
        token: :crypto.strong_rand_bytes(64),
        agent_id: agent,
        admitted_gate_gen: good.admitted_gate_gen
      },
      %Lease{token: good.token, agent_id: agent, admitted_gate_gen: 0},
      %Lease{token: good.token, agent_id: "", admitted_gate_gen: good.admitted_gate_gen},
      %Lease{
        token: good.token,
        agent_id: String.duplicate("a", max_agent_bytes + 1),
        admitted_gate_gen: good.admitted_gate_gen
      }
    ]

    for bad <- bad_leases do
      assert {:error, :invalid_lease} = ao(bad, server: ctx.server)
    end

    assert {:error, :invalid_lease} = ao(:not_a_lease, server: ctx.server)
    assert Fake.history(ctx.agent_name) == []
    assert Fake.peek(ctx.agent_name, key) == before
    assert :ok = MutationAdmission.release(good, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "token, agent, released, destroyed, dead holder, and wrong authority fail closed", ctx do
    require_assert_owner!()
    agent = "own_fail_closed"
    key = storage_key(agent)
    assert {:ok, %Lease{} = lease} = acq(ctx, agent)
    hash = lease_hash(lease.token)
    before = snapshot(ctx.agent_name, key, ctx.registry, hash)
    cas_before = cas_count(ctx.agent_name, key)

    wrong_token = %{lease | token: :crypto.strong_rand_bytes(32)}
    assert {:error, :invalid_lease} = ao(wrong_token, server: ctx.server)
    assert {:error, :invalid_lease} = ao(%{lease | agent_id: "own_other_agent"}, server: ctx.server)
    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before
    assert cas_count(ctx.agent_name, key) == cas_before

    other = start_authority(ctx.agent_name, ctx.runtime_fp, ctx.node_fp)
    assert {:error, :invalid_lease} = ao(lease, server: other.server)
    assert {:error, :unavailable} = ao(lease, server: :ma_own_missing_server)
    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before
    assert cas_count(ctx.agent_name, key) == cas_before

    assert :ok = MutationAdmission.release(lease, server: ctx.server)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent, server: ctx.server))
           end)

    assert {:error, :invalid_lease} = ao(lease, server: ctx.server)

    assert {:ok, fence} = MutationAdmission.drain(agent, server: ctx.server, timeout_ms: 500)
    assert :ok = MutationAdmission.mark_destroyed(fence, server: ctx.server)
    assert {:error, :destroyed} = ao(lease, server: ctx.server)

    dead_agent = "own_dead_holder"
    parent = self()

    holder =
      spawn(fn ->
        result = acq(ctx, dead_agent)
        send(parent, {:holder_ready, self(), result})

        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    assert_receive {:holder_ready, ^holder, {:ok, %Lease{} = dead_lease}}, 3_000
    href = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^href, :process, ^holder, _}, 2_000

    assert wait_until(fn ->
             match?(
               {:ok, %{active_roots: 0}},
               MutationAdmission.status(dead_agent, server: ctx.server)
             )
           end)

    assert {:error, :invalid_lease} = ao(dead_lease, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "other-runtime authority cannot promote a foreign root", ctx do
    require_assert_owner!()
    agent = "own_runtime"
    key = storage_key(agent)
    assert {:ok, %Lease{} = lease} = acq(ctx, agent)
    before = Fake.peek(ctx.agent_name, key)
    other_rt = String.duplicate("c", 64)
    refute other_rt == ctx.runtime_fp
    other = start_authority(ctx.agent_name, other_rt, ctx.node_fp)
    cas_before = cas_count(ctx.agent_name, key)
    assert {:error, :invalid_lease} = ao(lease, server: other.server)
    assert Fake.peek(ctx.agent_name, key) == before
    assert cas_count(ctx.agent_name, key) == cas_before
    assert :ok = ao(lease, server: ctx.server)
    assert :ok = MutationAdmission.release(lease, server: ctx.server)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "pending releasing guardian denies without mutating durable or runtime state", ctx do
    require_assert_owner!()
    agent = "own_releasing"
    key = storage_key(agent)
    parent = self()

    holder =
      spawn(fn ->
        assert {:ok, lease} = acq(ctx, agent)
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

        result = MutationAdmission.handoff(lease, target, server: ctx.server)
        send(parent, {:handoff_result, result})

        receive do
          {:assert, from} ->
            send(from, {:assert_result, ao(lease, server: ctx.server)})
        end

        receive do
          :done -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
    assert_receive {:lease, lease}, 3_000
    assert_receive {:target, target}, 3_000
    hash = lease_hash(lease.token)

    Fake.clear_history(ctx.agent_name)
    Fake.set_cas_success_budget(ctx.agent_name, 1)
    Fake.arm_sync(ctx.agent_name, [:cas], 1)
    send(holder, :do_handoff)
    assert :ok = Fake.await_sync(1, 2_000)
    Process.exit(target, :kill)
    tref = Process.monitor(target)
    assert_receive {:DOWN, ^tref, :process, ^target, _}, 1_000
    Fake.release_sync(ctx.agent_name)
    assert_receive {:handoff_result, {:error, :invalid_target}}, 3_000

    assert [{gpid, _}] = Registry.lookup(ctx.registry, {:guardian, hash})
    assert {:ok, %{phase: :releasing}} = Guardian.info(gpid)
    before = snapshot(ctx.agent_name, key, ctx.registry, hash)
    cas_before = cas_count(ctx.agent_name, key)
    send(holder, {:assert, self()})
    assert_receive {:assert_result, {:error, :busy}}, 3_000
    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before
    assert cas_count(ctx.agent_name, key) == cas_before

    Fake.clear_cas_success_budget(ctx.agent_name)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent, server: ctx.server))
           end)

    send(holder, :done)
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "pending handoff and release phases on a test-owned guardian are busy and observational",
       _ctx do
    require_assert_holder!()
    registry = :"ma_own_g_reg_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry},
      id: {:ma_own_g_reg, registry}
    )

    token = :crypto.strong_rand_bytes(32)
    hash = lease_hash(token)
    agent = "own_g_pending"

    {:ok, gpid} =
      start_supervised(
        {Guardian,
         [
           lease_hash: hash,
           agent_id: agent,
           token: token,
           holder: self(),
           admission: self(),
           admission_name: :"ma_own_g_adm_#{System.unique_integer([:positive])}",
           registry: registry,
           max_depth: 32
         ]}
      )

    target =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(target), do: Process.exit(target, :kill) end)

    assert :ok = Guardian.begin_handoff(gpid, self(), target)
    pending = guardian_snapshot(gpid, registry, hash)
    assert pending.info.phase == :handing_off
    assert {:error, :busy} = apply(Guardian, :assert_holder, [gpid, self()])
    assert guardian_snapshot(gpid, registry, hash) == pending
    assert :ok = Guardian.abort_handoff(gpid, self())

    assert {:ok, {:outermost, ^hash, ^agent}} = Guardian.release_depth(gpid, self())
    releasing = guardian_snapshot(gpid, registry, hash)
    assert releasing.info.phase == :releasing
    assert {:error, :busy} = apply(Guardian, :assert_holder, [gpid, self()])
    assert guardian_snapshot(gpid, registry, hash) == releasing

    assert {:error, :not_owner} =
             Task.await(Task.async(fn -> GenServer.call(gpid, {:assert_holder, self()}) end), 3_000)

    assert guardian_snapshot(gpid, registry, hash) == releasing
  end

  @tag packet: "VP-05D2C3I1B1F0"
  test "repeated successful and failed assertions leave durable and guardian state unchanged",
       ctx do
    require_assert_owner!()
    agent = "own_observe"
    key = storage_key(agent)
    assert {:ok, %Lease{} = lease} = acq(ctx, agent)
    hash = lease_hash(lease.token)
    Fake.clear_history(ctx.agent_name)
    before = snapshot(ctx.agent_name, key, ctx.registry, hash)
    cas_before = cas_count(ctx.agent_name, key)

    for _ <- 1..3 do
      assert :ok = ao(lease, server: ctx.server)
    end

    assert {:error, :not_owner} =
             Task.await(Task.async(fn -> ao(lease, server: ctx.server) end), 3_000)

    assert {:error, :invalid_lease} =
             ao(%{lease | token: :crypto.strong_rand_bytes(32)}, server: ctx.server)

    assert {:error, :invalid_request} = ao(lease, server: ctx.server, extra: true)
    assert snapshot(ctx.agent_name, key, ctx.registry, hash) == before
    assert cas_count(ctx.agent_name, key) == cas_before
    assert :ok = MutationAdmission.release(lease, server: ctx.server)
  end

  defp require_assert_owner! do
    assert function_exported?(MutationAdmission, :assert_owner, 2),
           "MutationAdmission.assert_owner/2 is not exported"
  end

  defp require_assert_holder! do
    assert function_exported?(Guardian, :assert_holder, 2),
           "Guardian.assert_holder/2 is not exported"
  end

  defp ao(lease, opts) do
    apply(MutationAdmission, :assert_owner, [lease, opts])
  end

  defp acq(ctx, agent, opts \\ []) do
    MutationAdmission.acquire(agent, Keyword.put(opts, :server, ctx.server))
  end

  defp start_authority(agent_name, runtime_fp, node_fp) do
    registry = :"ma_own_reg_#{System.unique_integer([:positive])}"
    sup_name = :"ma_own_sup_#{System.unique_integer([:positive])}"
    server = :"ma_own_srv_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry}, id: {:ma_own_reg, registry})

    start_supervised!(
      %{
        id: {:ma_own_gsup, sup_name},
        start:
          {DynamicSupervisor, :start_link,
           [[name: sup_name, strategy: :one_for_one, max_children: 4096]]}
      }
    )

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
      id: {:ma_own_shell, server}
    )

    %{server: server, registry: registry, sup: sup_name}
  end

  defp spawn_peer do
    parent = self()

    spawn(fn ->
      peer_loop(parent)
    end)
  end

  defp peer_loop(parent) do
    receive do
      {:run, fun, ref} when is_function(fun, 0) ->
        send(parent, {:peer, self(), ref, fun.()})
        peer_loop(parent)

      :exit ->
        :ok
    end
  end

  defp ask_peer(pid, fun) when is_function(fun, 0) do
    ref = make_ref()
    send(pid, {:run, fun, ref})

    receive do
      {:peer, ^pid, ^ref, result} -> result
    after
      3_000 -> flunk("peer #{inspect(pid)} did not answer")
    end
  end

  defp lease_hash(token) do
    :crypto.hash(:sha256, "arbor.memory.mutation_admission.lease:v1" <> token)
    |> Base.encode16(case: :lower)
  end

  defp storage_key(agent), do: Base.encode16(:crypto.hash(:sha256, agent), case: :lower)

  defp cas_count(agent_name, key) do
    agent_name
    |> Fake.history()
    |> Enum.count(&(&1.kind == :compare_and_swap and &1.key == key))
  end

  defp snapshot(agent_name, key, registry, hash) do
    record = Fake.peek(agent_name, key)
    lookup = Registry.lookup(registry, {:guardian, hash})

    {gpid, meta} =
      case lookup do
        [{pid, m}] -> {pid, m}
        other -> {nil, other}
      end

    guardian_fields(gpid, meta, record)
  end

  defp guardian_snapshot(gpid, registry, hash) do
    lookup = Registry.lookup(registry, {:guardian, hash})

    meta =
      case lookup do
        [{^gpid, m}] -> m
        other -> other
      end

    guardian_fields(gpid, meta, nil)
  end

  defp guardian_fields(gpid, meta, record) do
    info =
      if is_pid(gpid) and Process.alive?(gpid) do
        {:ok, value} = Guardian.info(gpid)
        value
      end

    monitors = if is_pid(gpid), do: Process.info(gpid, :monitors)
    monitored_by = if is_pid(gpid), do: Process.info(gpid, :monitored_by)

    %{
      record: record,
      revision: record && record.revision,
      bytes: record && :erlang.term_to_binary(record.data),
      gpid: gpid,
      meta: meta,
      info: info,
      monitors: monitors,
      monitored_by: monitored_by,
      root_count: root_count(record)
    }
  end

  defp root_count(%{data: %{"roots" => roots}}) when is_map(roots), do: map_size(roots)
  defp root_count(_), do: 0

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
end
