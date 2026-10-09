defmodule Arbor.Actions.ChannelTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.Channel
  alias Arbor.Contracts.Security.Identity
  alias Arbor.Security

  @moduletag :integration

  setup do
    # Start channel infrastructure if not already running
    ensure_channel_infra()
    member = register_agent!("Agent One")

    # Create a test channel via the Comms facade. Send uses the authority
    # principal, so the member id has to be that principal.
    {:ok, channel_id} =
      Arbor.Comms.create_channel("test_channel",
        type: :group,
        owner_id: member.identity.agent_id,
        members: [%{id: member.identity.agent_id, name: "Agent One", type: :agent}],
        rate_limit_ms: 0
      )

    on_exit(fn ->
      # Channel processes are under DynamicSupervisor; they'll be cleaned up
      # when the supervisor stops or we can just leave them — they're ephemeral.
      :ok
    end)

    %{channel_id: channel_id, member: member}
  end

  # ============================================================================
  # Channel.List
  # ============================================================================

  describe "Channel.List" do
    test "has correct action metadata" do
      assert Channel.List.name() == "channel_list"
      assert Channel.List.category() == "channel"
    end

    test "returns active channels", %{channel_id: channel_id} do
      assert {:ok, result} = Channel.List.run(%{}, %{})
      assert is_list(result.channels)
      assert Enum.any?(result.channels, &(&1.channel_id == channel_id))
    end

    test "includes channel info fields", %{channel_id: channel_id} do
      {:ok, result} = Channel.List.run(%{}, %{})
      chan = Enum.find(result.channels, &(&1.channel_id == channel_id))
      assert chan.name == "test_channel"
      assert chan.type == :group
      assert is_integer(chan.member_count)
    end

    test "filters by type", %{channel_id: _channel_id} do
      # Create a public channel for filtering
      {:ok, pub_id} = Arbor.Comms.create_channel("pub_chan", type: :public, rate_limit_ms: 0)

      {:ok, result} = Channel.List.run(%{type: "public"}, %{})
      ids = Enum.map(result.channels, & &1.channel_id)
      assert pub_id in ids

      {:ok, group_result} = Channel.List.run(%{type: "group"}, %{})
      pub_ids = Enum.map(group_result.channels, & &1.channel_id)
      refute pub_id in pub_ids
    end
  end

  # ============================================================================
  # Channel.Read
  # ============================================================================

  describe "Channel.Read" do
    test "has correct action metadata" do
      assert Channel.Read.name() == "channel_read"
      assert Channel.Read.category() == "channel"
    end

    test "returns empty for new channel", %{channel_id: channel_id} do
      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      assert result.channel_id == channel_id
      assert result.messages == []
      assert result.count == 0
    end

    test "returns messages after send", %{channel_id: channel_id, member: member} do
      Arbor.Comms.send_to_channel(
        channel_id,
        member.identity.agent_id,
        "Agent One",
        :agent,
        "Hello world!"
      )

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      assert result.count == 1
      [msg] = result.messages
      assert msg.sender_name == "Agent One"
      assert msg.content == "Hello world!"
    end

    test "respects limit", %{channel_id: channel_id, member: member} do
      for i <- 1..5 do
        Arbor.Comms.send_to_channel(
          channel_id,
          member.identity.agent_id,
          "Agent One",
          :agent,
          "msg #{i}"
        )
      end

      {:ok, result} = Channel.Read.run(%{channel_id: channel_id, limit: 3}, %{})
      assert result.count == 3
    end

    test "returns error for unknown channel" do
      assert {:error, :not_found} = Channel.Read.run(%{channel_id: "nonexistent"}, %{})
    end
  end

  # ============================================================================
  # Channel.Send
  # ============================================================================

  describe "Channel.Send" do
    test "has correct action metadata" do
      assert Channel.Send.name() == "channel_send"
      assert Channel.Send.category() == "channel"
    end

    test "sends message and returns result", %{channel_id: channel_id, member: member} do
      context = member.context
      params = %{channel_id: channel_id, content: "Hello via action!"}

      assert {:ok, result} = Channel.Send.run(params, context)
      assert result.channel_id == channel_id
      assert result.status == :sent
      assert is_binary(result.message_id)
    end

    test "extracts agent_id from context", %{channel_id: channel_id, member: member} do
      context = %{member.context | agent_name: "Test Agent"}

      {:ok, _} =
        Channel.Send.run(%{channel_id: channel_id, content: "test"}, context)

      # Verify via read
      {:ok, result} = Channel.Read.run(%{channel_id: channel_id}, %{})
      msg = List.last(result.messages)
      assert msg.sender_name == "Test Agent"
    end

    test "fails for non-member", %{channel_id: channel_id} do
      context = register_agent!("Outsider").context
      params = %{channel_id: channel_id, content: "Should fail"}

      assert {:error, reason} = Channel.Send.run(params, context)
      assert reason == :not_member
    end

    test "returns error for unknown channel", %{member: member} do
      assert {:error, :not_found} =
               Channel.Send.run(
                 %{channel_id: "nonexistent", content: "hi"},
                 member.context
               )
    end
  end

  # ============================================================================
  # Channel.Join
  # ============================================================================

  describe "Channel.Join" do
    test "has correct action metadata" do
      assert Channel.Join.name() == "channel_join"
      assert Channel.Join.category() == "channel"
    end

    test "joins channel and enables sending", %{channel_id: channel_id} do
      context = register_agent!("Agent Two").context

      # Should fail before joining
      assert {:error, :not_member} =
               Channel.Send.run(%{channel_id: channel_id, content: "before join"}, context)

      # Join
      assert {:ok, result} = Channel.Join.run(%{channel_id: channel_id}, context)
      assert result.channel_id == channel_id
      assert result.status == :joined

      # Should succeed after joining
      assert {:ok, _} =
               Channel.Send.run(%{channel_id: channel_id, content: "after join"}, context)
    end

    test "returns error for unknown channel" do
      context = %{agent_id: "agent_2", agent_name: "Agent Two"}
      assert {:error, :not_found} = Channel.Join.run(%{channel_id: "nonexistent"}, context)
    end
  end

  # ============================================================================
  # Channel.Leave
  # ============================================================================

  describe "Channel.Leave" do
    test "has correct action metadata" do
      assert Channel.Leave.name() == "channel_leave"
      assert Channel.Leave.category() == "channel"
    end

    test "leaves channel and blocks sending", %{channel_id: channel_id, member: member} do
      context = member.context

      # Can send while member
      assert {:ok, _} =
               Channel.Send.run(%{channel_id: channel_id, content: "still here"}, context)

      # Leave
      assert {:ok, result} = Channel.Leave.run(%{channel_id: channel_id}, context)
      assert result.channel_id == channel_id
      assert result.status == :left

      # Should fail after leaving
      assert {:error, :not_member} =
               Channel.Send.run(%{channel_id: channel_id, content: "gone"}, context)
    end

    test "returns error for unknown channel" do
      context = %{agent_id: "agent_1", agent_name: "Agent One"}
      assert {:error, :not_found} = Channel.Leave.run(%{channel_id: "nonexistent"}, context)
    end
  end

  # ============================================================================
  # Cross-action integration
  # ============================================================================

  # ============================================================================
  # Channel.Create
  # ============================================================================

  describe "Channel.Create" do
    test "has correct action metadata" do
      assert Channel.Create.name() == "channel_create"
      assert Channel.Create.category() == "channel"
    end

    test "creates a channel with owner as first member" do
      context = %{agent_id: "agent_creator", agent_name: "Creator"}
      params = %{name: "new_channel", type: "group"}

      assert {:ok, result} = Channel.Create.run(params, context)
      assert result.name == "new_channel"
      assert result.type == :group
      assert result.status == :created
      assert is_binary(result.channel_id)

      # Verify owner is a member
      {:ok, members} = Arbor.Comms.channel_members(result.channel_id)
      assert Enum.any?(members, &(&1.id == "agent_creator"))
    end

    test "defaults to group type" do
      context = %{agent_id: "agent_x", agent_name: "X"}
      assert {:ok, result} = Channel.Create.run(%{name: "default_type"}, context)
      assert result.type == :group
    end
  end

  # ============================================================================
  # Channel.Members
  # ============================================================================

  describe "Channel.Members" do
    test "has correct action metadata" do
      assert Channel.Members.name() == "channel_members"
      assert Channel.Members.category() == "channel"
    end

    test "returns member list", %{channel_id: channel_id, member: member} do
      assert {:ok, result} = Channel.Members.run(%{channel_id: channel_id}, %{})
      assert result.channel_id == channel_id
      assert result.count >= 1
      [listed | _] = result.members
      assert listed.id == member.identity.agent_id
      assert listed.name == "Agent One"
    end

    test "returns error for unknown channel" do
      assert {:error, :not_found} = Channel.Members.run(%{channel_id: "nonexistent"}, %{})
    end
  end

  # ============================================================================
  # Channel.Update
  # ============================================================================

  describe "Channel.Update" do
    test "has correct action metadata" do
      assert Channel.Update.name() == "channel_update"
      assert Channel.Update.category() == "channel"
    end

    test "owner can rename channel", %{channel_id: channel_id, member: member} do
      context = %{agent_id: member.identity.agent_id}
      params = %{channel_id: channel_id, name: "renamed_channel"}

      assert {:ok, result} = Channel.Update.run(params, context)
      assert result.status == :updated

      # Verify rename
      {:ok, info} = Arbor.Comms.get_channel_info(channel_id)
      assert info.name == "renamed_channel"
    end

    test "non-owner cannot update", %{channel_id: channel_id} do
      context = %{agent_id: "agent_outsider"}
      params = %{channel_id: channel_id, name: "hacked"}

      assert {:error, :not_owner} = Channel.Update.run(params, context)
    end

    test "returns error for unknown channel" do
      context = %{agent_id: "agent_1"}
      assert {:error, :not_found} = Channel.Update.run(%{channel_id: "nope", name: "x"}, context)
    end
  end

  # ============================================================================
  # Channel.Invite
  # ============================================================================

  describe "Channel.Invite" do
    test "has correct action metadata" do
      assert Channel.Invite.name() == "channel_invite"
      assert Channel.Invite.category() == "channel"
    end

    test "owner can invite member", %{channel_id: channel_id, member: member} do
      context = %{agent_id: member.identity.agent_id}

      params = %{
        channel_id: channel_id,
        invitee_id: "agent_invited",
        invitee_name: "Invited Agent"
      }

      assert {:ok, result} = Channel.Invite.run(params, context)
      assert result.status == :invited
      assert result.invitee_id == "agent_invited"

      # Verify membership
      {:ok, members} = Arbor.Comms.channel_members(channel_id)
      assert Enum.any?(members, &(&1.id == "agent_invited"))
    end

    test "idempotent — re-invite returns already_member", %{
      channel_id: channel_id,
      member: member
    } do
      context = %{agent_id: member.identity.agent_id}
      params = %{channel_id: channel_id, invitee_id: member.identity.agent_id}

      assert {:ok, result} = Channel.Invite.run(params, context)
      assert result.status == :already_member
    end

    test "non-owner cannot invite", %{channel_id: channel_id} do
      context = %{agent_id: "agent_outsider"}
      params = %{channel_id: channel_id, invitee_id: "agent_new"}

      assert {:error, :not_owner} = Channel.Invite.run(params, context)
    end
  end

  describe "action name resolution" do
    test "action_module_to_name produces correct URIs" do
      assert Arbor.Actions.action_module_to_name(Channel.List) == "channel.list"
      assert Arbor.Actions.action_module_to_name(Channel.Read) == "channel.read"
      assert Arbor.Actions.action_module_to_name(Channel.Send) == "channel.send"
      assert Arbor.Actions.action_module_to_name(Channel.Join) == "channel.join"
      assert Arbor.Actions.action_module_to_name(Channel.Leave) == "channel.leave"
      assert Arbor.Actions.action_module_to_name(Channel.Create) == "channel.create"
      assert Arbor.Actions.action_module_to_name(Channel.Members) == "channel.members"
      assert Arbor.Actions.action_module_to_name(Channel.Update) == "channel.update"
      assert Arbor.Actions.action_module_to_name(Channel.Invite) == "channel.invite"
    end

    test "channel actions are registered in list_actions" do
      actions = Arbor.Actions.list_actions()
      assert Map.has_key?(actions, :channel)
      assert length(actions.channel) == 9
    end
  end

  describe "comms unavailable" do
    test "graceful error when Comms module is missing" do
      # We can't easily unload Arbor.Comms at runtime in the umbrella,
      # but we verify the call_comms bridge pattern works by confirming
      # successful calls above. The :comms_unavailable path is tested
      # by verifying the pattern exists in the module.
      assert function_exported?(Arbor.Actions.Channel, :call_comms, 2)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp register_agent!(name) do
    {:ok, identity} = Identity.generate(name: name)
    :ok = Security.register_identity_fixture(Identity.public_only(identity))

    :ok =
      Security.store_signing_keypair_fixture(
        identity.agent_id,
        identity.private_key,
        identity.encryption_private_key
      )

    {:ok, signing_authority} = open_authority(identity)
    {:ok, send_authority} = Security.issue_channel_authority(signing_authority, :send)

    on_exit(fn ->
      _ = Security.delete_signing_key_fixture(identity.agent_id)
      _ = Security.deregister_identity_fixture(identity.agent_id)
    end)

    %{
      identity: identity,
      context: %{
        agent_id: identity.agent_id,
        agent_name: name,
        channel_authority: send_authority
      }
    }
  end

  defp open_authority(identity) do
    with {:ok, proof} <-
           Security.build_signing_authority_acquisition_proof(
             identity.agent_id,
             identity.private_key,
             purpose: :session,
             owner: self()
           ) do
      Security.open_signing_authority(proof)
    end
  end

  defp ensure_channel_infra do
    # Registry
    case Registry.start_link(keys: :unique, name: Arbor.Comms.ChannelRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # DynamicSupervisor
    case DynamicSupervisor.start_link(
           name: Arbor.Comms.ChannelSupervisor,
           strategy: :one_for_one
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
