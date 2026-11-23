defmodule Arbor.Security.AuthorityStoreCallCycleSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Custody
  alias Arbor.Security
  alias Arbor.Security.Capability.Signer
  alias Arbor.Security.CapabilityStore
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.SystemAuthority
  alias Arbor.Security.TestAuditConsumer

  setup do
    # The polling consumer also sends store calls. Pause it so mailbox length
    # is a barrier for the calls this fixture starts.
    :ok = :sys.suspend(TestAuditConsumer)
    on_exit(fn -> :ok = :sys.resume(TestAuditConsumer) end)

    {:ok, actor} = Identity.generate()
    {:ok, target} = Identity.generate()
    :ok = Registry.register_fixture(actor)
    :ok = Registry.register_fixture(target)

    on_exit(fn ->
      for principal <- [actor.agent_id, target.agent_id] do
        Security.revoke_all_fixture(principal)
        Security.deregister_identity_fixture(principal)
      end
    end)

    resource = "arbor://fs/read/call-cycle"

    assert {:ok, capability} =
             Security.grant_fixture(principal: target.agent_id, resource: resource)

    assert {:ok, right} =
             Security.grant_fixture(
               principal: actor.agent_id,
               resource: "arbor://security/revoke/#{target.agent_id}"
             )

    store = Process.whereis(CapabilityStore)
    assert is_pid(store)

    %{actor: actor, target: target, capability: capability, right: right, store: store}
  end

  test "security regression: revocation and a signature-checking store read both complete", ctx do
    %{actor: actor, target: target, capability: capability, store: store} = ctx
    resource = capability.resource_uri
    assert {:ok, ^capability} = CapabilityStore.find_authorizing(target.agent_id, resource)
    assert is_binary(capability.issuer_signature)

    reader =
      Task.async(fn ->
        receive do
          :read -> timed(fn -> CapabilityStore.find_authorizing(target.agent_id, resource) end)
        end
      end)

    revoker = start_revoker(actor, target.agent_id)

    # Put the signature-checking read ahead of the revocation's authority lookup.
    # Resume only when both calls are queued. The store mailbox remains sensitive.
    :ok = :sys.suspend(store)

    try do
      send(reader.pid, :read)
      await_queued_calls(store, 1)
      send(revoker.pid, :revoke)
      await_queued_calls(store, 2)
    after
      :ok = :sys.resume(store)
    end

    {read_result, read_ms} = Task.await(reader, 7_000)
    {revoke_result, revoke_ms} = Task.await(revoker, 7_000)

    assert read_ms < 2_000 and revoke_ms < 2_000,
           "read took #{read_ms} ms (#{inspect(result_kind(read_result))}), " <>
             "revocation took #{revoke_ms} ms (#{inspect(revoke_result)})"

    assert {:ok, ^capability} = read_result
    assert {:ok, 1} = revoke_result
    assert {:error, :not_found} = CapabilityStore.get(capability.id)
  end

  test "security regression: a removed revocation right invalidates a pending decision", ctx do
    %{actor: actor, target: target, capability: capability, right: right, store: store} = ctx
    authority = Process.whereis(SystemAuthority)
    assert is_pid(authority)
    revoker = start_revoker(actor, target.agent_id)

    :ok = :sys.suspend(store)

    try do
      send(revoker.pid, :revoke)
      await_queued_calls(store, 1)
      :ok = :sys.suspend(authority, 2_000)
    after
      :ok = :sys.resume(store)
    end

    try do
      # The lookup was already queued. The store serves it before removing
      # the right, while the authority cannot yet act on the reply.
      assert :ok = Security.revoke_fixture(right.id)
    after
      :ok = :sys.resume(authority)
    end

    assert {{:error, :capability_revocation_unauthorized}, elapsed_ms} = Task.await(revoker)
    assert elapsed_ms < 2_000
    assert {:ok, ^capability} = CapabilityStore.get(capability.id)
  end

  test "security regression: an unrelated write before delivery gets a fresh view", ctx do
    unrelated = grant_unrelated(ctx)
    authority = Process.whereis(SystemAuthority)
    revoker = start_revoker(ctx.actor, ctx.target.agent_id)

    with_suspended(ctx.store, fn ->
      send(revoker.pid, :revoke)
      await_queued_calls(ctx.store, 1)
      :ok = :sys.suspend(authority)
    end)

    try do
      assert :ok = Security.revoke_fixture(unrelated.id)
    after
      :ok = :sys.resume(authority)
    end

    assert {{:ok, 1}, _elapsed} = Task.await(revoker)
  end

  test "security regression: an unrelated write during the final lease check gets a fresh view",
       ctx do
    unrelated = grant_unrelated(ctx)
    registry = Process.whereis(Registry)
    revoker = start_revoker(ctx.actor, ctx.target.agent_id)

    with_suspended(ctx.store, fn ->
      send(revoker.pid, :revoke)
      await_queued_calls(ctx.store, 1)
      :ok = :sys.suspend(registry)
    end)

    try do
      await_queued_calls(registry, 1)
      assert :ok = Security.revoke_fixture(unrelated.id)
    after
      :ok = :sys.resume(registry)
    end

    assert {{:ok, 1}, _elapsed} = Task.await(revoker)
  end

  test "security regression: a stale check retries a signed request and spends its nonce once",
       ctx do
    unrelated = grant_unrelated(ctx)
    {cap, payload} = signed_grant_request(ctx)
    proof = sign_request(ctx.actor, payload)
    registry = Process.whereis(Registry)

    task =
      with_suspended(ctx.store, fn ->
        task =
          Task.async(fn ->
            SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
          end)

        await_queued_calls(ctx.store, 1)
        :ok = :sys.suspend(registry)
        task
      end)

    try do
      await_queued_calls(registry, 1)
      assert :ok = Security.revoke_fixture(unrelated.id)
    after
      :ok = :sys.resume(registry)
    end

    assert {:ok, ^cap, receipt} = Task.await(task)
    assert {:ok, _signed_cap} = CapabilityStore.put_authorized(cap, :grant, receipt)

    assert {:error, :capability_mutation_unauthorized} =
             SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
  end

  test "security regression: a proof can authorize delegation from its exact parent", ctx do
    assert {:ok, parent} =
             Security.grant_fixture(
               principal: ctx.actor.agent_id,
               resource: "arbor://fs/read/delegation-proof"
             )

    assert {:ok, child} = Capability.delegate(parent, ctx.target.agent_id)
    child = %{child | metadata: %{"granter_id" => ctx.actor.agent_id}}
    link = Signer.sign_delegation(parent, child, ctx.actor.private_key)
    child = %{child | delegation_chain: parent.delegation_chain ++ [link]}

    assert {:ok, payload} = SystemAuthority.capability_mutation_request_payload(:delegate, child)
    proof = sign_request(ctx.actor, payload)

    assert {:ok, ^child, receipt} =
             SystemAuthority.authorize_capability_mutation_proof(proof, :delegate, child)

    assert {:ok, delegated} = CapabilityStore.put_authorized(child, :delegate, receipt)
    assert delegated.parent_capability_id == parent.id
  end

  test "security regression: canonical map and keyword proofs get a view", ctx do
    {cap, payload} = signed_grant_request(ctx)

    for encode <- [&Map.from_struct/1, &(Map.from_struct(&1) |> Map.to_list())] do
      proof = ctx.actor |> sign_request(payload) |> encode.()

      assert {:ok, ^cap, _receipt} =
               SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)

      assert {:error, :capability_mutation_unauthorized} =
               SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
    end
  end

  test "security regression: an unrecorded lease cannot queue a view", ctx do
    authority = open_authority(ctx.actor)
    forged = %{authority | token: :crypto.strong_rand_bytes(32)}
    assert %SigningAuthority{} = forged

    with_suspended(ctx.store, fn ->
      assert {:error, :capability_revocation_unauthorized} =
               view_call(
                 {:issue_capability_revocation_attestation, forged, :revoke_all,
                  ctx.target.agent_id},
                 250
               )

      assert {:message_queue_len, 0} = Process.info(ctx.store, :message_queue_len)
    end)
  end

  test "security regression: a malformed or oversized parent cannot queue a view", ctx do
    authority = open_authority(ctx.actor)
    {cap, _payload} = signed_grant_request(ctx)

    with_suspended(ctx.store, fn ->
      for id <- [String.duplicate("p", 257), %{}] do
        child = %{cap | parent_capability_id: id}

        assert {:error, :capability_mutation_unauthorized} =
                 view_call({:authorize_capability_mutation, authority, :delegate, child}, 250)

        assert {:message_queue_len, 0} = Process.info(ctx.store, :message_queue_len)
      end
    end)
  end

  test "security regression: a proof with a bad signature cannot queue or consume a nonce", ctx do
    {cap, payload} = signed_grant_request(ctx)
    proof = sign_request(ctx.actor, payload)
    invalid = %{proof | signature: <<0::512>>}

    with_suspended(ctx.store, fn ->
      assert {:error, :capability_mutation_unauthorized} =
               view_call({:authorize_capability_mutation_proof, invalid, :grant, cap}, 250)

      assert {:message_queue_len, 0} = Process.info(ctx.store, :message_queue_len)
    end)

    assert {:ok, ^cap, _receipt} =
             SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
  end

  test "security regression: view expiry reports the operation-specific errors", ctx do
    authority = open_authority(ctx.actor)
    digest = String.duplicate("a", 64)

    assert {:error, :issuer_mutation_unauthorized} =
             view_call({:issue_issuer_mutation_attestation, authority, :register, digest}, -1)

    assert {:error, :identity_registration_unauthorized} =
             view_call({:issue_identity_registration_attestation, authority, digest}, -1)
  end

  test "security regression: the 65th admitted request is refused and completed slots reopen",
       ctx do
    {cap, payload} = signed_grant_request(ctx)

    tasks =
      with_suspended(ctx.store, fn ->
        tasks =
          for _ <- 1..64 do
            proof = sign_request(ctx.actor, payload)

            Task.async(fn ->
              SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
            end)
          end

        await_queued_calls(ctx.store, 64)
        proof = sign_request(ctx.actor, payload)

        assert {:error, :capability_mutation_unauthorized} =
                 SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)

        assert {:message_queue_len, 64} = Process.info(ctx.store, :message_queue_len)
        tasks
      end)

    for task <- tasks do
      assert {:ok, ^cap, _receipt} = Task.await(task)
    end

    assert {:ok, ^cap, _receipt} =
             SystemAuthority.authorize_capability_mutation_proof(
               sign_request(ctx.actor, payload),
               :grant,
               cap
             )
  end

  test "security regression: requester death leaves its late store reply without authority",
       ctx do
    {cap, payload} = signed_grant_request(ctx)
    proof = sign_request(ctx.actor, payload)

    with_suspended(ctx.store, fn ->
      task =
        Task.async(fn ->
          SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
        end)

      await_queued_calls(ctx.store, 1)
      assert nil == Task.shutdown(task, :brutal_kill)
    end)

    assert {:ok, ^cap, _receipt} =
             SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
  end

  test "security regression: a view reply after the original deadline cannot spend the proof",
       ctx do
    {cap, payload} = signed_grant_request(ctx)
    proof = sign_request(ctx.actor, payload)

    with_suspended(ctx.store, fn ->
      task =
        Task.async(fn ->
          view_call({:authorize_capability_mutation_proof, proof, :grant, cap}, 500)
        end)

      await_queued_calls(ctx.store, 1)
      assert {:error, :capability_mutation_unauthorized} = Task.await(task)
    end)

    assert {:ok, ^cap, _receipt} =
             SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
  end

  test "security regression: a restarted store cannot complete the former owner's request", ctx do
    {cap, payload} = signed_grant_request(ctx)
    proof = sign_request(ctx.actor, payload)
    monitor = Process.monitor(ctx.store)
    :ok = :sys.suspend(ctx.store)

    try do
      task =
        Task.async(fn ->
          SystemAuthority.authorize_capability_mutation_proof(proof, :grant, cap)
        end)

      await_queued_calls(ctx.store, 1)
      Process.exit(ctx.store, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2_000
      assert {:error, :capability_mutation_unauthorized} = Task.await(task)
    after
      if Process.alive?(ctx.store), do: :sys.resume(ctx.store)
    end

    assert wait_for_replacement(ctx.store, System.monotonic_time(:millisecond) + 2_000)
    assert is_map(CapabilityStore.stats())
  end

  defp wait_for_replacement(previous, deadline) do
    case Process.whereis(CapabilityStore) do
      pid when is_pid(pid) and pid != previous ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_for_replacement(previous, deadline)
        else
          false
        end
    end
  end

  defp grant_unrelated(ctx) do
    assert {:ok, cap} =
             Security.grant_fixture(
               principal: ctx.actor.agent_id,
               resource: "arbor://fs/read/unrelated"
             )

    cap
  end

  defp signed_grant_request(ctx) do
    assert {:ok, _right} =
             Security.grant_fixture(
               principal: ctx.actor.agent_id,
               resource: "arbor://security/grant/#{ctx.target.agent_id}"
             )

    assert {:ok, cap} =
             Capability.new(
               principal_id: ctx.target.agent_id,
               resource_uri: "arbor://fs/read/signed-grant",
               metadata: %{"granter_id" => ctx.actor.agent_id}
             )

    assert {:ok, payload} = SystemAuthority.capability_mutation_request_payload(:grant, cap)
    {cap, payload}
  end

  defp sign_request(actor, payload) do
    assert {:ok, proof} = SignedRequest.sign(payload, actor.agent_id, actor.private_key)
    proof
  end

  defp view_call(request, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Custody.authenticated_call(
      Process.whereis(SystemAuthority),
      {:with_capability_view, request, deadline}
    )
  end

  defp with_suspended(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :ok = :sys.resume(pid)
    end
  end

  defp open_authority(actor) do
    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(actor.agent_id, actor.private_key,
        purpose: :authority_store_call_cycle
      )

    {:ok, authority} = Security.open_ephemeral_signing_authority(proof, actor.private_key)
    authority
  end

  defp start_revoker(actor, target_id) do
    parent = self()

    task =
      Task.async(fn ->
        {:ok, proof} =
          Security.build_signing_authority_acquisition_proof(actor.agent_id, actor.private_key,
            purpose: :authority_store_call_cycle
          )

        {:ok, authority} = Security.open_ephemeral_signing_authority(proof, actor.private_key)
        send(parent, {:revoker_ready, self()})

        receive do
          :revoke -> timed(fn -> Security.revoke_all(target_id, actor_authority: authority) end)
        end
      end)

    assert_receive {:revoker_ready, pid}, 2_000
    assert pid == task.pid
    task
  end

  defp await_queued_calls(store, count) do
    assert wait_for_queue(store, count, System.monotonic_time(:millisecond) + 2_000),
           "expected #{count} calls in CapabilityStore's suspended mailbox, got #{inspect(Process.info(store, :message_queue_len))}"
  end

  defp wait_for_queue(store, count, deadline) do
    case Process.info(store, :message_queue_len) do
      {:message_queue_len, queued} when queued >= count ->
        true

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(1)
          wait_for_queue(store, count, deadline)
        else
          false
        end
    end
  end

  defp result_kind({:ok, _capability}), do: :ok
  defp result_kind(error), do: error

  defp timed(operation) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        operation.()
      catch
        :exit, {:timeout, _call} -> {:error, :timeout}
      end

    {result, System.monotonic_time(:millisecond) - started}
  end
end
