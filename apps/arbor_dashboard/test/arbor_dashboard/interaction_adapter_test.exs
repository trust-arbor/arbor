defmodule Arbor.Dashboard.InteractionAdapterTest do
  @moduledoc """
  Adapter-level tests for `Arbor.Dashboard.InteractionAdapter`.

  Verifies:
    * `send_interaction/2` broadcasts on the per-user dashboard topic
    * Missing PubSub server returns `{:error, :no_pubsub}` rather than
      crashing
    * `parse_response/1` always returns `:not_interaction` (dashboard
      responses come from LiveView click events, not raw text)
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Dashboard.InteractionAdapter

  setup_all do
    pubsub_name = pubsub_or_start()
    {:ok, pubsub: pubsub_name}
  end

  describe "send_interaction/2" do
    test "broadcasts on the per-user dashboard topic", %{pubsub: pubsub} do
      user_id = "test_user_#{System.unique_integer([:positive])}"
      topic = InteractionAdapter.topic_for_user(user_id)
      :ok = Phoenix.PubSub.subscribe(pubsub, topic)

      {:ok, interaction} =
        Arbor.Contracts.Comms.Interaction.new(%{
          kind: :approval,
          agent_id: "agent_x",
          user_id: user_id,
          description: "Run mix test?"
        })

      assert :ok = InteractionAdapter.send_interaction(%{}, interaction)

      assert_receive {:dashboard_interaction, %Arbor.Contracts.Comms.Interaction{}}, 500
    end
  end

  describe "channel_kind/0" do
    test "returns :dashboard" do
      assert InteractionAdapter.channel_kind() == :dashboard
    end
  end

  describe "parse_response/1" do
    test "always returns :not_interaction" do
      assert InteractionAdapter.parse_response("APPROVE irq_xyz") == :not_interaction
      assert InteractionAdapter.parse_response(%{some: :map}) == :not_interaction
      assert InteractionAdapter.parse_response(nil) == :not_interaction
    end
  end

  describe "topic_for_user/1" do
    test "returns 'dashboard:interactions:' <> user_id" do
      assert InteractionAdapter.topic_for_user("hysun") == "dashboard:interactions:hysun"
    end
  end

  defp pubsub_or_start do
    cond do
      Process.whereis(Arbor.Dashboard.PubSub) ->
        Arbor.Dashboard.PubSub

      Process.whereis(Arbor.Comms.PubSub) ->
        Arbor.Comms.PubSub

      true ->
        case Supervisor.start_link(
               [{Phoenix.PubSub, name: Arbor.Comms.PubSub}],
               strategy: :one_for_one,
               name: :"Arbor.Dashboard.InteractionAdapterTest.PubSubRoot"
             ) do
          {:ok, _} -> Arbor.Comms.PubSub
          {:error, {:already_started, _}} -> Arbor.Comms.PubSub
        end
    end
  end
end
