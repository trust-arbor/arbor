defmodule ConversationKit.Arbor.Gateway.NoticeSocketTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Gateway
  alias ConversationKit.Arbor.GatewayTest.Server
  @moduletag :fast
  @moduletag :integration
  @page Jason.decode!(File.read!(Path.join(__DIR__, "support/notice_page.json")))

  setup do
    {_public, key} = :crypto.generate_key(:eddsa, :ed25519)
    {server, url} = Server.start(self())
    on_exit(fn -> Process.exit(server, :kill) end)

    {:ok, remote} =
      Gateway.start_link(
        identity: %{agent_id: "human_linked_alias", private_key: key},
        target: @page["target_agent_id"],
        gateway_url: url,
        request_timeout_ms: 1_000
      )

    on_exit(fn -> Gateway.close(remote) end)
    {:ok, options} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(
        options[:caller],
        options[:target],
        options[:proof_provider],
        options[:adapter_options]
      )

    %{remote: remote, client: client}
  end

  defp attach(client) do
    task = Task.async(fn -> Arbor.window(client) end)
    assert_receive {:upgraded, channel, _}, 2_000
    assert_receive {:frame, ^channel, request}, 2_000

    send(
      channel,
      {:reply,
       %{
         type: "conversation_window",
         data: %{
           agent_id: @page["target_agent_id"],
           engagement_id: @page["engagement_id"],
           entries: [
             %{
               id: "message",
               role: "assistant",
               content: "Socket transcript",
               timestamp: "2026-10-03T00:00:00Z",
               entry_ordinal: 1
             }
           ],
           head: 1,
           first: 1,
           last: 1,
           has_older: false,
           has_newer: false
         }
       }}
    )

    assert {:ok, attached, _} = Task.await(task)
    {attached, channel, request}
  end

  defp roundtrip(channel, call, response) do
    task = Task.async(call)
    assert_receive {:frame, ^channel, request}, 2_000
    send(channel, {:reply, response})
    {Task.await(task), request}
  end

  test "actual SDK socket signs a fresh exact notice domain, keeps original recipient private and never publishes on reconnect",
       %{client: client} do
    {client, channel, window_request} = attach(client)

    {{:ok, read, _}, notice_request} =
      roundtrip(channel, fn -> Arbor.notices(client, before: 2, through: 1, limit: 1) end, %{
        type: "conversation_notices",
        data: @page
      })

    assert Jason.decode!(notice_request["payload"]) == [
             "arbor.conversation.notices.v1",
             "human_linked_alias",
             @page["target_agent_id"],
             [2, 1, 1],
             @page["engagement_id"]
           ]

    assert String.starts_with?(notice_request["authorization"], "Signature ")
    assert notice_request["authorization"] != window_request["authorization"]
    assert read.owner == @page["owner_id"]
    assert [%{"text" => "Socket transcript"}] = Arbor.projection(read)["messages"]
    assert [%{"kind" => "progress"}] = Arbor.projection(read)["notices"]
    assert Arbor.projection(read)["speech"] == []
    refute inspect(Arbor.projection(read)) =~ "recipient_subject_id"
    refute_receive {:frame, ^channel, _}, 100
  end

  test "malformed notice and unsupported-subject frames retain the actual channel for a later independently signed read",
       %{client: client} do
    {client, channel, _} = attach(client)

    {{:error, :invalid_notice_response}, bad_request} =
      roundtrip(channel, fn -> Arbor.notices(client) end, %{
        type: "conversation_notices",
        data: nil
      })

    refute_receive {:channel_closed, ^channel}, 50

    {{:error, :notice_subject_required}, unsupported_request} =
      roundtrip(channel, fn -> Arbor.notices(client) end, %{
        type: "error",
        reason: "notice_subject_required"
      })

    refute_receive {:channel_closed, ^channel}, 50

    {{:ok, read, _}, fresh_request} =
      roundtrip(channel, fn -> Arbor.notices(client) end, %{
        type: "conversation_notices",
        data: @page
      })

    assert length(
             Enum.uniq([
               bad_request["authorization"],
               unsupported_request["authorization"],
               fresh_request["authorization"]
             ])
           ) == 3

    assert Arbor.projection(read)["messages"] != []
    refute_receive {:frame, ^channel, _}, 100
  end

  test "valid foreign scope closes actual channel and an old client cannot silently reopen or replay the read",
       %{client: client} do
    {client, channel, _} = attach(client)
    foreign = %{@page | "target_agent_id" => "agent_foreign", "notices" => []}

    {{:error, :conversation_scope_changed}, _} =
      roundtrip(channel, fn -> Arbor.notices(client) end, %{
        type: "conversation_notices",
        data: foreign
      })

    assert_receive {:channel_closed, ^channel}, 2_000
    assert {:error, :transport_not_attached} = Arbor.notices(client)
    refute_receive {:frame, _, _}, 100
  end
end
