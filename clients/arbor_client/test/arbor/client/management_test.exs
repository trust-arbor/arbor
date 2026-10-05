defmodule Arbor.Client.ManagementTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  alias Arbor.Client
  alias Arbor.Client.Login.Session

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)

    identity = %{
      agent_id: "agent_" <> Base.encode16(:crypto.hash(:sha256, public), case: :lower),
      private_key: private
    }

    %{identity: identity, public: public}
  end

  test "public signed HTTP operations use exact method path and body with fresh nonces", ctx do
    rows = [
      %{
        agent_id: "agent_fixture",
        display_name: "Cedar",
        template: "test",
        model: "sealed",
        running: false
      }
    ]

    replies = [
      %{agents: rows},
      %{agent_id: "agent_fixture"},
      %{aliases: %{cedar: "agent_fixture"}},
      %{name: "cedar", agent_id: "agent_fixture"},
      %{name: "cedar", removed: true},
      %{agent_id: "agent_new", display_name: "New cedar", running: true},
      %{agent_id: "agent_fixture", running: true},
      %{agent_id: "agent_fixture", running: false}
    ]

    {peer, url} = peer(Enum.map(replies, &response/1))

    assert {:ok, %{agents: [%{display_name: "Cedar"}], truncated: false}} =
             Client.list_agents(ctx.identity, url)

    assert {:ok, "agent_fixture"} = Client.resolve_agent(ctx.identity, url, "cedar /% 雪")

    assert {:ok, %{aliases: [%{name: "cedar"}], truncated: false}} =
             Client.list_aliases(ctx.identity, url)

    assert {:ok, %{name: "cedar"}} = Client.set_alias(ctx.identity, url, "cedar", "Cedar")
    assert {:ok, %{removed: true}} = Client.remove_alias(ctx.identity, url, "cedar")

    assert {:ok, %{agent_id: "agent_new"}} =
             Client.create_agent(ctx.identity, url, %{template: "test", name: "New cedar"})

    assert {:ok, %{running: true}} = Client.start_agent(ctx.identity, url, "agent_fixture")
    assert {:ok, %{running: false}} = Client.stop_agent(ctx.identity, url, "agent_fixture")

    expected = [
      {"GET", "/api/chat/agents", ""},
      {"GET", "/api/chat/agents/resolve/cedar%20%2F%25%20%E9%9B%AA", ""},
      {"GET", "/api/chat/aliases", ""},
      {"POST", "/api/chat/aliases", Jason.encode!(%{name: "cedar", target: "Cedar"})},
      {"DELETE", "/api/chat/aliases/cedar", ""},
      {"POST", "/api/chat/agents", Jason.encode!(%{template: "test", name: "New cedar"})},
      {"POST", "/api/chat/agents/agent_fixture/start", "{}"},
      {"POST", "/api/chat/agents/agent_fixture/stop", "{}"}
    ]

    nonces =
      for {fingerprint, index} <- Enum.with_index(expected, 1) do
        assert_receive {:request, ^peer, ^index, request}, 1_000
        {method, path, headers, body} = parse_request(request)
        assert {method, path, body} == fingerprint
        assert "Signature " <> encoded = headers["authorization"]
        envelope = encoded |> Base.decode64!(padding: false) |> Jason.decode!()
        assert envelope["agent_id"] == ctx.identity.agent_id
        nonce = Base.decode64!(envelope["nonce"])
        payload = method <> "\n" <> path <> "\n" <> body

        signed =
          prefix(payload) <>
            prefix(ctx.identity.agent_id) <> prefix(envelope["timestamp"]) <> nonce

        assert :crypto.verify(:eddsa, :sha512, signed, Base.decode64!(envelope["signature"]), [
                 ctx.public,
                 :ed25519
               ])

        assert_receive {:closed, ^peer, ^index, {:error, :closed}}, 1_000
        nonce
      end

    assert length(Enum.uniq(nonces)) == 8
  end

  test "security regression: conversation leases and caller authority hints never dispatch HTTP",
       ctx do
    {peer, url} = peer([response(%{agents: []})])

    for identity <- [
          %Session{
            principal: "human_fixture",
            target: "agent_fixture",
            credential: String.duplicate("x", 43),
            lifetime: :connection
          },
          "bearer",
          %{credential: "secret"},
          Map.put(ctx.identity, :identity_verified, true)
        ] do
      assert {:error, :invalid_identity} = Client.list_agents(identity, url)
    end

    for opts <- [
          [authorization: "Bearer secret"],
          [identity_verified: true],
          [timeout_ms: 0],
          [max_entries: 101],
          [max_entries: 1, max_entries: 2],
          %{},
          [{"timeout_ms", 1}]
        ] do
      assert {:error, :invalid_options} = Client.list_agents(ctx.identity, url, opts)
    end

    for input <- [nil, <<255>>, "", String.duplicate("x", 257), "cedar\e[2J"] do
      assert {:error, :invalid_options} = Client.resolve_agent(ctx.identity, url, input)
      assert {:error, :invalid_options} = Client.stop_agent(ctx.identity, url, input)
    end

    for params <- [
          %{},
          %{template: "test", session_token: "secret"},
          %{template: "test", name: <<255>>}
        ] do
      assert {:error, :invalid_options} = Client.create_agent(ctx.identity, url, params)
    end

    assert {:error, :unsafe_gateway_url} =
             Client.list_agents(ctx.identity, "http://remote.example")

    refute_receive {:request, ^peer, _, _}, 100
  end

  test "bounded catalogs retain explicit truncation and reject duplicate or malformed rows",
       ctx do
    rows =
      for n <- 1..4,
          do: %{
            agent_id: "agent_#{n}",
            display_name: "Cedar #{n}",
            template: "test",
            model: "sealed",
            running: false
          }

    [first | _] = rows

    {peer, url} =
      peer([
        response(%{agents: rows}),
        response(%{aliases: %{a: "agent_1", b: "agent_2"}}),
        response(%{agents: [first, first]}),
        response_raw(~s({"aliases":{"a":"agent_1","a":"agent_2"}})),
        response(%{agents: [Map.put(first, :secret, "forbidden")]})
      ])

    assert {:ok, %{agents: [_, _], truncated: true}} =
             Client.list_agents(ctx.identity, url, max_entries: 2)

    assert {:ok, %{aliases: [%{name: "a"}], truncated: true}} =
             Client.list_aliases(ctx.identity, url, max_entries: 1)

    assert {:error, :invalid_response} = Client.list_agents(ctx.identity, url)
    assert {:error, :invalid_response} = Client.list_aliases(ctx.identity, url)
    assert {:error, :invalid_response} = Client.list_agents(ctx.identity, url)
    for index <- 1..5, do: assert_receive({:closed, ^peer, ^index, {:error, :closed}}, 1_000)
  end

  test "mutation timeout is uncertain, closes transport, preserves unrelated mail, and never retries",
       ctx do
    {peer, url} = peer([{:stall, "HTTP/1.1 200 OK\r\n"}])
    send(self(), {:unrelated, :keep})
    started = System.monotonic_time(:millisecond)

    assert {:error, :management_unconfirmed} =
             Client.stop_agent(ctx.identity, url, "agent_fixture", timeout_ms: 60)

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:unrelated, :keep}
    assert_receive {:request, ^peer, 1, _}, 1_000
    assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
    refute_receive {:request, ^peer, _, _}, 100
    {peer, url} = peer([{:stall, "HTTP/1.1 200 OK\r\n"}])
    assert {:error, :timeout} = Client.list_agents(ctx.identity, url, timeout_ms: 60)
    assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
  end

  test "owner death and response budgets close actual sockets", ctx do
    {peer, url} = peer([{:stall, "HTTP/1.1 200 OK\r\n"}])
    {worker, monitor} = spawn_monitor(fn -> Client.list_agents(ctx.identity, url) end)
    assert_receive {:request, ^peer, 1, _}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000

    for raw <- [
          response_raw(String.duplicate("x", 131_073)),
          "HTTP/1.1 200 OK\r\nx-unfinished: " <> String.duplicate("x", 262_145)
        ] do
      {peer, url} = peer([raw])
      assert {:error, :response_too_large} = Client.list_agents(ctx.identity, url)
      assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
    end
  end

  test "known refusal is distinct from uncertain mutation and no private server body is returned",
       ctx do
    {peer, url} =
      peer([
        response(%{error: "approval required: secret"}, 403),
        response(%{error: "unauthorized: secret"}, 403),
        response(%{error: "ambiguous secret"}, 409),
        response(%{error: "not found secret"}, 404),
        response(%{agent_id: "agent_wrong", running: false}),
        response_raw("secret", 302)
      ])

    assert {:error, :approval_required} =
             Client.create_agent(ctx.identity, url, %{template: "test"})

    assert {:error, :unauthorized} = Client.stop_agent(ctx.identity, url, "agent_fixture")
    assert {:error, :ambiguous} = Client.resolve_agent(ctx.identity, url, "cedar")
    assert {:error, :not_found} = Client.resolve_agent(ctx.identity, url, "cedar")

    assert {:error, :management_unconfirmed} =
             Client.stop_agent(ctx.identity, url, "agent_fixture")

    assert {:error, :management_unconfirmed} =
             Client.start_agent(ctx.identity, url, "agent_fixture")

    for index <- 1..6, do: assert_receive({:closed, ^peer, ^index, {:error, :closed}}, 1_000)
  end

  defp prefix(value), do: <<byte_size(value)::32, value::binary>>
  defp response(value, status \\ 200), do: response_raw(Jason.encode!(value), status)

  defp response_raw(body, status \\ 200),
    do:
      "HTTP/1.1 #{status} Response\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"

  defp parse_request(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [line | headers] = String.split(head, "\r\n")
    [method, path, _] = String.split(line, " ")

    headers =
      Map.new(headers, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(k), String.trim(v)}
      end)

    {method, path, headers, body}
  end

  defp peer(responses) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    owner = self()

    peer =
      spawn(fn ->
        try do
          for {response, index} <- Enum.with_index(responses, 1) do
            case :gen_tcp.accept(listener, 5_000) do
              {:ok, socket} ->
                try do
                  send(owner, {:request, self(), index, read_request(socket, "")})

                  raw =
                    case response do
                      {:stall, bytes} -> bytes
                      bytes -> bytes
                    end

                  :gen_tcp.send(socket, raw)
                  send(owner, {:closed, self(), index, :gen_tcp.recv(socket, 0, 5_000)})
                after
                  :gen_tcp.close(socket)
                end

              {:error, :closed} ->
                :ok
            end
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer), do: Process.exit(peer, :kill)
    end)

    {peer, "http://127.0.0.1:#{port}"}
  end

  defp read_request(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {offset, 4} ->
        head = binary_part(buffer, 0, offset)

        length =
          case Regex.run(~r/content-length: (\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(buffer) >= offset + 4 + length, do: buffer, else: more(socket, buffer)

      :nomatch ->
        more(socket, buffer)
    end
  end

  defp more(socket, buffer) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    read_request(socket, buffer <> bytes)
  end
end
