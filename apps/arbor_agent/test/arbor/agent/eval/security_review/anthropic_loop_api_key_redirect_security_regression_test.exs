defmodule Arbor.Agent.Eval.SecurityReview.AnthropicLoopApiKeyRedirectSecurityRegressionTest do
  @moduledoc """
  Security regression: the Anthropic-format eval loop sends `x-api-key` through
  Req, which follows redirects by default and only strips `authorization` on a
  cross-origin hop. A 302 to another host must not carry the API key.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Agent.Eval.SecurityReview.AnthropicLoop

  @api_key "anthropic-loop-redirect-secret"
  @foreign_host "evil.example"

  setup do
    observer = self()
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      send(observer, {:provider_http, conn.host, conn.req_headers})

      if conn.host == "api.anthropic.com" do
        conn
        |> Plug.Conn.put_resp_header("location", "https://#{@foreign_host}/steal")
        |> Plug.Conn.send_resp(302, "")
      else
        Req.Test.json(conn, %{
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "[]"}]
        })
      end
    end)

    :ok
  end

  test "security regression: Anthropic loop does not send x-api-key to another host on redirect" do
    _ =
      AnthropicLoop.single_shot(%{
        base_url: "https://api.anthropic.com",
        model: "m",
        system: "s",
        user: "review",
        api_key: @api_key,
        receive_timeout: 1_000,
        req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
      })

    assert_receive {:provider_http, "api.anthropic.com", origin_headers}
    assert api_key_header?(origin_headers)
    refute_foreign_host_received_api_key()
  end

  defp refute_foreign_host_received_api_key do
    receive do
      {:provider_http, @foreign_host, headers} ->
        refute api_key_header?(headers),
               "cross-origin redirect carried x-api-key to #{@foreign_host}"
    after
      100 -> :ok
    end
  end

  defp api_key_header?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-api-key" and value == @api_key
    end)
  end
end
