defmodule Arbor.Agent.ManagementSessionSecurityRegressionTest do
  use ExUnit.Case, async: false
  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.Test.ManagementSessionFixture, as: Fixture
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans
  @moduletag :integration
  @moduletag :database
  @moduletag :isolated_repo
  setup_all do
    Fixture.initialize!()
  end

  setup %{root: root} do
    Fixture.setup!(root)
  end

  for operation <- [:stop, :destroy] do
    test "general human session permits exact target #{operation} exactly once", ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)
      {result, effects} = observe(operation, ctx, target, Fixture.proof(ctx))
      assert result == :ok
      assert Enum.count(effects, &(&1 == {operation, target.target})) == 1
      refute Process.alive?(target.pid)
      Fixture.deleted_if_destroy!(operation, target.target)
    end

    test "security regression: #{operation} rejects absent forged mismatched expired and chat-only proof",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)
      other = Humans.human!()
      {:ok, mismatch} = Security.SessionToken.generate(other)
      {:ok, expired} = Security.SessionToken.generate(ctx.human_id, ttl: -1)
      {:ok, chat} = Security.SessionToken.generate_conversation(ctx.human_id, target.target)

      for token <- [nil, "", "forged", mismatch, expired, chat] do
        {result, effects} = observe(operation, ctx, target, session_token: token)
        assert {:error, {:unauthorized, _}} = result
        assert effects == []
        Fixture.preserved!(target)
      end
    end

    test "security regression: #{operation} rejects mixed duplicate and caller-forged authority options",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)

      for opts <- [
            [session_token: ctx.token, identity_verified: true],
            [session_token: ctx.token, signed_request: nil],
            [session_token: ctx.token, caller_id: ctx.human_id],
            [session_token: ctx.token, session_token: ctx.token],
            [session_token: ctx.token, unknown: :option]
          ] do
        {result, effects} = observe(operation, ctx, target, opts)
        assert {:error, {:unauthorized, _}} = result
        assert effects == []
      end

      for id <- [target.target <> "/other", target.target <> "/*", target.target <> "?scope=all"] do
        assert {:error, {:unauthorized, _}} =
                 invoke(operation, ctx.human_id, id, Fixture.proof(ctx))
      end

      Fixture.preserved!(target)
    end

    test "security regression: #{operation} rechecks exact capability scope and revocation",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      other = Fixture.target!()
      cap = Fixture.grant!(ctx.human_id, operation, target.target)

      for id <- [other.target, target.target <> "neighbor"] do
        {result, effects} =
          Fixture.observe!(self(), fn ->
            invoke(operation, ctx.human_id, id, Fixture.proof(ctx))
          end)

        assert {:error, {:unauthorized, _}} = result
        assert effects == []
      end

      assert :ok = Security.revoke(cap.id)
      {result, effects} = observe(operation, ctx, target, Fixture.proof(ctx))
      assert {:error, {:unauthorized, _}} = result
      assert effects == []
      Fixture.preserved!(target)
      Fixture.preserved!(other)
    end

    test "security regression: #{operation} denies revoked human or unavailable Security without effect",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()
      Fixture.grant!(ctx.human_id, operation, target.target)
      name = Security.CapabilityStore
      pid = Process.whereis(name)
      true = Process.unregister(name)

      try do
        {result, effects} = observe(operation, ctx, target, Fixture.proof(ctx))
        assert {:error, {:unauthorized, _}} = result
        assert effects == []
      after
        true = Process.register(pid, name)
      end

      assert :ok = Security.revoke_identity(ctx.human_id, reason: "private management fixture")
      {result, effects} = observe(operation, ctx, target, Fixture.proof(ctx))
      assert {:error, {:unauthorized, _}} = result
      assert effects == []
      Fixture.preserved!(target)
    end

    test "security regression: #{operation} preserves pending approval without lifecycle effect",
         ctx do
      operation = unquote(operation)
      target = Fixture.target!()

      Fixture.grant!(ctx.human_id, operation, target.target,
        constraints: %{requires_approval: true}
      )

      {result, effects} = observe(operation, ctx, target, Fixture.proof(ctx))
      assert {:ok, :pending_approval, "management-pending-fixture"} = result
      assert effects == []
      Fixture.preserved!(target)
    end
  end

  test "security regression: present invalid session cannot fall back to disabled legacy identity verification",
       ctx do
    target = Fixture.target!()
    Fixture.grant!(ctx.human_id, :stop, target.target)
    Fixture.set_env(:arbor_security, :identity_verification, false)
    {result, effects} = observe(:stop, ctx, target, session_token: nil)
    assert effects == []
    assert {:error, {:unauthorized, _}} = result
    Fixture.preserved!(target)
  end

  test "Gateway-preverified signed stop and two-argument legacy destroy retain existing semantics",
       ctx do
    target = Fixture.target!()
    {:ok, caller} = Security.generate_identity()
    :ok = Security.register_identity(caller)
    on_exit(fn -> Security.deregister_identity(caller.agent_id) end)
    Humans.grant!(caller.agent_id, Fixture.resource(:stop, target.target))

    {:ok, signed} =
      SignedRequest.sign(
        Fixture.resource(:stop, target.target),
        caller.agent_id,
        caller.private_key
      )

    assert {:ok, principal} = Security.verify_request(signed)
    assert principal == caller.agent_id
    assert :ok = Agents.authorize_stop(caller.agent_id, target.target, signed_request: signed)
    assert {:error, :replayed_nonce} = Security.verify_request(signed)
    destroy = Fixture.target!()
    Humans.grant!(ctx.human_id, "arbor://agent/lifecycle/destroy")
    Fixture.set_env(:arbor_security, :identity_verification, false)
    assert :ok = Agents.authorize_destroy(ctx.human_id, destroy.target)
    assert {:error, :not_found} = Agents.load_profile(destroy.target)
  end

  test "security regression: session destroy does not inherit legacy global destroy grant", ctx do
    target = Fixture.target!()
    Humans.grant!(ctx.human_id, "arbor://agent/lifecycle/destroy")

    assert {:error, {:unauthorized, _}} =
             Agents.authorize_destroy(ctx.human_id, target.target, Fixture.proof(ctx))

    assert {:error, {:unauthorized, _}} =
             Agents.authorize_destroy(ctx.human_id, target.target, [])

    Fixture.preserved!(target)
  end

  test "public session authorization records its exact decision in a real SQL invocation frame",
       ctx do
    target = Fixture.target!()
    Fixture.grant!(ctx.human_id, :stop, target.target)
    Fixture.set_env(:arbor_security, :invocation_audit_mode, :required)
    audit_before = Fixture.audit_count!(ctx.human_id)

    {result, effects} =
      Fixture.observe!(self(), fn ->
        Security.with_invocation_audit(%{principal_id: ctx.human_id, surface: :action}, fn ->
          Agents.authorize_stop(ctx.human_id, target.target, Fixture.proof(ctx))
        end)
      end)

    assert result == :ok
    assert effects == [{:stop, target.target}]
    assert Fixture.audit_count!(ctx.human_id) > audit_before
  end

  defp observe(operation, ctx, target, opts),
    do: Fixture.observe!(self(), fn -> invoke(operation, ctx.human_id, target.target, opts) end)

  defp invoke(:stop, actor, target, opts), do: Agents.authorize_stop(actor, target, opts)
  defp invoke(:destroy, actor, target, opts), do: Agents.authorize_destroy(actor, target, opts)
end
