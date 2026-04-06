defmodule Arbor.Contracts.Security.AuthContextTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.AuthContext

  describe "new/2" do
    test "creates context with principal_id" do
      ctx = AuthContext.new("agent_123")
      assert ctx.principal_id == "agent_123"
      assert ctx.identity_verified == false
      assert ctx.trust_tier == :untrusted
      assert ctx.trust_baseline == :ask
      assert ctx.capabilities == []
      assert ctx.decisions == []
    end

    test "accepts optional fields" do
      signer = fn _resource -> {:ok, :signed} end

      ctx =
        AuthContext.new("agent_123",
          signer: signer,
          trust_tier: :veteran,
          trust_baseline: :allow,
          session_id: "sess_1"
        )

      assert ctx.signer == signer
      assert ctx.trust_tier == :veteran
      assert ctx.trust_baseline == :allow
      assert ctx.session_id == "sess_1"
    end
  end

  describe "mark_verified/1" do
    test "sets identity_verified to true" do
      ctx = AuthContext.new("agent_123")
      assert ctx.identity_verified == false

      verified = AuthContext.mark_verified(ctx)
      assert verified.identity_verified == true
    end
  end

  describe "sign/2" do
    test "signs with signer function" do
      signer = fn resource -> {:ok, %{payload: resource, sig: "test"}} end
      ctx = AuthContext.new("agent_123", signer: signer)

      {:ok, signed_ctx} = AuthContext.sign(ctx, "arbor://fs/read")
      assert signed_ctx.signed_request.payload == "arbor://fs/read"
    end

    test "returns ok with nil signer" do
      ctx = AuthContext.new("agent_123")
      assert {:ok, ^ctx} = AuthContext.sign(ctx, "arbor://fs/read")
    end

    test "propagates signer error" do
      signer = fn _resource -> {:error, :no_key} end
      ctx = AuthContext.new("agent_123", signer: signer)

      assert {:error, :no_key} = AuthContext.sign(ctx, "arbor://fs/read")
    end
  end

  describe "record_decision/3" do
    test "prepends decision to trail" do
      ctx = AuthContext.new("agent_123")

      ctx = AuthContext.record_decision(ctx, "arbor://fs/read", :authorized)
      assert length(ctx.decisions) == 1
      assert hd(ctx.decisions).resource == "arbor://fs/read"
      assert hd(ctx.decisions).result == :authorized

      ctx = AuthContext.record_decision(ctx, "arbor://fs/write", :unauthorized)
      assert length(ctx.decisions) == 2
      assert hd(ctx.decisions).resource == "arbor://fs/write"
    end
  end
end
