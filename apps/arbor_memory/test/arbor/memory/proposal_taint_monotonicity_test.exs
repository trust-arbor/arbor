defmodule Arbor.Memory.ProposalTaintMonotonicityTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.Proposal
  alias Arbor.Memory.Proposal.{Core, Store}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"

  setup do
    ensure_durable_store()
    agent_id = "prop_taint_#{System.unique_integer([:positive])}"
    on_exit(fn -> _ = Proposal.delete_all(agent_id) end)
    %{agent_id: agent_id}
  end

  test "exact dedup joins hostile into retained and keeps worst status", %{agent_id: agent_id} do
    trusted = trusted_taint("create")
    hostile = hostile_taint("dedup")

    {:ok, first} =
      Proposal.create_tainted(agent_id, :fact, %{content: "Same content exact"}, trusted)

    {:ok, second} =
      Proposal.create_tainted(agent_id, :fact, %{content: "Same content exact"}, hostile)

    assert first.id == second.id

    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, first.id)
    assert status == :verified
    assert taint.level == :hostile
    assert taint.sensitivity == :restricted
  end

  test "fuzzy dedup joins taint monotonically for high-similarity content", %{agent_id: agent_id} do
    content_a = "alpha beta gamma delta epsilon zeta eta theta"
    content_b = "theta eta zeta epsilon delta gamma beta alpha"

    sim = Arbor.Memory.SelfKnowledge.text_similarity(content_a, content_b)
    assert sim >= 0.6

    {:ok, first} =
      Proposal.create_tainted(agent_id, :thought, %{content: content_a}, trusted_taint("a"))

    {:ok, second} =
      Proposal.create_tainted(agent_id, :thought, %{content: content_b}, hostile_taint("b"))

    assert first.id == second.id

    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, first.id)
    assert status == :verified
    assert taint.level == :hostile
    assert taint.sensitivity == :restricted
  end

  test "concurrent public creates converge on one id with joined hostile taint and worst legacy status",
       %{agent_id: agent_id} do
    content = "race content #{agent_id} #{System.unique_integer([:positive])}"

    tasks = [
      Task.async(fn -> Proposal.create(agent_id, :fact, %{content: content}) end),
      Task.async(fn ->
        Proposal.create_tainted(agent_id, :fact, %{content: content}, trusted_taint("race_t"))
      end),
      Task.async(fn ->
        Proposal.create_tainted(agent_id, :fact, %{content: content}, hostile_taint("race_h"))
      end)
    ]

    results = Task.await_many(tasks, 10_000)

    ids =
      results
      |> Enum.map(fn
        {:ok, %{id: id}} -> id
        {:ok, :reinforced} -> :reinforced
        other -> flunk("unexpected create result: #{inspect(other)}")
      end)
      |> Enum.reject(&(&1 == :reinforced))

    assert length(ids) >= 1
    unique_ids = Enum.uniq(ids)
    assert length(unique_ids) == 1
    [id] = unique_ids

    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, id)
    assert taint.level == :hostile
    assert taint.sensitivity == :restricted
    assert status == :legacy_unlabeled

    {:ok, pending} = Proposal.list_pending(agent_id, type: :fact)
    matching = Enum.filter(pending, &(&1.content == content))
    assert length(matching) == 1
    assert hd(matching).id == id
  end

  test "expired timed mutation is rejected without state change", %{agent_id: agent_id} do
    {:ok, p} =
      Proposal.create(agent_id, :fact, %{
        content: "deadline #{System.unique_integer([:positive])}"
      })

    before = :sys.get_state(Store)
    before_record = get_in(before, [:by_agent, agent_id, p.id])

    past = System.monotonic_time(:millisecond) - 1_000

    assert {:error, :request_expired} =
             GenServer.call(
               Store,
               {:timed, past, {:delete, agent_id, p.id}}
             )

    after_state = :sys.get_state(Store)
    assert get_in(after_state, [:by_agent, agent_id, p.id]) == before_record
    assert after_state.totals == before.totals
  end

  test "raw create uses legacy_unlabeled and missing fallback", %{agent_id: agent_id} do
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "raw create"})
    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, p.id)
    assert status == :legacy_unlabeled
    assert taint == TaintEnvelope.missing_fallback()
  end

  test "reject/defer/undefer join decision taint and preserve worst status", %{agent_id: agent_id} do
    {:ok, p} =
      Proposal.create_tainted(agent_id, :fact, %{content: "review join"}, trusted_taint("base"))

    assert :ok =
             Proposal.reject_tainted(agent_id, p.id, [reason: "nope"], hostile_taint("reject"))

    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, p.id)
    assert status == :verified
    assert taint.level == :hostile

    {:ok, p2} =
      Proposal.create_tainted(agent_id, :insight, %{content: "defer me"}, trusted_taint("d"))

    assert :ok = Proposal.defer_tainted(agent_id, p2.id, hostile_taint("defer"))
    {:ok, %TaintedValue{taint: t2}, _} = Proposal.get_tainted(agent_id, p2.id)
    assert t2.level == :hostile

    assert :ok = Proposal.undefer_tainted(agent_id, p2.id, trusted_taint("undefer"))
    {:ok, %TaintedValue{taint: t3}, _} = Proposal.get_tainted(agent_id, p2.id)
    assert t3.level == :hostile
  end

  test "raw review never synthesizes trusted decision labels", %{agent_id: agent_id} do
    {:ok, p} =
      Proposal.create_tainted(agent_id, :fact, %{content: "raw review"}, trusted_taint("t"))

    assert :ok = Proposal.reject(agent_id, p.id, reason: "x")
    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, p.id)
    # raw reject joins missing_fallback with :legacy_unlabeled decision status
    assert status == :legacy_unlabeled
    refute taint.level == :trusted and taint.sensitivity == :public
    refute taint == trusted_taint("t")
  end

  test "malformed sidecar fails closed on get and accept", %{agent_id: agent_id} do
    ensure_graph(agent_id)
    {:ok, p} = Proposal.create(agent_id, :fact, %{content: "will corrupt"})

    :sys.replace_state(Store, fn state ->
      update_in(state, [:by_agent, agent_id, p.id], fn record ->
        bad =
          Map.update!(record.envelope, "payload_sha256", fn _ ->
            String.duplicate("0", 64)
          end)

        %{record | envelope: bad}
      end)
    end)

    assert {:error, :invalid_provenance} = Proposal.get_tainted(agent_id, p.id)
    assert {:error, :invalid_provenance} = Proposal.get(agent_id, p.id)
    assert {:error, :invalid_provenance} = Proposal.accept(agent_id, p.id)
    assert {:error, :invalid_provenance} = Proposal.reject(agent_id, p.id)
  end

  test "accept joins decision taint; complete uses reserved joined taint", %{
    agent_id: agent_id
  } do
    ensure_graph(agent_id)

    {:ok, p} =
      Proposal.create_tainted(agent_id, :fact, %{content: "accept join"}, trusted_taint("c"))

    assert {:ok, _target} =
             Proposal.accept_tainted(agent_id, p.id, hostile_taint("decision"))

    {:ok, %TaintedValue{taint: taint}, status} = Proposal.get_tainted(agent_id, p.id)
    assert status == :verified
    assert taint.level == :hostile
  end

  test "in-flight fence blocks reject/defer/dedup and complete rejects sidecar drift", %{
    agent_id: agent_id
  } do
    ensure_graph(agent_id)

    content = "fence race proposal content unique"

    {:ok, p} =
      Proposal.create_tainted(agent_id, :fact, %{content: content}, trusted_taint("base"))

    decision = trusted_taint("decision")

    assert {:ok, {:ready, _proposal, _joined, _status, fence}} =
             GenServer.call(
               Store,
               {:prepare_accept, agent_id, p.id, decision, :verified}
             )

    assert fence.phase == :in_flight
    assert is_binary(fence.payload_sha256)
    assert is_binary(fence.envelope_fingerprint)

    assert {:error, :transfer_in_flight} = Proposal.reject(agent_id, p.id)
    assert {:error, :transfer_in_flight} = Proposal.defer(agent_id, p.id)

    assert {:error, :transfer_in_flight} =
             Proposal.create_tainted(agent_id, :fact, %{content: content}, hostile_taint("dedup"))

    # Alter sidecar after prepare — complete must fail closed
    :sys.replace_state(Store, fn state ->
      update_in(state, [:by_agent, agent_id, p.id], fn record ->
        payload = Core.canonicalize_payload(record.proposal)
        {:ok, env} = TaintEnvelope.new(payload, hostile_taint("race"))
        {:ok, env_map} = TaintEnvelope.to_map(env)
        %{record | envelope: env_map, status: :verified}
      end)
    end)

    assert {:error, :invalid_provenance} =
             GenServer.call(
               Store,
               {:complete_accept, agent_id, p.id, "node_should_not_matter", fence.operation_id}
             )

    # Public get fails closed on the corrupted sidecar; inspect owner state for label.
    state = :sys.get_state(Store)
    record = get_in(state, [:by_agent, agent_id, p.id])
    assert record.proposal.status == :pending
    assert match?(%{phase: :in_flight}, record.fence)
    refute match?(%{phase: :done}, record.fence)
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

  defp hostile_taint(source) do
    %Taint{
      level: :hostile,
      sensitivity: :restricted,
      sanitizations: 0,
      confidence: :unverified,
      source: source,
      chain: []
    }
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

  defp ensure_graph(agent_id) do
    alias Arbor.Memory.{GraphOps, KnowledgeGraph}
    graph = KnowledgeGraph.new(agent_id, auto_embed: false)
    _ = GraphOps.save_graph(agent_id, graph)
  end
end
