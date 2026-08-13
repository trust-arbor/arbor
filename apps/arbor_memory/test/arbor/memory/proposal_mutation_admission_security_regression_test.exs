defmodule Arbor.Memory.ProposalMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Security regression for Proposal owner roots and authenticated acceptance
  (VP-05D2C3I1B1F1). Compiles against parent 6ab30f292. Parent fails the
  post-drain create assertion rather than setup or compilation.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  alias Arbor.Memory.{
    Events,
    GoalStore,
    GraphOps,
    IntentStore,
    KnowledgeGraph,
    KnowledgeGraphStore,
    MutationAdmission,
    Proposal
  }

  alias Arbor.Memory.MutationAdmission.{Lease, OwnerRoots}
  alias Arbor.Memory.Proposal.{Core, Store}
  alias Arbor.Persistence.{BufferedStore, QueryableStore}

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1F1"
  @moduletag security_regression: true

  @malformed_goal_store :proposal_malformed_goal_store
  @ambiguity_collection :proposal_ambiguity_collection
  @ambiguity_control :proposal_ambiguity_control

  defmodule PostCommitBlockingBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    def arm(control, test_pid, delay_ms)
        when is_pid(test_pid) and is_integer(delay_ms) and delay_ms >= 0 do
      Agent.update(control, fn state ->
        %{state | armed: true, block_reads: false, delay_ms: delay_ms, test_pid: test_pid}
      end)
    end

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)

    @impl true
    def get(key, opts), do: guarded_read(opts, {:get, key}, fn -> ETS.get(key, opts) end)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: guarded_read(opts, :list, fn -> ETS.list(opts) end)

    @impl true
    def query(filter, opts), do: guarded_read(opts, :query, fn -> ETS.query(filter, opts) end)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      result = ETS.compare_and_swap(key, expected, replacement, opts)
      control = Keyword.fetch!(opts, :control)

      ambiguity =
        Agent.get_and_update(control, fn state ->
          if state.armed and match?({:ok, _record}, result) do
            value = {state.test_pid, state.delay_ms}
            {value, %{state | armed: false, block_reads: true}}
          else
            {nil, state}
          end
        end)

      case ambiguity do
        {test_pid, delay_ms} ->
          send(test_pid, {:ambiguous_target_cas_committed, key})
          if delay_ms > 0, do: Process.sleep(delay_ms)
          raise "simulated post-commit transport failure"

        nil ->
          result
      end
    end

    @impl true
    def compare_and_delete(key, expected, opts),
      do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart

    defp guarded_read(opts, operation, read) do
      control = Keyword.fetch!(opts, :control)

      case Agent.get(control, &{&1.block_reads, &1.test_pid}) do
        {true, test_pid} ->
          send(test_pid, {:target_convergence_read_blocked, operation, self()})

          receive do
            :release_target_convergence_read ->
              Agent.update(control, &%{&1 | block_reads: false})
              read.()
          after
            2_000 -> {:error, :forced_read_timeout}
          end

        {false, _test_pid} ->
          read.()
      end
    end
  end

  setup do
    ensure_durable_store()
    ensure_named(Store)
    ensure_named(GoalStore)
    ensure_named(IntentStore)
    ensure_named(KnowledgeGraphStore)
    :ok
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "target pending cap denies acceptance without leaking admission roots" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("tgtval")
    taint = trusted_taint("tgtval")

    lease = %Lease{
      token: :crypto.strong_rand_bytes(32),
      agent_id: agent_id,
      admitted_gate_gen: 1
    }

    ensure_graph(agent_id)
    store_pid = Process.whereis(Store)
    assert is_pid(store_pid)

    transfers =
      Map.new(1..Core.max_pending(), fn _i ->
        ref = make_ref()

        {ref,
         %{
           operation_ref: ref,
           agent_id: agent_id,
           proposal_id: "prop_cap",
           operation_id: "op_cap",
           kind: :create_goal,
           plan: %{description: "cap", domain_id: "goal_cap", priority: :medium},
           joined_taint: taint,
           lease: lease,
           store_pid: store_pid,
           store_monitor: Process.monitor(store_pid),
           deadline_ms: System.monotonic_time(:millisecond) + 5_000,
           timer_ref: nil,
           phase: :reserved
         }}
      end)

    :sys.replace_state(GoalStore, fn state -> Map.put(state, :proposal_transfers, transfers) end)

    try do
      {:ok, p} =
        Proposal.create(agent_id, :goal, %{
          content: "cap goal",
          metadata: %{goal_data: %{"priority" => "low"}}
        })

      assert {:error, :limit_exceeded} = Proposal.accept(agent_id, p.id)
      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    after
      :sys.replace_state(GoalStore, fn state -> Map.put(state, :proposal_transfers, %{}) end)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "after drain create/boost/review/delete/accept are denied and cleanup stays root-free" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("deny")
    ensure_graph(agent_id)
    taint = trusted_taint("deny")

    {:ok, created} = Proposal.create_tainted(agent_id, :fact, %{content: "keep me"}, taint)

    {:ok, boostable} =
      Proposal.create_tainted(agent_id, :insight, %{content: "boost target"}, taint)

    before = snapshot(agent_id, created.id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert {:error, :store_unavailable} =
             Proposal.create_tainted(agent_id, :fact, %{content: "after drain"}, taint)

    assert {:error, :store_unavailable} =
             Proposal.create_tainted(agent_id, :insight, %{content: "boost target"}, taint)

    assert {:error, :store_unavailable} = Proposal.reject(agent_id, created.id)
    assert {:error, :store_unavailable} = Proposal.defer(agent_id, created.id)
    assert {:error, :store_unavailable} = Proposal.undefer(agent_id, created.id)
    assert {:error, :store_unavailable} = Proposal.delete(agent_id, created.id)
    assert {:error, :store_unavailable} = Proposal.accept_tainted(agent_id, created.id, taint)

    assert snapshot(agent_id, created.id) == before
    {:ok, still} = Proposal.get(agent_id, boostable.id)
    assert still.status == :pending
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert :ok = Proposal.delete_agent_content(agent_id)
    assert {:ok, true} = Proposal.agent_content_absent?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "four routes wait for drain while target is suspended then complete" do
    require_proposal_owner_admission!()

    routes = [
      {:goal, GoalStore,
       fn agent ->
         Proposal.create(agent, :goal, %{
           content: "Ship owner admission",
           metadata: %{goal_data: %{"priority" => "high"}}
         })
       end,
       fn agent, proposal, target_id ->
         assert String.starts_with?(target_id, "goal_prop_")

         assert [{{^agent, ^target_id}, goal}] =
                  :ets.lookup(:arbor_memory_goals, {agent, target_id})

         assert goal.description == "Ship owner admission"

         refute_kg_projection_content(agent, "Ship owner admission")
         assert_accepted_event(agent, proposal.id, target_id)
       end},
      {:goal_update, GoalStore,
       fn agent ->
         {:ok, goal} = GoalStore.add_goal_tainted(agent, "Existing", [], trusted_taint("g"))

         Proposal.create(agent, :goal_update, %{
           content: "progress",
           metadata: %{update_data: %{"id" => goal.id, "progress" => 0.4}}
         })
       end,
       fn agent, proposal, target_id ->
         assert [{{^agent, ^target_id}, goal}] =
                  :ets.lookup(:arbor_memory_goals, {agent, target_id})

         assert_in_delta goal.progress, 0.4, 0.0001
         assert_accepted_event(agent, proposal.id, target_id)
       end},
      {:intent, IntentStore,
       fn agent ->
         Proposal.create(agent, :intent, %{
           content: "Read config",
           metadata: %{decomposition: %{"capability" => "fs", "op" => "read", "target" => "/tmp"}}
         })
       end,
       fn agent, proposal, target_id ->
         assert String.starts_with?(target_id, "int_prop_")
         assert [{^agent, data}] = :ets.lookup(:arbor_memory_intents, agent)
         assert intent = Enum.find(data.intents, &(&1.id == target_id))
         assert intent.reasoning == "Read config"
         assert intent.capability == "fs"
         refute_kg_projection_content(agent, "Read config")
         assert_accepted_event(agent, proposal.id, target_id)
       end},
      {:knowledge, KnowledgeGraphStore,
       fn agent -> Proposal.create(agent, :fact, %{content: "unique knowledge #{agent}"}) end,
       fn agent, proposal, target_id ->
         assert [{^agent, graph}] = :ets.lookup(:arbor_memory_graphs, agent)
         {:ok, node} = KnowledgeGraph.get_node(graph, target_id)
         assert node.content == "unique knowledge #{agent}"
         assert_accepted_event(agent, proposal.id, target_id)
       end}
    ]

    Enum.each(routes, fn {_kind, target, factory, assert_target} ->
      agent_id = unique_agent("route")
      ensure_graph(agent_id)
      {:ok, proposal} = factory.(agent_id)
      flush_accepted_signals()
      unsubscribe = subscribe_accepted(self())
      target_pid = Process.whereis(target)
      assert is_pid(target_pid)
      true = :erlang.suspend_process(target_pid)

      try do
        accept_task = Task.async(fn -> Proposal.accept(agent_id, proposal.id) end)
        await_roots(agent_id, 2)

        drain_task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 5_000) end)

        await_until(fn ->
          match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id))
        end)

        drain_ref = Process.monitor(drain_task.pid)
        refute_receive {:DOWN, ^drain_ref, :process, _, _}, 50

        true = :erlang.resume_process(target_pid)
        assert {:ok, target_id} = Task.await(accept_task, 5_000)
        assert is_binary(target_id)
        {:ok, done} = Proposal.get(agent_id, proposal.id)
        assert done.status == :accepted
        assert_accepted_signal(agent_id, proposal.id, target_id)
        assert_target.(agent_id, proposal, target_id)
        assert {:ok, _fence} = Task.await(drain_task, 5_000)

        assert {:error, :store_unavailable} =
                 Proposal.create(agent_id, :fact, %{content: "after #{agent_id}"})
      after
        unsubscribe.()
        resume_if_suspended(target_pid)
      end
    end)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "target death after handoff reports unknown and keeps the proposal pending" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("tdie")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :goal, %{content: "die after handoff"})

    proposal_lease = hand_lease_to(agent_id, Store)
    target_lease = hand_lease_to(agent_id, GoalStore)
    {from, tag} = reply_mailbox()
    op_ref = make_ref()
    goal_pid = Process.whereis(GoalStore)
    assert is_pid(goal_pid)
    goal_mon = Process.monitor(goal_pid)

    :sys.replace_state(Store, fn state ->
      put_injected_pending(state, %{
        from: from,
        agent_id: agent_id,
        proposal_id: p.id,
        operation_ref: op_ref,
        operation_id: "prop_xfer_" <> p.id,
        target_pid: goal_pid,
        target_module: GoalStore,
        target_monitor: Process.monitor(goal_pid),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        proposal_lease: proposal_lease,
        target_lease: :handed,
        kind: :create_goal,
        plan: %{description: "die after handoff", domain_id: "goal_die", priority: :medium},
        fence_origin: :new,
        phase: :awaiting_result
      })
    end)

    try do
      assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
      assert_receive {:DOWN, ^goal_mon, :process, ^goal_pid, _}, 2_000
      assert_receive {:gen_reply, ^tag, {:error, :transfer_outcome_unknown}}, 2_000
      {:ok, still} = Proposal.get(agent_id, p.id)
      assert still.status == :pending
      refute_accepted_event(agent_id, p.id)
      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    after
      ensure_named(GoalStore)
      drop_store_pending(op_ref)
      release_from(Store, proposal_lease)
      release_from(GoalStore, target_lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "timeout by each phase uses real leases and keeps unknown fences" do
    require_proposal_owner_admission!()

    Enum.each([:reserving, :handing_off, :awaiting_result], fn phase ->
      agent_id = unique_agent("tmo_#{phase}")
      ensure_graph(agent_id)
      {:ok, p} = Proposal.create(agent_id, :goal, %{content: "timeout #{phase}"})
      proposal_lease = hand_lease_to(agent_id, Store)

      {target_lease, tracked_target} =
        if phase == :awaiting_result do
          {hand_lease_to(agent_id, GoalStore), :handed}
        else
          {hand_lease_to(agent_id, Store), :lease}
        end

      {from, tag} = reply_mailbox()
      op_ref = make_ref()

      :sys.replace_state(Store, fn state ->
        put_injected_pending(state, %{
          from: from,
          agent_id: agent_id,
          proposal_id: p.id,
          operation_ref: op_ref,
          operation_id: "prop_xfer_" <> p.id,
          target_pid: Process.whereis(GoalStore),
          target_module: GoalStore,
          target_monitor: Process.monitor(Process.whereis(GoalStore)),
          deadline_ms: System.monotonic_time(:millisecond) - 25,
          proposal_lease: proposal_lease,
          target_lease: if(tracked_target == :handed, do: :handed, else: target_lease),
          kind: :create_goal,
          plan: %{description: "timeout #{phase}", domain_id: "goal_tmo", priority: :medium},
          fence_origin: :new,
          phase: phase
        })
      end)

      try do
        send(Process.whereis(Store), {:accept_timeout, op_ref})
        assert_receive {:gen_reply, ^tag, {:error, reason}}, 2_000
        assert reason in [:transfer_outcome_unknown, :invalid_request]
        {:ok, still} = Proposal.get(agent_id, p.id)
        assert still.status == :pending
        refute_accepted_event(agent_id, p.id)

        if phase == :awaiting_result do
          assert {:ok, %{active_roots: n}} = MutationAdmission.status(agent_id)
          assert n >= 1
        else
          await_until(fn ->
            match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
          end)
        end
      after
        drop_store_pending(op_ref)
        release_from(Store, proposal_lease)
        release_from(if(phase == :awaiting_result, do: GoalStore, else: Store), target_lease)
      end
    end)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "Store death during reserved accept fails closed and releases roots" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("sdie")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :goal, %{content: "store death"})
    target_pid = Process.whereis(GoalStore)
    store_pid = Process.whereis(Store)
    assert is_pid(target_pid) and is_pid(store_pid)
    store_mon = Process.monitor(store_pid)
    true = :erlang.suspend_process(target_pid)

    try do
      accept_task = Task.async(fn -> Proposal.accept(agent_id, p.id) end)
      await_roots(agent_id, 2)
      assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Store)
      assert_receive {:DOWN, ^store_mon, :process, ^store_pid, _}, 2_000

      result =
        case Task.yield(accept_task, 5_000) || Task.shutdown(accept_task, :brutal_kill) do
          {:ok, reply} -> reply
          _ -> {:error, :store_unavailable}
        end

      assert match?({:error, _}, result)
      resume_if_suspended(target_pid)
      ensure_named(Store)

      case Proposal.get(agent_id, p.id) do
        {:ok, still} -> assert still.status == :pending
        {:error, :not_found} -> :ok
        other -> flunk("unexpected get after Store death: #{inspect(other)}")
      end

      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    after
      resume_if_suspended(target_pid)
      ensure_named(Store)
      ensure_named(GoalStore)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "forged stolen-lease activate/result/wrong source/duplicate/late are effect-free" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("forge")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "forge #{agent_id}"})
    content = "forge #{agent_id}"

    assert {:error, :invalid_request} =
             GenServer.call(GoalStore, {:proposal_transfer_reserve, %{operation_ref: make_ref()}})

    assert {:error, :invalid_request} =
             GenServer.call(Store, {:proposal_transfer_result, %{operation_ref: make_ref()}})

    reserved_lease = hand_lease_to(agent_id, GoalStore)
    stolen_lease = hand_lease_to(agent_id, Store)
    reserved_ref = make_ref()

    :sys.replace_state(GoalStore, fn state ->
      put_goal_transfer(state, %{
        operation_ref: reserved_ref,
        agent_id: agent_id,
        proposal_id: p.id,
        operation_id: "prop_xfer_" <> p.id,
        kind: :create_goal,
        plan: %{description: "stolen", domain_id: "goal_stolen", priority: :medium},
        joined_taint: trusted_taint("stolen"),
        lease: reserved_lease,
        store_pid: Process.whereis(Store),
        store_monitor: Process.monitor(Process.whereis(Store)),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        timer_ref: nil,
        phase: :reserved
      })
    end)

    try do
      assert {:error, :invalid_request} =
               GenServer.call(GoalStore, {
                 :proposal_transfer_activate,
                 %{operation_ref: reserved_ref, lease: stolen_lease}
               })

      impersonate_store(fn ->
        assert {:error, :invalid_request} =
                 GenServer.call(GoalStore, {
                   :proposal_transfer_activate,
                   %{operation_ref: reserved_ref, lease: stolen_lease}
                 })
      end)

      transfers = Map.get(:sys.get_state(GoalStore), :proposal_transfers, %{})
      assert match?(%{phase: :reserved}, Map.get(transfers, reserved_ref))
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, "goal_stolen")

      {from, tag} = reply_mailbox()
      pending_ref = make_ref()
      proposal_lease = hand_lease_to(agent_id, Store)

      :sys.replace_state(Store, fn state ->
        put_injected_pending(state, %{
          from: from,
          agent_id: agent_id,
          proposal_id: p.id,
          operation_ref: pending_ref,
          operation_id: "prop_xfer_" <> p.id,
          target_pid: self(),
          target_module: KnowledgeGraphStore,
          target_monitor: Process.monitor(self()),
          deadline_ms: System.monotonic_time(:millisecond) + 5_000,
          proposal_lease: proposal_lease,
          target_lease: :handed,
          kind: :create_knowledge,
          plan: %{type: :fact, content: content, relevance: 0.7, metadata: %{}},
          fence_origin: :new,
          phase: :awaiting_result
        })
      end)

      wrong_source_report = %{
        agent_id: agent_id,
        proposal_id: p.id,
        operation_ref: pending_ref,
        operation_id: "prop_xfer_" <> p.id,
        outcome: {:ok, "node_stolen"}
      }

      # Wrong caller: a spawned process is not the parked target.
      assert {:error, :invalid_request} =
               Task.await(
                 Task.async(fn ->
                   GenServer.call(Store, {:proposal_transfer_result, wrong_source_report})
                 end),
                 2_000
               )

      assert {:error, :invalid_request} =
               GenServer.call(Store, {
                 :proposal_transfer_result,
                 Map.put(wrong_source_report, :operation_id, "prop_xfer_other")
               })

      {:ok, still} = Proposal.get(agent_id, p.id)
      assert still.status == :pending

      drop_store_pending(pending_ref)
      refute_receive {:gen_reply, ^tag, _}, 20

      assert {:error, :invalid_request} =
               GenServer.call(Store, {:proposal_transfer_result, wrong_source_report})

      release_from(Store, proposal_lease)
    after
      :sys.replace_state(GoalStore, fn state -> Map.put(state, :proposal_transfers, %{}) end)
      release_from(GoalStore, reserved_lease)
      release_from(Store, stolen_lease)
    end

    assert {:ok, target_id} = Proposal.accept(agent_id, p.id)
    assert is_binary(target_id)
    {:ok, done} = Proposal.get(agent_id, p.id)
    assert done.status == :accepted

    assert {:error, :invalid_request} =
             GenServer.call(Store, {
               :proposal_transfer_result,
               %{
                 agent_id: agent_id,
                 proposal_id: p.id,
                 operation_ref: make_ref(),
                 operation_id: "prop_xfer_" <> p.id,
                 outcome: {:ok, "node_duplicate"}
               }
             })

    assert {:ok, ^target_id} = Proposal.accept(agent_id, p.id)
    {:ok, graph} = GraphOps.get_graph(agent_id)

    matches =
      graph.nodes
      |> Map.values()
      |> Enum.filter(&(&1.content == content))

    assert length(matches) == 1
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "lost ack and stable retry converge to one target and keep the fence" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("lost")
    ensure_graph(agent_id)
    content = "lost ack replay #{agent_id}"
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: content})
    unsubscribe = subscribe_accepted(self())
    decision = TaintEnvelope.missing_fallback()

    try do
      assert {:ok, {:ready, proposal, joined_taint, _status, fence}} =
               GenServer.call(
                 Store,
                 {:prepare_accept, agent_id, p.id, decision, :legacy_unlabeled}
               )

      assert fence.phase == :in_flight
      assert fence.operation_id == "prop_xfer_" <> p.id
      assert {:knowledge, node_data} = Core.transfer_plan(proposal)

      assert {:ok, first_target} =
               GraphOps.add_knowledge_tainted(agent_id, node_data, joined_taint,
                 operation_id: fence.operation_id
               )

      {:ok, mid} = Proposal.get(agent_id, p.id)
      assert mid.status == :pending
      refute_receive {:proposal_accepted_signal, _}, 50

      assert {:ok, target} = Proposal.accept(agent_id, p.id)
      assert target == first_target
      assert {:ok, ^target} = Proposal.accept(agent_id, p.id)
      {:ok, done} = Proposal.get(agent_id, p.id)
      assert done.status == :accepted
      assert_accepted_signal(agent_id, p.id, target)
      assert_accepted_event(agent_id, p.id, target)

      {:ok, graph} = GraphOps.get_graph(agent_id)

      matches =
        graph.nodes
        |> Map.values()
        |> Enum.filter(&(&1.content == content))

      assert length(matches) == 1
      assert hd(matches).id == target

      {:ok, p2} = Proposal.create(agent_id, :insight, %{content: "second #{agent_id}"})

      assert {:ok, {:ready, _, _, _, fence2}} =
               GenServer.call(
                 Store,
                 {:prepare_accept, agent_id, p2.id, decision, :legacy_unlabeled}
               )

      assert fence2.operation_id == "prop_xfer_" <> p2.id
      assert fence2.operation_id != fence.operation_id
      assert {:ok, _drain_fence} = MutationAdmission.drain(agent_id)
      assert {:error, :store_unavailable} = Proposal.accept(agent_id, p2.id)
      state = :sys.get_state(Store)
      record = get_in(state, [:by_agent, agent_id, p2.id])
      assert match?(%{phase: :in_flight}, record.fence)
      assert record.fence.operation_id == fence2.operation_id
      assert record.proposal.status == :pending
    after
      unsubscribe.()
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "accepted goal retains a target root when projection defers" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("retain")
    ensure_graph(agent_id)

    {:ok, p} =
      Proposal.create(agent_id, :goal, %{
        content: "retain after accept",
        metadata: %{goal_data: %{"priority" => "low"}}
      })

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, Arbor.Memory.Provenance)
    assert Process.whereis(Arbor.Memory.Provenance) == nil

    try do
      assert {:ok, target_id} = Proposal.accept(agent_id, p.id)
      assert is_binary(target_id)
      {:ok, done} = Proposal.get(agent_id, p.id)
      assert done.status == :accepted
      assert {:ok, %{active_roots: n}} = MutationAdmission.status(agent_id)
      assert n >= 1

      drain_task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 2_000) end)
      drain_ref = Process.monitor(drain_task.pid)
      await_until(fn -> match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id)) end)
      refute_receive {:DOWN, ^drain_ref, :process, _, _}, 10

      ensure_named(Arbor.Memory.Provenance)
      assert {:ok, _fence} = Task.await(drain_task, 2_000)
    after
      ensure_named(Arbor.Memory.Provenance)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "transient unresolved settlement retries then releases on recovery" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("transient")
    ensure_graph(agent_id)
    lease = hand_lease_to(agent_id, Store)

    :sys.replace_state(Store, fn state ->
      Map.merge(state, %{
        unresolved_roots: %{agent_id => [lease]},
        unresolved_retry: %{timer_ref: nil, gen: 21, attempts: 0}
      })
    end)

    try do
      assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, MutationAdmission)
      send(Process.whereis(Store), {:unresolved_retry, 21})
      state = :sys.get_state(Store)
      assert lease in Map.get(state.unresolved_roots, agent_id, [])
      retry = state.unresolved_retry
      assert is_map(retry)
      assert retry[:status] == :armed
      assert is_reference(retry[:timer_ref])
      remaining = Process.read_timer(retry.timer_ref)
      assert is_integer(remaining) and remaining > 0
      ensure_named(MutationAdmission)
      gen = get_in(state, [:unresolved_retry, :gen]) || 21

      :sys.replace_state(Store, fn current ->
        Map.put(current, :unresolved_retry, %{timer_ref: nil, gen: gen, attempts: 0})
      end)

      send(Process.whereis(Store), {:unresolved_retry, gen})
      _ = :sys.get_state(Store)
      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
      state = :sys.get_state(Store)
      assert Map.get(state.unresolved_roots, agent_id, []) == []
    after
      ensure_named(MutationAdmission)
      release_from(Store, lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "unavailable owner fails before root acquisition" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("unavail")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :goal, %{content: "no owner"})
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, GoalStore)
    assert Process.whereis(GoalStore) == nil

    try do
      assert {:error, :store_unavailable} = Proposal.accept(agent_id, p.id)
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
      {:ok, still} = Proposal.get(agent_id, p.id)
      assert still.status == :pending
      refute_accepted_event(agent_id, p.id)
    after
      ensure_named(GoalStore)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "malformed mailbox and missing owner fail before root acquisition" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("pre")
    ensure_graph(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert {:error, :missing_content} = Proposal.create(agent_id, :fact, %{})
    oversize_id = String.duplicate("m", Core.limits().max_identifier_bytes + 1)
    assert byte_size(oversize_id) > 0
    assert {:error, :invalid_request} = Proposal.accept(agent_id, oversize_id)

    assert {:error, :invalid_request} =
             Proposal.accept_tainted(agent_id, oversize_id, trusted_taint("malformed"))

    assert {:error, :invalid_provenance} =
             Proposal.accept_tainted(agent_id, "prop_missing_#{agent_id}", :not_taint)

    {:ok, bad} =
      Proposal.create(agent_id, :goal, %{content: "   ", metadata: %{goal_data: %{}}})

    assert {:error, :empty_description} = Proposal.accept(agent_id, bad.id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    {:ok, over_progress} =
      Proposal.create(agent_id, :goal_update, %{
        content: "too much",
        metadata: %{update_data: %{"id" => "goal_bound", "progress" => 2.0}}
      })

    assert {:error, :invalid_request} = Proposal.accept(agent_id, over_progress.id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    limits = Core.limits()
    oversize_content = String.duplicate("a", limits.max_content_bytes + 1)
    oversize_reason = String.duplicate("r", limits.max_reject_reason_bytes + 1)

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{content: oversize_content})

    huge_meta =
      Map.new(1..(limits.max_metadata_entries + 1), fn i ->
        {Integer.to_string(i), "x"}
      end)

    assert {:error, :limit_exceeded} =
             Proposal.create(agent_id, :fact, %{content: "ok", metadata: huge_meta})

    {:ok, rejectable} = Proposal.create(agent_id, :fact, %{content: "reject bound #{agent_id}"})

    assert {:error, :limit_exceeded} =
             Proposal.reject(agent_id, rejectable.id, reason: oversize_reason)

    {:ok, missing_goal_id} =
      Proposal.create(agent_id, :goal_update, %{
        content: "missing id",
        metadata: %{update_data: %{"progress" => 0.1}}
      })

    assert {:error, :invalid_request} = Proposal.accept(agent_id, missing_goal_id.id)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "cleanup while Store remains responsive replies unknown and redacts status" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("clean")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :goal, %{content: "cleanup goal"})
    store_pid = Process.whereis(Store)
    assert is_pid(store_pid)
    proposal_lease = hand_lease_to(agent_id, Store)
    target_lease = hand_lease_to(agent_id, Store)
    {from, tag} = reply_mailbox()
    op_ref = make_ref()

    :sys.replace_state(Store, fn state ->
      put_injected_pending(state, %{
        from: from,
        agent_id: agent_id,
        proposal_id: p.id,
        operation_ref: op_ref,
        operation_id: "prop_xfer_" <> p.id,
        target_pid: Process.whereis(GoalStore),
        target_module: GoalStore,
        target_monitor: Process.monitor(Process.whereis(GoalStore)),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        proposal_lease: proposal_lease,
        target_lease: target_lease,
        kind: :create_goal,
        plan: %{description: "cleanup goal", domain_id: "goal_clean", priority: :medium},
        fence_origin: :new,
        phase: :reserving
      })
    end)

    assert Process.alive?(store_pid)
    assert :ok = Proposal.delete_agent_content(agent_id)
    assert Process.alive?(store_pid)
    assert Process.whereis(Store) == store_pid
    assert_receive {:gen_reply, ^tag, {:error, :transfer_outcome_unknown}}, 2_000
    assert {:ok, true} = Proposal.agent_content_absent?(agent_id)
    await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    redact_lease = hand_lease_to(agent_id, Store)

    :sys.replace_state(Store, fn state ->
      roots = Map.get(state, :owner_roots, OwnerRoots.new())
      {:ok, roots} = OwnerRoots.defer(roots, agent_id, redact_lease)
      Map.put(state, :owner_roots, roots)
    end)

    try do
      status = :sys.get_status(Store)
      status_bin = :erlang.term_to_binary(status)
      refute status_bin =~ redact_lease.token
      refute inspect(redact_lease) =~ redact_lease.token
    after
      :sys.replace_state(Store, fn state ->
        roots = Map.get(state, :owner_roots, OwnerRoots.new())
        {roots, _} = OwnerRoots.ack(roots, redact_lease)
        Map.put(state, :owner_roots, roots)
      end)

      release_from(Store, redact_lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "hot upgrade prove-and-settles orphan pending leases" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("upgrade")
    ensure_graph(agent_id)
    {:ok, _} = Proposal.create(agent_id, :fact, %{content: "upgrade #{agent_id}"})
    lease = hand_lease_to(agent_id, Store)

    :sys.replace_state(Store, fn state ->
      roots = Map.get(state, :owner_roots, OwnerRoots.new())
      {:ok, roots} = OwnerRoots.defer(roots, agent_id, lease)

      Map.merge(state, %{
        owner_roots: roots,
        pending_acceptances: %{make_ref() => %{agent_id: agent_id, from: nil}}
      })
    end)

    assert {:ok, _} = Store.stats(agent_id)
    await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    state = :sys.get_state(Store)
    assert is_map(state.pending_acceptances)

    refute Enum.any?(
             Map.values(state.pending_acceptances),
             &(&1 == %{agent_id: agent_id, from: nil})
           )

    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "already_done accept does not require a live target owner" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("done")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "done #{agent_id}"})
    assert {:ok, target_id} = Proposal.accept(agent_id, p.id)

    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, KnowledgeGraphStore)
    assert Process.whereis(KnowledgeGraphStore) == nil

    try do
      assert {:ok, ^target_id} = Proposal.accept(agent_id, p.id)
    after
      ensure_named(KnowledgeGraphStore)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "normalize keeps non-map pending crash-free and rearms expired deadlines" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("norm")
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "norm #{agent_id}"})
    ref = make_ref()
    lease = hand_lease_to(agent_id, Store)
    kept_lease = hand_lease_to(agent_id, Store)

    kg_pid = Process.whereis(KnowledgeGraphStore)
    assert is_pid(kg_pid)
    alias_from = {self(), [:alias | make_ref()]}
    kept_ref = make_ref()

    :sys.replace_state(Store, fn state ->
      pending = %{
        from: {self(), make_ref()},
        agent_id: agent_id,
        proposal_id: p.id,
        operation_ref: ref,
        operation_id: "prop_xfer_" <> p.id,
        target_pid: self(),
        target_module: GoalStore,
        target_monitor: Process.monitor(self()),
        deadline_ms: System.monotonic_time(:millisecond) - 25,
        timer_ref: nil,
        proposal_lease: lease,
        target_lease: :handed,
        kind: :create_knowledge,
        plan: %{},
        fence_origin: :new,
        phase: :awaiting_result
      }

      kept = %{
        from: alias_from,
        agent_id: agent_id,
        proposal_id: p.id,
        operation_ref: kept_ref,
        operation_id: "prop_xfer_kept_" <> p.id,
        target_pid: kg_pid,
        target_module: KnowledgeGraphStore,
        target_monitor: Process.monitor(kg_pid),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        timer_ref: nil,
        proposal_lease: kept_lease,
        target_lease: :handed,
        kind: :create_knowledge,
        plan: %{
          type: :fact,
          content: "norm keep #{agent_id}",
          relevance: 0.7,
          metadata: %{},
          skip_dedup: true
        },
        joined_taint: trusted_taint("norm"),
        fence_origin: :new,
        phase: :awaiting_result
      }

      %{
        state
        | pending_acceptances: %{
            ref => pending,
            kept_ref => kept,
            make_ref() => :not_a_map
          }
      }
    end)

    try do
      assert {:ok, _} = Store.stats(agent_id)
      state = :sys.get_state(Store)
      assert is_map(state.pending_acceptances)

      case Map.get(state.pending_acceptances, ref) do
        %{timer_ref: timer_ref} ->
          assert is_reference(timer_ref)

        nil ->
          assert true

        _other ->
          flunk("expired pending left without a timer or close")
      end

      kept = Map.get(state.pending_acceptances, kept_ref)
      assert is_map(kept)
      assert kept.from == alias_from
    after
      drop_store_pending(ref)
      drop_store_pending(kept_ref)
      release_from(Store, lease)
      release_from(Store, kept_lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "unresolved quarantine keeps absence false until cleanup retries settle" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("unres")
    ensure_graph(agent_id)
    {:ok, _} = Proposal.create(agent_id, :fact, %{content: "unres #{agent_id}"})
    lease = hand_lease_to(agent_id, Store)

    :sys.replace_state(Store, fn state ->
      Map.put(state, :unresolved_roots, %{agent_id => [lease]})
    end)

    try do
      assert {:ok, false} = Proposal.agent_content_absent?(agent_id)
      assert :ok = Proposal.delete_agent_content(agent_id)
      assert {:ok, true} = Proposal.agent_content_absent?(agent_id)
      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
    after
      :sys.replace_state(Store, fn state ->
        unresolved = Map.get(state, :unresolved_roots, %{})
        Map.put(state, :unresolved_roots, Map.delete(unresolved, agent_id))
      end)

      release_from(Store, lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "expired unresolved reservation is retained without a 0ms spin" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("nospin")
    ensure_graph(agent_id)
    lease = hand_lease_to(agent_id, GoalStore)
    ref = make_ref()
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, MutationAdmission)

    :sys.replace_state(GoalStore, fn state ->
      put_goal_transfer(state, %{
        operation_ref: ref,
        agent_id: agent_id,
        proposal_id: "prop_nospin",
        operation_id: "prop_xfer_prop_nospin",
        kind: :create_goal,
        plan: %{description: "nospin", domain_id: "goal_nospin", priority: :medium},
        joined_taint: trusted_taint("nospin"),
        lease: lease,
        store_pid: Process.whereis(Store),
        store_monitor: Process.monitor(Process.whereis(Store)),
        deadline_ms: System.monotonic_time(:millisecond) - 50,
        timer_ref: nil,
        phase: :reserved
      })
    end)

    try do
      _ = GoalStore.get_goal(agent_id, "goal_nospin")
      assert_positive_reserve_backoff(ref, 50)

      messages = elem(Process.info(Process.whereis(GoalStore), :messages), 1)

      refute Enum.any?(messages, fn
               {:transfer_reserve_timeout, ^ref} -> true
               _ -> false
             end)

      first = Map.fetch!(:sys.get_state(GoalStore).proposal_transfers, ref)

      Enum.each(1..3, fn _ ->
        _ = GoalStore.get_goal(agent_id, "goal_nospin")
      end)

      unchanged = Map.fetch!(:sys.get_state(GoalStore).proposal_transfers, ref)
      assert unchanged.timer_ref == first.timer_ref
      assert unchanged.settle_attempts == first.settle_attempts

      send(Process.whereis(GoalStore), {:transfer_reserve_timeout, ref})
      unchanged = Map.fetch!(:sys.get_state(GoalStore).proposal_transfers, ref)
      assert unchanged.timer_ref == first.timer_ref
      assert unchanged.settle_attempts == first.settle_attempts

      await_until(fn ->
        state = :sys.get_state(GoalStore)

        case Map.get(state.proposal_transfers, ref) do
          %{settle_attempts: attempts} -> attempts > first.settle_attempts
          nil -> true
          _ -> false
        end
      end)

      status_bin = :erlang.term_to_binary(:sys.get_status(GoalStore))
      refute status_bin =~ lease.token
    after
      ensure_named(MutationAdmission)
      :sys.replace_state(GoalStore, fn state -> Map.put(state, :proposal_transfers, %{}) end)
      release_from(GoalStore, lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "unresolved_roots are not truncated and redact to counts" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("nosecret")
    ensure_graph(agent_id)
    count = Core.max_pending() + 5
    leases = Enum.map(1..count, fn _ -> hand_lease_to(agent_id, Store) end)

    :sys.replace_state(Store, fn state ->
      Map.put(state, :unresolved_roots, %{agent_id => leases})
    end)

    try do
      state = :sys.get_state(Store)
      assert length(Map.get(state.unresolved_roots, agent_id, [])) == count
      assert {:ok, false} = Proposal.agent_content_absent?(agent_id)

      status_bin = :erlang.term_to_binary(:sys.get_status(Store))

      Enum.each(leases, fn lease ->
        refute status_bin =~ lease.token
      end)

      :sys.replace_state(Store, fn state ->
        Map.put(state, :unresolved_retry, %{timer_ref: nil, gen: 11, attempts: 0})
      end)

      send(Process.whereis(Store), {:unresolved_retry, 11})
      state = :sys.get_state(Store)
      remaining = length(Map.get(state.unresolved_roots, agent_id, []))
      assert remaining > 0
      assert remaining < count
      retry = state.unresolved_retry
      assert retry[:status] == :armed
      assert is_reference(retry[:timer_ref])
      timer_left = Process.read_timer(retry.timer_ref)
      assert is_integer(timer_left) and timer_left > 0

      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
      state = :sys.get_state(Store)
      assert Map.get(state.unresolved_roots, agent_id, []) == []
    after
      :sys.replace_state(Store, fn state ->
        unresolved = Map.get(state, :unresolved_roots, %{})
        Map.put(state, :unresolved_roots, Map.delete(unresolved, agent_id))
      end)

      Enum.each(leases, &release_from(Store, &1))
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "malformed pending without agent_id settles through lease.agent_id" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("malagent")
    ensure_graph(agent_id)
    lease = hand_lease_to(agent_id, Store)

    :sys.replace_state(Store, fn state ->
      pending = %{
        from: {self(), make_ref()},
        proposal_lease: lease,
        target_lease: :handed,
        phase: :reserving
      }

      Map.put(state, :pending_acceptances, %{make_ref() => pending})
    end)

    try do
      assert {:ok, _} = Store.stats(agent_id)
      await_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
      state = :sys.get_state(Store)
      assert state.pending_acceptances == %{} or map_size(state.pending_acceptances) == 0
    after
      release_from(Store, lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "hot-upgrade key and phase ownership mismatches settle every Store-owned root" do
    require_proposal_owner_admission!()

    Enum.each([:key_mismatch, :phase_mismatch], fn mode ->
      agent_id = unique_agent("pending_#{mode}")
      proposal_lease = hand_lease_to(agent_id, Store)
      target_lease = hand_lease_to(agent_id, Store)
      assert Core.valid_owner_lease?(proposal_lease, agent_id)
      assert Core.valid_owner_lease?(target_lease, agent_id)
      operation_ref = make_ref()
      stored_ref = if mode == :key_mismatch, do: make_ref(), else: operation_ref
      {from, tag} = reply_mailbox()

      pending = %{
        from: from,
        agent_id: agent_id,
        proposal_id: "prop_pending_mismatch",
        operation_ref: operation_ref,
        operation_id: "prop_xfer_prop_pending_mismatch",
        target_pid: Process.whereis(GoalStore),
        target_module: GoalStore,
        target_monitor: Process.monitor(Process.whereis(GoalStore)),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        proposal_lease: proposal_lease,
        target_lease: target_lease,
        kind: :create_goal,
        plan: %{description: "mismatch", domain_id: "goal_mismatch", priority: :medium},
        joined_taint: trusted_taint("mismatch"),
        fence_origin: :new,
        phase: if(mode == :phase_mismatch, do: :awaiting_result, else: :reserving)
      }

      :sys.replace_state(Store, fn state ->
        state = put_injected_pending(state, pending)
        acceptances = Map.fetch!(state, :pending_acceptances)
        stored = Map.fetch!(acceptances, operation_ref)
        Map.put(state, :pending_acceptances, %{stored_ref => stored})
      end)

      try do
        assert {:ok, _} = Store.stats(agent_id)
        assert_receive {:gen_reply, ^tag, {:error, :transfer_outcome_unknown}}, 2_000

        await_until(fn ->
          match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
        end)

        refute Map.has_key?(:sys.get_state(Store).pending_acceptances, stored_ref)
      after
        drop_store_pending(operation_ref)
        drop_store_pending(stored_ref)
        release_from(Store, proposal_lease)
        release_from(Store, target_lease)
      end
    end)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "acceptance keeps the original owner deadline through target reservation" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("deadline")
    ensure_graph(agent_id)
    {:ok, proposal} = Proposal.create(agent_id, :goal, %{content: "deadline fence"})
    target_pid = Process.whereis(GoalStore)
    true = :erlang.suspend_process(target_pid)
    deadline_ms = System.monotonic_time(:millisecond) + 50

    try do
      result =
        GenServer.call(
          Store,
          {:timed, deadline_ms,
           {:accept, agent_id, proposal.id, trusted_taint("deadline"), :verified}},
          2_000
        )

      assert result in [
               {:error, :request_expired},
               {:error, :transfer_outcome_unknown}
             ]

      resume_if_suspended(target_pid)
      {:ok, still} = Proposal.get(agent_id, proposal.id)
      assert still.status == :pending
      goal_id = Core.fence_ids(%{id: proposal.id, type: :goal}).domain_id
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal_id)

      await_until(fn ->
        match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
      end)
    after
      resume_if_suspended(target_pid)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "security regression: original owner deadline fences every target durable write" do
    require_proposal_owner_admission!()

    routes = [
      {:goal, GoalStore,
       fn agent_id ->
         Proposal.create(agent_id, :goal, %{content: "deadline goal #{agent_id}"})
       end,
       fn agent_id, proposal ->
         goal_id = Core.fence_ids(%{id: proposal.id, type: proposal.type}).domain_id
         assert {:error, :not_found} = GoalStore.get_goal(agent_id, goal_id)
       end},
      {:intent, IntentStore,
       fn agent_id ->
         Proposal.create(agent_id, :intent, %{
           content: "deadline intent #{agent_id}",
           metadata: %{
             decomposition: %{"capability" => "fs", "op" => "read", "target" => "/tmp"}
           }
         })
       end,
       fn agent_id, proposal ->
         intent_id = Core.fence_ids(%{id: proposal.id, type: proposal.type}).domain_id
         assert {:error, :not_found} = IntentStore.get_intent(agent_id, intent_id)
       end},
      {:knowledge, KnowledgeGraphStore,
       fn agent_id ->
         Proposal.create(agent_id, :fact, %{content: "deadline knowledge #{agent_id}"})
       end,
       fn agent_id, _proposal ->
         refute_kg_projection_content(agent_id, "deadline knowledge #{agent_id}")
       end}
    ]

    Enum.each(routes, fn {label, target, create_proposal, assert_absent} ->
      agent_id = unique_agent("durable_deadline_#{label}")
      ensure_graph(agent_id)
      {:ok, proposal} = create_proposal.(agent_id)

      assert_target_write_fenced_by_deadline(target, agent_id, proposal)
      assert_absent.(agent_id, proposal)

      {:ok, still} = Proposal.get(agent_id, proposal.id)
      assert still.status == :pending

      await_until(fn ->
        match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
      end)
    end)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "security regression: unknown target CAS retains its root through convergence" do
    require_proposal_owner_admission!()
    start_post_commit_blocking_backend!()

    routes = [
      {:goal, 0,
       fn agent_id ->
         Proposal.create(agent_id, :goal, %{content: "ambiguous goal #{agent_id}"})
       end,
       fn agent_id, proposal ->
         goal_id = Core.fence_ids(%{id: proposal.id, type: proposal.type}).domain_id

         assert [{{^agent_id, ^goal_id}, goal}] =
                  :ets.lookup(:arbor_memory_goals, {agent_id, goal_id})

         assert goal.description == "ambiguous goal #{agent_id}"
       end},
      {:intent, 0,
       fn agent_id ->
         Proposal.create(agent_id, :intent, %{
           content: "ambiguous intent #{agent_id}",
           metadata: %{
             decomposition: %{"capability" => "fs", "op" => "read", "target" => "/tmp"}
           }
         })
       end,
       fn agent_id, proposal ->
         intent_id = Core.fence_ids(%{id: proposal.id, type: proposal.type}).domain_id
         assert [{^agent_id, data}] = :ets.lookup(:arbor_memory_intents, agent_id)
         assert intent = Enum.find(data.intents, &(&1.id == intent_id))
         assert intent.reasoning == "ambiguous intent #{agent_id}"
       end},
      {:knowledge, 500,
       fn agent_id ->
         Proposal.create(agent_id, :fact, %{content: "ambiguous knowledge #{agent_id}"})
       end,
       fn agent_id, _proposal ->
         assert [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)

         assert Enum.any?(
                  Map.values(graph.nodes),
                  &(&1.content == "ambiguous knowledge #{agent_id}")
                )
       end}
    ]

    Enum.each(routes, fn {label, ambiguity_delay_ms, create_proposal, assert_effect} ->
      agent_id = unique_agent("unknown_root_#{label}")
      ensure_graph(agent_id)
      {:ok, proposal} = create_proposal.(agent_id)

      PostCommitBlockingBackend.arm(@ambiguity_control, self(), ambiguity_delay_ms)
      assert_acceptance_outcome_unknown(agent_id, proposal, ambiguity_delay_ms)
      assert_receive {:ambiguous_target_cas_committed, _key}, 2_000

      assert_receive {:target_convergence_read_blocked, _operation, authority_pid}, 2_000
      assert {:ok, %{active_roots: roots}} = MutationAdmission.status(agent_id)
      assert roots >= 1

      drain_task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 2_000) end)
      await_until(fn -> match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id)) end)
      assert Task.yield(drain_task, 20) == nil

      send(authority_pid, :release_target_convergence_read)
      assert {:ok, _fence} = Task.await(drain_task, 2_000)
      assert_effect.(agent_id, proposal)

      {:ok, still} = Proposal.get(agent_id, proposal.id)
      assert still.status == :pending
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    end)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "malformed reserved target transfer recovers agent identity from its live lease" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("xferagent")
    lease = hand_lease_to(agent_id, GoalStore)
    ref = make_ref()

    :sys.replace_state(GoalStore, fn state ->
      put_goal_transfer(state, %{
        operation_ref: ref,
        agent_id: nil,
        proposal_id: "prop_malformed",
        operation_id: "prop_xfer_prop_malformed",
        kind: :create_goal,
        plan: %{description: "malformed", domain_id: "goal_malformed", priority: :medium},
        joined_taint: trusted_taint("malformed"),
        lease: lease,
        store_pid: Process.whereis(Store),
        store_monitor: Process.monitor(Process.whereis(Store)),
        deadline_ms: System.monotonic_time(:millisecond) + 5_000,
        timer_ref: nil,
        phase: :reserved
      })
    end)

    try do
      assert {:error, :not_found} = GoalStore.get_goal(agent_id, "goal_malformed")
      assert Process.alive?(Process.whereis(GoalStore))

      await_until(fn ->
        match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
      end)

      state = :sys.get_state(GoalStore)
      refute Map.has_key?(Map.get(state, :proposal_transfers, %{}), ref)
    after
      release_from(GoalStore, lease)
    end
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "target normalization forgets locally tracked authority already absent at admission" do
    require_proposal_owner_admission!()
    agent_id = unique_agent("xferstale")
    lease = hand_lease_to(agent_id, GoalStore)
    ref = make_ref()

    :sys.replace_state(GoalStore, fn state ->
      roots = Map.get(state, :owner_roots, OwnerRoots.new())
      {:ok, roots} = OwnerRoots.defer(roots, agent_id, lease)
      :ok = MutationAdmission.release(lease)

      state
      |> Map.put(:owner_roots, roots)
      |> put_goal_transfer(%{
        operation_ref: ref,
        agent_id: agent_id,
        proposal_id: "prop_stale",
        operation_id: "prop_xfer_prop_stale",
        kind: :create_goal,
        plan: %{description: "stale", domain_id: "goal_stale", priority: :medium},
        joined_taint: trusted_taint("stale"),
        lease: lease,
        store_pid: Process.whereis(Store),
        store_monitor: Process.monitor(Process.whereis(Store)),
        deadline_ms: System.monotonic_time(:millisecond) - 1,
        timer_ref: nil,
        phase: :reserved
      })
    end)

    assert {:error, :not_found} = GoalStore.get_goal(agent_id, "goal_stale")
    state = :sys.get_state(GoalStore)
    refute OwnerRoots.held?(state.owner_roots, agent_id)
    refute Map.has_key?(state.proposal_transfers, ref)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  @tag packet: "VP-05D2C3I1B1F1"
  test "malformed or missing target lease evidence crashes the owner closed" do
    require_proposal_owner_admission!()

    Enum.each([:partial_lease, :missing_lease, :lost_record], fn mode ->
      agent_id = unique_agent("xfercrash_#{mode}")

      child_spec =
        {GoalStore, name: @malformed_goal_store}
        |> Supervisor.child_spec(id: {GoalStore, mode}, restart: :temporary)

      owner = start_supervised!(child_spec)
      lease = hand_lease_to(agent_id, @malformed_goal_store)
      ref = make_ref()
      owner_mon = Process.monitor(owner)

      :sys.replace_state(owner, fn state ->
        if mode == :lost_record do
          Map.put(state, :proposal_transfers, %{ref => :lost})
        else
          stored_lease = if mode == :partial_lease, do: Map.delete(lease, :agent_id), else: nil

          put_goal_transfer(state, %{
            operation_ref: ref,
            agent_id: agent_id,
            proposal_id: "prop_corrupt",
            operation_id: "prop_xfer_prop_corrupt",
            kind: :create_goal,
            plan: %{description: "corrupt", domain_id: "goal_corrupt", priority: :medium},
            joined_taint: trusted_taint("corrupt"),
            lease: stored_lease,
            store_pid: Process.whereis(Store),
            store_monitor: Process.monitor(Process.whereis(Store)),
            deadline_ms: System.monotonic_time(:millisecond) + 5_000,
            timer_ref: nil,
            phase: :reserved
          })
        end
      end)

      send(owner, :normalize_malformed_proposal_transfer)
      assert_receive {:DOWN, ^owner_mon, :process, ^owner, _reason}, 2_000

      await_until(fn ->
        match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
      end)

      assert Process.whereis(@malformed_goal_store) == nil
    end)
  end

  defp require_proposal_owner_admission! do
    agent = "prop_own_probe_#{System.unique_integer([:positive])}"
    {:ok, _} = Proposal.create(agent, :fact, %{content: "probe #{agent}"})
    assert {:ok, _} = MutationAdmission.drain(agent)

    case Proposal.create(agent, :fact, %{content: "after drain #{agent}"}) do
      {:error, _} ->
        :ok

      {:ok, _} ->
        flunk("proposal create remains admitted after drain")
    end
  end

  defp snapshot(agent_id, proposal_id) do
    {:ok, proposal} = Proposal.get(agent_id, proposal_id)
    {:ok, recent} = Events.get_recent(agent_id, 20)
    {proposal.status, proposal.confidence, length(recent)}
  end

  defp unique_agent(label), do: "prop_adm_#{label}_#{System.unique_integer([:positive])}"

  defp ensure_graph(agent_id) do
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    assert :ok = GraphOps.save_graph(agent_id, graph)
  end

  defp trusted_taint(source) do
    %Taint{
      level: :trusted,
      sensitivity: :public,
      sanitizations: 0,
      confidence: :verified,
      source: source,
      chain: []
    }
  end

  defp flush_accepted_signals do
    receive do
      {:proposal_accepted_signal, _} -> flush_accepted_signals()
    after
      0 -> :ok
    end
  end

  defp subscribe_accepted(test_pid) do
    {:ok, sub_id} =
      Arbor.Signals.subscribe("memory.proposal_accepted", fn signal ->
        send(test_pid, {:proposal_accepted_signal, signal})
      end)

    fn -> Arbor.Signals.unsubscribe(sub_id) end
  end

  defp assert_accepted_signal(agent_id, proposal_id, target_id) do
    assert_receive {:proposal_accepted_signal, signal}, 2_000
    data = signal_data(signal)

    if signal_field(data, :agent_id) != agent_id or
         signal_field(data, :proposal_id) != proposal_id do
      assert_accepted_signal(agent_id, proposal_id, target_id)
    else
      assert (signal_field(data, :target_id) || signal_field(data, :node_id)) == target_id
    end
  end

  defp signal_data(%{data: data}) when is_map(data), do: data
  defp signal_data(%{payload: data}) when is_map(data), do: data
  defp signal_data(data) when is_map(data), do: data
  defp signal_data(_), do: %{}

  defp signal_field(data, key) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp assert_accepted_event(agent_id, proposal_id, target_id) do
    assert {:ok, recent} = Events.get_recent(agent_id, 50)

    accepted =
      Enum.filter(recent, fn event ->
        to_string(event.type) == "proposal_accepted" and
          (event.data["proposal_id"] == proposal_id or event.data[:proposal_id] == proposal_id)
      end)

    assert length(accepted) == 1
    [event] = accepted

    assert event.data["node_id"] == target_id or event.data[:node_id] == target_id or
             event.data["target_id"] == target_id or event.data[:target_id] == target_id
  end

  defp refute_accepted_event(agent_id, proposal_id) do
    assert {:ok, recent} = Events.get_recent(agent_id, 50)

    refute Enum.any?(recent, fn event ->
             to_string(event.type) == "proposal_accepted" and
               (event.data["proposal_id"] == proposal_id or
                  event.data[:proposal_id] == proposal_id)
           end)
  end

  defp refute_kg_projection_content(agent_id, content) do
    assert [{^agent_id, graph}] = :ets.lookup(:arbor_memory_graphs, agent_id)
    refute Enum.any?(Map.values(graph.nodes), &(&1.content == content))
  end

  defp assert_target_write_fenced_by_deadline(target, agent_id, proposal) do
    durable_pid = Process.whereis(:arbor_memory_durable)
    assert is_pid(durable_pid)
    true = :erlang.suspend_process(durable_pid)
    deadline_ms = System.monotonic_time(:millisecond) + 500

    accept_task =
      Task.async(fn ->
        GenServer.call(
          Store,
          {:timed, deadline_ms,
           {:accept, agent_id, proposal.id, trusted_taint("durable deadline"), :verified}},
          2_000
        )
      end)

    try do
      await_until(
        fn ->
          Store
          |> :sys.get_state()
          |> Map.get(:pending_acceptances, %{})
          |> Map.values()
          |> Enum.any?(fn pending ->
            pending[:agent_id] == agent_id and pending[:phase] == :awaiting_result
          end)
        end,
        400
      )

      assert Task.await(accept_task, 2_000) in [
               {:error, :request_expired},
               {:error, :transfer_outcome_unknown}
             ]
    after
      resume_if_suspended(durable_pid)

      if Process.alive?(accept_task.pid) do
        Task.shutdown(accept_task, :brutal_kill)
      end
    end

    await_until(fn ->
      transfers = target |> :sys.get_state() |> Map.get(:proposal_transfers, %{})
      map_size(transfers) == 0
    end)
  end

  defp start_post_commit_blocking_backend! do
    assert :ok = stop_supervised!(BufferedStore)
    start_supervised!({QueryableStore.ETS, name: @ambiguity_collection})

    start_supervised!(%{
      id: @ambiguity_control,
      start:
        {Agent, :start_link,
         [
           fn -> %{armed: false, block_reads: false, delay_ms: 0, test_pid: self()} end,
           [name: @ambiguity_control]
         ]}
    })

    start_supervised!(
      {BufferedStore,
       name: :arbor_memory_durable,
       backend: PostCommitBlockingBackend,
       backend_opts: [control: @ambiguity_control],
       collection: @ambiguity_collection,
       write_mode: :sync,
       ack_mode: :backend}
    )
  end

  defp assert_acceptance_outcome_unknown(agent_id, proposal, 0) do
    assert {:error, :transfer_outcome_unknown} = Proposal.accept(agent_id, proposal.id)
  end

  defp assert_acceptance_outcome_unknown(agent_id, proposal, ambiguity_delay_ms)
       when is_integer(ambiguity_delay_ms) and ambiguity_delay_ms > 0 do
    deadline_ms = System.monotonic_time(:millisecond) + div(ambiguity_delay_ms, 2)

    assert {:error, :transfer_outcome_unknown} =
             GenServer.call(
               Store,
               {:timed, deadline_ms,
                {:accept, agent_id, proposal.id, trusted_taint("ambiguous CAS"), :verified}},
               2_000
             )
  end

  defp await_roots(agent_id, min) do
    await_until(fn ->
      match?({:ok, %{active_roots: n}} when n >= min, MutationAdmission.status(agent_id))
    end)
  end

  defp await_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_until(fun, deadline)
  end

  defp do_await_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met")
      else
        receive do
        after
          0 -> do_await_until(fun, deadline)
        end
      end
    end
  end

  defp reply_mailbox do
    parent = self()
    tag = make_ref()

    pid =
      spawn(fn ->
        receive do
          {^tag, reply} -> send(parent, {:gen_reply, tag, reply})
        end
      end)

    {{pid, tag}, tag}
  end

  defp hand_lease_to(agent_id, name) do
    {:ok, lease} = MutationAdmission.acquire(agent_id)
    pid = Process.whereis(name)
    assert is_pid(pid)
    assert {:ok, ^lease} = MutationAdmission.handoff(lease, pid)
    lease
  end

  defp release_from(name, %Lease{} = lease) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          roots = Map.get(state, :owner_roots, OwnerRoots.new())
          {roots, _} = OwnerRoots.ack(roots, lease)
          Map.put(state, :owner_roots, roots)
        end)

        :ok

      _ ->
        :ok
    end
  end

  defp release_from(_name, _), do: :ok

  defp put_injected_pending(state, pending) do
    roots = Map.get(state, :owner_roots, OwnerRoots.new())

    roots =
      case pending.proposal_lease do
        %Lease{} = lease ->
          case OwnerRoots.defer(roots, pending.agent_id, lease) do
            {:ok, next} -> next
            _ -> roots
          end

        _ ->
          roots
      end

    roots =
      case pending.target_lease do
        %Lease{} = lease ->
          case OwnerRoots.defer(roots, pending.agent_id, lease) do
            {:ok, next} -> next
            _ -> roots
          end

        _ ->
          roots
      end

    pending =
      pending
      |> Map.put_new(:timer_ref, nil)
      |> Map.put_new(:joined_taint, trusted_taint("inject"))

    acceptances = Map.get(state, :pending_acceptances, %{})

    state
    |> Map.put(:owner_roots, roots)
    |> Map.put(:pending_acceptances, Map.put(acceptances, pending.operation_ref, pending))
  end

  defp put_goal_transfer(state, xfer) do
    transfers = Map.get(state, :proposal_transfers, %{})
    Map.put(state, :proposal_transfers, Map.put(transfers, xfer.operation_ref, xfer))
  end

  defp drop_store_pending(op_ref) do
    case Process.whereis(Store) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          pending = Map.get(state, :pending_acceptances, %{})
          Map.put(state, :pending_acceptances, Map.delete(pending, op_ref))
        end)

      _ ->
        :ok
    end
  end

  defp impersonate_store(fun) do
    store_pid = Process.whereis(Store)
    assert is_pid(store_pid)
    true = Process.unregister(Store)
    true = Process.register(self(), Store)

    try do
      fun.()
    after
      unregister_if(self(), Store)

      if Process.whereis(Store) == nil and Process.alive?(store_pid) do
        true = Process.register(store_pid, Store)
      end
    end
  end

  defp unregister_if(pid, name) do
    case Process.info(pid, :registered_name) do
      {:registered_name, ^name} ->
        try do
          Process.unregister(name)
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp assert_positive_reserve_backoff(ref, max_ms) do
    state = :sys.get_state(GoalStore)
    xfer = Map.get(Map.get(state, :proposal_transfers, %{}), ref)
    assert is_map(xfer)
    assert is_reference(xfer.timer_ref)
    remaining = Process.read_timer(xfer.timer_ref)
    assert is_integer(remaining) and remaining > 0
    assert remaining <= max_ms
  end

  defp resume_if_suspended(pid) when is_pid(pid) do
    try do
      _ = :erlang.resume_process(pid)
    rescue
      ArgumentError -> :ok
    catch
      :error, _ -> :ok
    end

    :ok
  end

  defp resume_if_suspended(_), do: :ok

  defp ensure_named(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, name) do
          {:ok, pid} ->
            pid

          {:ok, pid, _} ->
            pid

          {:error, {:already_started, pid}} ->
            pid

          {:error, :running} ->
            Process.whereis(name)

          other ->
            case name.start_link([]) do
              {:ok, pid} -> pid
              {:error, {:already_started, pid}} -> pid
              _ -> flunk("failed to restore #{inspect(name)}: #{inspect(other)}")
            end
        end
    end
  end

  defp ensure_durable_store do
    case Process.whereis(:arbor_memory_durable) do
      nil ->
        start_supervised!(
          {BufferedStore, name: :arbor_memory_durable, backend: nil, write_mode: :sync}
        )

      _ ->
        :ok
    end
  end
end
