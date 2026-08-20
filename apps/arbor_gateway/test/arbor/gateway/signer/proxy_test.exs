defmodule Arbor.Gateway.Signer.ProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Gateway.Signer.Proxy

  @moduletag :fast

  defmodule RecordingClient do
    @moduledoc false

    def post(_url, body, headers) do
      state = Application.fetch_env!(:arbor_gateway, :signer_http_client_state)
      decoded = Jason.decode!(body)

      request = %{
        id: Map.get(decoded, "id"),
        method: Map.get(decoded, "method"),
        body: body,
        authorization: header(headers, "authorization"),
        session_id: header(headers, "mcp-session-id"),
        protocol_version: header(headers, "mcp-protocol-version")
      }

      Agent.get_and_update(state, fn
        %{responses: [response | rest], requests: requests} = current ->
          {{:ok, response}, %{current | responses: rest, requests: requests ++ [request]}}

        %{responses: []} ->
          raise "unexpected signer HTTP request: #{inspect(request)}"
      end)
    end

    defp header(headers, name), do: List.keyfind(headers, name, 0) |> header_value()

    defp header_value({_name, value}), do: value
    defp header_value(nil), do: nil
  end

  defmodule SessionAwareClient do
    @moduledoc false

    def post(_url, body, headers) do
      session =
        Enum.find_value(headers, fn
          {"mcp-session-id", value} -> value
          _other -> nil
        end)

      cond do
        String.contains?(body, ~s("method":"initialize")) ->
          {:ok,
           %{
             status: 200,
             body: ~s({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}),
             headers: [{"mcp-session-id", "sess-1"}, {"mcp-protocol-version", "2025-03-26"}]
           }}

        is_nil(session) ->
          {:ok, %{status: 400, body: ~s({"error":{"message":"Session ID required"}})}}

        String.contains?(body, "notifications/initialized") ->
          {:ok, %{status: 202, body: "", headers: [{"mcp-session-id", session}]}}

        true ->
          {:ok,
           %{
             status: 200,
             body: ~s({"jsonrpc":"2.0","id":2,"result":{"tools":[]}}),
             headers: [{"mcp-session-id", session}]
           }}
      end
    end
  end

  defmodule AcceptedNotificationClient do
    @moduledoc false

    def post(_url, _body, _headers) do
      {:ok, %{status: 202, body: ""}}
    end
  end

  setup do
    previous_client = Application.get_env(:arbor_gateway, :signer_http_client)
    previous_state = Application.get_env(:arbor_gateway, :signer_http_client_state)

    on_exit(fn ->
      restore_env(:signer_http_client, previous_client)
      restore_env(:signer_http_client_state, previous_state)
    end)

    :ok
  end

  test "does not emit a response for accepted JSON-RPC notifications" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor-signer-proxy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    key_file = write_key_file!(tmp_dir)
    Application.put_env(:arbor_gateway, :signer_http_client, AcceptedNotificationClient)

    notification = ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}) <> "\n"

    stdout =
      capture_io(notification, fn ->
        assert :ok =
                 Proxy.start(
                   key_file: key_file,
                   upstream: "http://localhost:4000/mcp"
                 )
      end)

    assert stdout == ""
  end

  test "replays the server-issued mcp-session-id after initialize" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor-signer-proxy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    key_file = write_key_file!(tmp_dir)
    Application.put_env(:arbor_gateway, :signer_http_client, SessionAwareClient)

    frames =
      [
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}),
        ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}),
        ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    stdout =
      capture_io(frames, fn ->
        assert :ok =
                 Proxy.start(
                   key_file: key_file,
                   upstream: "http://localhost:4000/mcp"
                 )
      end)

    refute stdout =~ "Session ID required"
    assert stdout =~ ~s("id":2)
    assert stdout =~ ~s("tools")
  end

  test "a second initialize starts a fresh HTTP session and adopts its negotiated protocol" do
    key_file = test_key_file!()

    state =
      start_recording_client([
        response("old-init", %{"protocolVersion" => "2025-03-26"}, [
          {"mcp-session-id", "sess-old"},
          {"mcp-protocol-version", "2025-03-26"}
        ]),
        accepted_response([{"mcp-session-id", "sess-old"}]),
        response("new-init", %{"protocolVersion" => "2025-11-25"}, [
          {"mcp-session-id", "sess-new"}
        ]),
        accepted_response([{"mcp-session-id", "sess-new"}]),
        response("after-new-init", %{"tools" => []})
      ])

    frames =
      [
        ~s({"jsonrpc":"2.0","id":"old-init","method":"initialize","params":{"protocolVersion":"2025-03-26"}}),
        ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{"generation":"old"}}),
        ~s({"jsonrpc":"2.0","id":"new-init","method":"initialize","params":{"protocolVersion":"2025-06-18"}}),
        ~s({"jsonrpc":"2.0","method":"notifications/initialized","params":{"generation":"new"}}),
        ~s({"jsonrpc":"2.0","id":"after-new-init","method":"tools/list","params":{}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    stdout = run_proxy(frames, key_file)

    assert [
             %{"id" => "old-init", "result" => %{"protocolVersion" => "2025-03-26"}},
             %{"id" => "new-init", "result" => %{"protocolVersion" => "2025-11-25"}},
             %{"id" => "after-new-init", "result" => %{"tools" => []}}
           ] = decode_frames(stdout)

    assert [
             %{id: "old-init", session_id: nil, protocol_version: "2025-03-26"},
             %{method: "notifications/initialized", session_id: "sess-old"},
             %{id: "new-init", session_id: nil, protocol_version: "2025-06-18"},
             %{
               method: "notifications/initialized",
               session_id: "sess-new",
               protocol_version: "2025-11-25"
             },
             %{
               id: "after-new-init",
               session_id: "sess-new",
               protocol_version: "2025-11-25"
             }
           ] = recorded_requests(state)
  end

  test "stale protocol transparently replays lifecycle and continues the same stdio session" do
    key_file = test_key_file!()
    initialize = initialize_frame("initialize", "2025-06-18")
    initialized = initialized_frame("cached")
    original = request_frame("recover-me", "tools/list")
    next = request_frame("next-frame", "resources/list")

    state =
      start_recording_client(
        recovery_responses(stale_protocol_response(), "recover-me", %{"tools" => []}) ++
          [response("next-frame", %{"resources" => []})]
      )

    stdout = run_proxy(join_frames([initialize, initialized, original, next]), key_file)

    assert [
             %{"id" => "initialize"},
             %{"id" => "recover-me", "result" => %{"tools" => []}},
             %{"id" => "next-frame", "result" => %{"resources" => []}}
           ] = decode_frames(stdout)

    requests = recorded_requests(state)

    assert Enum.map(requests, & &1.method) == [
             "initialize",
             "notifications/initialized",
             "tools/list",
             "initialize",
             "notifications/initialized",
             "tools/list",
             "resources/list"
           ]

    assert Enum.map(requests, & &1.session_id) == [
             nil,
             "sess-old",
             "sess-old",
             nil,
             "sess-new",
             "sess-new",
             "sess-new"
           ]

    assert Enum.map(requests, & &1.protocol_version) == List.duplicate("2025-06-18", 7)
    assert Enum.at(requests, 0).body == Enum.at(requests, 3).body
    assert Enum.at(requests, 1).body == Enum.at(requests, 4).body
    assert Enum.at(requests, 2).body == Enum.at(requests, 5).body
    refute Enum.at(requests, 0).authorization == Enum.at(requests, 3).authorization
    refute Enum.at(requests, 1).authorization == Enum.at(requests, 4).authorization
    refute Enum.at(requests, 2).authorization == Enum.at(requests, 5).authorization
  end

  test "unknown stale session transparently replays lifecycle once" do
    key_file = test_key_file!()
    state = start_recording_client(recovery_responses(session_not_found_response(), "recover-me"))

    frames =
      [
        initialize_frame("initialize", "2025-06-18"),
        initialized_frame("cached"),
        request_frame("recover-me", "tools/list")
      ]

    assert [
             %{"id" => "initialize"},
             %{"id" => "recover-me", "result" => %{"ok" => true}}
           ] = frames |> join_frames() |> run_proxy(key_file) |> decode_frames()

    assert Enum.map(recorded_requests(state), & &1.method) == [
             "initialize",
             "notifications/initialized",
             "tools/list",
             "initialize",
             "notifications/initialized",
             "tools/list"
           ]
  end

  test "unrelated HTTP 400 is not replayed and the same session handles the next frame" do
    key_file = test_key_file!()

    state =
      start_recording_client([
        response("initialize", %{"protocolVersion" => "2025-06-18"}, [
          {"mcp-session-id", "sess-application-error"}
        ]),
        accepted_response([{"mcp-session-id", "sess-application-error"}]),
        application_error_response(),
        response("after-application-error", %{"tools" => []})
      ])

    frames =
      join_frames([
        initialize_frame("initialize", "2025-06-18"),
        initialized_frame("cached"),
        request_frame("application-error", "tools/call"),
        request_frame("after-application-error", "tools/list")
      ])

    assert [
             %{"id" => "initialize"},
             %{"id" => "application-error", "error" => %{"code" => -32_603}},
             %{"id" => "after-application-error", "result" => %{"tools" => []}}
           ] = frames |> run_proxy(key_file) |> decode_frames()

    assert Enum.map(recorded_requests(state), & &1.method) == [
             "initialize",
             "notifications/initialized",
             "tools/call",
             "tools/list"
           ]
  end

  test "incomplete cached lifecycle returns a clear error without replay" do
    key_file = test_key_file!()

    state =
      start_recording_client([
        response("initialize", %{"protocolVersion" => "2025-06-18"}, [
          {"mcp-session-id", "sess-old"}
        ]),
        stale_protocol_response()
      ])

    frames =
      join_frames([
        initialize_frame("initialize", "2025-06-18"),
        request_frame("recover-me", "tools/list")
      ])

    assert [
             %{"id" => "initialize"},
             %{
               "id" => "recover-me",
               "error" => %{
                 "code" => -32_603,
                 "message" => "upstream MCP session lost; automatic recovery failed",
                 "data" => %{"reason" => ":incomplete_cached_lifecycle"}
               }
             }
           ] = frames |> run_proxy(key_file) |> decode_frames()

    assert length(recorded_requests(state)) == 2
  end

  test "incompatible recovery negotiation returns a clear error without replaying initialized" do
    key_file = test_key_file!()

    state =
      start_recording_client([
        response("initialize", %{"protocolVersion" => "2025-06-18"}, [
          {"mcp-session-id", "sess-old"}
        ]),
        accepted_response([{"mcp-session-id", "sess-old"}]),
        stale_protocol_response(),
        response("initialize", %{"protocolVersion" => "2025-11-25"}, [
          {"mcp-session-id", "sess-incompatible"}
        ])
      ])

    frames =
      join_frames([
        initialize_frame("initialize", "2025-06-18"),
        initialized_frame("cached"),
        request_frame("recover-me", "tools/list")
      ])

    assert [
             %{"id" => "initialize"},
             %{
               "id" => "recover-me",
               "error" => %{
                 "code" => -32_603,
                 "message" => "upstream MCP session lost; automatic recovery failed",
                 "data" => %{"reason" => reason}
               }
             }
           ] = frames |> run_proxy(key_file) |> decode_frames()

    assert reason =~ "incompatible_protocol"

    assert Enum.map(recorded_requests(state), & &1.method) == [
             "initialize",
             "notifications/initialized",
             "tools/list",
             "initialize"
           ]
  end

  test "a second invalidation on the retried request does not recurse" do
    key_file = test_key_file!()

    state =
      start_recording_client(
        recovery_responses(stale_protocol_response(), "recover-me")
        |> List.replace_at(5, session_not_found_response())
      )

    frames =
      join_frames([
        initialize_frame("initialize", "2025-06-18"),
        initialized_frame("cached"),
        request_frame("recover-me", "tools/list")
      ])

    assert [
             %{"id" => "initialize"},
             %{
               "id" => "recover-me",
               "error" => %{
                 "code" => -32_603,
                 "message" => "upstream MCP session lost; automatic recovery failed"
               }
             }
           ] = frames |> run_proxy(key_file) |> decode_frames()

    assert length(recorded_requests(state)) == 6
  end

  defp start_recording_client(responses) do
    {:ok, state} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    Application.put_env(:arbor_gateway, :signer_http_client, RecordingClient)
    Application.put_env(:arbor_gateway, :signer_http_client_state, state)

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    state
  end

  defp recorded_requests(state), do: Agent.get(state, & &1.requests)

  defp recovery_responses(stale_response, request_id, result \\ %{"ok" => true}) do
    [
      response("initialize", %{"protocolVersion" => "2025-06-18"}, [
        {"mcp-session-id", "sess-old"}
      ]),
      accepted_response([{"mcp-session-id", "sess-old"}]),
      stale_response,
      response("initialize", %{"protocolVersion" => "2025-06-18"}, [
        {"mcp-session-id", "sess-new"}
      ]),
      accepted_response([{"mcp-session-id", "sess-new"}]),
      response(request_id, result)
    ]
  end

  defp response(id, result, headers \\ []) do
    %{
      status: 200,
      body: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}),
      headers: headers
    }
  end

  defp accepted_response(headers), do: %{status: 202, body: "", headers: headers}

  defp stale_protocol_response do
    %{
      status: 400,
      body:
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{
            "code" => -32_600,
            "message" =>
              "MCP-Protocol-Version 2025-06-18 does not match the negotiated version 2025-11-25.",
            "data" => %{"expectedVersion" => "2025-11-25"}
          }
        })
    }
  end

  defp session_not_found_response do
    %{
      status: 404,
      body:
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{"code" => -32_600, "message" => "Session not found"}
        })
    }
  end

  defp application_error_response do
    %{
      status: 400,
      body:
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "application-error",
          "error" => %{
            "code" => -32_600,
            "message" => "Request ID has already been used in this session",
            "data" => %{"type" => "duplicate_request_id"}
          }
        })
    }
  end

  defp initialize_frame(id, version) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{"protocolVersion" => version}
    })
  end

  defp initialized_frame(generation) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{"generation" => generation}
    })
  end

  defp request_frame(id, method) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => %{}})
  end

  defp join_frames(frames), do: Enum.join(frames, "\n") <> "\n"

  defp test_key_file! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor-signer-proxy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    write_key_file!(tmp_dir)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_gateway, key, value)

  defp run_proxy(frames, key_file) do
    capture_io(frames, fn ->
      assert :ok =
               Proxy.start(
                 key_file: key_file,
                 upstream: "http://localhost:4000/mcp"
               )
    end)
  end

  defp decode_frames(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_key_file!(tmp_dir) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    agent_id = "agent_" <> Base.encode16(:crypto.hash(:sha256, public_key), case: :lower)

    path = Path.join(tmp_dir, "codex-smoke.arbor.key")

    File.write!(path, """
    agent_id=#{agent_id}
    private_key_b64=#{Base.encode64(private_key)}
    """)

    path
  end
end
