defmodule Arbor.Common.OAuth.DeviceCodeTest do
  @moduledoc """
  Focused device-code primitive tests:
  bounded option validation, deterministic polling, RFC 8628 error handling,
  and secret/body redaction in inspect/error pathways.
  """

  use ExUnit.Case, async: true

  alias Arbor.Common.OAuth.DeviceCode
  alias Arbor.Common.OAuth.DeviceCode.{PollParams, RefreshParams, StartParams}
  alias Arbor.Common.OAuth.HttpClient.Response

  @moduletag :fast

  @device_endpoint "https://idp.example/device"
  @token_endpoint "https://idp.example/token"

  defmodule StubClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(request) do
      requests = Process.get({__MODULE__, self(), :requests}, [])
      Process.put({__MODULE__, self(), :requests}, [request | requests])

      case Process.get({__MODULE__, self()}) do
        nil ->
          {:error, {:transport_error, :other}}

        [] ->
          {:error, {:transport_error, :other}}

        [response | remaining] ->
          called = Process.get({__MODULE__, self(), :called}, 0)
          Process.put({__MODULE__, self(), :called}, called + 1)
          Process.put({__MODULE__, self()}, remaining)
          {:ok, response}

        unexpected ->
          {:error, {:transport_error, unexpected}}
      end
    end

    def stub(responses) do
      Process.put({__MODULE__, self()}, responses)
      Process.put({__MODULE__, self(), :called}, 0)
      Process.put({__MODULE__, self(), :requests}, [])
    end

    def called_count do
      Process.get({__MODULE__, self(), :called}, 0)
    end

    def clear do
      Process.delete({__MODULE__, self()})
      Process.delete({__MODULE__, self(), :called})
      Process.delete({__MODULE__, self(), :sleep_calls})
      Process.delete({__MODULE__, self(), :requests})
    end

    def requests, do: Process.get({__MODULE__, self(), :requests}, [])
  end

  defp response(status, body), do: %Response{status: status, body: Jason.encode!(body)}

  defp response_body_only(binary), do: %Response{status: 200, body: binary}

  defp setup_stub(responses) do
    StubClient.clear()
    StubClient.stub(responses)
    on_exit(fn -> StubClient.clear() end)
    StubClient
  end

  describe "start/1 option validation" do
    test "rejects malformed options before any request" do
      responses = [response(200, %{"device_code" => "dev", "interval" => 5, "expires_in" => 300})]
      setup_stub(responses)

      assert {:error, {:invalid_params, :invalid_endpoint}} =
               DeviceCode.start(
                 device_authorization_endpoint: "http://idp.example/device",
                 client_id: "client-id",
                 http_client: StubClient
               )

      assert StubClient.called_count() == 0
    end

    test "rejects out-of-range request bytes before IO" do
      setup_stub([response(200, %{"device_code" => "dev", "interval" => 5, "expires_in" => 300})])

      assert {:error, {:invalid_params, {:max_response_bytes, :invalid_range}}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 max_response_bytes: 2_000_000,
                 http_client: StubClient
               )

      assert StubClient.called_count() == 0
    end

    test "uses the shared HTTP timeout bound before invoking the adapter" do
      setup_stub([
        response(200, %{
          "device_code" => "device-code",
          "expires_in" => 300,
          "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://idp.example/verify"
        })
      ])

      assert {:error, {:invalid_params, {:timeout_ms, :invalid_range}}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 timeout_ms: 120_001,
                 http_client: StubClient
               )

      assert StubClient.called_count() == 0

      assert {:ok, _response} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 timeout_ms: 120_000,
                 http_client: StubClient
               )

      assert [%{timeout_ms: 120_000}] = StubClient.requests()
    end

    test "rejects whitespace in list scopes before IO but permits a singular scope string" do
      setup_stub([
        response(200, %{
          "device_code" => "device-code",
          "expires_in" => 300,
          "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://idp.example/verify"
        })
      ])

      assert {:error, {:invalid_params, :invalid_scopes}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 scopes: ["openid email"],
                 http_client: StubClient
               )

      assert StubClient.called_count() == 0

      setup_stub([
        response(200, %{
          "device_code" => "device-code",
          "expires_in" => 300,
          "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://idp.example/verify"
        })
      ])

      assert {:ok, _response} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 scope: "openid email",
                 http_client: StubClient
               )
    end
  end

  describe "start/1 device-response bounds" do
    test "requires RFC fields and defaults the optional interval" do
      setup_stub([
        response(200, %{
          "device_code" => "device-code",
          "expires_in" => 300,
          "user_code" => "ABCD-EFGH",
          "verification_uri" => "https://idp.example/verify"
        })
      ])

      assert {:ok, %{"interval" => 5}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 http_client: StubClient
               )

      setup_stub([response(200, %{"device_code" => "device-code", "expires_in" => 300})])

      assert {:error, {:invalid_device_response, "user_code"}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 http_client: StubClient
               )
    end

    test "rejects overlong response strings" do
      setup_stub([
        response(200, %{
          "device_code" => "d",
          "interval" => 5,
          "expires_in" => 300,
          "verification_uri" => "https://idp.example/verify",
          "user_code" => String.duplicate("x", 2_048)
        })
      ])

      assert {:error, {:invalid_device_response, "user_code"}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )
    end

    test "rejects response depth and key-count violations" do
      nested_bad =
        %{
          "device_code" => "dev",
          "interval" => 5,
          "expires_in" => 300,
          "user_code" => "ABCD",
          "verification_uri" => "https://idp.example/verify",
          "nested" => %{
            "a" => %{
              "b" => %{
                "c" => %{
                  "d" => %{"e" => "x"}
                }
              }
            }
          }
        }

      setup_stub([response(200, nested_bad)])

      assert {:error, {:invalid_token_response, :depth}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )

      many = for i <- 1..65, do: {Integer.to_string(i), "v"}

      key_count_payload =
        Enum.into(many, %{})
        |> Map.put("device_code", "dev")
        |> Map.put("interval", 5)
        |> Map.put("expires_in", 300)
        |> Map.put("user_code", "ABCD")
        |> Map.put("verification_uri", "https://idp.example/verify")

      setup_stub([response(200, key_count_payload)])

      assert {:error, {:invalid_token_response, :keys}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )
    end
  end

  describe "poll/1 state machine and deterministic deadlines" do
    test "handles authorization_pending and returns success" do
      setup_stub([
        response(400, %{"error" => "authorization_pending"}),
        response(200, %{
          "access_token" => "at",
          "refresh_token" => "rt",
          "id_token" => "id",
          "token_type" => "Bearer",
          "expires_in" => 3_600
        })
      ])

      {:ok, sleep_calls} = Agent.start_link(fn -> [] end)

      assert {:ok, response} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 300,
                 poll_timeout_ms: 10_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient,
                 sleep_fn: fn ms ->
                   Agent.update(sleep_calls, &[ms | &1])
                 end
               )

      assert response["access_token"] == "at"

      Agent.stop(sleep_calls)
    end

    test "handles slow_down and expiry terminalization deterministically" do
      setup_stub([
        response(400, %{"error" => "slow_down"}),
        response(200, %{
          "access_token" => "at",
          "token_type" => "Bearer",
          "expires_in" => 3_600
        })
      ])

      assert {:ok, _} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 client_secret: "secret",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 300,
                 poll_timeout_ms: 10_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient,
                 sleep_fn: fn
                   6000 -> :ok
                   _ms -> :ok
                 end
               )
    end

    test "enforces explicit access_denied/expired_token branches" do
      setup_stub([response(400, %{"error" => "expired_token"})])

      assert {:error, :device_code_expired} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 300,
                 poll_timeout_ms: 1_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )

      setup_stub([response(400, %{"error" => "access_denied"})])

      assert {:error, :access_denied} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 300,
                 poll_timeout_ms: 1_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )

      setup_stub([response(400, %{"error" => "not_an_error"})])

      assert {:error, {:token_request_failed, 400}} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 300,
                 poll_timeout_ms: 1_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )
    end

    test "deadline is aggregate and deterministic with injected clock" do
      times = [100, 400]
      Process.put(:device_code_now_ticks, times)
      on_exit(fn -> Process.delete(:device_code_now_ticks) end)

      setup_stub([response(400, %{"error" => "authorization_pending"})])

      assert {:error, :device_flow_expired} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 10,
                 poll_timeout_ms: 200,
                 max_response_bytes: 64_000,
                 http_client: StubClient,
                 now_fn: fn ->
                   case Process.get(:device_code_now_ticks) do
                     [head | tail] ->
                       Process.put(:device_code_now_ticks, tail)
                       head

                     [] ->
                       1_000
                   end
                 end,
                 sleep_fn: fn _ms -> :ok end
               )
    end

    test "caps each request timeout and sleep to the aggregate deadline" do
      Process.put(:device_code_deadline_ticks, [100, 120, 125, 150, 300])
      on_exit(fn -> Process.delete(:device_code_deadline_ticks) end)
      on_exit(fn -> Process.delete(:device_code_sleep_ms) end)
      setup_stub([response(400, %{"error" => "authorization_pending"})])

      assert {:error, :device_flow_expired} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 10,
                 poll_timeout_ms: 200,
                 timeout_ms: 10_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient,
                 now_fn: fn ->
                   case Process.get(:device_code_deadline_ticks) do
                     [head | tail] ->
                       Process.put(:device_code_deadline_ticks, tail)
                       head
                   end
                 end,
                 sleep_fn: fn ms -> Process.put(:device_code_sleep_ms, ms) end
               )

      assert [%{timeout_ms: 180}] = StubClient.requests()
      assert Process.get(:device_code_sleep_ms) == 150
    end

    test "rejects a late successful response after the aggregate deadline" do
      Process.put(:device_code_late_ticks, [100, 120, 300])
      on_exit(fn -> Process.delete(:device_code_late_ticks) end)
      setup_stub([response(200, %{"access_token" => "late", "token_type" => "Bearer"})])

      assert {:error, :device_flow_expired} =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 expires_in: 10,
                 poll_timeout_ms: 200,
                 max_response_bytes: 64_000,
                 http_client: StubClient,
                 now_fn: fn ->
                   case Process.get(:device_code_late_ticks) do
                     [head | tail] ->
                       Process.put(:device_code_late_ticks, tail)
                       head
                   end
                 end
               )

      assert StubClient.called_count() == 1
    end

    test "uses AuthCode response-schema semantics for null and required fields" do
      cases = [
        {%{"access_token" => "at", "optional" => nil},
         %{"access_token" => :required_string, "optional" => :optional_string}, :field_type},
        {%{"access_token" => "at", "optional" => nil},
         %{"access_token" => :required_string, "optional" => :optional_integer}, :field_type},
        {%{"access_token" => "at"},
         %{"access_token" => :required_string, "required" => :required_string}, :missing_field},
        {%{"access_token" => "at", "required" => 1},
         %{"access_token" => :required_string, "required" => :required_string}, :field_type}
      ]

      for {body, schema, reason} <- cases do
        setup_stub([response(200, body)])

        assert {:error, {:invalid_token_response, ^reason}} =
                 DeviceCode.poll(
                   token_endpoint: @token_endpoint,
                   client_id: "client-id",
                   device_code: "device-xyz",
                   interval: 1,
                   expires_in: 300,
                   poll_timeout_ms: 1_000,
                   max_response_bytes: 64_000,
                   response_schema: schema,
                   http_client: StubClient
                 )
      end
    end
  end

  describe "error and inspect redaction behavior" do
    test "omits canary text on non-200 and malformed responses" do
      canary = "ARBOR-DEVICE-CODE-CANARY-#{System.unique_integer([:positive])}"
      setup_stub([response(400, %{"error" => canary}), response_body_only(canary)])

      assert {:error, {:device_code_request_failed, 400}} =
               start_error =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 http_client: StubClient
               )

      setup_stub([response_body_only(canary)])

      assert {:error, {:invalid_token_response, :malformed_json}} =
               DeviceCode.start(
                 device_authorization_endpoint: @device_endpoint,
                 client_id: "client-id",
                 http_client: StubClient
               )

      setup_stub([response(400, %{"error" => canary})])

      assert {:error, {:token_request_failed, 400}} =
               token_error =
               DeviceCode.poll(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 device_code: "device-xyz",
                 interval: 1,
                 expires_in: 5,
                 poll_timeout_ms: 1_000,
                 max_response_bytes: 64_000,
                 http_client: StubClient
               )

      refute inspect(start_error) =~ canary
      refute inspect(token_error) =~ canary
    end

    test "rejects malformed refresh options before request" do
      setup_stub([response(200, %{"access_token" => "at"})])

      assert {:error, {:invalid_params, :invalid_endpoint}} =
               DeviceCode.refresh(
                 token_endpoint: "http://idp.example/token",
                 client_id: "client-id",
                 refresh_token: "rt",
                 http_client: StubClient
               )

      assert StubClient.called_count() == 0
    end

    test "omits canary text on refresh error responses" do
      canary = "ARBOR-DEVICE-CODE-REFRESH-CANARY-#{System.unique_integer([:positive])}"
      setup_stub([response(400, %{"error" => canary, "error_description" => canary})])

      assert {:error, {:token_request_failed, 400}} =
               refresh_error =
               DeviceCode.refresh(
                 token_endpoint: @token_endpoint,
                 client_id: "client-id",
                 refresh_token: "rt",
                 max_response_bytes: 64_000,
                 response_schema: %{"access_token" => :required_string},
                 http_client: StubClient
               )

      refute inspect(refresh_error) =~ canary
    end

    test "redacts credentials and codes in inspect output" do
      start_params =
        %StartParams{
          device_authorization_endpoint: "https://idp.example/device",
          client_id: "client-id",
          client_secret: "client-secret",
          scopes: ["openid"],
          max_response_bytes: 65_536,
          timeout_ms: 10_000
        }

      assert inspect(start_params) =~ ~s(device_authorization_endpoint: "[REDACTED]")
      assert inspect(start_params) =~ ~s(client_secret: "[REDACTED]")
      refute inspect(start_params) =~ "client-secret"

      poll_params =
        %PollParams{
          token_endpoint: "https://idp.example/token",
          client_id: "client-id",
          client_secret: "client-secret",
          device_code: "device-code",
          interval: 5,
          expires_in: 300,
          response_schema: %{"access_token" => :required_string},
          max_response_bytes: 65_536,
          timeout_ms: 10_000
        }

      assert inspect(poll_params) =~ ~s(token_endpoint: "[REDACTED]")
      assert inspect(poll_params) =~ ~s(client_secret: "[REDACTED]")
      assert inspect(poll_params) =~ ~s(device_code: "[REDACTED]")
      refute inspect(poll_params) =~ "client-secret"
      refute inspect(poll_params) =~ "device-code"

      refresh_params =
        %RefreshParams{
          token_endpoint: "https://idp.example/token",
          client_id: "client-id",
          client_secret: "client-secret",
          refresh_token: "refresh-token",
          response_schema: %{"access_token" => :required_string},
          max_response_bytes: 65_536,
          timeout_ms: 10_000
        }

      assert inspect(refresh_params) =~ ~s(token_endpoint: "[REDACTED]")
      assert inspect(refresh_params) =~ ~s(refresh_token: "[REDACTED]")
      refute inspect(refresh_params) =~ "client-secret"
      refute inspect(refresh_params) =~ "refresh-token"
    end
  end
end
