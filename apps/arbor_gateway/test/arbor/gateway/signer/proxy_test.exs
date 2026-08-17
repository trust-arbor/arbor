defmodule Arbor.Gateway.Signer.ProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Gateway.Signer.Proxy

  @moduletag :fast

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
    previous = Application.get_env(:arbor_gateway, :signer_http_client)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_gateway, :signer_http_client)
      else
        Application.put_env(:arbor_gateway, :signer_http_client, previous)
      end
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
