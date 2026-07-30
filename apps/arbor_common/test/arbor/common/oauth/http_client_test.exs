defmodule Arbor.Common.OAuth.HttpClientTest do
  @moduledoc """
  Adapter resolution, request validation, and the pinned Req options.

  The pinned-options test reads the built `Req.Request` directly, so it proves
  the hardening without performing any IO.
  """

  use ExUnit.Case, async: true

  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.{Pool, Request, Response}

  @moduletag :fast

  defmodule EchoClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(%Request{} = request) do
      {:ok, %Response{status: 200, headers: [], body: request.url}}
    end
  end

  defmodule ResultClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(_request) do
      case Process.get({__MODULE__, self()}) do
        :raise -> raise "adapter exception body must not escape"
        :throw -> throw("adapter throw body must not escape")
        :exit -> exit("adapter exit body must not escape")
        result -> result
      end
    end

    def return(result), do: Process.put({__MODULE__, self()}, result)
  end

  defp request(overrides \\ []) do
    struct(
      %Request{
        method: :get,
        url: "https://idp.example/x",
        max_response_bytes: 1_024,
        timeout_ms: 1_000
      },
      overrides
    )
  end

  describe "adapter resolution" do
    test "defaults to the Req adapter" do
      assert HttpClient.adapter() == HttpClient.Req
      assert HttpClient.default_adapter() == HttpClient.Req
    end

    test "an explicit :http_client option wins" do
      assert HttpClient.adapter(http_client: EchoClient) == EchoClient
    end

    test "a nil :http_client falls back to the default" do
      assert HttpClient.adapter(http_client: nil) == HttpClient.Req
    end

    test "dispatches through the resolved adapter" do
      assert {:ok, %Response{body: "https://idp.example/x"}} =
               HttpClient.request(request(), http_client: EchoClient)
    end
  end

  describe "request validation runs before dispatch" do
    test "rejects an unsupported method, empty url, and non-positive budgets" do
      assert {:error, {:invalid_request, :unsupported_method}} =
               HttpClient.request(request(method: :delete), http_client: EchoClient)

      assert {:error, {:invalid_request, :url_required}} =
               HttpClient.request(request(url: ""), http_client: EchoClient)

      assert {:error, {:invalid_request, {:max_response_bytes, :positive_required}}} =
               HttpClient.request(request(max_response_bytes: 0), http_client: EchoClient)

      assert {:error, {:invalid_request, {:timeout_ms, :positive_required}}} =
               HttpClient.request(request(timeout_ms: 0), http_client: EchoClient)

      assert {:error, {:invalid_request, :form_must_be_map}} =
               HttpClient.request(request(form: "a=b"), http_client: EchoClient)
    end

    test "rejects out-of-range budgets and invalid adapter modules" do
      assert {:error, {:invalid_request, {:max_response_bytes, {:max, 1_048_576}}}} =
               HttpClient.request(request(max_response_bytes: 1_048_577), http_client: EchoClient)

      assert {:error, {:invalid_request, {:timeout_ms, {:max, 120_000}}}} =
               HttpClient.request(request(timeout_ms: 120_001), http_client: EchoClient)

      assert {:error, {:invalid_request, :invalid_http_client}} =
               HttpClient.request(request(), http_client: self())
    end

    test "validates headers before dispatch" do
      assert {:ok, %Response{status: 200}} =
               HttpClient.request(
                 request(headers: List.duplicate({"x", "value"}, 64)),
                 http_client: EchoClient
               )

      assert {:error, {:invalid_request, :invalid_headers}} =
               HttpClient.request(
                 request(headers: ["bad"]),
                 http_client: EchoClient
               )

      assert {:error, {:invalid_request, :invalid_headers}} =
               HttpClient.request(
                 request(headers: [{"accept", 42}]),
                 http_client: EchoClient
               )

      assert {:error, {:invalid_request, :invalid_headers}} =
               HttpClient.request(
                 request(headers: List.duplicate({"x", "value"}, 65)),
                 http_client: EchoClient
               )
    end

    test "rejects malformed request options" do
      assert {:error, {:invalid_request, :invalid_options}} =
               HttpClient.request(request(), foo: 1)

      assert {:error, {:invalid_request, :invalid_options}} =
               HttpClient.request(request(), [
                 {:http_client, EchoClient},
                 {:http_client, EchoClient}
               ])

      assert {:error, {:invalid_request, :invalid_options}} =
               HttpClient.request(request(), [{"http_client", EchoClient}])

      assert {:error, {:invalid_request, :invalid_options}} =
               HttpClient.request(request(), [{:http_client, EchoClient} | :improper])
    end
  end

  describe "adapter result normalization" do
    test "admits documented errors and rejects unknown results without reflecting them" do
      ResultClient.return({:error, {:timeout, 250}})

      assert {:error, {:timeout, 250}} =
               HttpClient.request(request(), http_client: ResultClient)

      canary = "ADAPTER-CANARY-#{System.unique_integer([:positive])}"

      for result <- [
            {:error, {:provider_error, canary}},
            {:error, {:invalid_request, canary}},
            {:ok, %{status: 500, body: canary}},
            {:unexpected, canary}
          ] do
        ResultClient.return(result)
        normalized = HttpClient.request(request(), http_client: ResultClient)

        assert {:error, {:transport_error, :other}} = normalized
        refute inspect(normalized) =~ canary
      end

      ResultClient.return(:raise)

      assert {:error, {:transport_error, :other}} =
               HttpClient.request(request(), http_client: ResultClient)
    end

    test "defensively enforces the response byte budget for custom adapters" do
      ResultClient.return({:ok, %Response{status: 200, body: String.duplicate("x", 1_025)}})

      assert {:error, {:response_bytes_exceeded, 1_024}} =
               HttpClient.request(request(), http_client: ResultClient)
    end

    test "admits only a closed bounded response-header shape from custom adapters" do
      ResultClient.return(
        {:ok,
         %Response{
           status: 200,
           headers: List.duplicate({"x-trace", "value"}, 64),
           body: ""
         }}
      )

      assert {:ok, %Response{headers: headers}} =
               HttpClient.request(request(), http_client: ResultClient)

      assert length(headers) == 64

      for headers <- [
            :not_a_list,
            [{"x", "value"} | :improper],
            [{"bad\nname", "value"}],
            [{"x", "bad\r\nvalue"}],
            List.duplicate({"x", "value"}, 65),
            [{"x", String.duplicate("v", 4_097)}],
            List.duplicate({"x", String.duplicate("v", 4_096)}, 9)
          ] do
        ResultClient.return({:ok, %Response{status: 200, headers: headers, body: ""}})

        assert {:error, {:invalid_response, :invalid_headers}} =
                 HttpClient.request(request(), http_client: ResultClient)
      end
    end

    test "normalizes adapter throws and exits without reflecting their terms" do
      for mode <- [:throw, :exit] do
        ResultClient.return(mode)
        result = HttpClient.request(request(), http_client: ResultClient)

        assert {:error, {:transport_error, :other}} = result
        refute inspect(result) =~ "adapter"
      end
    end
  end

  describe "Inspect redaction" do
    test "redacts credential-bearing forms, bodies, and header values" do
      code = "CODE-CANARY"
      verifier = "VERIFIER-CANARY"
      secret = "SECRET-CANARY"
      token = "TOKEN-CANARY"
      authorization = "Bearer AUTHORIZATION-CANARY"
      cookie = "session=COOKIE-CANARY"

      rendered_request =
        inspect(
          request(
            method: :post,
            headers: [{"authorization", authorization}],
            form: %{
              "code" => code,
              "code_verifier" => verifier,
              "client_secret" => secret
            }
          )
        )

      refute rendered_request =~ code
      refute rendered_request =~ verifier
      refute rendered_request =~ secret
      refute rendered_request =~ authorization
      assert rendered_request =~ "[REDACTED]"
      assert rendered_request =~ "https://idp.example/x"
      assert rendered_request =~ "authorization"

      rendered_response =
        inspect(%Response{
          status: 200,
          headers: [{"set-cookie", cookie}],
          body: token
        })

      refute rendered_response =~ token
      refute rendered_response =~ cookie
      assert rendered_response =~ "[REDACTED]"
      assert rendered_response =~ "status: 200"
      assert rendered_response =~ "set-cookie"
    end
  end

  describe "pinned Req options" do
    test "redirect, compression, body decoding, and retry are all disabled" do
      req = HttpClient.Req.build(request(method: :post, form: %{"a" => "b"}))

      assert req.options[:redirect] == false
      assert req.options[:max_redirects] == 0
      assert req.options[:compressed] == false
      assert req.options[:decode_body] == false
      assert req.options[:retry] == false
      assert req.options[:pool_timeout] == 1_000
      assert req.options[:receive_timeout] == 1_000
      assert req.options[:finch] == Pool.name()
      refute Map.has_key?(req.options, :connect_options)

      # The bounded collector is installed, not merely configured.
      assert is_function(req.into, 2)
    end

    test "the dedicated pool pins HTTP/1 and Mint's parser-level header limit" do
      options = Pool.pool_options()

      assert options[:protocols] == [:http1]
      assert options[:conn_opts] == [max_header_list_size: Pool.max_header_list_size()]
      assert Pool.max_header_list_size() == 32_768
      assert Process.whereis(Pool.name())
    end
  end

  describe "bounded_into/1 never retains more than the maximum" do
    test "an over-budget chunk is discarded whole and halts the request" do
      collector = HttpClient.Req.bounded_into(10)
      req = Req.new(url: "https://idp.example")
      resp = %Req.Response{status: 200, body: "", private: %{}}

      # Under budget: retained and continuing.
      assert {:cont, {_req, resp}} = collector.({:data, "12345"}, {req, resp})
      assert resp.private[:arbor_oauth_response_bytes] == 5

      # Would exceed: whole chunk dropped (no truncated prefix), overflow flagged.
      assert {:halt, {halted_req, halted_resp}} = collector.({:data, "678901"}, {req, resp})
      assert halted_req.halted
      assert halted_resp.private[:arbor_oauth_response_overflow] == 10
      assert halted_resp.private[:arbor_oauth_response_chunks] == []
      assert halted_resp.body == ""
    end

    test "an exactly-at-budget chunk is retained" do
      collector = HttpClient.Req.bounded_into(5)
      req = Req.new(url: "https://idp.example")
      resp = %Req.Response{status: 200, body: "", private: %{}}

      assert {:cont, {_req, resp}} = collector.({:data, "12345"}, {req, resp})
      assert resp.private[:arbor_oauth_response_bytes] == 5
      refute Map.has_key?(resp.private, :arbor_oauth_response_overflow)
    end
  end

  describe "transport failure normalization" do
    test "a closed loopback port yields econnrefused, not a raw exception" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, {:transport_error, :econnrefused}} =
               HttpClient.request(request(url: "http://127.0.0.1:#{port}/x"))
    end
  end
end
