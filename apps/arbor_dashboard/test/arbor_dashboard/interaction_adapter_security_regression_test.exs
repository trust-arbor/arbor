defmodule Arbor.Dashboard.InteractionAdapterSecurityRegressionTest do
  @moduledoc """
  Security regression: dashboard HITL prompts must reach a live subscriber.

  `Arbor.Dashboard.InteractionAdapter` broadcasts on
  `dashboard:interactions:<user_id>`. ChatLive was the only subscriber and
  was removed on 2026-10-08. ConversationLive is the routed consumer and
  must subscribe to that exact topic so approvals and questions are not
  silently dropped.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Dashboard.InteractionAdapter
  alias Arbor.Dashboard.Live.ConversationLive

  setup_all do
    {:ok, pubsub: pubsub_or_start()}
  end

  test "security regression: ConversationLive is subscribed to the adapter topic and receives broadcasts" do
    user_id = "human_hitl_#{System.unique_integer([:positive])}"
    topic = InteractionAdapter.topic_for_user(user_id)

    {:module, ConversationLive} = Code.ensure_loaded(ConversationLive)
    assert function_exported?(ConversationLive, :subscribe_interactions, 1)
    assert function_exported?(InteractionAdapter, :subscribe, 1)

    assert :ok = ConversationLive.subscribe_interactions(user_id)

    {:ok, interaction} =
      Interaction.new(%{
        kind: :approval,
        agent_id: "agent_hitl",
        user_id: user_id,
        description: "Approve the dashboard delivery?"
      })

    assert :ok = InteractionAdapter.send_interaction(%{}, interaction)

    assert_receive {:dashboard_interaction, %Interaction{} = received}, 1_000
    assert received.request_id == interaction.request_id
    assert received.user_id == user_id
    assert received.kind == :approval
    assert received.description == "Approve the dashboard delivery?"
    assert topic == "dashboard:interactions:" <> user_id
  end

  defp pubsub_or_start do
    cond do
      Process.whereis(Arbor.Comms.PubSub) ->
        Arbor.Comms.PubSub

      Process.whereis(Arbor.Dashboard.PubSub) ->
        Arbor.Dashboard.PubSub

      true ->
        case Supervisor.start_link(
               [{Phoenix.PubSub, name: Arbor.Comms.PubSub}],
               strategy: :one_for_one,
               name: :"Arbor.Dashboard.InteractionAdapterSecurityRegressionTest.PubSubRoot"
             ) do
          {:ok, _} -> Arbor.Comms.PubSub
          {:error, {:already_started, _}} -> Arbor.Comms.PubSub
        end
    end
  end
end
