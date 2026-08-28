defmodule Arbor.Orchestrator.CrossAppContinuation.JournalTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Orchestrator.Config
  alias Arbor.Orchestrator.CrossAppContinuation.FakeStore
  alias Arbor.Orchestrator.CrossAppContinuation.Journal
  alias Arbor.Persistence.QueryableStore

  @moduletag :fast

  @inv1 String.duplicate("a", 64)
  @inv2 String.duplicate("b", 64)
  @hex String.duplicate("c", 64)
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)
  @now ~U[2026-08-27 12:00:00.000000Z]

  setup do
    store = unique(:store)
    journal = unique(:journal)
    {:ok, _} = FakeStore.start_link(name: store)

    {:ok, clock} = Agent.start_link(fn -> @now end)

    {:ok, _pid} =
      Journal.start_link(
        name: journal,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end,
        token_fun: fn -> "tok_" <> String.duplicate("a", 60) end,
        claim_ttl_ms: 3_600_000
      )

    assert %{"ready" => true} = await_ready(server: journal)

    {:ok, store: store, journal: journal, clock: clock, opts: [server: journal]}
  end

  test "application child is disabled in test and facade reports that status" do
    status = Journal.durability_status()
    assert status["ready"] == false
    assert status["reason"] == "disabled"
    assert status["backend"] == nil
    {:ok, fetched} = Arbor.Orchestrator.Config.fetch_cross_app_continuation()
    assert Keyword.get(fetched, :backend) == nil
  end

  test "open claim get redacts token and operation replay recovers it after restart", %{
    store: store,
    opts: opts,
    clock: clock
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    assert opened["successor"] == nil
    assert opened["terminal"] == nil

    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    assert is_binary(token)

    refute Map.has_key?(
             Journal.get(id, opts) |> elem(1) |> Map.get("snapshot") |> Map.get("claim"),
             "fence_token"
           )

    {:ok, got} = Journal.get(id, opts)
    refute Map.has_key?(got["snapshot"]["claim"], "fence_token")

    {:ok, replay} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    assert replay["snapshot"]["claim"]["fence_token"] == token

    assert {:error, :conflict} =
             Journal.claim(id, %{"operation_id" => "op-other"}, opts)

    journal2 = unique(:journal)

    {:ok, _} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end,
        token_fun: fn -> "tok_" <> String.duplicate("b", 60) end
      )

    assert %{"ready" => true} = await_ready(server: journal2)
    opts2 = [server: journal2]
    {:ok, recovered} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts2)
    assert recovered["snapshot"]["claim"]["fence_token"] == token
    {:ok, redacted} = Journal.get(id, opts2)
    refute Map.has_key?(redacted["snapshot"]["claim"], "fence_token")

    {:ok, fenced} =
      Journal.accept_passed_receipt(
        id,
        %{
          "operation_id" => "op-receipt",
          "fence_token" => token,
          "fence_generation" => generation,
          "receipt" => passed(hd(plan()))
        },
        opts2
      )

    assert fenced["snapshot"]["accepted_receipts"] |> length() == 1
    assert fenced["successor"] == nil
    refute Map.has_key?(fenced["snapshot"]["claim"], "fence_token")
  end

  test "principal-bound get and mutation admit and bind the same backend record", %{
    store: store,
    opts: opts
  } do
    {:ok, opened} = Journal.open(open_input("op-principal-open"), opts)
    id = opened["continuation_id"]
    principal_id = opened["snapshot"]["identities"]["principal_id"]
    durable_open = FakeStore.peek(store, id)

    get_count = FakeStore.get_call_count(store)
    assert {:ok, got} = Journal.get_for_principal(id, principal_id, opts)
    assert FakeStore.get_call_count(store) == get_count + 1
    assert got["snapshot"]["status"] == "open"

    get_count = FakeStore.get_call_count(store)

    assert {:error, :subject_principal_mismatch} =
             Journal.get_for_principal(id, "agent_attacker", opts)

    assert FakeStore.get_call_count(store) == get_count + 1
    assert FakeStore.peek(store, id) == durable_open

    get_count = FakeStore.get_call_count(store)

    assert {:ok, claimed} =
             Journal.mutate_for_principal(
               "claim",
               id,
               %{"operation_id" => "op-principal-claim"},
               principal_id,
               opts
             )

    assert FakeStore.get_call_count(store) == get_count + 1
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    assert is_binary(token)
    durable_claimed = FakeStore.peek(store, id)

    assert {:error, :subject_principal_mismatch} =
             Journal.mutate_for_principal(
               "claim",
               id,
               %{"operation_id" => "op-principal-claim"},
               "agent_attacker",
               opts
             )

    assert FakeStore.peek(store, id) == durable_claimed

    assert {:error, :subject_principal_mismatch} =
             Journal.mutate_for_principal(
               "claim",
               id,
               %{"operation_id" => "op-attacker-claim"},
               "agent_attacker",
               opts
             )

    assert FakeStore.peek(store, id) == durable_claimed

    assert {:ok, receipt} =
             Journal.mutate_for_principal(
               "accept_passed_receipt",
               id,
               %{
                 "operation_id" => "op-principal-receipt",
                 "fence_token" => token,
                 "fence_generation" => generation,
                 "receipt" => passed(hd(plan()))
               },
               principal_id,
               opts
             )

    refute Map.has_key?(receipt["snapshot"]["claim"], "fence_token")
  end

  test "principal-bound access fully admits malformed persisted data before comparison", %{
    store: store,
    journal: journal,
    opts: opts
  } do
    {:ok, opened} = Journal.open(open_input("op-principal-malformed"), opts)
    id = opened["continuation_id"]
    current = FakeStore.peek(store, id)
    malformed = Record.update(current, Map.put(current.data, "unexpected", true))

    FakeStore.put_record(store, %{
      malformed
      | generation: current.generation,
        revision: current.revision
    })

    assert {:error, :malformed_record} =
             Journal.get_for_principal(id, "agent_attacker", opts)

    assert %{"ready" => false, "reason" => "poisoned"} =
             Journal.durability_status(server: journal)
  end

  test "claim then receipt then restart recovers token only for exact claim replay", %{
    store: store,
    opts: opts,
    clock: clock
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]

    {:ok, receipt} =
      Journal.accept_passed_receipt(
        id,
        %{
          "operation_id" => "op-receipt",
          "fence_token" => token,
          "fence_generation" => generation,
          "receipt" => passed(hd(plan()))
        },
        opts
      )

    refute Map.has_key?(receipt["snapshot"]["claim"], "fence_token")
    stored = FakeStore.peek(store, id)
    assert stored.data["commit"]["transition"] == "accept_passed_receipt"
    assert stored.data["claim_binding"]["operation_id"] == "op-claim"
    refute Map.has_key?(stored.data["commit"], "payload")
    assert stored.data["commit"]["payload_sha256"] =~ ~r/\A[0-9a-f]{64}\z/

    journal2 = unique(:journal)

    {:ok, _} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end,
        token_fun: fn -> "tok_" <> String.duplicate("d", 60) end
      )

    assert %{"ready" => true} = await_ready(server: journal2)
    opts2 = [server: journal2]
    {:ok, recovered} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts2)
    assert recovered["snapshot"]["claim"]["fence_token"] == token

    assert {:error, :conflict} =
             Journal.claim(
               id,
               %{
                 "operation_id" => "op-claim",
                 "owner_id" => recovered["snapshot"]["identities"]["principal_id"]
               },
               opts2
             )

    {:ok, got} = Journal.get(id, opts2)
    refute Map.has_key?(got["snapshot"]["claim"], "fence_token")

    {:ok, receipt_replay} =
      Journal.accept_passed_receipt(
        id,
        %{
          "operation_id" => "op-receipt",
          "fence_token" => token,
          "fence_generation" => generation,
          "receipt" => passed(hd(plan()))
        },
        opts2
      )

    refute Map.has_key?(receipt_replay["snapshot"]["claim"], "fence_token")

    assert {:error, :wrong_fence} =
             Journal.accept_passed_receipt(
               id,
               %{
                 "operation_id" => "op-receipt",
                 "fence_token" => "wrong_" <> token,
                 "fence_generation" => generation,
                 "receipt" => passed(hd(plan()))
               },
               opts2
             )

    {:ok, still_redacted} = Journal.get(id, opts2)
    refute Map.has_key?(still_redacted["snapshot"]["claim"], "fence_token")

    assert {:error, :conflict} =
             Journal.claim(id, %{"operation_id" => "op-other"}, opts2)
  end

  test "concurrent claim CAS loser does not observe the winner token", %{
    store: store,
    opts: opts,
    clock: clock
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    journal_b = unique(:journal)

    {:ok, _} =
      Journal.start_link(
        name: journal_b,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end,
        token_fun: fn -> "tok_" <> String.duplicate("c", 60) end
      )

    assert %{"ready" => true} = await_ready(server: journal_b)

    task_a =
      Task.async(fn -> Journal.claim(id, %{"operation_id" => "op-a"}, opts) end)

    task_b =
      Task.async(fn ->
        Journal.claim(id, %{"operation_id" => "op-b"}, server: journal_b)
      end)

    results = [Task.await(task_a), Task.await(task_b)]
    oks = for {:ok, envelope} <- results, do: envelope
    errors = for {:error, reason} <- results, do: reason
    assert length(oks) == 1
    assert :conflict in errors
    winner = hd(oks)
    assert is_binary(winner["snapshot"]["claim"]["fence_token"])
    {:ok, got} = Journal.get(id, opts)
    refute Map.has_key?(got["snapshot"]["claim"], "fence_token")
    assert got["snapshot"]["status"] == "claimed"
  end

  test "stale fence after expire+reclaim and stale Record CAS conflict", %{
    opts: opts,
    clock: clock,
    store: store
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]

    Agent.update(clock, fn _ -> DateTime.add(@now, 3_600_000, :millisecond) end)

    assert {:error, :stale_fence} =
             Journal.accept_passed_receipt(
               id,
               %{
                 "operation_id" => "op-late",
                 "fence_token" => token,
                 "fence_generation" => generation,
                 "receipt" => passed(hd(plan()))
               },
               opts
             )

    {:ok, expired} =
      Journal.expire_claim(
        id,
        %{
          "operation_id" => "op-expire",
          "fence_token" => token,
          "fence_generation" => generation
        },
        opts
      )

    assert expired["snapshot"]["claim"] == nil

    {:ok, reclaimed} = Journal.claim(id, %{"operation_id" => "op-reclaim"}, opts)
    assert reclaimed["snapshot"]["claim"]["fence_generation"] == 2

    assert {:error, :stale_fence} =
             Journal.revoke_claim(
               id,
               %{
                 "operation_id" => "op-stale",
                 "fence_token" => token,
                 "fence_generation" => generation
               },
               opts
             )

    current = FakeStore.peek(store, id)
    stale = %{current | revision: current.revision - 1}
    replacement = Record.update(current, current.data)

    assert {:error, :conflict} =
             Arbor.Persistence.compare_and_swap(
               store,
               FakeStore,
               id,
               {:value, stale},
               replacement,
               name: store
             )
  end

  test "restart hydration poisons on malformed records and installs nothing", %{
    store: store,
    opts: opts,
    clock: clock
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    current = FakeStore.peek(store, id)
    bad = Record.update(current, Map.put(current.data, "extra", "nope"))

    FakeStore.put_record(store, %{
      bad
      | generation: current.generation,
        revision: current.revision
    })

    journal2 = unique(:journal)

    {:ok, pid} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end
      )

    status = await_status(server: journal2, ready: false, reason: "poisoned")
    assert status["inventory_count"] == 0
    assert Process.alive?(pid)
    assert {:error, :not_ready} = Journal.get(id, server: journal2)
  end

  test "restart hydration recomputes and verifies receipt idempotency", %{
    store: store,
    opts: opts,
    clock: clock
  } do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    current = FakeStore.peek(store, id)

    tampered_data =
      put_in(current.data, ["commit", "idempotency_key"], String.duplicate("0", 64))

    FakeStore.put_record(store, %{
      Record.update(current, tampered_data)
      | generation: current.generation,
        revision: current.revision
    })

    journal2 = unique(:journal)

    {:ok, _pid} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        clock: fn -> Agent.get(clock, & &1) end
      )

    status = await_status(server: journal2, ready: false, reason: "poisoned")
    assert status["inventory_count"] == 0
    assert status["poison_detail"] == "malformed_record"
  end

  test "backend CAS failure leaves durable state unchanged", %{store: store, opts: opts} do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    before = FakeStore.peek(store, id)
    FakeStore.fail_next(store, :compare_and_swap, :injected_failure)

    assert {:error, :unavailable} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    after_fail = FakeStore.peek(store, id)
    assert after_fail.revision == before.revision
    assert after_fail.data["snapshot"]["status"] == "open"
  end

  test "process_lifetime backends are rejected and honest node_restart CAS is admitted" do
    agent = unique(:agent)
    {:ok, _} = QueryableStore.Agent.start_link(name: agent)
    journal = unique(:journal)

    {:ok, _} =
      Journal.start_link(
        name: journal,
        backend: QueryableStore.Agent,
        store_name: agent,
        backend_opts: []
      )

    status = Journal.durability_status(server: journal)
    assert status["ready"] == false
    assert status["reason"] == "insufficient_durability"

    durable_store = unique(:durable_store)
    durable_journal = unique(:durable_journal)
    {:ok, _} = FakeStore.start_link(name: durable_store)
    FakeStore.set_durability_class(durable_store, :node_restart)

    {:ok, _} =
      Journal.start_link(
        name: durable_journal,
        backend: FakeStore,
        store_name: durable_store,
        backend_opts: []
      )

    durable_status = await_ready(server: durable_journal)
    assert durable_status["durability_class"] == "node_restart"
    assert durable_status["fenced_cas"] == true
  end

  test "returned Record keys are exact-bound and malformed authority poisons", %{
    store: store,
    journal: journal,
    opts: opts
  } do
    FakeStore.mismatch_next_key(store, :compare_and_swap, "xappc_" <> String.duplicate("f", 64))
    assert {:error, :malformed_record} = Journal.open(open_input("op-mismatched-insert"), opts)

    assert %{"ready" => false, "reason" => "poisoned"} =
             Journal.durability_status(server: journal)

    store2 = unique(:key_store)
    journal2 = unique(:key_journal)
    {:ok, _} = FakeStore.start_link(name: store2)

    {:ok, _} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store2,
        backend_opts: []
      )

    opts2 = [server: journal2]
    assert %{"ready" => true} = await_ready(server: journal2)
    {:ok, opened} = Journal.open(open_input("op-key-open"), opts2)
    id = opened["continuation_id"]
    FakeStore.mismatch_next_key(store2, :get, "xappc_" <> String.duplicate("e", 64))
    assert {:error, :malformed_record} = Journal.get(id, opts2)

    assert %{"ready" => false, "reason" => "poisoned"} =
             Journal.durability_status(server: journal2)

    store3 = unique(:cas_key_store)
    journal3 = unique(:cas_key_journal)
    {:ok, _} = FakeStore.start_link(name: store3)

    {:ok, _} =
      Journal.start_link(
        name: journal3,
        backend: FakeStore,
        store_name: store3,
        backend_opts: []
      )

    opts3 = [server: journal3]
    assert %{"ready" => true} = await_ready(server: journal3)
    {:ok, opened3} = Journal.open(open_input("op-cas-key-open"), opts3)
    id3 = opened3["continuation_id"]
    FakeStore.mismatch_next_key(store3, :compare_and_swap, "xappc_" <> String.duplicate("d", 64))

    assert {:error, :malformed_record} =
             Journal.claim(id3, %{"operation_id" => "op-claim"}, opts3)

    assert %{"ready" => false, "reason" => "poisoned"} =
             Journal.durability_status(server: journal3)
  end

  test "runtime numeric overrides may tighten but never widen configured limits" do
    configured = [
      max_items: 100,
      max_data_bytes: 100_000,
      claim_ttl_ms: 100_000,
      hydration_timeout_ms: 1_000
    ]

    tighter = [
      max_items: 99,
      max_data_bytes: 99_999,
      claim_ttl_ms: 99_999,
      hydration_timeout_ms: 999
    ]

    assert {:ok, resolved} = Config.tighten_cross_app_continuation(configured, tighter)
    assert Map.new(Keyword.take(resolved, Keyword.keys(tighter))) == Map.new(tighter)

    for {key, configured_value} <- configured do
      assert {:error, {:widening_override, ^key}} =
               Config.tighten_cross_app_continuation(
                 configured,
                 [{key, configured_value + 1}]
               )

      assert {:error, {:invalid_override, ^key}} =
               Config.tighten_cross_app_continuation(configured, [{key, 0}])
    end
  end

  test "live open enforces max_items while preserving exact replay at capacity" do
    store = unique(:capacity_store)
    journal = unique(:capacity_journal)
    {:ok, _} = FakeStore.start_link(name: store)

    {:ok, _} =
      Journal.start_link(
        name: journal,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        max_items: 1
      )

    opts = [server: journal]
    assert %{"ready" => true} = await_ready(opts)
    list_count_after_hydration = FakeStore.list_call_count(store)
    assert list_count_after_hydration == 1

    first_input = open_input("op-capacity-first")
    {:ok, first} = Journal.open(first_input, opts)
    assert FakeStore.list_call_count(store) == list_count_after_hydration
    assert FakeStore.record_count(store) == 1

    {:ok, replay} = Journal.open(first_input, opts)
    assert replay["continuation_id"] == first["continuation_id"]
    assert replay["durability"]["revision"] == first["durability"]["revision"]
    assert FakeStore.list_call_count(store) == list_count_after_hydration
    assert FakeStore.record_count(store) == 1

    second_input =
      "op-capacity-second"
      |> open_input()
      |> put_in(["identities", "task_id"], "task_cross_app_other")

    assert {:error, :capacity_exceeded} = Journal.open(second_input, opts)
    assert FakeStore.list_call_count(store) == list_count_after_hydration
    assert FakeStore.record_count(store) == 1

    assert %{"ready" => true, "inventory_count" => 1} =
             Journal.durability_status(server: journal)

    journal2 = unique(:capacity_restart_journal)

    {:ok, _} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        max_items: 1
      )

    assert %{"ready" => true, "inventory_count" => 1} = await_ready(server: journal2)
    restart_list_count = FakeStore.list_call_count(store)
    assert restart_list_count == list_count_after_hydration + 1

    {:ok, restart_replay} = Journal.open(first_input, server: journal2)
    assert restart_replay["durability"]["revision"] == first["durability"]["revision"]
    assert FakeStore.list_call_count(store) == restart_list_count
    assert FakeStore.record_count(store) == 1
  end

  test "unknown Journal startup options fail closed" do
    assert {:error, {:invalid_cross_app_continuation, {:unknown_start_opts, [:max_itemz]}}} =
             GenServer.start(Journal, max_itemz: 1)
  end

  test "idempotent open/handoff replay and persist-only claim clears successor", %{
    opts: opts,
    store: store
  } do
    {:ok, first} = Journal.open(open_input("op-open"), opts)
    {:ok, second} = Journal.open(open_input("op-open"), opts)
    assert first["durability"]["revision"] == second["durability"]["revision"]
    id = first["continuation_id"]
    stored = FakeStore.peek(store, id)
    assert stored.id != id
    assert String.starts_with?(stored.id, "rec_")

    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    structural = v3_handoff(plan(), [], nil, plan(), "structural")

    {:ok, handed} =
      Journal.accept_capacity_handoff(
        id,
        %{
          "operation_id" => "op-handoff",
          "fence_token" => token,
          "fence_generation" => generation,
          "handoff" => structural
        },
        opts
      )

    assert handed["successor"]["op"] == "mint_successor"
    assert handed["snapshot"]["claim"] == nil
    assert FakeStore.peek(store, id).data["claim_binding"] == nil

    {:ok, replay} =
      Journal.accept_capacity_handoff(
        id,
        %{
          "operation_id" => "op-handoff",
          "fence_token" => token,
          "fence_generation" => generation,
          "handoff" => structural
        },
        opts
      )

    assert replay["durability"]["revision"] == handed["durability"]["revision"]
    {:ok, reclaimed} = Journal.claim(id, %{"operation_id" => "op-claim-2"}, opts)
    assert reclaimed["successor"] == nil
    assert reclaimed["snapshot"]["status"] == "claimed"
  end

  test "large handoff keeps only a bounded payload digest in the commit receipt", %{
    store: store,
    opts: opts
  } do
    large_plan =
      for index <- 1..256 do
        inventory = :crypto.hash(:sha256, "batch-#{index}") |> Base.encode16(case: :lower)
        batch(index, 256, 1, inventory)
      end

    {:ok, opened} =
      Journal.open(
        Map.put(fresh_attrs(large_plan), "operation_id", "op-large-open"),
        opts
      )

    id = opened["continuation_id"]
    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-large-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    handoff = v3_handoff(large_plan, [], nil, large_plan, "structural")
    assert byte_size(Jason.encode!(handoff)) > 20_000

    {:ok, _handed} =
      Journal.accept_capacity_handoff(
        id,
        %{
          "operation_id" => "op-large-handoff",
          "fence_token" => token,
          "fence_generation" => generation,
          "handoff" => handoff
        },
        opts
      )

    commit = FakeStore.peek(store, id).data["commit"]
    assert byte_size(Jason.encode!(commit)) < 1_000
    assert commit["payload_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    refute Map.has_key?(commit, "payload")
    refute Map.has_key?(commit, "handoff")
    refute Map.has_key?(commit, "fence_token")
  end

  test "expiry and revocation with injected clock", %{opts: opts, clock: clock} do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    at_expiry = DateTime.add(@now, 3_600_000, :millisecond)
    Agent.update(clock, fn _ -> at_expiry end)

    assert {:error, :stale_fence} =
             Journal.fail(
               id,
               %{
                 "operation_id" => "op-fail",
                 "fence_token" => token,
                 "fence_generation" => generation
               },
               opts
             )

    {:ok, revoked} =
      Journal.revoke_claim(
        id,
        %{
          "operation_id" => "op-revoke",
          "fence_token" => token,
          "fence_generation" => generation
        },
        opts
      )

    assert revoked["snapshot"]["status"] == "open"

    assert {:error, :malformed_state} =
             Journal.claim(
               id,
               %{"operation_id" => "op-bad", "now" => "2026-08-27T12:00:00Z"},
               opts
             )
  end

  test "terminal conflict versus same-operation reconstruct", %{opts: opts} do
    {:ok, opened} = Journal.open(open_input("op-open"), opts)
    id = opened["continuation_id"]
    {:ok, claimed} = Journal.claim(id, %{"operation_id" => "op-claim"}, opts)
    token = claimed["snapshot"]["claim"]["fence_token"]
    generation = claimed["snapshot"]["claim"]["fence_generation"]
    [first, second] = plan()

    {:ok, _after_first} =
      Journal.accept_passed_receipt(
        id,
        %{
          "operation_id" => "op-r1",
          "fence_token" => token,
          "fence_generation" => generation,
          "receipt" => passed(first)
        },
        opts
      )

    {:ok, _full} =
      Journal.accept_passed_receipt(
        id,
        %{
          "operation_id" => "op-r2",
          "fence_token" => token,
          "fence_generation" => generation,
          "receipt" => passed(second)
        },
        opts
      )

    {:ok, completed} =
      Journal.complete(
        id,
        %{
          "operation_id" => "op-complete",
          "fence_token" => token,
          "fence_generation" => generation
        },
        opts
      )

    assert completed["terminal"]["status"] == "completed"

    {:ok, replay} =
      Journal.complete(
        id,
        %{
          "operation_id" => "op-complete",
          "fence_token" => token,
          "fence_generation" => generation
        },
        opts
      )

    assert replay["durability"]["revision"] == completed["durability"]["revision"]

    assert {:error, :terminal_conflict} =
             Journal.fail(
               id,
               %{
                 "operation_id" => "op-fail",
                 "fence_token" => token,
                 "fence_generation" => generation
               },
               opts
             )
  end

  test "inventory overflow poisons and worker timeout does not kill journal", %{clock: clock} do
    store = unique(:store)
    {:ok, _} = FakeStore.start_link(name: store)

    Enum.each(1..3, fn i ->
      FakeStore.put_record(store, Record.new("xappc_" <> String.duplicate("#{i}", 64), %{}))
    end)

    journal = unique(:journal)

    {:ok, pid} =
      Journal.start_link(
        name: journal,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        max_items: 1,
        clock: fn -> Agent.get(clock, & &1) end
      )

    status = await_status(server: journal, ready: false, reason: "poisoned")
    assert status["poison_detail"] == "inventory_too_large"
    assert Process.alive?(pid)

    store2 = unique(:store)
    {:ok, _} = FakeStore.start_link(name: store2)
    FakeStore.set_list_delay(store2, 5_000)
    journal2 = unique(:journal)

    {:ok, pid2} =
      Journal.start_link(
        name: journal2,
        backend: FakeStore,
        store_name: store2,
        backend_opts: [],
        hydration_timeout_ms: 20,
        clock: fn -> Agent.get(clock, & &1) end
      )

    status2 = await_status(server: journal2, ready: false, reason: "poisoned")
    assert status2["poison_detail"] == "hydration_timeout"
    assert Process.alive?(pid2)

    store3 = unique(:store)
    {:ok, _} = FakeStore.start_link(name: store3)
    FakeStore.set_list_delay(store3, 5_000)
    journal3 = unique(:journal)

    {:ok, pid3} =
      Journal.start_link(
        name: journal3,
        backend: FakeStore,
        store_name: store3,
        backend_opts: [],
        hydration_timeout_ms: 5_000,
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert %{"reason" => "hydrating"} =
             await_status(server: journal3, ready: false, reason: "hydrating")

    state = :sys.get_state(pid3)
    Process.exit(state.worker.pid, :kill)
    status3 = await_status(server: journal3, ready: false, reason: "poisoned")
    assert status3["poison_detail"] == "hydration_worker_down"
    assert Process.alive?(pid3)
  end

  test "stale hydration timeout after success does not crash journal", %{clock: clock} do
    store = unique(:store)
    {:ok, _} = FakeStore.start_link(name: store)
    journal = unique(:journal)

    {:ok, pid} =
      Journal.start_link(
        name: journal,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        hydration_timeout_ms: 20,
        clock: fn -> Agent.get(clock, & &1) end
      )

    assert %{"ready" => true} = await_ready(server: journal)
    Process.sleep(40)
    assert %{"ready" => true} = Journal.durability_status(server: journal)
    assert Process.alive?(pid)
  end

  test "orchestrator lib does not import ContinuationCore" do
    root = Path.expand("../../../lib", __DIR__)

    files =
      root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()

    hits =
      files
      |> Enum.filter(fn path ->
        File.read!(path) =~ "Arbor.Actions.Coding.CrossApp.ContinuationCore"
      end)

    assert files != []
    assert hits == []
  end

  defp await_ready(opts) do
    await_status(Keyword.put(opts, :ready, true))
  end

  defp await_status(opts) do
    server = Keyword.fetch!(opts, :server)
    ready = Keyword.get(opts, :ready, true)
    reason = Keyword.get(opts, :reason)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      status = Journal.durability_status(server: server)

      cond do
        status["ready"] == ready and (is_nil(reason) or status["reason"] == reason) ->
          {:halt, status}

        true ->
          Process.sleep(10)
          {:cont, status}
      end
    end)
  end

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp open_input(operation_id) do
    Map.put(fresh_attrs(), "operation_id", operation_id)
  end

  defp plan, do: [batch(1, 2, 1, @inv1), batch(2, 2, 1, @inv2)]

  defp batch(index, total, count, inventory) do
    %{
      "index" => index,
      "total" => total,
      "count" => count,
      "label" => "batch-#{index}-of-#{total}-n#{count}-#{inventory}",
      "inventory_sha256" => inventory
    }
  end

  defp passed(batch), do: Map.put(batch, "outcome", "passed")

  defp identities(plan) do
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_continuation_slice2",
      "work_packet_digest" => "sha256:" <> @hex,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_tree_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @candidate_tree_oid,
      "validation_plan_digest" => digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }
  end

  defp fresh_attrs(plan \\ plan()) do
    %{
      "identities" => identities(plan),
      "planned_batches" => plan,
      "per_batch_budget_ms" => 1_000,
      "static_stage_receipt_digest" => String.duplicate("d", 64)
    }
  end

  defp v3_handoff(planned, completed, interrupted, unstarted, phase) do
    digest_subject = if interrupted, do: [interrupted | unstarted], else: unstarted
    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(digest_subject)
    completed_files = Enum.reduce(completed, 0, fn batch, acc -> acc + batch["count"] end)
    interrupted_files = if is_map(interrupted), do: interrupted["count"], else: 0
    unstarted_files = Enum.reduce(unstarted, 0, fn batch, acc -> acc + batch["count"] end)

    {:ok, descriptor} =
      ValidationCapacityHandoff.new(%{
        "schema_version" => ValidationCapacityHandoff.schema_version(),
        "phase" => phase,
        "available_budget_ms" => 0,
        "per_batch_budget_ms" => 1_000,
        "completed_batch_count" => length(completed),
        "completed_file_count" => completed_files,
        "unstarted_batch_count" => length(unstarted),
        "unstarted_file_count" => unstarted_files,
        "total_batch_count" => length(planned),
        "total_file_count" => completed_files + interrupted_files + unstarted_files,
        "ordered_plan_sha256" => digest,
        "interrupted_batch" => interrupted,
        "unstarted_batches" => unstarted
      })

    ValidationCapacityHandoff.to_map(descriptor)
  end
end
