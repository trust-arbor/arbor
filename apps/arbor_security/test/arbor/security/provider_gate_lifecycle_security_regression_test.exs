defmodule Arbor.Security.ProviderGateLifecycleSecurityRegressionTest do
  @moduledoc """
  Security regression: ProviderGate is a name-first startup-ordering barrier.
  """
  use ExUnit.Case, async: false

  @provider_roots [:joken, :joken_jwks, :req]
  @earlier :joken
  @later :joken_jwks
  @owner :arbor_security
  @probe_app :arbor_security_provider_share_probe
  @handles_key {__MODULE__, :handles}
  @wait_ms 5_000
  @named_stores [
    :arbor_security_capabilities,
    :arbor_security_identities,
    :arbor_security_signing_keys,
    :arbor_security_issuers
  ]
  @squat_child Arbor.Security.DeliveryReceiptBroker
  @squat_name Arbor.Security.DeliveryReceiptBroker

  defmodule LaterProviderStart do
    @timeout_ms 15_000
    @pt_key {__MODULE__, :barrier}

    def pt_key, do: @pt_key

    def install(waiter) when is_pid(waiter) do
      ref = make_ref()

      :persistent_term.put(@pt_key, %{
        ref: ref,
        waiter: waiter,
        blocker_pid: nil,
        outcome: nil
      })

      ref
    end

    def start(_type, _args) do
      %{ref: ref, waiter: waiter} = :persistent_term.get(@pt_key)

      :persistent_term.put(@pt_key, %{
        ref: ref,
        waiter: waiter,
        blocker_pid: self(),
        outcome: nil
      })

      send(waiter, {:later_provider_entered, ref, self()})

      receive do
        {:later_provider_release, ^ref} ->
          put_outcome(:forced_later_provider_failure)
          {:error, :forced_later_provider_failure}
      after
        @timeout_ms ->
          put_outcome(:later_provider_barrier_timeout)
          {:error, :later_provider_barrier_timeout}
      end
    end

    def state do
      case :persistent_term.get(@pt_key, :error) do
        %{ref: _, waiter: _, blocker_pid: _} = state -> state
        _ -> nil
      end
    end

    def outcome do
      case :persistent_term.get(@pt_key, %{}) do
        %{outcome: outcome} -> outcome
        _ -> nil
      end
    end

    defp put_outcome(outcome) do
      state = :persistent_term.get(@pt_key)
      :persistent_term.put(@pt_key, Map.put(state, :outcome, outcome))
    end
  end

  defmodule ProbeServer do
    use GenServer

    def start_link(provider) do
      GenServer.start_link(__MODULE__, provider, name: __MODULE__)
    end

    @impl true
    def init(provider), do: {:ok, provider}

    @impl true
    def handle_call(:ping, _from, provider) do
      started? =
        Enum.any?(Application.started_applications(), fn {app, _desc, _vsn} ->
          app == provider
        end)

      reply =
        if started? do
          :pong
        else
          {:error, {:provider_not_started, provider}}
        end

      {:reply, reply, provider}
    end
  end

  defmodule ProbeApp do
    alias Arbor.Security.ProviderGateLifecycleSecurityRegressionTest.ProbeServer

    def start(_type, provider) when is_atom(provider) do
      ProbeServer.start_link(provider)
    end
  end

  setup do
    {:trap_exit, trap_exit} = Process.info(self(), :trap_exit)

    originals = %{
      apps: Map.new([@owner | @provider_roots], fn app -> {app, snapshot_app(app)} end),
      start_children: Application.fetch_env(:arbor_security, :start_children),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime),
      topology: snapshot_owner_topology(),
      trap_exit: trap_exit
    }

    :persistent_term.put(@handles_key, %{
      starter_pid: nil,
      starter_mref: nil,
      result_ref: nil,
      barrier_ref: nil,
      blocker_pid: nil,
      rogue_pids: []
    })

    on_exit(fn -> cleanup(originals) end)
    :ok
  end

  test "security regression: provider gate name collision has zero provider load or start side effects" do
    stop_security()
    stop_and_unload_roots()
    loaded_before = loaded_root_set()
    started_before = started_root_set()
    {:ok, rogue} = Agent.start_link(fn -> :ok end, name: Arbor.Security.ProviderGate)
    track_rogue(rogue)
    put_full_start()

    {result, stops} =
      with_application_stop_trace(fn ->
        Application.ensure_all_started(@owner)
      end)

    assert {:error, {:arbor_security, {reason, {Arbor.Security.Application, :start, _}}}} =
             result

    assert reason == {:provider_gate_name_collision, rogue}
    assert Process.whereis(Arbor.Security.ProviderGate) == rogue
    assert Process.alive?(rogue)
    refute Process.whereis(Arbor.Security.Supervisor)
    refute Process.whereis(Arbor.Security.CapabilityStore)
    refute Process.whereis(Arbor.Security.DeliveryReceiptBroker)
    refute Process.whereis(Arbor.Security.SystemAuthority)

    Enum.each(@named_stores, fn name ->
      refute Process.whereis(name)
    end)

    assert loaded_root_set() == loaded_before
    assert started_root_set() == started_before
    refute Enum.any?(stops, &(&1 in @provider_roots))
  end

  @tag :provider_gate_late_sharing
  test "security regression: later provider start failure preserves admitted roots and late probe consumer" do
    stop_security()
    barrier_ref = install_later_barrier()
    stop_admitted_prefix()
    refute_prefix_started()
    load_probe_spec!()
    put_full_start()

    {{otp, sequence}, stops} =
      with_application_stop_trace(fn ->
        {starter_pid, starter_mref, result_ref} = start_owner_unlinked(@owner)

        {:blocked, blocker_pid} =
          await_later_barrier(barrier_ref, starter_pid, starter_mref, result_ref)

        sequence = [:later_provider_barrier_entered]
        assert_prefix_started()
        {:ok, _} = Application.ensure_all_started(@probe_app)
        assert GenServer.call(ProbeServer, :ping) == :pong
        sequence = sequence ++ [:probe_adopted]
        send(blocker_pid, {:later_provider_release, barrier_ref})
        sequence = sequence ++ [:later_provider_barrier_released]
        otp = await_owner_result(starter_pid, starter_mref, result_ref)
        {otp, sequence}
      end)

    assert sequence == [
             :later_provider_barrier_entered,
             :probe_adopted,
             :later_provider_barrier_released
           ]

    assert {:error, {:arbor_security, {reason, {Arbor.Security.Application, :start, _}}}} = otp
    assert_forced_later_provider_failure(reason)
    refute Process.whereis(Arbor.Security.Supervisor)
    refute Process.whereis(Arbor.Security.ProviderGate)
    assert_prefix_started()
    refute MapSet.member?(started_app_set(), @later)
    assert MapSet.member?(started_app_set(), @probe_app)
    assert GenServer.call(ProbeServer, :ping) == :pong
    refute Enum.any?(stops, &(&1 in [@probe_app | @provider_roots]))
  end

  test "security regression: downstream start failure leaves admitted providers running and does not peel unrelated errors" do
    stop_security()
    stop_and_unload_roots()
    {:ok, squat} = Agent.start_link(fn -> :ok end, name: @squat_name)
    track_rogue(squat)
    put_full_start()

    {result, stops} =
      with_application_stop_trace(fn ->
        Application.ensure_all_started(@owner)
      end)

    assert {:error, {:arbor_security, {reason, {Arbor.Security.Application, :start, _}}}} =
             result

    assert identifies_squatted_child?(reason, @squat_child, squat)
    refute match?({:provider_gate_name_collision, _}, reason)
    refute Process.whereis(Arbor.Security.Supervisor)
    refute Process.whereis(Arbor.Security.ProviderGate)
    assert Process.whereis(@squat_name) == squat
    assert Process.alive?(squat)

    Enum.each(@provider_roots, fn app ->
      assert MapSet.member?(started_app_set(), app)
    end)

    refute Enum.any?(stops, &(&1 in @provider_roots))
  end

  test "security regression: owning application stop does not stop provider roots" do
    stop_security()
    newly_admitted = stop_roots_for_cold_admission!()
    refute_roots_started(newly_admitted)
    put_full_start()
    assert {:ok, _} = Application.ensure_all_started(@owner)
    assert_roots_started(newly_admitted)

    {result, stops} =
      with_application_stop_trace(fn ->
        Application.stop(@owner)
      end)

    assert result == :ok
    refute Process.whereis(Arbor.Security.Supervisor)
    refute Enum.any?(stops, &(&1 in newly_admitted))
    assert_roots_started(newly_admitted)

    assert {:ok, _} = Application.ensure_all_started(@owner)
    assert_roots_started(newly_admitted)

    {warm_result, warm_stops} =
      with_application_stop_trace(fn ->
        Application.stop(@owner)
      end)

    assert warm_result == :ok
    refute Process.whereis(Arbor.Security.Supervisor)
    refute Enum.any?(warm_stops, &(&1 in newly_admitted))
    assert_roots_started(newly_admitted)
  end

  defp admitted_prefix, do: Enum.take_while(@provider_roots, &(&1 != @later))

  defp stop_admitted_prefix do
    Enum.each(Enum.reverse(admitted_prefix()), &Application.stop/1)
  end

  defp refute_prefix_started do
    Enum.each(admitted_prefix(), fn app ->
      refute MapSet.member?(started_app_set(), app)
    end)
  end

  defp assert_prefix_started do
    Enum.each(admitted_prefix(), fn app ->
      assert MapSet.member?(started_app_set(), app)
    end)
  end

  defp stop_roots_for_cold_admission! do
    Enum.each(Enum.reverse(@provider_roots), fn app ->
      if app == :req and kernel_runtime_started?() do
        :ok
      else
        case Application.stop(app) do
          :ok -> :ok
          {:error, {:not_started, ^app}} -> :ok
          other -> flunk("failed to stop #{inspect(app)} for cold owner-stop: #{inspect(other)}")
        end
      end
    end)

    Enum.reject(@provider_roots, &(&1 == :req and kernel_runtime_started?()))
  end

  defp refute_roots_started(roots) do
    Enum.each(roots, fn app ->
      refute MapSet.member?(started_app_set(), app)
    end)
  end

  defp assert_roots_started(roots) do
    Enum.each(roots, fn app ->
      assert MapSet.member?(started_app_set(), app)
    end)
  end

  defp assert_forced_later_provider_failure(reason) do
    assert LaterProviderStart.outcome() == :forced_later_provider_failure
    assert {:provider_start_failed, @later, inner} = reason
    assert reason_contains?(inner, :forced_later_provider_failure)
    refute reason_contains?(inner, :later_provider_barrier_timeout)
    refute reason_contains?(reason, :later_provider_barrier_timeout)
  end

  defp reason_contains?(term, atom) when term == atom, do: true

  defp reason_contains?(term, atom) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&reason_contains?(&1, atom))
  end

  defp reason_contains?(term, atom) when is_list(term) do
    Enum.any?(term, &reason_contains?(&1, atom))
  end

  defp reason_contains?(_other, _atom), do: false

  defp put_full_start do
    Application.put_env(:arbor_security, :start_children, true)
    put_kernel_runtime(start_profile: :full)
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp started_app_set do
    Application.started_applications()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp started_root_set, do: MapSet.intersection(started_app_set(), MapSet.new(@provider_roots))

  defp loaded_root_set do
    Application.loaded_applications()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(@provider_roots))
  end

  defp snapshot_app(app) do
    cond do
      MapSet.member?(started_app_set(), app) -> :started
      loaded_app?(app) -> :loaded
      true -> :unloaded
    end
  end

  defp loaded_app?(app) do
    Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == app))
  end

  defp stop_and_unload_roots do
    Enum.each(Enum.reverse(@provider_roots), fn app ->
      if app == :req and kernel_runtime_started?() do
        :ok
      else
        _ = Application.stop(app)
        _ = Application.unload(app)
      end
    end)

    :ok
  end

  defp kernel_runtime_started?, do: MapSet.member?(started_app_set(), :arbor_kernel_runtime)

  defp req_held_by_kernel_runtime? do
    kernel_runtime_started?() and @later != :req
  end

  defp install_later_barrier do
    _ = Code.ensure_loaded!(LaterProviderStart)
    ref = LaterProviderStart.install(self())
    put_handle(%{barrier_ref: ref})

    case Application.load(@later) do
      :ok -> :ok
      {:error, {:already_loaded, @later}} -> :ok
    end

    {:ok, keys} = :application.get_all_key(@later)
    _ = Application.stop(@later)
    _ = Application.unload(@later)

    :ok =
      :application.load({:application, @later, Keyword.put(keys, :mod, {LaterProviderStart, []})})

    ref
  end

  defp load_probe_spec! do
    unload_probe()

    spec = [
      description: ~c"security provider share probe",
      vsn: ~c"0.0.0",
      id: ~c"",
      modules: [ProbeApp, ProbeServer],
      registered: [ProbeServer],
      applications: [:kernel, :stdlib, @earlier],
      env: [],
      mod: {ProbeApp, @earlier}
    ]

    :ok = :application.load({:application, @probe_app, spec})
    :ok
  end

  defp unload_probe do
    _ = Application.stop(@probe_app)
    _ = Application.unload(@probe_app)
    :ok
  end

  defp stop_security do
    case Application.stop(@owner) do
      :ok -> :ok
      {:error, {:not_started, @owner}} -> :ok
    end
  end

  defp stop_named(name) do
    pid = Process.whereis(name)
    if is_pid(pid), do: stop_pid(pid)
    :ok
  end

  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> Process.exit(pid, :kill)
      end
    end

    :ok
  end

  defp track_rogue(pid) when is_pid(pid) do
    put_handle(%{rogue_pids: [pid | handles().rogue_pids]})
  end

  defp handles do
    :persistent_term.get(@handles_key, %{
      starter_pid: nil,
      starter_mref: nil,
      result_ref: nil,
      barrier_ref: nil,
      blocker_pid: nil,
      rogue_pids: []
    })
  end

  defp put_handle(updates) when is_map(updates) do
    :persistent_term.put(@handles_key, Map.merge(handles(), updates))
  end

  defp start_owner_unlinked(owner) do
    result_ref = make_ref()
    caller = self()

    {starter_pid, starter_mref} =
      spawn_monitor(fn ->
        send(caller, {:owner_start_result, result_ref, Application.ensure_all_started(owner)})
      end)

    put_handle(%{starter_pid: starter_pid, starter_mref: starter_mref, result_ref: result_ref})
    {starter_pid, starter_mref, result_ref}
  end

  defp await_later_barrier(barrier_ref, starter_pid, starter_mref, result_ref) do
    receive do
      {:later_provider_entered, ^barrier_ref, blocker_pid} when is_pid(blocker_pid) ->
        put_handle(%{blocker_pid: blocker_pid})
        {:blocked, blocker_pid}

      {:owner_start_result, ^result_ref, result} ->
        Process.demonitor(starter_mref, [:flush])
        flunk("owner start completed before later-provider barrier: #{inspect(result)}")

      {:DOWN, ^starter_mref, :process, ^starter_pid, reason} ->
        flunk("owner starter exited before later-provider barrier: #{inspect(reason)}")
    after
      @wait_ms -> flunk("timed out waiting for later-provider start to enter barrier")
    end
  end

  defp await_owner_result(starter_pid, starter_mref, result_ref) do
    receive do
      {:owner_start_result, ^result_ref, result} ->
        Process.demonitor(starter_mref, [:flush])
        result

      {:DOWN, ^starter_mref, :process, ^starter_pid, reason} ->
        flunk("owner starter died without result: #{inspect(reason)}")
    after
      @wait_ms -> flunk("timed out waiting for owner start result")
    end
  end

  defp release_later_barrier do
    hs = handles()
    state = LaterProviderStart.state()
    ref = hs.barrier_ref || (is_map(state) && state.ref)
    pid = hs.blocker_pid || (is_map(state) && state.blocker_pid)

    if is_pid(pid) and Process.alive?(pid) and is_reference(ref) do
      send(pid, {:later_provider_release, ref})
    end

    :ok
  end

  defp finish_starter do
    hs = handles()
    pid = hs.starter_pid
    mref = hs.starter_mref

    if is_pid(pid) and Process.alive?(pid) do
      wait_mref = Process.monitor(pid)

      receive do
        {:DOWN, ^wait_mref, :process, ^pid, _} -> :ok
      after
        @wait_ms ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^wait_mref, :process, ^pid, _} -> :ok
          after
            @wait_ms -> :ok
          end
      end

      Process.demonitor(wait_mref, [:flush])
    end

    if is_reference(mref), do: Process.demonitor(mref, [:flush])
    :ok
  end

  defp cleanup(originals) do
    disable_traces()
    release_later_barrier()
    finish_starter()
    Enum.each(handles().rogue_pids, &stop_pid/1)
    stop_named(Arbor.Security.ProviderGate)
    stop_named(@squat_name)
    stop_named(ProbeServer)
    unload_probe()
    stop_security()
    restore_provider_roots(originals)
    restore_fetched_env(:arbor_security, :start_children, originals.start_children)

    case originals.kernel_runtime do
      {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
      :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
    end

    restore_app(@owner, Map.fetch!(originals.apps, @owner))
    restore_owner_topology(originals.topology, Map.fetch!(originals.apps, @owner))
    _ = :persistent_term.erase(@handles_key)
    _ = :persistent_term.erase(LaterProviderStart.pt_key())
    Process.flag(:trap_exit, originals.trap_exit)
    assert snapshot_app(@owner) == Map.fetch!(originals.apps, @owner)

    Enum.each(@provider_roots, fn app ->
      assert snapshot_app(app) == Map.fetch!(originals.apps, app)
    end)
  end

  defp restore_provider_roots(originals) do
    Enum.each(Enum.reverse(@provider_roots), fn app ->
      restore_provider_root_phase(app, originals, :reset)
    end)

    Enum.each(@provider_roots, fn app ->
      restore_provider_root_phase(app, originals, :apply)
    end)
  end

  defp restore_provider_root_phase(:req = app, originals, phase) do
    if req_held_by_kernel_runtime?() do
      assert snapshot_app(:req) == Map.fetch!(originals.apps, :req)
      :ok
    else
      do_restore_provider_root_phase(app, originals, phase)
    end
  end

  defp restore_provider_root_phase(app, originals, phase) do
    do_restore_provider_root_phase(app, originals, phase)
  end

  defp do_restore_provider_root_phase(app, _originals, :reset) do
    stop_app!(app)
    unload_app!(app)
  end

  defp do_restore_provider_root_phase(app, originals, :apply) do
    apply_lifecycle(app, Map.fetch!(originals.apps, app))
  end

  defp restore_app(app, desired) do
    stop_app!(app)
    unload_app!(app)
    apply_lifecycle(app, desired)
  end

  defp stop_app!(app) do
    case Application.stop(app) do
      :ok -> :ok
      {:error, {:not_started, ^app}} -> :ok
      other -> flunk("failed to stop #{inspect(app)}: #{inspect(other)}")
    end
  end

  defp unload_app!(app) do
    case Application.unload(app) do
      :ok -> :ok
      {:error, {:not_loaded, ^app}} -> :ok
      other -> flunk("failed to unload #{inspect(app)}: #{inspect(other)}")
    end
  end

  defp apply_lifecycle(_app, :unloaded), do: :ok
  defp apply_lifecycle(app, :loaded), do: load_app(app)

  defp apply_lifecycle(app, :started) do
    load_app(app)

    case Application.ensure_all_started(app) do
      {:ok, _} -> :ok
      other -> flunk("failed to start #{inspect(app)}: #{inspect(other)}")
    end
  end

  defp load_app(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      other -> flunk("failed to load #{inspect(app)}: #{inspect(other)}")
    end
  end

  defp restore_fetched_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_fetched_env(app, key, :error), do: Application.delete_env(app, key)

  defp snapshot_owner_topology do
    %{
      owner: snapshot_supervisor(Arbor.Security.Supervisor),
      named:
        Map.new(@named_stores, fn name ->
          {name, classify_named_process(name, Arbor.Security.Supervisor)}
        end)
    }
  end

  defp snapshot_supervisor(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        children =
          Enum.map(Supervisor.which_children(name), fn {id, child, _type, _mods} ->
            spec =
              case Supervisor.get_childspec(name, id) do
                {:ok, child_spec} -> child_spec
                other -> flunk("failed to snapshot child spec #{inspect(id)}: #{inspect(other)}")
              end

            status =
              cond do
                is_pid(child) -> :pid
                child == :undefined -> :undefined
                child == :restarting -> :restarting
                true -> child
              end

            %{id: id, spec: spec, status: status}
          end)

        {:present, children}

      _ ->
        :absent
    end
  end

  defp classify_named_process(name, supervisor) do
    pid = Process.whereis(name)

    cond do
      not is_pid(pid) -> :absent
      supervisor_has_id?(supervisor, name) -> :supervisor_child
      true -> :independent
    end
  end

  defp supervisor_has_id?(supervisor, id) do
    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        Enum.any?(Supervisor.which_children(supervisor), fn
          {^id, _, _, _} -> true
          _ -> false
        end)

      _ ->
        false
    end
  end

  defp restore_owner_topology(_topology, desired) when desired != :started, do: :ok

  defp restore_owner_topology(topology, :started) do
    assert_owner_child_ids!(topology.owner)
    restore_named!(topology.named)
    assert_named_topology!(topology.named)
  end

  defp assert_owner_child_ids!(:absent), do: refute(Process.whereis(Arbor.Security.Supervisor))

  defp assert_owner_child_ids!({:present, children}) do
    supervisor = Arbor.Security.Supervisor
    assert is_pid(Process.whereis(supervisor))
    expected = MapSet.new(children, & &1.id)

    actual =
      supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    missing = MapSet.difference(expected, actual)

    Enum.each(children, fn %{id: id, spec: spec} ->
      if MapSet.member?(missing, id) do
        start_child_exact!(supervisor, id, spec)
      end
    end)

    actual =
      supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    assert MapSet.subset?(expected, actual)
    refute supervisor_has_id?(supervisor, Arbor.Security.ProviderGate) and
             not Enum.any?(children, &(&1.id == Arbor.Security.ProviderGate))
  end

  defp start_child_exact!(supervisor, id, spec) do
    case Supervisor.start_child(supervisor, spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok

      {:error, :already_present} ->
        :ok = Supervisor.delete_child(supervisor, id)

        case Supervisor.start_child(supervisor, spec) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          other -> flunk("failed to restart #{inspect(id)}: #{inspect(other)}")
        end

      other ->
        flunk("failed to restore #{inspect(id)}: #{inspect(other)}")
    end
  end

  defp restore_named!(named) do
    Enum.each(@named_stores, fn name ->
      case Map.fetch!(named, name) do
        :absent ->
          if is_pid(Process.whereis(name)) and
               not supervisor_has_id?(Arbor.Security.Supervisor, name) do
            stop_named(name)
          end

        _present ->
          :ok
      end
    end)
  end

  defp assert_named_topology!(named) do
    Enum.each(@named_stores, fn name ->
      case Map.fetch!(named, name) do
        :absent ->
          refute classify_named_process(name, Arbor.Security.Supervisor) == :independent

        expected ->
          assert classify_named_process(name, Arbor.Security.Supervisor) == expected
      end
    end)
  end

  defp identifies_squatted_child?(reason, child_id, squat_pid) do
    failure_branch_identifies?(reason, child_id, squat_pid)
  end

  defp failure_branch_identifies?({:shutdown, inner}, child_id, squat_pid) do
    failure_branch_identifies?(inner, child_id, squat_pid)
  end

  defp failure_branch_identifies?({:failed_to_start_child, id, inner}, child_id, squat_pid)
       when id == child_id do
    already_started_pid?(inner, squat_pid)
  end

  defp failure_branch_identifies?({:failed_to_start_child, _id, inner}, child_id, squat_pid) do
    failure_branch_identifies?(inner, child_id, squat_pid)
  end

  defp failure_branch_identifies?({inner, child}, child_id, squat_pid)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    if child_record_id?(child, child_id) do
      already_started_pid?(inner, squat_pid)
    else
      failure_branch_identifies?(inner, child_id, squat_pid)
    end
  end

  defp failure_branch_identifies?(_other, _child_id, _squat_pid), do: false

  defp child_record_id?(child, child_id) do
    mfargs = elem(child, 3)
    elem(child, 2) == child_id or match?({^child_id, _, _}, mfargs)
  end

  defp already_started_pid?({:already_started, pid}, squat_pid) when pid == squat_pid, do: true
  defp already_started_pid?({:shutdown, inner}, squat_pid), do: already_started_pid?(inner, squat_pid)

  defp already_started_pid?({:failed_to_start_child, _id, inner}, squat_pid) do
    already_started_pid?(inner, squat_pid)
  end

  defp already_started_pid?({inner, child}, squat_pid)
       when is_tuple(child) and tuple_size(child) >= 4 and elem(child, 0) == :child do
    already_started_pid?(inner, squat_pid)
  end

  defp already_started_pid?(_other, _squat_pid), do: false

  defp with_application_stop_trace(fun) do
    _ = Code.ensure_loaded!(:application)
    :erlang.trace_pattern({:application, :stop, 1}, true, [:local])
    :erlang.trace(:all, true, [:call])

    try do
      result = fun.()
      delivery = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, :all, ^delivery} -> :ok
      after
        @wait_ms -> flunk("trace delivery barrier timed out")
      end

      {result, collect_stop_traces([])}
    after
      disable_traces()
    end
  end

  defp disable_traces do
    :erlang.trace(:all, false, [:call])
    :erlang.trace_pattern({:application, :stop, 1}, false, [:local])
    flush_traces()
    :ok
  end

  defp collect_stop_traces(acc) do
    receive do
      {:trace, _pid, :call, {:application, :stop, [app]}} -> collect_stop_traces(acc ++ [app])
    after
      0 -> acc
    end
  end

  defp flush_traces do
    receive do
      {:trace, _, _, _} -> flush_traces()
      {:trace, _, _, _, _} -> flush_traces()
    after
      0 -> :ok
    end
  end
end
