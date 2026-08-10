defmodule Arbor.Agent.TemplateAuthorityLifecycleQuiescenceSecurityRegressionTest do
  @moduledoc """
  Phase 4C C2B security regression: error-preserving runtime ownership observation,
  serialized Reconciler suppression under the exact TaskStore fence, and bounded
  local runtime quiescence with positive drain proof.

  Calls PUBLIC Agent-library APIs (Registry.observe_target/1, Reconciler.reconcile_now/1,
  Reconciler.synchronize_target/3, RuntimeQuiescence.quiesce/3, TaskStore fence API).
  Test-build-only collaborator seams (gated by Mix.env()==:test) inject deterministic
  sources without tearing down global Registry/:pg state. Every fail-open case name
  includes "security regression".
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Agent.{Character, Profile, ProfileStore, Reconciler, Registry, RuntimeQuiescence}
  alias Arbor.Agent.Orchestration.{TaskControlRecoveryMemory, TaskStore}
  alias Arbor.Persistence.BufferedStore

  @profiles_store :arbor_agent_profiles
  @peer_rpc_timeout_ms 2_000
  @peer_stop_timeout_ms 3_000
  @peer_name :c2b_peer
  @distributed_name :c2b_test
  @dead_stop_supervisor :c2b_dead_sup

  # ---------------------------------------------------------------------------
  # Test doubles (test-build only; never referenced by production code)
  # ---------------------------------------------------------------------------

  # Records calls to a shared :duplicate_bag ETS table (:c2b_calls) so any process
  # (Reconciler or test) can read them. resume_agent blocks on a :release message
  # only when :resume_blocks is set; otherwise returns immediately.
  defmodule FakeManager do
    @moduledoc false

    alias Arbor.Agent.Registry, as: Reg

    def resume_agent(agent_id, _opts) do
      record(:resume, agent_id)
      send(test_pid(), {:resume_entered, agent_id})

      if blocks?() do
        receive do
          :release -> :ok
        after
          5_000 -> :timeout
        end
      end

      # Simulate the start becoming observable.
      register_local(agent_id)
      send(test_pid(), {:resume_done, agent_id})
      {:ok, agent_id, nil}
    end

    # Reap path: Reconciler applies a :reap intent via stop_agent/1 by agent id.
    def stop_agent(agent_id) do
      record(:stop_agent, agent_id)

      case stop_mode() do
        :noop -> :ok
        :normal -> unregister_and_kill(agent_id)
      end
    end

    # Exact-owner stop path (Phase 4C C2B). RuntimeQuiescence calls stop_owner/1
    # with the observed owner pid AFTER compare_delete already removed the
    # registry row, so this never touches the registry. The pid is the exact
    # observed owner — never a re-resolution by agent id. Modes: :normal kills
    # the exact pid; :noop returns immediately (worker settles via DOWN);
    # :blocking never settles -> the worker is killed at the effect cutoff ->
    # :stop_timeout.
    def stop_owner(owner_pid) do
      record(:stop_owner, owner_pid)

      case stop_mode() do
        :noop -> :ok
        :blocking -> receive(do: (:release_blocking -> :ok))
        :normal -> Process.exit(owner_pid, :kill)
      end

      :ok
    end

    defp register_local(agent_id) do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Reg.register(agent_id, pid, %{module: __MODULE__})
      Process.put({__MODULE__, {:last_pid, agent_id}}, pid)
    end

    defp unregister_and_kill(agent_id) do
      case Reg.whereis(agent_id) do
        {:ok, pid} ->
          Process.exit(pid, :kill)
          Reg.unregister(agent_id)
          :ok

        _ ->
          :ok
      end
    end

    # stop_mode lives in ETS so it is visible to the worker process that runs
    # stop_owner/1 (Process.get would read the wrong process dictionary).
    defp stop_mode do
      case :ets.lookup(:c2b_calls, :stop_mode) do
        [{:stop_mode, mode}] -> mode
        [] -> :normal
      end
    end

    defp blocks? do
      :ets.lookup(:c2b_calls, :resume_blocks) == [{:resume_blocks, true}]
    end

    defp test_pid do
      case :ets.lookup(:c2b_calls, :test_pid) do
        [{:test_pid, pid}] -> pid
        [] -> self()
      end
    end

    defp record(tag, agent_id) do
      if :ets.whereis(:c2b_calls) != :undefined,
        do: :ets.insert(:c2b_calls, {tag, agent_id})
    end
  end

  # Scripted TaskStore: returns canned replies for target_fenced?/verify_target_fence,
  # and can exit on a target_fenced? call. Other calls return {:error, :unknown}.
  defmodule FakeTaskStore do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def set_target_fenced(name, reply), do: GenServer.call(name, {:set_fenced, reply})

    def init(opts) do
      {:ok,
       %{
         fenced: Keyword.get(opts, :target_fenced_reply, {:ok, false}),
         exit_fenced: Keyword.get(opts, :exit_on_target_fenced, false)
       }}
    end

    def handle_call({:set_fenced, reply}, _from, s), do: {:reply, :ok, %{s | fenced: reply}}

    def handle_call({:target_fenced?, _target}, _from, %{exit_fenced: true} = _s),
      do: exit(:c2b_boom)

    def handle_call({:target_fenced?, _target}, _from, s), do: {:reply, s.fenced, s}

    def handle_call(_other, _from, s), do: {:reply, {:error, :unknown}, s}
  end

  # Strict-list fake registry for the actual-snapshot suppression test.
  defmodule FakeRegistry do
    @moduledoc false

    def list_strict do
      case :ets.lookup(:c2b_calls, :list_strict_reply) do
        [{:list_strict_reply, reply}] -> reply
        [] -> {:ok, []}
      end
    end
  end

  # Scripted runtime probe: returns a scripted sequence (consumed in order) or a
  # fixed reply, for drain-loop tests.
  defmodule FakeRuntimeProbe do
    @moduledoc false

    alias Arbor.Agent.Registry, as: Reg

    # observe_target_owner/1 returns owner-shaped scripted values consumed by
    # the quiescence shell: {:ok, pid} for a confirmed local owner, or a typed
    # error. Scripted via :probe_script (consumed in order) or :probe_reply.
    def observe_target_owner(_agent_id) do
      case :ets.lookup(:c2b_calls, :probe_script) do
        [{:probe_script, [h | t]}] ->
          :ets.insert(:c2b_calls, {:probe_script, t})
          h

        [{:probe_script, []}] ->
          {:error, :absent}

        [] ->
          case :ets.lookup(:c2b_calls, :probe_reply) do
            [{:probe_reply, reply}] -> reply
            [] -> {:error, :absent}
          end
      end
    end

    # The atomic exact-owner compare-delete runs for real through the public
    # Registry API whenever the stop path reaches it.
    def remove_owner_if_match(agent_id, observed_pid) do
      Reg.remove_owner_if_match(agent_id, observed_pid)
    end
  end

  # Deterministic TaskStore fake for fence-loss-during-drain: counts
  # verify_target_fence calls and flips to {:error, :target_not_fenced} after a
  # configured count, so the drain loses the fence on a FIXED iteration with no
  # scheduler race. Handles install/remove/target_fenced?/verify_target_fence.
  defmodule DeterministicFenceStore do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def set_fence(name, id, op), do: GenServer.call(name, {:set_fence, id, op})
    def set_verify_delay(name, call, ms), do: GenServer.call(name, {:set_verify_delay, call, ms})

    @impl true
    def init(opts) do
      {:ok,
       %{
         fence: nil,
         verify_calls: 0,
         fail_after: Keyword.get(opts, :fail_after, :infinity),
         delay_on: Keyword.get(opts, :delay_on),
         delay_ms: Keyword.get(opts, :delay_ms, 0)
       }}
    end

    @impl true
    def handle_call({:set_fence, id, op}, _from, s), do: {:reply, :ok, %{s | fence: {id, op}}}

    def handle_call({:set_verify_delay, call, ms}, _from, s),
      do: {:reply, :ok, %{s | delay_on: call, delay_ms: ms}}

    def handle_call({:install_target_fence, id, op}, _from, s),
      do: {:reply, :ok, %{s | fence: {id, op}}}

    def handle_call({:remove_target_fence, _id, _op}, _from, s),
      do: {:reply, :ok, %{s | fence: nil}}

    def handle_call({:target_fenced?, _id}, _from, s),
      do: {:reply, {:ok, s.fence != nil}, s}

    def handle_call({:verify_target_fence, id, op}, _from, s) do
      n = s.verify_calls + 1

      if s.delay_on == n and s.delay_ms > 0 do
        Process.sleep(s.delay_ms)
      end

      reply = verify_reply(s, id, op, n)
      {:reply, reply, %{s | verify_calls: n}}
    end

    def handle_call(_other, _from, s), do: {:reply, {:error, :unknown}, s}

    defp verify_reply(s, id, op, n) do
      cond do
        s.fail_after != :infinity and n > s.fail_after -> {:error, :target_not_fenced}
        s.fence == {id, op} -> :ok
        s.fence == nil -> {:error, :target_not_fenced}
        true -> {:error, :not_owner}
      end
    end
  end

  # A deliberately non-responsive stand-in for Task.Supervisor. It exercises the
  # public quiescence path when Task.Supervisor.start_child/2 itself never replies.
  defmodule BlockingStopSupervisor do
    @moduledoc false
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(_request, _from, state), do: {:noreply, state}
  end

  # Scripted identity backend for Reconciler identity-uncertainty injection
  # (Phase 4C C2B): determinate present/not-found proceeds; any other error,
  # raise, or exit is uncertain and must suppress the whole reconcile pass.
  defmodule FakeIdentity do
    @moduledoc false

    def identity_status(_agent_id) do
      case :ets.lookup(:c2b_calls, :identity_reply) do
        [{:identity_reply, :raise}] -> raise "identity boom"
        [{:identity_reply, :exit}] -> exit(:identity_exit)
        [{:identity_reply, reply}] -> reply
        [] -> {:error, :not_found}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    TaskControlRecoveryMemory.ensure!()
    TaskControlRecoveryMemory.reset!()

    table =
      if :ets.whereis(:c2b_calls) == :undefined do
        :ets.new(:c2b_calls, [:named_table, :public, :duplicate_bag])
      else
        :c2b_calls
      end

    :ets.insert(table, {:test_pid, self()})

    # Track only C2B-owned ids/pids/profiles for cleanup (on_exit runs after this
    # process and its ETS are gone, so the owned set lives in :persistent_term
    # keyed by the test pid). Never Registry.list -> unregister every agent.
    test_pid = self()
    :persistent_term.put({:c2b_owned, test_pid}, empty_owned())

    ensure_pg_scope()
    ensure_registry()
    ensure_profiles_store()
    ensure_stop_supervisor()

    task_sup = start_supervised!({Task.Supervisor, name: unique(:tsup)})
    store = ready_store(task_sup)
    # Shared Reconciler for the quiescence describe block (barrier calls only;
    # enabled:false so it never ticks). Its manager is FakeManager, but quiescence
    # never drives a reconcile through it.
    server = start_quiescence_reconciler(store)

    on_exit(fn ->
      cleanup_owned(test_pid)
    end)

    {:ok, %{store: store, server: server, task_sup: task_sup, table: table}}
  end

  # ---------------------------------------------------------------------------
  # A. Ownership — public observe_target/1
  # ---------------------------------------------------------------------------

  describe "ownership observation" do
    test "absent target is confirmed absent (public observe_target/1)" do
      assert {:ok, :absent} = Registry.observe_target(unique_agent())
    end

    test "exact local owner (public observe_target/1)" do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, :local_owner} = Registry.observe_target(id)
    end

    test "duplicate local members are ambiguous (public observe_target/1)" do
      id = unique_agent()
      pid1 = spawn_live()
      :ok = Registry.register(id, pid1, %{module: __MODULE__})
      # A second LOCAL pid in the same pg group -> duplicate local owners.
      pid2 = spawn_live()
      :pg.join(:arbor_agents, {:agent, id}, pid2)
      assert {:error, :ambiguous_ownership} = Registry.observe_target(id)
    end

    test "security regression: dead local ETS pid is ambiguous not absent (observe_target/1)" do
      id = unique_agent()
      # Inject a raw entry whose pid is a dead LOCAL pid; observe must NOT say :absent.
      dead = spawn(fn -> :ok end)
      Process.sleep(20)
      refute Process.alive?(dead)
      put_local_raw({:entry, %{pid: dead}})
      put_pg_raw({:members, []})
      assert {:error, :ambiguous_ownership} = Registry.observe_target(id)
    end

    test "security regression: malformed local ETS pid is observation_unavailable not absent" do
      put_local_raw({:entry, %{pid: :not_a_pid}})
      put_pg_raw({:members, []})
      assert {:error, :observation_unavailable} = Registry.observe_target(unique_agent())
    end

    test "security regression: local table undefined is observation_unavailable not absent" do
      put_local_raw(:table_undefined)
      assert {:error, :observation_unavailable} = Registry.observe_target(unique_agent())
    end

    test "security regression: pg source failure is observation_unavailable not absent" do
      put_local_raw({:entry, %{pid: spawn_live()}})
      put_pg_raw(:pg_exit)
      assert {:error, :observation_unavailable} = Registry.observe_target(unique_agent())
    end

    test "security regression: malformed pg membership is observation_unavailable not absent" do
      put_local_raw({:entry, %{pid: spawn_live()}})
      put_pg_raw({:members, [:not_a_pid]})
      assert {:error, :observation_unavailable} = Registry.observe_target(unique_agent())
    end

    test "remote-only owner via public observe_target/1 (deterministic fact seam)" do
      # No real remote pid can be fabricated without a managed peer, so inject the
      # gathered pg_fact directly; the real classify_ownership + decorate still run
      # on it through arity-1 observe_target/1 (non-vacuous, no silent pass).
      put_local_fact(:absent)
      put_pg_fact({:ok, {[], 1}})
      assert {:ok, :remote_owner} = Registry.observe_target(unique_agent())
    end

    test "local-plus-remote ambiguity via public observe_target/1 (deterministic fact seam)" do
      pid = spawn_live()
      put_local_fact({:ok, pid})
      put_pg_fact({:ok, {[pid], 1}})
      assert {:error, :ambiguous_ownership} = Registry.observe_target(unique_agent())
    end

    test "pure core classifies every ownership row (incl. remote and unavailable)" do
      alias Arbor.Agent.RuntimeQuiescenceCore, as: C

      assert C.classify_ownership({:ok, self()}, {:ok, {[self()], 0}}) == :local_owner
      assert C.classify_ownership({:ok, self()}, {:ok, {[self()], 1}}) == :ambiguous
      assert C.classify_ownership({:ok, self()}, {:ok, {[self(), self()], 0}}) == :ambiguous
      assert C.classify_ownership({:ok, self()}, {:ok, {[], 0}}) == :ambiguous
      assert C.classify_ownership(:absent, {:ok, {[], 0}}) == :absent
      assert C.classify_ownership(:absent, {:ok, {[], 1}}) == :remote_owner
      assert C.classify_ownership(:absent, {:ok, {[], 2}}) == :ambiguous
      assert C.classify_ownership(:absent, {:ok, {[self()], 0}}) == :ambiguous
      assert C.classify_ownership(:inconsistent, {:ok, {[], 0}}) == :ambiguous
      assert C.classify_ownership(:unavailable, {:ok, {[], 0}}) == :unavailable
      assert C.classify_ownership({:ok, self()}, :unavailable) == :unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # A2. Registry.list_strict/0 shape validation (security regression)
  # ---------------------------------------------------------------------------

  describe "list_strict shape validation" do
    test "returns valid live local entries" do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, entries} = Registry.list_strict()
      assert Enum.any?(entries, &(&1.agent_id == id))
    end

    test "security regression: non-map ETS entry yields observation_unavailable (no crash)" do
      id = unique_agent()
      :ets.insert(:arbor_agent_registry, {id, "not_a_map"})
      assert {:error, :observation_unavailable} = Registry.list_strict()
    end

    test "security regression: entry with non-pid :pid yields observation_unavailable (no Process.alive? crash)" do
      id = unique_agent()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: id, pid: :not_a_pid}})
      assert {:error, :observation_unavailable} = Registry.list_strict()
    end

    test "security regression: entry missing :pid yields observation_unavailable (no KeyError)" do
      id = unique_agent()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: id}})
      assert {:error, :observation_unavailable} = Registry.list_strict()
    end

    test "security regression: ETS key differing from entry.agent_id is rejected" do
      id = unique_agent()
      other = unique_agent()
      pid = spawn_live()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: other, pid: pid, module: __MODULE__}})
      assert {:error, :observation_unavailable} = Registry.list_strict()
    end
  end

  # ---------------------------------------------------------------------------
  # B. Reconciler suppression
  # ---------------------------------------------------------------------------

  describe "reconciler suppression" do
    test "security regression: actual snapshot unavailable produces and applies no start intent",
         %{store: store} do
      id = unique_agent()
      store_auto_start_profile(id)
      :ets.insert(:c2b_calls, {:list_strict_reply, {:error, :observation_unavailable}})

      server =
        start_reconciler(%{task_store: store, registry: FakeRegistry, manager: FakeManager})

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id and &1.action == :start)) == []
      assert :ets.lookup(:c2b_calls, :resume) == []
    end

    test "security regression: fenced target suppresses start without rate-limit or restart",
         _context do
      id = unique_agent()
      store_auto_start_profile(id)
      fake = start_fake_task_store(target_fenced_reply: {:ok, true})

      server =
        start_reconciler(%{
          task_store: fake,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      intents = Reconciler.reconcile_now(server)
      # C2B: a fenced target emits NO auto-start intent — reconcile_now/1 returns
      # applied intents only, so a fence-suppressed start is absent (and consumes
      # no rate-limit slot, emits no restart signal).
      assert Enum.filter(intents, &(&1.agent_id == id and &1.action == :start)) == []
      assert :ets.lookup(:c2b_calls, :resume) == []
      assert :sys.get_state(server).start_attempts == %{}
    end

    test "security regression: fence_not_ready suppresses start without rate-limit or restart" do
      id = unique_agent()
      store_auto_start_profile(id)
      fake = start_fake_task_store(target_fenced_reply: {:error, :fence_not_ready})

      server =
        start_reconciler(%{
          task_store: fake,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id and &1.action == :start)) == []
      assert :ets.lookup(:c2b_calls, :resume) == []
      assert :sys.get_state(server).start_attempts == %{}
    end

    test "security regression: malformed target_fenced reply suppresses start" do
      Enum.each([{:ok, "maybe"}, :wat, {:ok, nil}], fn malformed ->
        :ets.match_delete(:c2b_calls, {:resume, :_})
        id = unique_agent()
        store_auto_start_profile(id)
        fake = start_fake_task_store(target_fenced_reply: malformed)

        server =
          start_reconciler(%{
            task_store: fake,
            registry: Arbor.Agent.Registry,
            manager: FakeManager
          })

        intents = Reconciler.reconcile_now(server)
        assert Enum.filter(intents, &(&1.agent_id == id and &1.action == :start)) == []
        assert :ets.lookup(:c2b_calls, :resume) == []
        assert :sys.get_state(server).start_attempts == %{}
      end)
    end

    test "security regression: TaskStore exit on target_fenced suppresses start" do
      id = unique_agent()
      store_auto_start_profile(id)
      fake = start_fake_task_store(exit_on_target_fenced: true)

      server =
        start_reconciler(%{
          task_store: fake,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id and &1.action == :start)) == []
      assert :ets.lookup(:c2b_calls, :resume) == []
      assert :sys.get_state(server).start_attempts == %{}
    end

    test "preserved behavior: unfenced target admits and rate-limits normally", %{store: store} do
      id = unique_agent()
      store_auto_start_profile(id)

      server =
        start_reconciler(%{
          task_store: store,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      intents = Reconciler.reconcile_now(server)
      # Admitted + applied: the :start intent IS returned (resume recorded and a
      # rate-limit attempt recorded). Proves the applied-only filter does not
      # over-suppress admitted starts.
      assert Enum.any?(intents, &(&1.agent_id == id and &1.action == :start))
      assert [{:resume, ^id}] = :ets.lookup(:c2b_calls, :resume)
      assert Map.has_key?(:sys.get_state(server).start_attempts, id)
    end

    # Phase 4C C2B identity uncertainty: a determinate present/not-found identity
    # proceeds; any uncertain result (error/raise/exit) suppresses the WHOLE pass
    # so uncertainty is never collapsed to absence (no G1 start, no G2 reap).
    defp identity_reconciler(store) do
      start_reconciler(%{
        task_store: store,
        registry: Arbor.Agent.Registry,
        manager: FakeManager,
        identity: FakeIdentity
      })
    end

    defp live_registered_agent do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      {id, pid}
    end

    test "security regression: uncertain identity error suppresses the whole pass (no reap, no start)",
         %{store: store} do
      {id, pid} = live_registered_agent()
      :ets.insert(:c2b_calls, {:identity_reply, {:error, :boom}})
      server = identity_reconciler(store)

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id)) == []
      assert :ets.lookup(:c2b_calls, :resume) == []
      assert :ets.lookup(:c2b_calls, :stop_agent) == []
      # The live agent is NOT reaped on uncertainty.
      assert {:ok, ^pid} = Registry.whereis(id)
    end

    test "security regression: identity raise suppresses the whole pass", %{store: store} do
      {id, pid} = live_registered_agent()
      :ets.insert(:c2b_calls, {:identity_reply, :raise})
      server = identity_reconciler(store)

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id)) == []
      assert :ets.lookup(:c2b_calls, :stop_agent) == []
      assert {:ok, ^pid} = Registry.whereis(id)
    end

    test "security regression: identity exit suppresses the whole pass", %{store: store} do
      {id, pid} = live_registered_agent()
      :ets.insert(:c2b_calls, {:identity_reply, :exit})
      server = identity_reconciler(store)

      intents = Reconciler.reconcile_now(server)
      assert Enum.filter(intents, &(&1.agent_id == id)) == []
      assert :ets.lookup(:c2b_calls, :stop_agent) == []
      assert {:ok, ^pid} = Registry.whereis(id)
    end

    test "security regression: determinate not-found identity reaps the zombie",
         %{store: store} do
      {id, pid} = live_registered_agent()
      :ets.insert(:c2b_calls, {:identity_reply, {:error, :not_found}})
      server = identity_reconciler(store)

      _intents = Reconciler.reconcile_now(server)
      assert [{:stop_agent, ^id}] = :ets.lookup(:c2b_calls, :stop_agent)
      assert {:error, :not_found} = Registry.whereis(id)
      refute Process.alive?(pid)
    end

    test "security regression: determinate present identity is protected (not reaped)",
         %{store: store} do
      {id, pid} = live_registered_agent()
      :ets.insert(:c2b_calls, {:identity_reply, {:ok, :active}})
      server = identity_reconciler(store)

      _intents = Reconciler.reconcile_now(server)
      assert :ets.lookup(:c2b_calls, :stop_agent) == []
      assert {:ok, ^pid} = Registry.whereis(id)
    end
  end

  # ---------------------------------------------------------------------------
  # C. Serialized barrier + in-flight resume race + exact operation_id
  # ---------------------------------------------------------------------------

  describe "serialized barrier and in-flight race" do
    test "security regression: in-flight reconcile blocked in resume settles before the barrier and quiescence drains its start",
         %{store: store} do
      id = unique_agent()
      store_auto_start_profile(id)
      :ets.insert(:c2b_calls, {:resume_blocks, true})

      server =
        start_reconciler(%{
          task_store: store,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      caller = self()

      # (i)+(ii) proc A drives a reconcile that reaches resume and BLOCKS (gate
      # returned {:ok, false}: no fence yet).
      spawn_link(fn ->
        intents = Reconciler.reconcile_now(server)
        send(caller, {:a_done, intents})
      end)

      assert_receive {:resume_entered, ^id}, 200

      # (iii) install the fence while A is blocked inside resume.
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      # (iv) proc B drives synchronize_target; it must block until A's callback returns.
      spawn_link(fn ->
        res = Reconciler.synchronize_target(id, "op1", server)
        send(caller, {:b_done, res})
      end)

      refute_receive {:b_done, _}, 150

      # (v)+(vi) release resume -> A completes, then the barrier runs and verifies.
      send(server, :release)
      assert_receive {:a_done, _}, 500
      assert_receive {:b_done, :ok}, 500

      # The start is observable as a local owner; capture its exact pid so the
      # stop assertion can bind the EXACT observed owner (not a logical id).
      assert {:ok, :local_owner} = Registry.observe_target(id)
      {:ok, owner_pid} = Registry.whereis(id)

      # (vii) quiescence crosses the barrier, stops once, drains to absence.
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      assert {:ok, %{was_running: true}} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 1_000,
                 poll_interval_ms: 25
               )

      assert {:ok, :absent} = Registry.observe_target(id)
      assert [{:resume, ^id}] = :ets.lookup(:c2b_calls, :resume)
      assert [{:stop_owner, ^owner_pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "fence-scoped: removing the fence lets a later reconcile admit", %{store: store} do
      id = unique_agent()
      store_auto_start_profile(id)
      :ets.match_delete(:c2b_calls, {:resume, :_})

      server =
        start_reconciler(%{
          task_store: store,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      _intents = Reconciler.reconcile_now(server)
      assert :ets.lookup(:c2b_calls, :resume) == []

      assert :ok = TaskStore.remove_target_fence(id, "op1", name: store)
      _intents = Reconciler.reconcile_now(server)
      assert [{:resume, ^id}] = :ets.lookup(:c2b_calls, :resume)
    end

    test "security regression: a different operation_id cannot use or clear the fence (barrier)",
         %{store: store} do
      id = unique_agent()
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      server =
        start_reconciler(%{
          task_store: store,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      assert {:error, :fence_not_owned} = Reconciler.synchronize_target(id, "op2", server)
      assert {:ok, true} = TaskStore.target_fenced?(id, name: store)
    end
  end

  # ---------------------------------------------------------------------------
  # D. Quiescence
  # ---------------------------------------------------------------------------

  describe "quiescence" do
    test "already-absent succeeds without stopping (was_running: false)", %{
      store: store,
      server: server
    } do
      id = unique_agent()
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      assert {:ok, %{was_running: false}} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry
               )

      assert :ets.lookup(:c2b_calls, :stop_owner) == []
    end

    test "exact local owner stops the exact observed pid and drains to confirmed absence", %{
      store: store,
      server: server
    } do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      assert {:ok, %{was_running: true}} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 1_000,
                 poll_interval_ms: 25
               )

      assert {:ok, :absent} = Registry.observe_target(id)
      # The EXACT observed owner pid was stopped (never a re-resolution by id).
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: ambiguous ownership never stops (protects a live local owner)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      extra = spawn_live()
      :pg.join(:arbor_agents, {:agent, id}, extra)
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      assert {:error, :ambiguous_ownership} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry
               )

      assert {:ok, ^pid} = Registry.whereis(id)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []
    end

    test "security regression: observation_unavailable never stops", %{
      store: store,
      server: server
    } do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:probe_reply, {:error, :observation_unavailable}})

      assert {:error, :observation_unavailable} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: FakeRuntimeProbe
               )

      assert {:ok, ^pid} = Registry.whereis(id)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []
    end

    test "security regression: drain timeout fails closed when post-stop observation never confirms absence",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      # No-op stop: compare_delete removes the ETS row but the pid stays alive in
      # :pg, so observe stays :ambiguous and the drain polls until the deadline.
      :ets.insert(:c2b_calls, {:stop_mode, :noop})

      assert {:error, :drain_timeout} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 80,
                 poll_interval_ms: 25
               )

      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: observation failure during drain fails closed (never success)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :noop})

      :ets.insert(
        :c2b_calls,
        {:probe_script, [{:ok, pid}, {:error, :observation_unavailable}]}
      )

      assert {:error, :observation_unavailable} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: FakeRuntimeProbe,
                 drain_timeout_ms: 1_000,
                 poll_interval_ms: 25
               )

      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: deterministic fence loss during drain fails closed" do
      # A counting TaskStore fake loses the fence on a FIXED drain iteration
      # (the 4th verify_target_fence call) — no Process.sleep race. The first
      # three verifies (initial quiesce, Reconciler barrier, stop-owner) pass.
      det =
        start_supervised!(
          {DeterministicFenceStore, name: unique(:det), fail_after: 3},
          id: unique(:det_id)
        )

      det_server =
        start_reconciler(%{
          task_store: det,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      :ok = DeterministicFenceStore.set_fence(det, id, "op1")
      :ets.insert(:c2b_calls, {:stop_mode, :noop})
      :ets.insert(:c2b_calls, {:probe_reply, {:ok, pid}})

      assert {:error, :fence_lost} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: det,
                 manager: FakeManager,
                 reconciler: det_server,
                 runtime_probe: FakeRuntimeProbe,
                 drain_timeout_ms: 2_000,
                 poll_interval_ms: 25
               )

      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: delayed post-admission fence read is bounded and retryable" do
      # Verify calls are: initial ownership check, Reconciler barrier, then the
      # destructive pre-effect check. Stall exactly that third call beyond the
      # operation's effect cutoff.
      det =
        start_supervised!(
          {DeterministicFenceStore, name: unique(:det), delay_on: 3, delay_ms: 350},
          id: unique(:det_id)
        )

      det_server =
        start_reconciler(%{
          task_store: det,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      :ok = DeterministicFenceStore.set_fence(det, id, "op1")
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      {us, result} =
        :timer.tc(fn ->
          RuntimeQuiescence.quiesce(id, "op1",
            task_store: det,
            manager: FakeManager,
            reconciler: det_server,
            runtime_probe: Arbor.Agent.Registry,
            drain_timeout_ms: 160,
            poll_interval_ms: 25
          )
        end)

      assert {:error, :fence_lost} = result
      assert us < 300_000
      assert {:ok, ^pid} = Registry.whereis(id)
      assert Process.alive?(pid)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []

      # The delayed fake eventually finishes its abandoned read. Disable the
      # delay and prove the same still-owned fence and owner can be retried.
      :ok = DeterministicFenceStore.set_verify_delay(det, nil, 0)

      assert {:ok, %{was_running: true}} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: det,
                 manager: FakeManager,
                 reconciler: det_server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 1_000,
                 poll_interval_ms: 25
               )

      assert {:ok, :absent} = Registry.observe_target(id)
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: delayed drain fence read cannot exceed the stop deadline" do
      # The fourth verify is the first drain iteration, after the exact-owner stop
      # has been released. It must still use the same absolute deadline.
      det =
        start_supervised!(
          {DeterministicFenceStore, name: unique(:det), delay_on: 4, delay_ms: 350},
          id: unique(:det_id)
        )

      det_server =
        start_reconciler(%{
          task_store: det,
          registry: Arbor.Agent.Registry,
          manager: FakeManager
        })

      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      :ok = DeterministicFenceStore.set_fence(det, id, "op1")
      :ets.insert(:c2b_calls, {:stop_mode, :noop})

      {us, result} =
        :timer.tc(fn ->
          RuntimeQuiescence.quiesce(id, "op1",
            task_store: det,
            manager: FakeManager,
            reconciler: det_server,
            runtime_probe: Arbor.Agent.Registry,
            drain_timeout_ms: 160,
            poll_interval_ms: 25
          )
        end)

      assert {:error, :drain_timeout} = result
      assert us < 300_000
      assert Process.alive?(pid)
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: drain is bounded by one absolute deadline (no post-deadline poll)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      # :noop removes the ETS row but leaves the owner in :pg, so observe stays
      # :ambiguous forever and the drain must poll until the single deadline.
      :ets.insert(:c2b_calls, {:stop_mode, :noop})

      {us, result} =
        :timer.tc(fn ->
          RuntimeQuiescence.quiesce(id, "op1",
            task_store: store,
            manager: FakeManager,
            reconciler: server,
            runtime_probe: Arbor.Agent.Registry,
            drain_timeout_ms: 200,
            poll_interval_ms: 400
          )
        end)

      assert {:error, :drain_timeout} = result
      # Fixed code sleeps no longer than the remaining budget each poll, so total
      # ~= the 200ms deadline. A post-deadline full poll (200 + 400 = 600ms) would
      # blow past this bound — the buggy strict > + unbounded sleep did exactly that.
      assert us < 350_000
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: a different operation_id cannot quiesce (fence not owned)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      assert {:error, :fence_not_owned} =
               RuntimeQuiescence.quiesce(id, "op2",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry
               )

      # The other op did not stop the agent or clear the fence.
      assert {:ok, ^pid} = Registry.whereis(id)
      assert {:ok, true} = TaskStore.target_fenced?(id, name: store)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []
    end

    test "security regression: exact replacement pid is never stopped (compare-delete linearization)",
         %{store: store, server: server} do
      id = unique_agent()
      pid1 = spawn_live()
      :ok = Registry.register(id, pid1, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      # The probe reports the STALE observed owner pid1, but the real registry
      # row now points at a replacement pid2. The atomic compare-delete must
      # refuse (:owner_replaced) so neither owner is stopped.
      pid2 = spawn_live()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: id, pid: pid2, module: __MODULE__}})
      :pg.join(:arbor_agents, {:agent, id}, pid2)
      :ets.insert(:c2b_calls, {:probe_reply, {:ok, pid1}})

      assert {:error, :owner_replaced} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: FakeRuntimeProbe
               )

      assert :ets.lookup(:c2b_calls, :stop_owner) == []
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end

    test "security regression: supervisor admission failure fails closed (no stop, no orphan)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      # max_children: 0 rejects every start_child with {:error, :max_children}
      # -> admit_stop_child normalizes to {:error, :stop_unavailable}, no crash.
      reject_sup =
        start_supervised!(
          {Task.Supervisor, name: unique(:rej), max_children: 0},
          id: unique(:rej_id)
        )

      assert {:error, :stop_unavailable} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 stop_supervisor: reject_sup
               )

      assert :ets.lookup(:c2b_calls, :stop_owner) == []
      assert Process.alive?(pid)
    end

    test "security regression: admission failure preserves ownership and a retry quiesces it",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      # max_children: 0 rejects admission. Admission precedes compare-delete, so
      # the live owner row is NOT invalidated.
      reject_sup =
        start_supervised!(
          {Task.Supervisor, name: unique(:rej), max_children: 0},
          id: unique(:rej_id)
        )

      assert {:error, :stop_unavailable} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 stop_supervisor: reject_sup
               )

      # The live owner is STILL registered (ETS + :pg) — a later retry can find it.
      assert {:ok, :local_owner} = Registry.observe_target(id)
      assert {:ok, ^pid} = Registry.whereis(id)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []

      # Retry on the same still-registered owner with the default (working)
      # supervisor: admit -> compare-delete -> release -> stop -> drain to absence.
      assert {:ok, %{was_running: true}} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 1_000,
                 poll_interval_ms: 25
               )

      assert {:ok, :absent} = Registry.observe_target(id)
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end

    test "security regression: stalled supervisor admission is bounded and preserves ownership",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})

      blocking_sup =
        start_supervised!(
          {BlockingStopSupervisor, name: unique(:blocking_sup)},
          id: unique(:blocking_sup_id)
        )

      {us, result} =
        :timer.tc(fn ->
          RuntimeQuiescence.quiesce(id, "op1",
            task_store: store,
            manager: FakeManager,
            reconciler: server,
            runtime_probe: Arbor.Agent.Registry,
            stop_supervisor: blocking_sup,
            drain_timeout_ms: 120,
            poll_interval_ms: 25
          )
        end)

      assert {:error, :stop_unavailable} = result
      assert us < 250_000
      assert {:ok, :local_owner} = Registry.observe_target(id)
      assert {:ok, ^pid} = Registry.whereis(id)
      assert Process.alive?(pid)
      assert :ets.lookup(:c2b_calls, :stop_owner) == []
    end

    test "security regression: dead stop supervisor fails closed (no crash)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      :ets.insert(:c2b_calls, {:stop_mode, :normal})
      # A name that is never started -> start_child exits :noproc ->
      # admit_stop_child catches it -> {:error, :stop_unavailable}.
      assert {:error, :stop_unavailable} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 stop_supervisor: @dead_stop_supervisor
               )

      assert :ets.lookup(:c2b_calls, :stop_owner) == []
      assert Process.alive?(pid)
    end

    test "security regression: blocking stop times out bounded (no false reaped success)",
         %{store: store, server: server} do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)
      # :blocking makes the supervised stop worker never settle -> it is killed
      # at the effect cutoff -> :stop_timeout (never claimed reaped success).
      :ets.insert(:c2b_calls, {:stop_mode, :blocking})

      assert {:error, :stop_timeout} =
               RuntimeQuiescence.quiesce(id, "op1",
                 task_store: store,
                 manager: FakeManager,
                 reconciler: server,
                 runtime_probe: Arbor.Agent.Registry,
                 drain_timeout_ms: 120,
                 poll_interval_ms: 25
               )

      # The observed owner pid was never killed and success was never claimed.
      assert Process.alive?(pid)
      assert [{:stop_owner, ^pid}] = :ets.lookup(:c2b_calls, :stop_owner)
    end
  end

  # ---------------------------------------------------------------------------
  # E. Registry.remove_owner_if_match/2 — exact-owner compare-delete
  # ---------------------------------------------------------------------------

  describe "remove_owner_if_match exact-owner compare-delete" do
    test "exact observed pid deletes the row" do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})

      assert :ok = Registry.remove_owner_if_match(id, pid)
      assert {:error, :not_found} = Registry.whereis(id)
    end

    test "security regression: replacement owner row is preserved (never deleted by a stale pid)" do
      id = unique_agent()
      pid1 = spawn_live()
      :ok = Registry.register(id, pid1, %{module: __MODULE__})
      # Replacement: overwrite the row with a different pid.
      pid2 = spawn_live()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: id, pid: pid2, module: __MODULE__}})

      assert {:error, :owner_replaced} = Registry.remove_owner_if_match(id, pid1)
      # The replacement owner is intact.
      assert {:ok, ^pid2} = Registry.whereis(id)
    end

    test "security regression: absent row is owner_replaced" do
      id = unique_agent()
      other = spawn_live()
      assert {:error, :owner_replaced} = Registry.remove_owner_if_match(id, other)
    end

    test "security regression: malformed (non-pid) row is owner_replaced" do
      id = unique_agent()
      :ets.insert(:arbor_agent_registry, {id, %{agent_id: id, pid: :not_a_pid}})
      assert {:error, :owner_replaced} = Registry.remove_owner_if_match(id, spawn_live())
    end

    test "security regression: non-map row is owner_replaced" do
      id = unique_agent()
      :ets.insert(:arbor_agent_registry, {id, "not_a_map"})
      assert {:error, :owner_replaced} = Registry.remove_owner_if_match(id, spawn_live())
    end
  end

  # ---------------------------------------------------------------------------
  # F. Cluster ownership — real managed :peer (no fabricated facts)
  # ---------------------------------------------------------------------------

  describe "cluster ownership (real managed :peer)" do
    test "security regression: remote-only owner is remote_owner, never absent (real peer)" do
      id = unique_agent()

      with_remote_owner(id, fn _peer_node, remote_pid ->
        assert node(remote_pid) != node()
        assert {:ok, :remote_owner} = Registry.observe_target(id)
        assert {:error, :remote_owner} = Registry.observe_target_owner(id)
      end)
    end

    test "security regression: local-plus-remote is ambiguous, never local_owner (real peer)" do
      id = unique_agent()
      pid = spawn_live()
      :ok = Registry.register(id, pid, %{module: __MODULE__})

      with_remote_owner(id, fn _peer_node, _remote_pid ->
        assert {:error, :ambiguous_ownership} = Registry.observe_target(id)
        assert {:ok, ^pid} = Registry.whereis(id)
      end)
    end

    test "security regression: quiescence never stops a remote-only owner (real peer)",
         %{store: store, server: server} do
      id = unique_agent()
      assert {:ok, _} = TaskStore.install_target_fence(id, "op1", name: store)

      with_remote_owner(id, fn peer_node, remote_pid ->
        assert {:error, :remote_owner} =
                 RuntimeQuiescence.quiesce(id, "op1",
                   task_store: store,
                   manager: FakeManager,
                   reconciler: server,
                   runtime_probe: Arbor.Agent.Registry
                 )

        assert {:ok, true} = safe_erpc(peer_node, :erlang, :is_process_alive, [remote_pid])
        assert :ets.lookup(:c2b_calls, :stop_owner) == []
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_reconciler(%{task_store: ts, registry: reg, manager: mgr} = opts) do
    name = unique(:reconciler)

    extra = if identity = opts[:identity], do: [identity: identity], else: []

    child_opts =
      [name: name, enabled: false, g1_policy: :start, task_store: ts, registry: reg, manager: mgr] ++
        extra

    pid = start_supervised!({Reconciler, child_opts}, id: unique(:reconciler_id))

    pid
  end

  defp start_quiescence_reconciler(store) do
    # Shared Reconciler for the quiescence describe block (barrier calls only).
    start_reconciler(%{task_store: store, registry: Arbor.Agent.Registry, manager: FakeManager})
  end

  defp start_fake_task_store(opts) do
    name = unique(:fake_store)

    start_supervised!(
      {FakeTaskStore,
       name: name,
       target_fenced_reply: opts[:target_fenced_reply],
       exit_on_target_fenced: opts[:exit_on_target_fenced]},
      id: unique(:fake_store_id)
    )
  end

  # Mirror of the dispatch fence test's ready_store, minimal for fence API use.
  defp ready_store(task_sup) do
    start_supervised!(
      {TaskStore,
       name: unique(:store),
       task_supervisor: task_sup,
       cleanup_supervisor: task_sup,
       recovery_force_ready: true,
       task_control_recovery_facade: TaskControlRecoveryMemory,
       task_control_security_module: NoopSecurity,
       runner: HangRunner},
      id: unique(:store_id)
    )
  end

  def store_auto_start_profile(agent_id) do
    profile = %Profile{
      agent_id: agent_id,
      display_name: "c2b",
      character: Character.new(name: "c2b"),
      auto_start: true,
      metadata: %{},
      created_at: DateTime.utc_now(),
      version: 1
    }

    :ok = ProfileStore.store_profile(profile)
    track_owned_profile(agent_id)
    agent_id
  end

  defp ensure_pg_scope do
    unless pg_scope_running?() do
      start_supervised!(%{id: :arbor_agents_pg, start: {:pg, :start_link, [:arbor_agents]}})
    end
  end

  defp pg_scope_running? do
    is_list(:pg.which_groups(:arbor_agents))
  catch
    :exit, _ -> false
    :error, _ -> false
  end

  defp ensure_registry do
    if Process.whereis(Arbor.Agent.Registry) == nil do
      start_supervised!(Arbor.Agent.Registry)
    end
  end

  # The production stop supervisor (default :stop_supervisor collaborator). When
  # the app is not fully started in test, start the named supervisor here so the
  # default quiescence stop path resolves a real supervisor without each call
  # passing stop_supervisor: explicitly.
  defp ensure_stop_supervisor do
    if Process.whereis(Arbor.Agent.Orchestration.TaskSupervisor) == nil do
      start_supervised!(
        {Task.Supervisor, name: Arbor.Agent.Orchestration.TaskSupervisor},
        id: :c2b_stop_supervisor
      )
    end
  end

  defp ensure_profiles_store do
    if Process.whereis(@profiles_store) == nil do
      start_supervised!(
        Supervisor.child_spec(
          {BufferedStore, name: @profiles_store, backend: nil, write_mode: :sync},
          id: @profiles_store
        )
      )
    end
  end

  # Raw-source seam injectors (Registry observe_target/1 arity-1, test-build only).
  defp put_local_raw(value), do: Process.put({Arbor.Agent.Registry, :test_local_raw}, value)
  defp put_pg_raw(value), do: Process.put({Arbor.Agent.Registry, :test_pg_raw}, value)

  # Fact-level seam injectors (deterministic; real classify_ownership/decorate runs
  # on the injected fact). Used for remote/local+remote where no real remote pid
  # can be fabricated without a managed peer.
  defp put_local_fact(value), do: Process.put({Arbor.Agent.Registry, :test_local_fact}, value)

  defp put_pg_fact(value), do: Process.put({Arbor.Agent.Registry, :test_pg_fact}, value)

  defp spawn_live do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    track_owned_pid(pid)
    pid
  end

  # Real managed :peer helper. Starts distribution if needed, starts a real
  # :peer node, starts the named :arbor_agents :pg scope ON the peer from a
  # transient stdlib process (whose normal exit does not take the scope down),
  # spawns a long-lived owner process on it via a stdlib MFA, and joins that
  # remote pid into the :arbor_agents group FROM the peer node (local to
  # remote_pid). node(remote_pid) == peer_node, so distributed :pg replicates
  # the member to the local node and the local classify_ownership sees a remote
  # member through the PUBLIC Registry API — no fabricated fact seam. Bounded
  # setup/teardown with EXPLICIT failures (raises), never silent skips.
  #
  # control PID stays DISTINCT from peer_node and remote_pid throughout.
  defp with_remote_owner(agent_id, body) do
    ensure_distributed!()
    {:ok, control, peer_node} = :peer.start_link(%{name: @peer_name})

    # Setup is outside the body-capture try so remote_pid is bound before
    # teardown. A setup failure stops the peer (best-effort) then re-raises so
    # no peer leaks and the real setup error surfaces.
    remote_pid =
      try do
        start_peer_scope_and_owner!(peer_node, agent_id)
      catch
        kind, reason ->
          teardown_remote_owner!(peer_node, agent_id, nil)
          stop_peer_safely(control, peer_node)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    # Capture the body outcome so teardown ALWAYS runs and a body/assertion
    # failure is never masked by teardown noise.
    outcome =
      try do
        body.(peer_node, remote_pid)
        :ok
      catch
        kind, reason -> {:thrown, kind, reason, __STACKTRACE__}
      end

    # Teardown always runs (never silently skipped). teardown_remote_owner!/1 is
    # best-effort; :peer.stop is the authoritative teardown whose failure is
    # surfaced explicitly — but only when the body succeeded, so it can never
    # mask a body failure.
    teardown_error =
      try do
        teardown_remote_owner!(peer_node, agent_id, remote_pid)
        stop_peer_bounded(control, peer_node)
        nil
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    case {outcome, teardown_error} do
      {:ok, nil} -> :ok
      {:ok, {kind, reason, stack}} -> :erlang.raise(kind, reason, stack)
      {{:thrown, kind, reason, stack}, _} -> :erlang.raise(kind, reason, stack)
    end
  end

  # Start the named :arbor_agents :pg scope with :pg.start/1, OTP's explicit
  # unlinked primitive, then spawn the remote owner and join it from the peer
  # node. Idempotent: an already-started scope is reused. Raises (explicit
  # failure) at every bound.
  defp start_peer_scope_and_owner!(peer_node, agent_id) do
    _ = :erlang.spawn(peer_node, :pg, :start, [:arbor_agents])

    wait_until!("peer :arbor_agents :pg scope ready", fn ->
      match?({:ok, _}, safe_erpc(peer_node, :pg, :which_groups, [:arbor_agents]))
    end)

    remote_pid = :erlang.spawn(peer_node, :timer, :sleep, [:infinity])

    :ok = :erpc.call(peer_node, :pg, :join, [:arbor_agents, {:agent, agent_id}, remote_pid])

    wait_until!("remote owner pg membership", fn ->
      remote_pid in :pg.get_members(:arbor_agents, {:agent, agent_id})
    end)

    remote_pid
  end

  # Best-effort teardown (never raises): leave the group on the peer (tolerate a
  # dead peer) and kill the remote owner. :peer.stop (in with_remote_owner/2) is
  # the authoritative teardown; it removes the peer node so distributed :pg drops
  # all its members. Each test uses a unique agent_id (unique group), so no stale
  # remote pid can collide with another test.
  defp teardown_remote_owner!(_peer_node, _agent_id, nil), do: :ok

  defp teardown_remote_owner!(peer_node, agent_id, remote_pid) do
    try do
      :erpc.call(peer_node, :pg, :leave, [:arbor_agents, {:agent, agent_id}, remote_pid])
    catch
      _, _ -> :ok
    end

    _ = safe_erpc(peer_node, :erlang, :exit, [remote_pid, :kill])
    :ok
  end

  # Swallowing peer-stop variant: used only on the setup-failure path so a
  # :peer.stop hiccup can never mask the real setup error that is re-raised.
  defp stop_peer_safely(control, peer_node) do
    try do
      stop_peer_bounded(control, peer_node)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # Bounded :peer.stop with an owned kill fallback: if the authoritative stop does
  # not settle within the bound, the peer node is halted and the local control is
  # forced down so neither can leak. Runs only in teardown (after the body), so it
  # can never mask a body failure.
  defp stop_peer_bounded(control, peer_node) do
    caller = self()
    stop_ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + @peer_stop_timeout_ms
    control_mon = Process.monitor(control)

    {stopper, stopper_mon} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, :peer.stop(control)}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(caller, {stop_ref, result})
      end)

    case await_peer_stop(stop_ref, stopper_mon, stopper, deadline) do
      :ok ->
        await_process_down(control_mon, control, deadline)
        :ok

      {:error, _reason} ->
        # :peer.start_link/1 linked the control to this test process. Detach it
        # before the kill fallback so cleanup cannot kill the test caller.
        Process.unlink(control)
        _ = Process.exit(stopper, :kill)
        settle_monitor(stopper_mon, stopper)
        _ = safe_erpc(peer_node, :init, :stop, [])
        _ = Process.exit(control, :kill)
        await_process_down(control_mon, control, fallback_deadline())
        :ok
    end
  end

  defp await_peer_stop(stop_ref, stopper_mon, stopper, deadline) do
    receive do
      {^stop_ref, {:ok, _result}} ->
        settle_monitor(stopper_mon, stopper)
        :ok

      {^stop_ref, {:error, reason}} ->
        {:error, reason}

      {:DOWN, ^stopper_mon, :process, ^stopper, reason} ->
        receive do
          {^stop_ref, {:ok, _result}} -> :ok
          {^stop_ref, {:error, stop_reason}} -> {:error, stop_reason}
        after
          0 -> {:error, {:stopper_down, reason}}
        end
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, :timeout}
    end
  end

  defp settle_monitor(mon, pid) do
    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
    after
      100 -> Process.demonitor(mon, [:flush])
    end
  end

  defp await_process_down(mon, pid, deadline) do
    receive do
      {:DOWN, ^mon, :process, ^pid, _reason} -> :ok
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Process.demonitor(mon, [:flush])

        if Process.alive?(pid) do
          raise "with_remote_owner: peer control did not stop within the teardown bound"
        end

        :ok
    end
  end

  defp fallback_deadline do
    System.monotonic_time(:millisecond) + @peer_rpc_timeout_ms
  end

  # Bounded poll: :ok on truthy check; raises (explicit failure, never a skip)
  # on timeout. Never an unbounded search.
  defp wait_until!(label, check) when is_function(check, 0) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    poll_until!(label, deadline, check)
  end

  defp poll_until!(label, deadline, check) do
    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "with_remote_owner: timed out waiting for #{label}"

      true ->
        Process.sleep(10)
        poll_until!(label, deadline, check)
    end
  end

  defp safe_erpc(node, mod, fun, args) do
    {:ok, :erpc.call(node, mod, fun, args, @peer_rpc_timeout_ms)}
  catch
    _, _ -> :error
  end

  defp ensure_distributed! do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([@distributed_name, :shortnames])
    end

    :ok
  end

  defp empty_owned, do: %{ids: MapSet.new(), pids: MapSet.new(), profiles: MapSet.new()}

  defp track_owned_id(id), do: update_owned(:ids, id)
  defp track_owned_pid(pid), do: update_owned(:pids, pid)
  defp track_owned_profile(id), do: update_owned(:profiles, id)

  defp update_owned(field, value) do
    key = {:c2b_owned, self()}
    cur = :persistent_term.get(key, empty_owned())
    :persistent_term.put(key, Map.put(cur, field, MapSet.put(Map.get(cur, field), value)))
  end

  # Removes ONLY C2B-owned ids/pids/profiles. Registered pids are reached via their
  # tracked agent_id; directly-spawned pids via :pids; profiles via :profiles.
  defp cleanup_owned(test_pid) do
    key = {:c2b_owned, test_pid}
    owned = :persistent_term.get(key, empty_owned())

    Enum.each(owned.ids, fn id ->
      # Kill any live owner for a tracked id (best-effort: a malformed injected
      # row can make whereis raise, which is swallowed per-id).
      try do
        case Registry.whereis(id) do
          {:ok, pid} -> Process.exit(pid, :kill)
          _ -> :ok
        end
      catch
        _, _ -> :ok
      end

      # Always remove the C2B-owned registry row: unregister is a bare
      # :ets.delete and never raises, so a malformed injected row cannot leak
      # across tests and poison list_strict/0 for later tests.
      try do
        Registry.unregister(id)
      catch
        _, _ -> :ok
      end
    end)

    Enum.each(owned.pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    try do
      Enum.each(owned.profiles, fn id -> ProfileStore.delete_profile(id) end)
    catch
      _, _ -> :ok
    end

    :persistent_term.erase(key)
  end

  defp unique(prefix) do
    {:global, {__MODULE__, prefix, System.unique_integer([:positive])}}
  end

  defp unique_agent do
    id = "agent_c2b_#{System.unique_integer([:positive])}"
    track_owned_id(id)
    id
  end

  # Module-level security double used by the TaskStore (grant/revoke no-ops).
  defmodule NoopSecurity do
    @moduledoc false

    def grant(opts) do
      id = "cap_#{System.unique_integer([:positive])}"
      {:ok, %{id: id, resource_uri: opts[:resource], task_id: opts[:task_id]}}
    end

    def revoke(_id), do: :ok
    def revoke_by_task(_task_id), do: {:ok, 0}
  end

  defmodule HangRunner do
    @moduledoc false

    def run(_agent_id, _task, _opts) do
      Process.sleep(60_000)
      {:ok, %{}}
    end
  end
end
