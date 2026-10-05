defmodule ConversationKit.Arbor.Gateway.ControlSocketTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Gateway
  alias ConversationKit.Arbor.GatewayTest.Server
  @moduletag :fast
  @moduletag :integration
  @eng "eng_11111111111111111111111111111111"

  setup do
    {_public, key} = :crypto.generate_key(:eddsa, :ed25519)
    {server, url} = Server.start(self())
    on_exit(fn -> Process.exit(server, :kill) end)
    %{url: url, identity: %{agent_id: "human_test", private_key: key}}
  end

  defp start(c, auth) do
    {:ok, remote} =
      Gateway.start_link(
        auth ++ [target: "agent_test", gateway_url: c.url, request_timeout_ms: 1000]
      )

    on_exit(fn -> Gateway.close(remote) end)
    {:ok, opts} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(opts[:caller], opts[:target], opts[:proof_provider], opts[:adapter_options])

    {remote, client, opts}
  end

  defp attach(client) do
    task = Task.async(fn -> Arbor.window(client) end)
    assert_receive {:upgraded, channel, _}, 2000
    assert_receive {:frame, ^channel, request}, 2000

    send(
      channel,
      {:reply,
       %{
         type: "conversation_window",
         data: %{
           agent_id: "agent_test",
           engagement_id: @eng,
           entries: [],
           head: 0,
           first: 0,
           last: 0,
           has_older: false,
           has_newer: false
         }
       }}
    )

    assert {:ok, attached, _} = Task.await(task)
    {attached, channel, request}
  end

  defp roundtrip(channel, fun, reply) do
    task = Task.async(fun)
    assert_receive {:frame, ^channel, request}, 2000
    send(channel, {:reply, reply})
    {Task.await(task), request}
  end

  defp activity,
    do: %{
      agent_id: "agent_test",
      engagement_id: @eng,
      commands: [
        %{
          command_id: "cmd",
          task_id: "private_task",
          delivery_status: "dispatch_started",
          cancellation: %{status: "none"},
          admitted_cursor: 1,
          execution: "running"
        }
      ],
      source_watermark: 1,
      index_watermark: 1,
      incomplete: false,
      has_more: false,
      next_cursor: nil,
      truncated: false
    }

  defp input,
    do: %{
      command_id: "cmd",
      request_id: "request",
      operation_id: "operation",
      revision: 1,
      choice_id: "choice"
    }

  test "actual Socket control calls acquire fresh signed exact-operation payloads and correlate empty lists",
       c do
    {_remote, client, opts} = start(c, identity: c.identity)
    refute opts[:approval_answer_allowed]
    {client, channel, attach_request} = attach(client)

    {{:ok, ^client, [%{"command_id" => "cmd"}], _}, activity_request} =
      roundtrip(channel, fn -> Arbor.activity(client) end, %{
        type: "conversation_activity",
        data: activity()
      })

    {{:ok, ^client, []}, prompt_request} =
      roundtrip(channel, fn -> Arbor.interactions(client, "cmd") end, %{
        type: "conversation_interactions",
        data: %{agent_id: "agent_test", engagement_id: @eng, command_id: "cmd", interactions: []}
      })

    {{:ok, ^client, %{"cancellation" => %{"status" => "requested"}}}, cancel_request} =
      roundtrip(channel, fn -> Arbor.cancel(client, "cmd") end, %{
        type: "conversation_cancellation",
        data: %{
          agent_id: "agent_test",
          engagement_id: @eng,
          command_id: "cmd",
          task_id: "private_task",
          delivery_status: "dispatch_started",
          cancellation: %{status: "requested"},
          termination_observation: "unconfirmed"
        }
      })

    requests = [attach_request, activity_request, prompt_request, cancel_request]
    assert Enum.all?(requests, &String.starts_with?(&1["authorization"], "Signature "))
    assert length(Enum.uniq_by(requests, & &1["authorization"])) == 4

    assert [
             "arbor.conversation.activity.v1",
             "human_test",
             "agent_test",
             nil,
             [nil, nil, nil],
             @eng
           ] = Jason.decode!(activity_request["payload"])

    assert ["arbor.conversation.interactions.v1", "human_test", "agent_test", "cmd", @eng] =
             Jason.decode!(prompt_request["payload"])

    assert [
             "arbor.conversation.cancel.v1",
             "human_test",
             "agent_test",
             "cmd",
             [nil, nil, nil],
             @eng
           ] = Jason.decode!(cancel_request["payload"])
  end

  test "security regression wrong answer correlation closes actual channel and never retries on it",
       c do
    {_remote, client, _} = start(c, identity: c.identity)
    {client, channel, _} = attach(client)

    reply = %{
      type: "conversation_interaction_answer",
      data: %{
        agent_id: "agent_test",
        engagement_id: @eng,
        command_id: "cmd",
        request_id: "other",
        operation_id: "operation",
        revision: 1,
        status: "responded"
      }
    }

    {{:error, :invalid_transport_response}, request} =
      roundtrip(channel, fn -> Arbor.answer_choice(client, input()) end, reply)

    assert [
             "arbor.conversation.interaction.choice.v1",
             "human_test",
             "agent_test",
             operation,
             @eng
           ] = Jason.decode!(request["payload"])

    assert operation == ["cmd", "request", "operation", 1, "choice"]
    assert_receive {:channel_closed, ^channel}, 2000
    assert {:error, :transport_not_attached} = Arbor.interactions(client, "cmd")
    refute_receive {:frame, _, _}
  end

  test "chat-purpose lease refuses protected approval before Socket send and retains ordinary chat attachment",
       c do
    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: Base.url_encode64(:binary.copy(<<19>>, 32), padding: false),
      lifetime: :connection
    }

    {_remote, client, opts} = start(c, session: session)
    {client, channel, _} = attach(client)
    input = Map.drop(input(), [:choice_id]) |> Map.merge(%{decision: :approve, note: nil})
    assert {:error, :approval_answer_required} = Arbor.answer_approval(client, input)
    refute opts[:approval_answer_allowed]

    context = %{
      operation: :interaction_approval,
      caller: "human_test",
      target: "agent_test",
      input: input,
      options: [expected_engagement_id: @eng]
    }

    assert {:error, :approval_answer_required} =
             opts[:adapter_options][:transport].(context, session_token: session.credential)

    refute_receive {:frame, _, _}

    {{:ok, ^client, []}, request} =
      roundtrip(channel, fn -> Arbor.interactions(client, "cmd") end, %{
        type: "conversation_interactions",
        data: %{agent_id: "agent_test", engagement_id: @eng, command_id: "cmd", interactions: []}
      })

    assert request["authentication"] == "conversation_session"
    refute Jason.encode!(request) =~ session.credential
  end
end
