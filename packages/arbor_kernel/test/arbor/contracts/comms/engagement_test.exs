defmodule Arbor.Contracts.Comms.EngagementTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Comms.Engagement

  @moduletag :fast

  describe "new/1" do
    test "auto-generates an eng_-prefixed id and created_at" do
      e = Engagement.new(agent_id: "agent_abc")
      assert String.starts_with?(e.id, "eng_")
      assert %DateTime{} = e.created_at
    end

    test "applies defaults: :channel scope, :active status, :private visibility, no channels" do
      e = Engagement.new(agent_id: "agent_abc")
      assert e.scope == :channel
      assert e.status == :active
      # fail-closed: a fresh engagement is non-disclosing until its audience is set
      assert e.visibility == :private
      assert e.attached_channels == []
      assert e.metadata == %{}
    end

    test "requires agent_id" do
      assert_raise ArgumentError, fn -> Engagement.new([]) end
    end

    test "accepts overrides" do
      e =
        Engagement.new(
          agent_id: "agent_abc",
          owner_tenant: "tenant_1",
          scope: :user,
          visibility: :group,
          primary_channel: "chan_1"
        )

      assert e.owner_tenant == "tenant_1"
      assert e.scope == :user
      assert e.visibility == :group
      assert e.primary_channel == "chan_1"
    end

    test "accepts each visibility tag" do
      for v <- [:private, :group, :internal, :public] do
        assert Engagement.new(agent_id: "a", visibility: v).visibility == v
      end
    end
  end

  describe "attach_channel/2 and detach_channel/2" do
    test "attach is idempotent and order-preserving" do
      e = Engagement.new(agent_id: "agent_abc")
      e = Engagement.attach_channel(e, "chan_1")
      e = Engagement.attach_channel(e, "chan_2")
      e = Engagement.attach_channel(e, "chan_1")

      assert e.attached_channels == ["chan_1", "chan_2"]
    end

    test "detach removes the channel but keeps the engagement" do
      e =
        Engagement.new(agent_id: "agent_abc")
        |> Engagement.attach_channel("chan_1")
        |> Engagement.attach_channel("chan_2")
        |> Engagement.detach_channel("chan_1")

      assert e.attached_channels == ["chan_2"]
      assert e.status == :active
    end

    test "detaching the last channel leaves an empty list, not an error" do
      e =
        Engagement.new(agent_id: "agent_abc")
        |> Engagement.attach_channel("chan_1")
        |> Engagement.detach_channel("chan_1")

      assert e.attached_channels == []
    end
  end
end
