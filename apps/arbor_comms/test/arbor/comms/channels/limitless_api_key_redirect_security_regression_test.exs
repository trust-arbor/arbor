defmodule Arbor.Comms.Channels.LimitlessApiKeyRedirectSecurityRegressionTest do
  @moduledoc """
  Security regression: Limitless sends `X-API-Key` through Req, which follows
  redirects by default and only strips `authorization` on a cross-origin hop.
  A 302 to another host must not carry the API key.
  """
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Comms.Channels.Limitless.Client

  @api_key "limitless-redirect-secret"
  @foreign_host "evil.example"

  defmodule RedirectAdapter do
    def run(request) do
      host = request.url.host
      send(Process.whereis(__MODULE__), {:provider_http, host, request.headers})

      if host == "api.limitless.ai" do
        {request,
         Req.Response.new(
           status: 302,
           headers: [{"location", "https://evil.example/steal"}]
         )}
      else
        {request, Req.Response.new(status: 200, body: %{"data" => %{"lifelogs" => []}})}
      end
    end
  end

  setup do
    previous = Application.get_env(:arbor_comms, :limitless)
    Process.register(self(), RedirectAdapter)

    Application.put_env(:arbor_comms, :limitless,
      api_key: @api_key,
      base_url: "https://api.limitless.ai/v1",
      req_options: [adapter: RedirectAdapter, retry: false]
    )

    on_exit(fn ->
      if Process.whereis(RedirectAdapter), do: Process.unregister(RedirectAdapter)
      restore(:arbor_comms, :limitless, previous)
    end)

    :ok
  end

  test "security regression: Limitless does not send X-API-Key to another host on redirect" do
    _ = Client.get_lifelogs(limit: 1)

    assert_receive {:provider_http, "api.limitless.ai", origin_headers}
    assert api_key_header?(origin_headers)
    refute_foreign_host_received_api_key()
  end

  defp refute_foreign_host_received_api_key do
    receive do
      {:provider_http, @foreign_host, headers} ->
        refute api_key_header?(headers),
               "cross-origin redirect carried X-API-Key to #{@foreign_host}"
    after
      100 -> :ok
    end
  end

  defp api_key_header?(headers) when is_map(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-api-key" and header_has_key?(value)
    end)
  end

  defp api_key_header?(headers) when is_list(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-api-key" and header_has_key?(value)
    end)
  end

  defp header_has_key?(value) when is_list(value), do: @api_key in value
  defp header_has_key?(value), do: value == @api_key

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
