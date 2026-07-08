defmodule Arbor.Gateway.Signer.ProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Gateway.Signer.Proxy

  @moduletag :fast

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
