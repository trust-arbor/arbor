defmodule Arbor.LLM.Plugs.DispatchProviderErrorTest do
  @moduledoc """
  D4 regression (`.arbor/roadmap/0-inbox/imp-dspy-port-review-2026-09-27.md`):
  every `Plugs.Dispatch` failure must reach its consumers as one typed
  `%Arbor.LLM.ProviderError{}`. Before the fix a non-2xx response came back as
  a raw `ReqLLM.Error.API.Request` struct that `RateLimitBackoff`,
  `Retry.fallback_eligible?/1`, and `LLMError.classify/1` did not match, so a
  real 429 skipped backoff and provider fallback.

  The provider is a real local HTTP server (Plug.Cowboy, which is what Bypass
  wraps; Bypass is not an arbor_llm dependency) so each request crosses Req,
  ReqLLM's provider encoding, the bounded body decoder, the default adapter
  pipeline, and `Arbor.LLM.Boundary` exactly as production does.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.{Message, ProviderError, Request, Retry}

  defmodule ScriptedProvider do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, %{test_pid: test_pid, status: status, headers: headers, body: body}) do
      send(test_pid, {:provider_request, conn.request_path})

      headers
      |> Enum.reduce(conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
      |> send_resp(status, body)
    end
  end

  @backoff_event [:arbor, :llm, :rate_limit_backoff]

  setup do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}
    original_endpoints = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)

    :ok = :telemetry.attach(handler_id, @backoff_event, &__MODULE__.forward_backoff/4, test_pid)

    Application.put_env(:arbor_llm, :rate_limit_backoff_sleep_fn, fn ms ->
      send(test_pid, {:backoff_sleep, ms})
    end)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.delete_env(:arbor_llm, :rate_limit_backoff_sleep_fn)

      if is_nil(original_endpoints),
        do: Application.delete_env(:arbor_llm, :trusted_proxy_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_proxy_endpoints, original_endpoints)
    end)

    :ok
  end

  @doc false
  def forward_backoff(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:rate_limit_backoff, metadata})

  test "D4 regression: a real HTTP 429 drives rate-limit backoff and stays fallback-eligible" do
    url =
      start_provider(
        429,
        [{"content-type", "application/json"}, {"retry-after", "1"}],
        Jason.encode!(%{
          "error" => %{
            "message" => "Rate limit reached for requests",
            "type" => "requests",
            "code" => "rate_limit_exceeded"
          }
        })
      )

    assert {:error, reason} = Adapter.complete(request("openai", "gpt-4o"), transport_opts(url))

    # RateLimitBackoff saw the failure, backed off for the provider's
    # Retry-After, and redispatched through the real Dispatch plug twice.
    assert_receive {:rate_limit_backoff, %{attempt: 1, retry_after_ms_from_provider: 1_000}}
    assert_receive {:rate_limit_backoff, %{attempt: 2, retry_after_ms_from_provider: 1_000}}
    assert_receive {:backoff_sleep, 1_000}
    assert provider_request_count() == 3

    # The failure that bubbles out is still eligible for provider fallback.
    assert Retry.fallback_eligible?(reason)
    assert %ProviderError{status: 429, retryable: true, retry_after_ms: 1_000} = reason
  end

  # New typed fields are read with Map.get/2 so this file still compiles
  # against the pre-fix struct and each test fails there on behavior.

  test "D4 regression: Anthropic 529 overloaded is retryable and fallback-eligible" do
    url =
      start_raw_provider(
        "529 Overloaded",
        json(),
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        })
      )

    assert {:error, reason} =
             Adapter.complete(request("anthropic", "claude-sonnet-4-5"), transport_opts(url))

    assert %ProviderError{status: 529, retryable: true} = reason
    assert Retry.fallback_eligible?(reason)

    # No Retry-After, so not a rate limit: Retry and provider fallback own it.
    refute_received {:rate_limit_backoff, _}
    assert provider_request_count() == 1
  end

  test "D4 regression: Anthropic 'prompt is too long' on a huge prompt is a typed context overflow" do
    url =
      start_provider(
        400,
        json(),
        Jason.encode!(%{
          "type" => "error",
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "prompt is too long: 208310 tokens > 200000 maximum"
          }
        })
      )

    # A prompt far over the adapter-error budget: before the fix the provider
    # library's exception carried it as `request_body`, so the Boundary
    # replaced the whole error with `{:invalid_adapter_error, _}`.
    prompt = String.duplicate("history ", 20_000)

    assert {:error, reason} =
             Adapter.complete(
               request("anthropic", "claude-sonnet-4-5", prompt),
               transport_opts(url)
             )

    assert %ProviderError{status: 400, retryable: false} = reason
    assert Map.get(reason, :context_window_exceeded) == true
    assert Arbor.LLM.context_window_exceeded?(reason)
    refute Retry.fallback_eligible?(reason)
    refute_received {:rate_limit_backoff, _}
    assert provider_request_count() == 1

    # The original failure is kept as a term — the provider's response, not
    # text and not the request (which would carry the prompt).
    assert %Req.Response{
             status: 400,
             body: %{"error" => %{"message" => "prompt is too long" <> _}}
           } = Map.get(reason, :original)

    refute inspect(Map.get(reason, :original), limit: :infinity) =~ "history history"
  end

  test "D4 regression: OpenAI context_length_exceeded keeps status and flag even when oversized" do
    url =
      start_provider(
        400,
        json(),
        Jason.encode!(%{
          "error" => %{
            "message" => "This model's maximum context length is 8192 tokens.",
            "type" => "invalid_request_error",
            "code" => "context_length_exceeded"
          },
          "echo" => String.duplicate("x", 100_000)
        })
      )

    assert {:error, reason} = Adapter.complete(request("openai", "gpt-4o"), transport_opts(url))

    assert %ProviderError{status: 400, retryable: false} = reason
    assert Map.get(reason, :context_window_exceeded) == true
    refute Retry.fallback_eligible?(reason)
  end

  test "D4 regression: a proxy's HTML 502 is a retryable provider failure, not an invalid body" do
    page = "<html><body><h1>502 Bad Gateway</h1></body></html>"
    url = start_provider(502, [{"content-type", "text/html"}], page)

    assert {:error, reason} = Adapter.complete(request("openai", "gpt-4o"), transport_opts(url))

    assert %ProviderError{status: 502, retryable: true} = reason
    assert Retry.fallback_eligible?(reason)
    assert %Req.Response{status: 502, body: ^page} = Map.get(reason, :original)
  end

  test "D4 regression: a refused connection is a retryable transport failure" do
    url = trust_endpoint("http://127.0.0.1:1/v1")

    assert {:error, reason} = Adapter.complete(request("openai", "gpt-4o"), transport_opts(url))

    assert %ProviderError{status: nil, retryable: true} = reason
    assert %Req.TransportError{reason: :econnrefused} = Map.get(reason, :original)
    assert Retry.fallback_eligible?(reason)
  end

  test "D4 regression: an embedding HTTP failure is the same typed error" do
    url =
      start_provider(
        503,
        [{"content-type", "application/json"}, {"retry-after", "2"}],
        Jason.encode!(%{"error" => %{"message" => "busy", "type" => "server_error"}})
      )

    assert {:error, reason} =
             Adapter.embed(["hello"], "text-embedding-3-small",
               provider: "openai",
               base_url: url,
               api_key: "test-key",
               receive_timeout: 30_000
             )

    assert %ProviderError{status: 503, retryable: true, retry_after_ms: 2_000} = reason
    assert Retry.fallback_eligible?(reason)

    # A retryable failure carrying Retry-After gets same-path backoff too.
    assert_receive {:rate_limit_backoff, %{attempt: 1, retry_after_ms_from_provider: 2_000}}
    assert provider_request_count() == 3
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp request(provider, model, content \\ "hello") do
    %Request{
      provider: provider,
      model: model,
      messages: [%Message{role: :user, content: content}]
    }
  end

  defp json, do: [{"content-type", "application/json"}]

  # Generous deadline: the first ReqLLM call in a VM loads the model catalog
  # (~3s cold), and a deadline expiry is itself fallback-eligible, which would
  # mask the classification under test.
  defp transport_opts(url), do: [base_url: url, api_key: "test-key", receive_timeout: 30_000]

  defp start_provider(status, headers, body) do
    ref = {__MODULE__, make_ref()}

    plug_opts = %{test_pid: self(), status: status, headers: headers, body: body}

    {:ok, _pid} =
      Plug.Cowboy.http(ScriptedProvider, plug_opts,
        ref: ref,
        port: 0,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    trust_endpoint("http://127.0.0.1:#{:ranch.get_port(ref)}/v1")
  end

  # Plug cannot send 529 (it has no reason phrase for it), so this one-shot
  # responder writes the status line itself. It serves exactly one request.
  defp start_raw_provider(status_line, headers, body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    test_pid = self()

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 30_000)
      :ok = :gen_tcp.close(listener)
      :ok = receive_request_headers(socket, "")
      send(test_pid, {:provider_request, :raw})

      header_lines = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status_line}\r\n" <>
            header_lines <>
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )

      :gen_tcp.close(socket)
    end)

    trust_endpoint("http://127.0.0.1:#{port}/v1")
  end

  defp receive_request_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 30_000)
      receive_request_headers(socket, acc <> data)
    end
  end

  defp trust_endpoint(url) do
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      "anthropic" => [url],
      "openai" => [url]
    })

    url
  end

  defp provider_request_count(count \\ 0) do
    receive do
      {:provider_request, _path} -> provider_request_count(count + 1)
    after
      0 -> count
    end
  end
end
