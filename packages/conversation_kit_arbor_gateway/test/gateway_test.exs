defmodule ConversationKit.Arbor.GatewayTest do
  use ExUnit.Case, async: true
  alias ConversationKit.Arbor
  alias ConversationKit.Arbor.Gateway
  alias ConversationKit.Arbor.GatewayTest.Server
  @engagement "eng_11111111111111111111111111111111"

  setup do
    {pub, key} = :crypto.generate_key(:eddsa, :ed25519)
    {server, url} = Server.start(self())
    on_exit(fn -> Process.exit(server, :kill) end)
    identity = %{agent_id: "human_test", private_key: key}
    %{identity: identity, pub: pub, url: url}
  end

  defp start(c, timeout \\ 5_000) do
    {:ok, remote} =
      Gateway.start_link(
        identity: c.identity,
        target: "agent_test",
        gateway_url: c.url,
        request_timeout_ms: timeout
      )

    {:ok, opts} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(opts[:caller], opts[:target], opts[:proof_provider], opts[:adapter_options])

    {remote, client, opts}
  end

  defp history,
    do: %{
      type: "conversation_history",
      data: %{
        agent_id: "agent_test",
        engagement_id: @engagement,
        entries: [],
        cursor: 0,
        head: 0,
        has_more: false
      }
    }

  defp events,
    do: %{
      type: "conversation_events",
      data: %{engagement_id: @engagement, events: [], cursor: 0, head: 0, has_more: false}
    }

  defp window(extra \\ %{}) do
    %{
      type: "conversation_window",
      data:
        Map.merge(
          %{
            agent_id: "agent_test",
            engagement_id: @engagement,
            entries: [
              %{
                id: "host_12",
                role: "assistant",
                content: "Host window message",
                timestamp: "2026-10-02T00:00:00Z",
                entry_ordinal: 12
              }
            ],
            head: 12,
            first: 12,
            last: 12,
            has_older: true,
            has_newer: false
          },
          extra
        )
    }
  end

  defp attach_window(client, reply \\ window()) do
    task = Task.async(fn -> Arbor.window(client, limit: 20) end)
    assert_receive {:upgraded, channel, _}, 2_000
    assert_receive {:frame, ^channel, request}, 2_000
    send(channel, {:reply, reply})
    assert_receive {:reply_sent, ^channel, :ok}
    {Task.await(task), channel, request}
  end

  defp attach(client, unsolicited \\ nil) do
    task = Task.async(fn -> Arbor.sync(client) end)
    assert_receive {:upgraded, channel, _}, 2_000
    assert_receive {:frame, ^channel, history_request}, 2_000
    send(channel, {:reply, history()})
    assert_receive {:reply_sent, ^channel, :ok}
    assert_receive {:frame, ^channel, events_request}, 2_000

    if unsolicited,
      do: send(channel, {:reply_and_push, events(), unsolicited}),
      else: send(channel, {:reply, events()})

    assert_receive {:reply_sent, ^channel, :ok}, 1_000
    assert {:ok, next} = Task.await(task)
    {next, channel, history_request, events_request}
  end

  test "actual Socket channel uses fresh signatures and explicit fenced reattachment", c do
    {remote, client, opts} = start(c)
    {attached, old_channel, first, second} = attach(client)
    refute first["authorization"] == second["authorization"]
    assert_signed(first, c.pub)
    assert_signed(second, c.pub)

    assert ["arbor.conversation.v2", "events", "human_test", "agent_test", 0, _, @engagement] =
             Jason.decode!(second["payload"])

    assert :ok = opts[:disconnect].()
    assert {:error, :transport_not_attached} = Arbor.command(attached, "id1")
    refute_receive {:frame, _, _}, 20
    {_next, new_channel, reconnect, _} = attach(attached)
    refute old_channel == new_channel
    assert List.last(Jason.decode!(reconnect["payload"])) == @engagement
    assert :ok = Gateway.close(remote)
  end

  test "a stopped-agent submit rejection reaches the public adapter without replay", c do
    {remote, client, _opts} = start(c)
    {attached, channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.submit(attached, "stopped_remote", "Keep this draft") end)
    assert_receive {:frame, ^channel, request}, 2_000
    assert_signed(request, c.pub)

    assert ["arbor.conversation.v2", "submit", "human_test", "agent_test", input, _, @engagement] =
             Jason.decode!(request["payload"])

    assert input == ["stopped_remote", "Keep this draft"]

    send(channel, {
      :reply,
      %{type: "conversation_rejected", data: %{id: "stopped_remote", reason: "agent_not_running"}}
    })

    assert {:error, :agent_not_running} = Task.await(task)
    assert Arbor.position(attached) == %{history: 0, commands: 0}
    assert Arbor.projection(attached)["messages"] == []
    assert Arbor.projection(attached)["deliveries"] == []
    refute_receive {:frame, _, _}
    refute_receive {:channel_closed, ^channel}
    assert :ok = Gateway.close(remote)
  end

  test "security regression: stopped-agent rejection with a different ID retires the channel",
       c do
    {remote, client, _opts} = start(c)
    {attached, channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.submit(attached, "expected_id", "Keep this draft") end)
    assert_receive {:frame, ^channel, _request}, 2_000

    send(channel, {
      :reply,
      %{type: "conversation_rejected", data: %{id: "another_id", reason: "agent_not_running"}}
    })

    assert {:error, :invalid_transport_response} = Task.await(task)
    assert_receive {:channel_closed, ^channel}, 2_000
    refute_receive {:frame, _, _}
    assert :ok = Gateway.close(remote)
  end

  test "bounded window startup attaches the signed socket without replaying transcript or journal",
       c do
    {remote, client, opts} = start(c)
    {{:ok, attached, metadata}, old_channel, request} = attach_window(client)
    assert_signed(request, c.pub)

    assert Jason.decode!(request["payload"]) ==
             [
               "arbor.conversation.window.v1",
               "human_test",
               "agent_test",
               [nil, nil, nil, 20],
               nil
             ]

    assert metadata == %{head: 12, first: 12, last: 12, has_older: true, has_newer: false}

    assert [%{"id" => "host_12", "ordinal" => 12, "text" => "Host window message"}] =
             Arbor.projection(attached)["messages"]

    assert Arbor.position(attached) == %{history: 12, commands: 0}
    refute_receive {:frame, ^old_channel, _}, 20

    :ok = opts[:disconnect].()
    {{:ok, reattached, _}, new_channel, reconnect} = attach_window(attached)
    refute new_channel == old_channel
    assert List.last(Jason.decode!(reconnect["payload"])) == @engagement
    assert_signed(reconnect, c.pub)
    assert Arbor.projection(reattached) == Arbor.projection(attached)
    refute_receive {:frame, ^new_channel, _}, 20
    assert :ok = Gateway.close(remote)
  end

  test "tampered window target retires its real channel and a fresh read recovers", c do
    {remote, client, _opts} = start(c)

    {{:error, :invalid_transport_response}, old_channel, _request} =
      attach_window(client, window(%{agent_id: "agent_other"}))

    assert_receive {:channel_closed, ^old_channel}, 2_000
    assert Arbor.projection(client)["messages"] == []
    {{:ok, recovered, _}, new_channel, _request} = attach_window(client)
    refute old_channel == new_channel
    assert [%{"id" => "host_12"}] = Arbor.projection(recovered)["messages"]
    assert :ok = Gateway.close(remote)
  end

  test "a window owner change cannot replace or submit through the established client scope", c do
    {remote, client, _opts} = start(c)
    {{:ok, attached, _}, channel, _request} = attach_window(client)
    task = Task.async(fn -> Arbor.window(attached, before: 12, through: 12, limit: 20) end)
    assert_receive {:frame, ^channel, request}, 2_000

    assert Jason.decode!(request["payload"]) ==
             [
               "arbor.conversation.window.v1",
               "human_test",
               "agent_test",
               [12, nil, 12, 20],
               @engagement
             ]

    send(channel, {:reply, window(%{engagement_id: "eng_22222222222222222222222222222222"})})
    assert {:error, :conversation_scope_changed} = Task.await(task)
    assert [%{"id" => "host_12"}] = Arbor.projection(attached)["messages"]

    assert {:error, :conversation_scope_changed} =
             Arbor.submit(attached, "same-scope", "must not send")

    refute_receive {:frame, ^channel, _}, 30
    assert :ok = Gateway.close(remote)
  end

  test "security regression: timeout retires channel and late response cannot satisfy another operation",
       c do
    {remote, client, _opts} = start(c, 2_000)
    {attached, old_channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.command(attached, "timed-out") end)
    assert_receive {:frame, ^old_channel, _}, 1_000
    assert {:error, :transport_timeout} = Task.await(task)
    send(old_channel, {:reply, %{type: "error", reason: "not_found"}})
    # Reattachment is a new TCP/WebSocket generation. Old frame/errors cannot
    # satisfy either new history or events request.
    {_next, new_channel, _, _} = attach(attached)
    refute old_channel == new_channel
    assert :ok = Gateway.close(remote)
  end

  test "concurrent operation is refused while exactly one wire request is unresolved", c do
    {remote, client, _opts} = start(c)
    {attached, channel, _, _} = attach(client)
    pending = Task.async(fn -> Arbor.command(attached, "first") end)
    assert_receive {:frame, ^channel, frame}
    assert Enum.at(Jason.decode!(frame["payload"]), 4) == "first"
    assert {:error, :transport_busy} = Arbor.command(attached, "second")
    refute_receive {:frame, _, _}, 20
    send(channel, {:reply, %{type: "error", reason: "not_found"}})
    assert {:error, :not_found} = Task.await(pending)
    assert :ok = Gateway.close(remote)
  end

  test "security regression: queued submit past its deadline never reaches the socket", c do
    {remote, client, opts} = start(c, 2_000)
    {_attached, _channel, _, _} = attach(client)

    context = %{
      caller: "human_test",
      target: "agent_test",
      operation: :submit,
      input: %{id: "expired-submit", text: "must not execute"},
      options: [expected_engagement_id: @engagement]
    }

    assert {:ok, proof} = opts[:proof_provider].(context)
    transport = opts[:adapter_options][:transport]
    :ok = :sys.suspend(remote)

    try do
      pending = Task.async(fn -> transport.(context, proof) end)
      assert {:error, :transport_timeout} = Task.await(pending, 4_000)
    after
      :sys.resume(remote)
    end

    # This call is a barrier after the expired queued request has been checked.
    assert {:ok, _} = Gateway.client_options(remote)
    refute_receive {:frame, _, _}, 30
    assert :ok = Gateway.close(remote)
  end

  @tag :terminal_credential_redaction
  test "security regression: actual remote-owner crash diagnostics redact private message and reason",
       c do
    {remote, _client, _opts} = start(c)
    Process.unlink(remote)
    on_exit(fn -> if Process.alive?(remote), do: Process.exit(remote, :kill) end)
    credential = Base.url_encode64(:binary.copy(<<89>>, 32), padding: false)

    monitor = Process.monitor(remote)

    {{result, reason}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        result =
          try do
            GenServer.call(remote, {:unhandled_private_request, [session_token: credential]})
          catch
            :exit, _ -> :owner_exited
          end

        assert_receive {:DOWN, ^monitor, :process, ^remote, reason}, 1_000
        {result, reason}
      end)

    assert log =~ "terminating"
    refute log =~ credential
    assert result == {:error, :invalid_request}
    assert reason == :invalid_request
    refute Process.alive?(remote)

    synthetic =
      Gateway.format_status(%{
        state: credential,
        message: credential,
        reason: credential,
        log: [credential]
      })

    refute inspect(synthetic) =~ credential
  end

  test "session mode keeps credential at upgrade and binds every operation to the owned session",
       c do
    credential = Base.url_encode64(:binary.copy(<<19>>, 32), padding: false)

    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: credential,
      lifetime: :connection
    }

    assert {:ok, remote} =
             Gateway.start_link(session: session, target: "agent_test", gateway_url: c.url)

    assert {:ok, opts} = Gateway.client_options(remote)
    assert opts[:caller] == session.principal

    assert {:ok, client} =
             Arbor.new(
               opts[:caller],
               opts[:target],
               opts[:proof_provider],
               opts[:adapter_options]
             )

    task = Task.async(fn -> Arbor.sync(client) end)
    assert_receive {:upgraded, channel, headers}, 2_000
    assert headers =~ "authorization: Conversation " <> credential
    assert_receive {:frame, ^channel, first}, 2_000
    assert Enum.sort(Map.keys(first)) == ["authentication", "payload"]
    assert first["authentication"] == "conversation_session"
    refute Jason.encode!(first) =~ credential
    send(channel, {:reply, history()})
    assert_receive {:frame, ^channel, second}, 2_000
    assert second["authentication"] == "conversation_session"
    send(channel, {:reply, events()})
    assert {:ok, attached} = Task.await(task)
    assert Arbor.position(attached) == %{history: 0, commands: 0}

    context = %{
      caller: "human_test",
      target: "agent_test",
      operation: :command,
      input: "id1",
      options: [expected_engagement_id: @engagement]
    }

    assert {:error, :unauthorized} =
             opts[:adapter_options][:transport].(context, session_token: "other")

    refute_receive {:frame, ^channel, _}, 100
    refute inspect(:sys.get_status(remote), limit: :infinity) =~ credential
    assert :ok = Gateway.close(remote)
  end

  test "session target and mutually exclusive authentication modes are checked before startup",
       c do
    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: Base.url_encode64(:binary.copy(<<19>>, 32), padding: false),
      lifetime: :connection
    }

    assert {:error, :invalid_options} =
             Gateway.start_link(session: session, target: "agent_other", gateway_url: c.url)

    assert {:error, :invalid_options} =
             Gateway.start_link(
               identity: c.identity,
               session: session,
               target: "agent_test",
               gateway_url: c.url
             )

    assert {:error, :invalid_options} =
             Gateway.start_link(
               session: %{session | lifetime: :unknown},
               target: "agent_test",
               gateway_url: c.url
             )

    refute_receive {:upgraded, _, _}, 100
  end

  @tag :terminal_idle_authloss
  test "security regression: unsolicited session revocation latches unauthorized until a new login",
       c do
    {remote, client, opts} = start_session(c)
    {attached, channel, _, _} = attach(client, %{type: "error", reason: "unauthorized"})
    assert_receive {:channel_closed, ^channel}, 2_000

    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
    assert :ok = opts[:disconnect].()
    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
    assert Arbor.position(attached) == %{history: 0, commands: 0}
    refute_receive {:upgraded, _, _}, 100
    refute_receive {:frame, _, _}, 100
    assert :ok = Gateway.close(remote)
  end

  test "session authorization loss after a sent submit stays uncertain and is never replayed",
       c do
    {remote, client, opts} = start_session(c)
    {attached, channel, _, _} = attach(client)
    task = Task.async(fn -> Arbor.submit(attached, "stable-uncertain", "one effect at most") end)
    assert_receive {:frame, ^channel, request}, 2_000

    assert ["arbor.conversation.v2", "submit", "human_test", "agent_test", input, _, @engagement] =
             Jason.decode!(request["payload"])

    assert input == ["stable-uncertain", "one effect at most"]
    # Exercise ordinary response decoding beyond the small idle-control fast path.
    revoked =
      String.duplicate(" ", 257) <> Jason.encode!(%{type: "error", reason: "unauthorized"})

    send(channel, {:reply, revoked})
    assert {:error, :unauthorized} = Task.await(task)
    assert_receive {:channel_closed, ^channel}, 2_000
    assert :ok = opts[:disconnect].()

    assert {:error, :unauthorized} =
             Arbor.submit(attached, "stable-uncertain", "one effect at most")

    assert {:error, :unauthorized} = Arbor.sync(attached)
    assert Arbor.position(attached) == %{history: 0, commands: 0}
    refute_receive {:upgraded, _, _}, 100
    refute_receive {:frame, _, _}, 100
    assert :ok = Gateway.close(remote)
  end

  test "unsolicited conversation data and signed-mode authorization events remain invalid", c do
    for {mode, unsolicited} <- [
          {:session, history()},
          {:session, %{type: "error", reason: "unauthorized", extra: "not a control envelope"}},
          {:signature, %{type: "error", reason: "unauthorized"}}
        ] do
      {remote, client, _opts} = if mode == :session, do: start_session(c), else: start(c)
      {attached, channel, _, _} = attach(client, unsolicited)
      assert_receive {:channel_closed, ^channel}, 2_000
      assert {:error, :invalid_transport_response} = Arbor.sync(attached)
      refute_receive {:upgraded, _, _}, 50
      refute_receive {:frame, _, _}, 50
      assert :ok = Gateway.close(remote)
    end
  end

  test "session upgrade rejection latches unauthorized without sending a conversation operation",
       c do
    for status <- [401, 403] do
      {server, url} = Server.start(self(), status)
      on_exit(fn -> Process.exit(server, :kill) end)
      {remote, client, opts} = start_session(%{c | url: url})
      assert {:error, :unauthorized} = Arbor.sync(client)
      assert_receive {:upgrade_refused, _, ^status}, 2_000
      assert {:error, :unauthorized} = opts[:proof_provider].(history_context())
      assert :ok = opts[:disconnect].()
      assert {:error, :unauthorized} = Arbor.sync(client)
      refute_receive {:upgrade_refused, _, _}, 100
      refute_receive {:frame, _, _}, 100
      assert :ok = Gateway.close(remote)
    end
  end

  defp start_session(c) do
    session = %{
      principal: "human_test",
      target: "agent_test",
      credential: Base.url_encode64(:binary.copy(<<29>>, 32), padding: false),
      lifetime: :connection
    }

    {:ok, remote} =
      Gateway.start_link(session: session, target: session.target, gateway_url: c.url)

    {:ok, opts} = Gateway.client_options(remote)

    {:ok, client} =
      Arbor.new(opts[:caller], opts[:target], opts[:proof_provider], opts[:adapter_options])

    {remote, client, opts}
  end

  defp history_context,
    do: %{
      caller: "human_test",
      target: "agent_test",
      operation: :history,
      input: nil,
      options: []
    }

  defp assert_signed(%{"payload" => payload, "authorization" => "Signature " <> encoded}, pub) do
    auth = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
    nonce = Base.decode64!(auth["nonce"])
    signature = Base.decode64!(auth["signature"])

    fields =
      for value <- [payload, auth["agent_id"], auth["timestamp"]],
          into: <<>>,
          do: <<byte_size(value)::32, value::binary>>

    assert :crypto.verify(:eddsa, :sha512, fields <> nonce, signature, [pub, :ed25519])
  end
end
