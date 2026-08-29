defmodule Arbor.Orchestrator.CrossAppContinuationAuthorizationSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :security_regression

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.CrossAppContinuation.Authorization
  alias Arbor.Orchestrator.CrossAppContinuation.FakeStore
  alias Arbor.Orchestrator.CrossAppContinuation.Journal
  alias Arbor.Security

  defmodule PendingConsensus do
    @moduledoc false
    def submit(_proposal, _opts \\ []), do: {:ok, "proposal_cross_app_pending"}
  end

  test "security regression: public continuation facade has no unauthenticated route" do
    legacy_arities = [
      coding_cross_app_continuation_open: [1, 2],
      coding_cross_app_continuation_get: [1, 2],
      coding_cross_app_continuation_claim: [2, 3],
      coding_cross_app_continuation_accept_passed_receipt: [2, 3],
      coding_cross_app_continuation_accept_capacity_handoff: [2, 3],
      coding_cross_app_continuation_fail: [2, 3],
      coding_cross_app_continuation_cancel: [2, 3],
      coding_cross_app_continuation_expire_claim: [2, 3],
      coding_cross_app_continuation_revoke_claim: [2, 3],
      coding_cross_app_continuation_complete: [2, 3],
      coding_cross_app_continuation_execute: [3],
      coding_cross_app_continuation_durability_status: [0, 1],
      coding_cross_app_continuation_refresh: [0, 1]
    ]

    for {operation, arities} <- legacy_arities, arity <- arities do
      refute function_exported?(Orchestrator, operation, arity),
             "legacy #{operation}/#{arity} must not reach Journal"
    end
  end

  test "security regression: every public operation authorizes before Journal access" do
    {journal, store} = start_journal()
    legitimate = identity_and_authority("continuation-operation-table")
    input = open_input(legitimate.identity.agent_id, "open-table")
    {:ok, open_resource} = Authorization.open_resource(input)

    get_count = FakeStore.get_call_count(store)
    list_count = FakeStore.list_call_count(store)

    assert {:error, _reason} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert FakeStore.record_count(store) == 0
    assert FakeStore.get_call_count(store) == get_count
    assert FakeStore.list_call_count(store) == list_count

    grant!(legitimate.identity.agent_id, open_resource)

    assert {:ok, opened} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    continuation_id = opened["continuation_id"]
    durable_before = FakeStore.peek(store, continuation_id)
    get_count = FakeStore.get_call_count(store)
    list_count = FakeStore.list_call_count(store)

    operation_rows =
      [
        {"get", nil,
         fn ->
           Orchestrator.coding_cross_app_continuation_get(
             continuation_id,
             legitimate.identity.agent_id,
             legitimate.authority,
             server: journal
           )
         end}
      ] ++
        Enum.map(mutation_inputs(), fn {operation, mutation_input} ->
          {operation, mutation_input["operation_id"],
           fn ->
             invoke_public_mutation(
               operation,
               continuation_id,
               mutation_input,
               legitimate,
               journal
             )
           end}
        end) ++
        [
          {"durability_status", nil,
           fn ->
             Orchestrator.coding_cross_app_continuation_durability_status(
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )
           end},
          {"refresh", nil,
           fn ->
             Orchestrator.coding_cross_app_continuation_refresh(
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )
           end}
        ]

    for {operation, _operation_id, invoke} <- operation_rows do
      assert {:error, _reason} = invoke.(), "#{operation} must fail without its capability"
      assert FakeStore.peek(store, continuation_id) == durable_before
      assert FakeStore.get_call_count(store) == get_count
      assert FakeStore.list_call_count(store) == list_count
    end
  end

  test "security regression: every record-bound operation rejects a capable wrong subject" do
    {journal, store} = start_journal()
    legitimate = identity_and_authority("continuation-table-owner")
    attacker = identity_and_authority("continuation-table-attacker")
    input = open_input(legitimate.identity.agent_id, "open-wrong-subject-table")
    {:ok, open_resource} = Authorization.open_resource(input)
    grant!(legitimate.identity.agent_id, open_resource)

    assert {:ok, opened} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    continuation_id = opened["continuation_id"]

    rows =
      [
        {"get", nil,
         fn ->
           Orchestrator.coding_cross_app_continuation_get(
             continuation_id,
             attacker.identity.agent_id,
             attacker.authority,
             server: journal
           )
         end}
      ] ++
        Enum.map(mutation_inputs(), fn {operation, mutation_input} ->
          {operation, mutation_input["operation_id"],
           fn ->
             invoke_public_mutation(operation, continuation_id, mutation_input, attacker, journal)
           end}
        end)

    for {operation, operation_id, invoke} <- rows do
      {:ok, resource} = Authorization.resource(continuation_id, operation, operation_id)
      grant!(attacker.identity.agent_id, resource)
      durable_before = FakeStore.peek(store, continuation_id)

      assert {:error, :subject_principal_mismatch} = invoke.()
      assert FakeStore.peek(store, continuation_id) == durable_before
    end
  end

  test "security regression: malformed authority and wrong subject cannot access durable state" do
    {journal, store} = start_journal()
    legitimate = identity_and_authority("continuation-legitimate")
    attacker = identity_and_authority("continuation-attacker")
    input = open_input(legitimate.identity.agent_id, "open-1")
    {:ok, open_resource} = Authorization.open_resource(input)
    grant!(legitimate.identity.agent_id, open_resource)

    mismatched_input = open_input(attacker.identity.agent_id, "open-mismatch")
    {:ok, mismatched_resource} = Authorization.open_resource(mismatched_input)
    grant!(legitimate.identity.agent_id, mismatched_resource)

    assert {:error, :subject_principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_open(
               mismatched_input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert {:error, _reason} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               nil,
               server: journal
             )

    assert {:error, :principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               attacker.authority,
               server: journal
             )

    assert FakeStore.record_count(store) == 0

    assert {:ok, opened} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    continuation_id = opened["continuation_id"]
    {:ok, get_resource} = Authorization.resource(continuation_id, "get")
    {:ok, claim_resource} = Authorization.resource(continuation_id, "claim", "claim-1")

    assert {:error, _reason} =
             Orchestrator.coding_cross_app_continuation_get(
               continuation_id,
               attacker.identity.agent_id,
               attacker.authority,
               server: journal
             )

    grant!(attacker.identity.agent_id, get_resource)

    assert {:error, :subject_principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_get(
               continuation_id,
               attacker.identity.agent_id,
               attacker.authority,
               server: journal
             )

    assert {:ok, durable} = Journal.get(continuation_id, server: journal)
    assert durable["snapshot"]["status"] == "open"
    assert durable["snapshot"]["claim"] == nil
    assert durable["durability"]["revision"] == opened["durability"]["revision"]
    assert FakeStore.record_count(store) == 1

    grant!(legitimate.identity.agent_id, get_resource)
    grant!(legitimate.identity.agent_id, claim_resource)
    get_count = FakeStore.get_call_count(store)

    assert {:ok, legitimate_read} =
             Orchestrator.coding_cross_app_continuation_get(
               continuation_id,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert legitimate_read["snapshot"]["status"] == "open"
    assert FakeStore.get_call_count(store) == get_count + 1
    get_count = FakeStore.get_call_count(store)

    assert {:ok, claimed} =
             Orchestrator.coding_cross_app_continuation_claim(
               continuation_id,
               %{"operation_id" => "claim-1"},
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert FakeStore.get_call_count(store) == get_count + 1
    token = claimed["snapshot"]["claim"]["fence_token"]
    assert is_binary(token)

    assert {:ok, replayed} =
             Orchestrator.coding_cross_app_continuation_claim(
               continuation_id,
               %{"operation_id" => "claim-1"},
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert replayed["snapshot"]["claim"]["fence_token"] == token

    fence_generation = claimed["snapshot"]["claim"]["fence_generation"]

    receipt_input = %{
      "operation_id" => "receipt-1",
      "fence_token" => token,
      "fence_generation" => fence_generation,
      "receipt" =>
        claimed["snapshot"]["planned_batches"]
        |> hd()
        |> Map.put("outcome", "passed")
    }

    {:ok, receipt_resource} =
      Authorization.resource(continuation_id, "accept_passed_receipt", "receipt-1")

    grant!(attacker.identity.agent_id, claim_resource)
    grant!(attacker.identity.agent_id, receipt_resource)
    durable_before_attacker_replay = FakeStore.peek(store, continuation_id)

    assert {:error, :subject_principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_get(
               continuation_id,
               attacker.identity.agent_id,
               attacker.authority,
               server: journal
             )

    assert {:error, :subject_principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_claim(
               continuation_id,
               %{"operation_id" => "claim-1"},
               attacker.identity.agent_id,
               attacker.authority,
               server: journal
             )

    assert {:error, :subject_principal_mismatch} =
             Orchestrator.coding_cross_app_continuation_accept_passed_receipt(
               continuation_id,
               receipt_input,
               attacker.identity.agent_id,
               attacker.authority,
               server: journal
             )

    assert FakeStore.peek(store, continuation_id) == durable_before_attacker_replay

    grant!(legitimate.identity.agent_id, receipt_resource)

    assert {:ok, mutated} =
             Orchestrator.coding_cross_app_continuation_accept_passed_receipt(
               continuation_id,
               receipt_input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert mutated["durability"]["revision"] >
             durable_before_attacker_replay.revision
  end

  test "closed and partial authority, closed opts, and pending approval fail before Journal" do
    {journal, store} = start_journal()
    legitimate = identity_and_authority("continuation-bounded-failures")
    input = open_input(legitimate.identity.agent_id, "open-bounded")
    {:ok, resource} = Authorization.open_resource(input)

    partial_authority = %{
      __struct__: Arbor.Contracts.Security.SigningAuthority,
      principal_id: legitimate.identity.agent_id
    }

    for authority <- [nil, %{}, partial_authority] do
      assert {:error, _reason} =
               Orchestrator.coding_cross_app_continuation_open(
                 input,
                 legitimate.identity.agent_id,
                 authority,
                 server: journal
               )
    end

    assert {:error, :invalid_options} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal,
               server: journal
             )

    assert {:error, :invalid_options} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal,
               authorizer: fn _, _ -> :ok end
             )

    grant!(legitimate.identity.agent_id, resource, requires_approval: true)
    previous_escalation = Application.get_env(:arbor_security, :consensus_escalation_enabled)
    previous_consensus = Application.get_env(:arbor_security, :consensus_module)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, true)
    Application.put_env(:arbor_security, :consensus_module, PendingConsensus)

    on_exit(fn ->
      restore_env(:consensus_escalation_enabled, previous_escalation)
      restore_env(:consensus_module, previous_consensus)
    end)

    assert {:error, {:pending_approval, "proposal_cross_app_pending"}} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert FakeStore.record_count(store) == 0

    assert :ok = Security.close_signing_authority(legitimate.authority)

    assert {:error, _reason} =
             Orchestrator.coding_cross_app_continuation_open(
               input,
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert FakeStore.record_count(store) == 0
  end

  test "security regression: direct Journal execute grant without proof does not arm" do
    {journal, _store} = start_journal()
    legitimate = identity_and_authority("continuation-execute-proof")
    input = open_input(legitimate.identity.agent_id, "open-execute")
    {:ok, open_resource} = Authorization.open_resource(input)
    grant!(legitimate.identity.agent_id, open_resource)

    {:ok, opened} =
      Orchestrator.coding_cross_app_continuation_open(
        input,
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    continuation_id = opened["continuation_id"]
    {:ok, claim_resource} = Authorization.resource(continuation_id, "claim", "claim-execute")
    grant!(legitimate.identity.agent_id, claim_resource)

    {:ok, _claimed} =
      Orchestrator.coding_cross_app_continuation_claim(
        continuation_id,
        %{"operation_id" => "claim-execute"},
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    before = Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count()

    assert {:error, reason} =
             Journal.issue_execution_grant(
               continuation_id,
               %{"operation_id" => "execute-1"},
               server: journal
             )

    assert reason in [:execution_grant_proof_required, :malformed_state, :unauthorized]
    assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == before

    assert {:error, _} =
             GenServer.call(journal, {:issue_execution_grant, continuation_id, %{}})

    assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == before
    refute function_exported?(Orchestrator, :coding_cross_app_continuation_execute, 3)
  end

  test "security regression: revoke invalidates a live generation" do
    {journal, _store} = start_journal()
    legitimate = identity_and_authority("continuation-revoke-invalidate")
    input = open_input(legitimate.identity.agent_id, "open-revoke")
    {:ok, open_resource} = Authorization.open_resource(input)
    grant!(legitimate.identity.agent_id, open_resource)

    {:ok, opened} =
      Orchestrator.coding_cross_app_continuation_open(
        input,
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    continuation_id = opened["continuation_id"]
    {:ok, claim_resource} = Authorization.resource(continuation_id, "claim", "claim-revoke")
    grant!(legitimate.identity.agent_id, claim_resource)
    {:ok, revoke_resource} = Authorization.resource(continuation_id, "revoke_claim", "revoke-1")
    grant!(legitimate.identity.agent_id, revoke_resource)

    {:ok, claimed} =
      Orchestrator.coding_cross_app_continuation_claim(
        continuation_id,
        %{"operation_id" => "claim-revoke"},
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    fence = claimed["snapshot"]["claim"]

    {:ok, _revoked} =
      Orchestrator.coding_cross_app_continuation_revoke_claim(
        continuation_id,
        %{
          "operation_id" => "revoke-1",
          "fence_token" => fence["fence_token"],
          "fence_generation" => fence["fence_generation"]
        },
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == 0

    {:ok, execute_resource} =
      Authorization.resource(continuation_id, "execute", "execute-after-revoke")

    grant!(legitimate.identity.agent_id, execute_resource)

    assert {:error, _reason} =
             Orchestrator.coding_cross_app_continuation_execute(
               continuation_id,
               %{
                 "operation_id" => "execute-after-revoke",
                 "params" => %{},
                 "context" => %{},
                 "static_receipt" => %{}
               },
               legitimate.identity.agent_id,
               legitimate.authority,
               server: journal
             )

    assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == 0
  end

  test "security regression: fail and cancel invalidate a live generation" do
    for {operation, fun, op_id} <- [
          {"fail", :coding_cross_app_continuation_fail, "fail-1"},
          {"cancel", :coding_cross_app_continuation_cancel, "cancel-1"}
        ] do
      {journal, _store} = start_journal()
      legitimate = identity_and_authority("continuation-#{operation}-invalidate")
      input = open_input(legitimate.identity.agent_id, "open-#{op_id}")
      {:ok, open_resource} = Authorization.open_resource(input)
      grant!(legitimate.identity.agent_id, open_resource)

      {:ok, opened} =
        Orchestrator.coding_cross_app_continuation_open(
          input,
          legitimate.identity.agent_id,
          legitimate.authority,
          server: journal
        )

      continuation_id = opened["continuation_id"]
      {:ok, claim_resource} = Authorization.resource(continuation_id, "claim", "claim-#{op_id}")
      grant!(legitimate.identity.agent_id, claim_resource)
      {:ok, mutation_resource} = Authorization.resource(continuation_id, operation, op_id)
      grant!(legitimate.identity.agent_id, mutation_resource)

      {:ok, execute_resource} =
        Authorization.resource(continuation_id, "execute", "exec-#{op_id}")

      grant!(legitimate.identity.agent_id, execute_resource)

      {:ok, claimed} =
        Orchestrator.coding_cross_app_continuation_claim(
          continuation_id,
          %{"operation_id" => "claim-#{op_id}"},
          legitimate.identity.agent_id,
          legitimate.authority,
          server: journal
        )

      fence = claimed["snapshot"]["claim"]

      {:ok, _mutated} =
        apply(Orchestrator, fun, [
          continuation_id,
          %{
            "operation_id" => op_id,
            "fence_token" => fence["fence_token"],
            "fence_generation" => fence["fence_generation"]
          },
          legitimate.identity.agent_id,
          legitimate.authority,
          [server: journal]
        ])

      assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == 0

      assert {:error, _reason} =
               Orchestrator.coding_cross_app_continuation_execute(
                 continuation_id,
                 %{
                   "operation_id" => "exec-#{op_id}",
                   "params" => %{},
                   "context" => %{},
                   "static_receipt" => %{}
                 },
                 legitimate.identity.agent_id,
                 legitimate.authority,
                 server: journal
               )

      assert Arbor.Actions.Coding.ContinuationExecutionOwner.grant_count() == 0
    end
  end

  test "security regression: public get redacts fence_token" do
    {journal, _store} = start_journal()
    legitimate = identity_and_authority("continuation-get-redact")
    input = open_input(legitimate.identity.agent_id, "open-redact")
    {:ok, open_resource} = Authorization.open_resource(input)
    grant!(legitimate.identity.agent_id, open_resource)

    {:ok, opened} =
      Orchestrator.coding_cross_app_continuation_open(
        input,
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    continuation_id = opened["continuation_id"]
    {:ok, claim_resource} = Authorization.resource(continuation_id, "claim", "claim-redact")
    grant!(legitimate.identity.agent_id, claim_resource)
    {:ok, get_resource} = Authorization.resource(continuation_id, "get")
    grant!(legitimate.identity.agent_id, get_resource)

    {:ok, claimed} =
      Orchestrator.coding_cross_app_continuation_claim(
        continuation_id,
        %{"operation_id" => "claim-redact"},
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    assert is_binary(claimed["snapshot"]["claim"]["fence_token"])

    {:ok, got} =
      Orchestrator.coding_cross_app_continuation_get(
        continuation_id,
        legitimate.identity.agent_id,
        legitimate.authority,
        server: journal
      )

    refute Map.has_key?(got["snapshot"]["claim"], "fence_token")
  end

  test "resource construction is closed and bounded" do
    continuation_id = "xappc_" <> String.duplicate("a", 64)

    assert {:ok, resource} = Authorization.resource(continuation_id, "claim", "op-1")
    assert byte_size(resource) < 256
    assert String.ends_with?(resource, "/#{continuation_id}/claim/op-1")
    assert {:error, _} = Authorization.resource("xappc_short", "get")
    assert {:error, _} = Authorization.resource(continuation_id, "claim", "../escape")
    assert {:error, :invalid_operation} = Authorization.resource(continuation_id, "unknown", "op")
    assert {:error, :invalid_operation} = Authorization.resource(continuation_id, "get", "op")
  end

  defp start_journal do
    store = unique(:security_store)
    journal = unique(:security_journal)
    {:ok, _store_pid} = FakeStore.start_link(name: store)

    {:ok, _journal_pid} =
      Journal.start_link(
        name: journal,
        backend: FakeStore,
        store_name: store,
        backend_opts: [],
        max_items: 10
      )

    assert %{"ready" => true} = await_ready(server: journal)
    {journal, store}
  end

  defp identity_and_authority(name) do
    {:ok, identity} = Identity.generate(name: name)
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :session,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    %{identity: identity, authority: authority}
  end

  defp grant!(principal, resource, opts \\ []) do
    {:ok, capability} =
      Security.grant(
        principal: principal,
        resource: resource,
        delegation_depth: 0,
        constraints: Map.new(opts),
        metadata: %{test: true}
      )

    on_exit(fn -> Security.revoke(capability.id) end)
  end

  defp open_input(principal_id, operation_id) do
    plan = [
      %{
        "index" => 1,
        "total" => 1,
        "count" => 1,
        "label" => "batch-1-of-1-n1-" <> String.duplicate("a", 64),
        "inventory_sha256" => String.duplicate("a", 64)
      }
    ]

    {:ok, plan_digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "operation_id" => operation_id,
      "identities" => %{
        "task_id" => "task_continuation_security",
        "work_packet_digest" => "sha256:" <> String.duplicate("c", 64),
        "base_commit" => String.duplicate("1", 40),
        "base_tree_oid" => String.duplicate("2", 40),
        "candidate_head" => String.duplicate("1", 40),
        "candidate_tree_oid" => String.duplicate("3", 40),
        "validation_plan_digest" => plan_digest,
        "toolchain_digest" => String.duplicate("3", 64),
        "wrapper_digest" => String.duplicate("5", 64),
        "dependency_baseline_digest" => String.duplicate("4", 64),
        "validator_id" => "coding_cross_app_validate",
        "principal_id" => principal_id,
        "configuration_digest" => String.duplicate("6", 64)
      },
      "planned_batches" => plan,
      "per_batch_budget_ms" => 1_000,
      "static_stage_receipt_digest" => String.duplicate("d", 64)
    }
  end

  defp mutation_inputs do
    fence = %{"fence_token" => "token", "fence_generation" => 1}

    [
      {"claim", %{"operation_id" => "table-claim"}},
      {"accept_passed_receipt",
       Map.merge(fence, %{"operation_id" => "table-receipt", "receipt" => %{}})},
      {"accept_capacity_handoff",
       Map.merge(fence, %{"operation_id" => "table-handoff", "handoff" => %{}})},
      {"fail", Map.merge(fence, %{"operation_id" => "table-fail"})},
      {"cancel", Map.merge(fence, %{"operation_id" => "table-cancel"})},
      {"expire_claim", Map.merge(fence, %{"operation_id" => "table-expire"})},
      {"revoke_claim", Map.merge(fence, %{"operation_id" => "table-revoke"})},
      {"complete", Map.merge(fence, %{"operation_id" => "table-complete"})},
      {"execute",
       %{
         "operation_id" => "table-execute",
         "params" => %{},
         "context" => %{},
         "static_receipt" => %{}
       }}
    ]
  end

  defp invoke_public_mutation(operation, continuation_id, input, principal, journal) do
    args = [
      continuation_id,
      input,
      principal.identity.agent_id,
      principal.authority,
      [server: journal]
    ]

    case operation do
      "claim" ->
        apply(Orchestrator, :coding_cross_app_continuation_claim, args)

      "accept_passed_receipt" ->
        apply(Orchestrator, :coding_cross_app_continuation_accept_passed_receipt, args)

      "accept_capacity_handoff" ->
        apply(Orchestrator, :coding_cross_app_continuation_accept_capacity_handoff, args)

      "fail" ->
        apply(Orchestrator, :coding_cross_app_continuation_fail, args)

      "cancel" ->
        apply(Orchestrator, :coding_cross_app_continuation_cancel, args)

      "expire_claim" ->
        apply(Orchestrator, :coding_cross_app_continuation_expire_claim, args)

      "revoke_claim" ->
        apply(Orchestrator, :coding_cross_app_continuation_revoke_claim, args)

      "complete" ->
        apply(Orchestrator, :coding_cross_app_continuation_complete, args)

      "execute" ->
        apply(Orchestrator, :coding_cross_app_continuation_execute, args)
    end
  end

  defp await_ready(opts, attempts \\ 100)
  defp await_ready(_opts, 0), do: flunk("Journal did not become ready")

  defp await_ready(opts, attempts) do
    case Journal.durability_status(opts) do
      %{"ready" => true} = status ->
        status

      _status ->
        Process.sleep(10)
        await_ready(opts, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"
end
