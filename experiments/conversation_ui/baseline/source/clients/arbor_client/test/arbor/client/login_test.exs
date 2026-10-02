defmodule Arbor.Client.LoginTest do
  use ExUnit.Case, async: true
  @moduletag :integration
  alias Arbor.Client.{Endpoint, Login}
  @token Base.url_encode64(:binary.copy(<<17>>, 32), padding: false)
  @credential Base.url_encode64(:binary.copy(<<29>>, 32), padding: false)
  @target "agent_login_target"

  defp pending do
    %{
      status: "pending",
      handle: @token,
      verification_uri: "https://identity.example/device?flow=chat",
      user_code: "ABCD-EFGH",
      expires_in: 300,
      interval: 1
    }
  end

  defp complete do
    %{
      status: "complete",
      principal: "human_login_test",
      target: @target,
      credential: @credential,
      lifetime: "connection"
    }
  end

  test "real HTTP login cycle uses fixed POST routes and credential only for logout" do
    {peer, url} =
      peer(
        Enum.map(
          [pending(), %{status: "pending"}, complete(), %{status: "closed"}, %{status: "closed"}],
          &response/1
        )
      )

    assert {:ok, flow} = Login.start(url, @target)
    assert_receive {:request, ^peer, 1, request}, 1_000
    assert request =~ "POST /api/chat/login/start HTTP/1.1"
    assert request =~ Jason.encode!(%{target: @target})
    refute String.downcase(request) =~ "authorization:"
    refute inspect(flow) =~ @token
    assert {:ok, :pending} = Login.poll(url, flow.handle)
    assert {:ok, session} = Login.poll(url, flow.handle)
    assert session.principal == "human_login_test"
    assert session.target == @target
    assert session.lifetime == :connection
    refute inspect(session) =~ @credential
    assert :ok = Login.cancel(url, flow.handle)
    assert :ok = Login.logout(url, session.credential)
    assert_receive {:request, ^peer, 5, logout}, 1_000
    assert logout =~ "POST /api/chat/login/logout HTTP/1.1"
    assert logout =~ "authorization: Conversation " <> @credential
    assert String.ends_with?(logout, "\r\n\r\n{}")
    for index <- 1..5, do: assert_receive({:closed, ^peer, ^index, {:error, :closed}}, 1_000)
  end

  @tag :localhost_verification_uri
  test "security regression: real HTTP login accepts a localhost browser verification link" do
    uri = "http://localhost:8080/device?flow=chat"
    {peer, url} = peer([response(Map.put(pending(), :verification_uri, uri))])

    assert {:ok, flow} = Login.start(url, @target)
    assert flow.verification_uri == uri
    assert_receive {:request, ^peer, 1, request}, 1_000
    assert request =~ "POST /api/chat/login/start HTTP/1.1"
    refute String.downcase(request) =~ "authorization:"
    assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
  end

  test "strict closed schemas reject unknown fields, duplicate keys and unsafe instructions" do
    malformed = [
      Map.put(pending(), :extra, @credential),
      Map.put(pending(), :interval, 0),
      Map.put(pending(), :expires_in, 301),
      Map.put(pending(), :user_code, "\e[2J"),
      Map.put(pending(), :verification_uri, "file:///private/key"),
      Map.put(pending(), :verification_uri, "https://user:secret@example.test/"),
      Map.put(pending(), :verification_uri, "http://localhost.example.test/device"),
      Map.put(pending(), :verification_uri, "http://localhost./device"),
      Map.put(pending(), :verification_uri, "http://sub.localhost/device"),
      Map.put(pending(), :verification_uri, "http://remote.example/device"),
      Map.put(pending(), :verification_uri, "http://user:secret@localhost:8080/device"),
      Map.put(pending(), :verification_uri, "http://localhost:8080/device#token"),
      Map.put(pending(), :verification_uri, "http://localhost:8080/device with space"),
      Map.put(pending(), :verification_uri, "https://identity.example:0/device"),
      Map.put(pending(), :verification_uri, "https://identity.example:65536/device"),
      Map.put(pending(), :handle, String.duplicate("x", 44))
    ]

    for body <- malformed do
      {_peer, url} = peer([response(body)])
      assert {:error, :invalid_response} = Login.start(url, @target)
    end

    {_peer, url} = peer([response_raw(~s({"status":"pending","status":"pending"}))])
    assert {:error, :invalid_response} = Login.poll(url, @token)
  end

  test "malformed or unsupported session lifetimes never become client receipts" do
    for update <- [
          %{lifetime: "forever"},
          %{lifetime: nil},
          %{expires_at: System.system_time(:second) + 900},
          %{credential: "secret\r\ninjected"},
          %{principal: "agent_not_a_human"},
          %{target: "../../elsewhere"}
        ] do
      {_peer, url} = peer([response(Map.merge(complete(), update))])
      assert {:error, :invalid_response} = Login.poll(url, @token)
    end
  end

  @tag :connection_lifetime
  test "security regression: connection lifetime is explicit and has no client-side wall-clock cutoff" do
    {_peer, url} = peer([response(complete())])
    assert {:ok, session} = Login.poll(url, @token)
    assert {:ok, ^session} = Login.session(session)
    refute Map.has_key?(Map.from_struct(session), :expires_at)

    legacy = Map.drop(complete(), [:status, :lifetime])
    legacy = Map.put(legacy, :expires_at, System.system_time(:second) + 900)
    assert {:error, :invalid_session} = Login.session(legacy)
  end

  test "redirects and provider errors are bounded errors without body or header disclosure" do
    for status <- [302, 401, 403, 500] do
      raw =
        response_raw(@credential, status, [
          {"location", "https://elsewhere.example/" <> @credential}
        ])

      {peer, url} = peer([raw])
      expected = if status in [401, 403], do: :unauthorized, else: :login_unavailable
      assert {:error, ^expected} = Login.poll(url, @token)
      assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
    end
  end

  test "body and incomplete-header wire limits close the actual HTTP connection" do
    for raw <- [
          response_raw(String.duplicate("x", 16_385)),
          "HTTP/1.1 200 OK\r\nx-unfinished: " <> String.duplicate("x", 65_537)
        ] do
      {peer, url} = peer([raw])
      assert {:error, :invalid_response} = Login.poll(url, @token)
      assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
    end
  end

  @tag :slow
  test "poll keeps one total deadline despite incomplete HTTP progress" do
    {peer, url} = peer([{:stall, "HTTP/1.1 200 OK\r\n"}])
    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = Login.poll(url, @token)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 4_000 and elapsed < 7_000
    assert_receive {:closed, ^peer, 1, {:error, :closed}}, 1_000
  end

  test "unsafe destination and caller inputs fail before any request" do
    for url <- [
          "http://example.com",
          "http://localhost:4000",
          "ws://localhost",
          "https://user:secret@example.com",
          "https://example.com?redirect=1",
          "https://example.com/private",
          "file:///tmp"
        ] do
      assert {:error, :unsafe_gateway_url} = Login.start(url, @target)
    end

    assert {:ok, %{scheme: "https"}} = Endpoint.parse("wss://gateway.example")
    assert {:ok, %{scheme: "http"}} = Endpoint.parse("http://[::1]:4000")
    assert {:ok, _} = Endpoint.socket("ws://localhost:4000", :signed)
    assert {:error, :invalid_options} = Login.poll("http://127.0.0.1:1", "invalid")
    assert {:error, :invalid_options} = Login.start("http://127.0.0.1:1", "bad target")
  end

  test "malformed JSON or content type cannot masquerade as login success" do
    for raw <- [
          response_raw("[]"),
          response_raw("broken-json"),
          response_raw(~s({"status":"pending"}), 200, [{"content-encoding", "gzip"}]),
          String.replace(response(%{status: "pending"}), "application/json", "text/html")
        ] do
      {_peer, url} = peer([raw])
      assert {:error, :invalid_response} = Login.poll(url, @token)
    end
  end

  defp response(value), do: response_raw(Jason.encode!(value))

  defp response_raw(body, status \\ 200, headers \\ []) do
    extra = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    "HTTP/1.1 #{status} Response\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n#{extra}\r\n#{body}"
  end

  defp peer(responses) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    owner = self()

    peer =
      spawn(fn ->
        try do
          responses
          |> Enum.with_index(1)
          |> Enum.each(fn {response, index} ->
            {:ok, socket} = :gen_tcp.accept(listener, 10_000)

            try do
              request = read_request(socket, "")
              send(owner, {:request, self(), index, request})

              bytes =
                case response do
                  {:stall, bytes} -> bytes
                  bytes -> bytes
                end

              :ok = :gen_tcp.send(socket, bytes)
              send(owner, {:closed, self(), index, :gen_tcp.recv(socket, 0, 7_000)})
            after
              :gen_tcp.close(socket)
            end
          end)
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
        headers = binary_part(buffer, 0, offset)
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        expected = offset + 4 + String.to_integer(length)

        if byte_size(buffer) >= expected do
          buffer
        else
          {:ok, more} = :gen_tcp.recv(socket, 0, 2_000)
          read_request(socket, buffer <> more)
        end

      :nomatch ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 2_000)
        read_request(socket, buffer <> more)
    end
  end
end
