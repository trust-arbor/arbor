defmodule Arbor.Security.PrivateMemorySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Identifiers
  alias Arbor.Security
  alias Arbor.Security.DeliveryReceiptBroker

  @moduletag :fast

  setup do
    settings = [
      identity_verification: true,
      policy_enforcer_enabled: false,
      approval_guard_enabled: false,
      reflex_checking_enabled: false,
      uri_registry_enforcement: false
    ]

    previous =
      for {key, value} <- settings do
        old = Application.fetch_env(:arbor_security, key)
        Application.put_env(:arbor_security, key, value)
        {key, old}
      end

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    human =
      Arbor.Security.OIDCTestHelper.issue_identity(subject: Identifiers.generate_id("memory_"))

    assert :ok = Security.register_oidc_identity(human.identity, human.id_token, human.provider)
    assert {:ok, agent} = Identity.generate(name: "private-memory-security-test")
    assert :ok = Security.register_identity(Identity.public_only(agent))

    on_exit(fn ->
      human.cleanup.()
      Security.deregister_identity(human.identity.agent_id)
      Security.deregister_identity(agent.agent_id)
    end)

    resource = "arbor://chat/agent/" <> agent.agent_id
    chat = grant!(human.identity.agent_id, resource)
    read = grant!(agent.agent_id, "arbor://memory/read/" <> agent.agent_id)
    write = grant!(agent.agent_id, "arbor://memory/write/" <> agent.agent_id)

    %{
      agent: agent,
      human: human.identity,
      resource: resource,
      chat: chat,
      read: read,
      write: write,
      context: %{
        session_id: Identifiers.generate_id("session_"),
        turn_id: Identifiers.generate_id("turn_")
      }
    }
  end

  test "security regression: genuine receipt is one use and pending admission requires activation",
       ctx do
    receipt = receipt!(ctx)
    assert {:ok, admission} = exchange(ctx, receipt)
    assert {:error, :invalid_memory_admission} = exchange(ctx, receipt)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)

    assert :ok = Security.activate_private_memory_admission(admission, "engagement_private")

    assert {:error, :invalid_memory_admission} =
             Security.activate_private_memory_admission(admission, "other")

    assert {:ok, scope} = Security.authorize_private_memory_turn(admission, :read)
    assert scope.agent_id == ctx.agent.agent_id
    assert scope.human_id == ctx.human.agent_id
    assert scope.engagement_id == "engagement_private"
    assert scope.turn_id == ctx.context.turn_id
    assert {:ok, ^scope} = Security.authorize_private_memory_turn(admission, :write)
    assert inspect(admission) =~ "REDACTED"
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(admission) end
    assert :ok = Security.close_private_memory_admission(admission)
    assert :ok = Security.close_private_memory_admission(admission)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)
  end

  test "security regression: wrong sender or target spends receipt; raw and embellished claims deny",
       ctx do
    for altered <- [
          %{ctx | resource: ctx.resource <> "/other"},
          %{ctx | human: %{ctx.human | agent_id: "human_forged"}}
        ] do
      receipt = receipt!(ctx)
      target = if altered.resource == ctx.resource, do: ctx.agent.agent_id, else: "agent_wrong"

      assert {:error, :invalid_memory_admission} =
               Security.exchange_private_memory_receipt(
                 receipt,
                 target,
                 altered.human.agent_id,
                 ctx.context
               )

      assert {:error, :invalid_memory_admission} = exchange(ctx, receipt)
    end

    for context <- [
          nil,
          %{},
          Map.put(ctx.context, :engagement_id, "forged"),
          %{ctx.context | turn_id: String.duplicate("x", 257)}
        ] do
      receipt = receipt!(ctx)

      assert {:error, :invalid_memory_admission} =
               Security.exchange_private_memory_receipt(
                 receipt,
                 ctx.agent.agent_id,
                 ctx.human.agent_id,
                 context
               )

      assert {:error, :invalid_memory_admission} = exchange(ctx, receipt)
    end

    admission = active!(ctx)

    for forged <- [
          Map.from_struct(admission),
          Map.put(admission, :human_id, ctx.human.agent_id),
          %{admission | token: :crypto.strong_rand_bytes(32)},
          %{capability_id: ctx.read.id}
        ] do
      assert {:error, :invalid_memory_admission} =
               Security.authorize_private_memory_turn(forged, :read)
    end

    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: copied token cannot activate use or close another process admission",
       ctx do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, admission} = exchange(ctx, receipt!(ctx))
        send(parent, {:admission, admission})

        receive do
          :activate ->
            :ok = Security.activate_private_memory_admission(admission, "engagement_private")
            send(parent, :activated)
        end

        receive do
          :finish -> :ok
        end
      end)

    ref = Process.monitor(owner)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert_receive {:admission, admission}, 5_000

    assert {:error, :invalid_memory_admission} =
             Security.activate_private_memory_admission(admission, "forged")

    send(owner, :activate)
    assert_receive :activated

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)

    assert {:error, :invalid_memory_admission} =
             Security.close_private_memory_admission(admission)

    send(owner, :finish)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)
  end

  test "security regression: current chat and memory revocation each close live use", ctx do
    admission = active!(ctx)
    assert {:ok, _} = Security.authorize_private_memory_turn(admission, :read)
    Security.revoke(ctx.read.id)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)

    assert {:ok, _} = Security.authorize_private_memory_turn(admission, :write)
    Security.revoke(ctx.chat.id)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :write)

    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: suspended human loses a previously active admission", ctx do
    admission = active!(ctx)
    assert {:ok, _} = Security.authorize_private_memory_turn(admission, :read)
    assert :ok = Security.suspend_identity(ctx.human.agent_id)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)

    assert :ok = Security.close_private_memory_admission(admission)
  end

  test "security regression: immutable broker expiry and broker restart invalidate admissions",
       ctx do
    admission = active!(ctx)
    # Test-owned clock advances the existing owner; public APIs still perform admission.
    :sys.replace_state(DeliveryReceiptBroker, fn state ->
      %{state | clock: fn -> System.monotonic_time(:millisecond) + 3_600_001 end}
    end)

    on_exit(fn -> restart_broker!() end)

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(admission, :read)

    restart_broker!()
    fresh = active!(ctx)
    restart_broker!()

    assert {:error, :invalid_memory_admission} =
             Security.authorize_private_memory_turn(fresh, :read)
  end

  defp active!(ctx) do
    assert {:ok, admission} = exchange(ctx, receipt!(ctx))
    assert :ok = Security.activate_private_memory_admission(admission, "engagement_private")
    admission
  end

  defp receipt!(ctx) do
    assert {:ok, signed} =
             SignedRequest.sign(ctx.resource, ctx.human.agent_id, ctx.human.private_key)

    assert {:ok, receipt} =
             Security.authorize_and_issue_delivery_receipt(
               ctx.human.agent_id,
               ctx.resource,
               :chat,
               signed_request: signed,
               expected_resource: ctx.resource
             )

    receipt
  end

  defp exchange(ctx, receipt),
    do:
      Security.exchange_private_memory_receipt(
        receipt,
        ctx.agent.agent_id,
        ctx.human.agent_id,
        ctx.context
      )

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)
    on_exit(fn -> Security.revoke(cap.id) end)
    cap
  end

  defp restart_broker! do
    assert :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, DeliveryReceiptBroker)
    assert {:ok, _} = Supervisor.restart_child(Arbor.Security.Supervisor, DeliveryReceiptBroker)
  end
end
