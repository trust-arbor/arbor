defmodule Arbor.Comms.InteractionRegistryTest do
  @moduledoc """
  Tests for `Arbor.Comms.InteractionRegistry`.

  Covers the `list_pending_for_user/1` accessor added 2026-06-06 for
  the Signal adapter's partial-response resolution path. (Other
  registry behaviour — put/get/resolve — is covered indirectly by
  `interaction_router_test.exs`.)
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Contracts.Comms.Interaction

  setup do
    if Process.whereis(InteractionRegistry) == nil do
      start_supervised!(InteractionRegistry)
    end

    InteractionRegistry.reset()
    :ok
  end

  describe "list_pending_for_user/1" do
    test "returns empty list for a user with no pending interactions" do
      assert [] = InteractionRegistry.list_pending_for_user("nobody")
    end

    test "filters by user_id" do
      {:ok, a} = put_for("alice", "first")
      {:ok, _b} = put_for("bob", "second")

      assert [^a] = InteractionRegistry.list_pending_for_user("alice")
    end

    test "sorts newest first" do
      {:ok, older} = put_for("alice", "old", DateTime.add(DateTime.utc_now(), -10, :second))
      {:ok, newer} = put_for("alice", "new", DateTime.utc_now())

      assert [^newer, ^older] = InteractionRegistry.list_pending_for_user("alice")
    end

    test "doesn't return resolved interactions" do
      {:ok, a} = put_for("alice", "first")
      assert [^a] = InteractionRegistry.list_pending_for_user("alice")

      {:ok, ^a} = InteractionRegistry.resolve(a.request_id)
      assert [] = InteractionRegistry.list_pending_for_user("alice")
    end
  end

  defp put_for(user_id, description, submitted_at \\ nil) do
    submitted_at = submitted_at || DateTime.utc_now()

    {:ok, interaction} =
      Interaction.new(%{
        kind: :approval,
        agent_id: "agent_test_#{:erlang.unique_integer([:positive])}",
        user_id: user_id,
        description: description,
        submitted_at: submitted_at
      })

    InteractionRegistry.put(interaction)
  end
end
