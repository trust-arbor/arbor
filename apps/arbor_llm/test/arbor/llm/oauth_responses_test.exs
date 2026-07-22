defmodule Arbor.LLM.OAuth.ResponsesTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.OAuth.Responses

  @env_keys [
    :oauth_store_dir,
    :oauth_source_files,
    :oauth_response_endpoints,
    :oauth_refresh_fun,
    :trusted_oauth_response_endpoints
  ]

  setup do
    original = Map.new(@env_keys, &{&1, Application.fetch_env(:arbor_llm, &1)})

    root =
      Path.join(System.tmp_dir!(), "arbor-oauth-responses-#{System.unique_integer([:positive])}")

    store_dir = Path.join(root, "oauth")
    File.mkdir_p!(store_dir)

    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    Application.delete_env(:arbor_llm, :oauth_source_files)
    Application.delete_env(:arbor_llm, :oauth_response_endpoints)
    Application.delete_env(:arbor_llm, :oauth_refresh_fun)
    Application.delete_env(:arbor_llm, :trusted_oauth_response_endpoints)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)

      File.rm_rf!(root)
    end)

    {:ok, root: root, store_dir: store_dir}
  end

  test "bounded Responses SSE parsing preserves text and decoded tool arguments" do
    raw =
      sse(%{"type" => "response.output_text.delta", "delta" => "hello "}) <>
        sse(%{"type" => "response.output_text.delta", "delta" => "world"}) <>
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call-1",
            "name" => "lookup",
            "arguments" => Jason.encode!(%{"q" => "bounded"})
          }
        }) <>
        "data: [DONE]\n\n"

    assert {:ok,
            %{
              text: "hello world",
              tool_calls: [
                %{id: "call-1", name: "lookup", arguments: %{"q" => "bounded"}}
              ]
            }} = Responses.parse_sse(raw)
  end

  test "xAI in-progress function calls may have empty arguments before the terminal item" do
    raw =
      sse(%{
        "sequence_number" => 29,
        "type" => "response.output_item.added",
        "output_index" => 1,
        "item" => %{
          "arguments" => "",
          "call_id" => "call-1",
          "name" => "lookup",
          "type" => "function_call",
          "id" => "item-1",
          "status" => "in_progress"
        }
      }) <>
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call-1",
            "name" => "lookup",
            "arguments" => Jason.encode!(%{"q" => "complete"})
          }
        }) <>
        "data: [DONE]\n\n"

    assert {:ok,
            %{
              tool_calls: [
                %{id: "call-1", name: "lookup", arguments: %{"q" => "complete"}}
              ]
            }} = Responses.parse_sse(raw)
  end

  test "terminal function-call arguments must contain complete JSON" do
    raw =
      sse(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "lookup",
          "arguments" => ""
        }
      })

    assert {:error, {:invalid_responses_event, {:invalid_tool_arguments, {:invalid_json, _}}}} =
             Responses.parse_sse(raw)
  end

  test "security regression: Responses events enforce byte, event, work, and depth ceilings" do
    valid = sse(%{"type" => "response.output_text.delta", "delta" => "x"})
    deep = String.duplicate("[", 33) <> "0" <> String.duplicate("]", 33)
    deep_event = "data: {\"nested\":#{deep}}\n\n"

    assert {:error, {:response_bytes_exceeded, 8}} =
             Responses.parse_sse(valid, max_response_bytes: 8, max_event_bytes: 8)

    assert {:error, {:stream_limit_exceeded, :events, 1}} =
             Responses.parse_sse(valid <> valid, max_events: 1)

    assert {:error, {:invalid_responses_event, {:stream_limit_exceeded, :work, 2}}} =
             Responses.parse_sse(valid, max_work: 2)

    assert {:error, {:invalid_responses_event, {:decoded_term_limit_exceeded, :depth, 32}}} =
             Responses.parse_sse(deep_event)

    assert {:error, :valid_utf8_sse_required} = Responses.parse_sse("data: " <> <<255>>)

    assert {:error, :invalid_responses_limits} =
             Responses.parse_sse(valid, %{timeout: 100})
  end

  test "security regression: aggregate tool argument nodes fail before decoded retention" do
    arguments = Jason.encode!(%{"items" => List.duplicate(0, 4_500)})

    raw =
      1..30
      |> Enum.map(fn index ->
        sse(%{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call-#{index}",
            "name" => "bounded",
            "arguments" => arguments
          }
        })
      end)
      |> IO.iodata_to_binary()

    assert {:error, {:invalid_responses_event, {:stream_limit_exceeded, boundary, 100_000}}} =
             Responses.parse_sse(raw)

    assert boundary in [:decoded_nodes, :decoded_list_items]
  end

  test "security regression: thousands of tiny Responses events collect linearly" do
    raw =
      1..4_000
      |> Enum.map(fn _index ->
        sse(%{"type" => "response.output_text.delta", "delta" => "x"})
      end)
      |> IO.iodata_to_binary()

    task = Task.async(fn -> Responses.parse_sse(raw, max_events: 4_000) end)
    assert {:ok, {:ok, %{text: text, tool_calls: []}}} = Task.yield(task, 2_000)
    assert byte_size(text) == 4_000
  end

  test "security regression: drip-fed Responses TCP is owned by one absolute deadline" do
    {url, server} = start_drip_server(100, 10)
    started = System.monotonic_time(:millisecond)

    assert Responses.request_sse(url, [], %{}, receive_timeout: 120) ==
             {:error, {:responses_deadline_exceeded, 120}}

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 100
    assert elapsed < 300

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < 100
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "security regression: OAuth HTTP errors never return provider bodies or bearer secrets" do
    secret = "oauth-provider-secret-body"
    token = "oauth-bearer-secret"

    {url, server} =
      start_error_server(401, Jason.encode!(%{"detail" => secret, "token" => token}))

    result =
      Responses.request_sse(
        url,
        [{"authorization", "Bearer " <> token}],
        %{},
        receive_timeout: 500
      )

    assert result == {:error, {:responses_http, 401, :redacted}}
    refute inspect(result) =~ secret
    refute inspect(result) =~ token
    assert %{request: request} = Task.await(server, 2_000)
    assert request =~ "authorization: Bearer " <> token
  end

  test "security regression: OAuth transport failures never return request bearer secrets" do
    token = "oauth-transport-bearer-secret"
    {url, server} = start_drop_server()

    result =
      Responses.request_sse(
        url,
        [{"authorization", "Bearer " <> token}],
        %{},
        receive_timeout: 500
      )

    assert result == {:error, {:responses_request_failed, :redacted}}
    refute inspect(result) =~ token
    assert :closed = Task.await(server, 2_000)
  end

  test "security regression: unchanged Codex source after 401 returns stable auth error without retry",
       %{root: root, store_dir: store_dir} do
    source_path =
      configure_source_owned_openai!(root, store_dir, "same-access", "never-send-refresh")

    source_bytes = File.read!(source_path)
    {url, server} = start_unchanged_401_server()
    configure_responses_endpoint!(url)

    result = Responses.complete(:openai, empty_request(), receive_timeout: 1_000)

    assert result == {:error, :oauth_source_reauthentication_required}
    refute inspect(result) =~ "same-access"
    refute inspect(result) =~ "never-send-refresh"
    assert %{request: request, retried?: false} = Task.await(server, 2_000)
    assert request =~ "authorization: Bearer same-access"
    assert request =~ "chatgpt-account-id: acct_source"
    refute request =~ "never-send-refresh"
    assert File.read!(source_path) == source_bytes
  end

  test "security regression: changed Codex access token after 401 retries exactly once with one receipt",
       %{root: root, store_dir: store_dir} do
    source_path =
      configure_source_owned_openai!(root, store_dir, "old-access", "old-refresh-never-send")

    {url, server} =
      start_changed_401_server(source_path, "new-access", "new-refresh-never-send")

    configure_responses_endpoint!(url)

    assert {:ok, %{text: "retried", tool_calls: []}} =
             Responses.complete(:openai, empty_request(), receive_timeout: 1_500)

    assert %{first: first, second: second, extra_request?: false} = Task.await(server, 2_000)
    assert first =~ "authorization: Bearer old-access"
    assert first =~ "chatgpt-account-id: acct_source"
    assert second =~ "authorization: Bearer new-access"
    assert second =~ "chatgpt-account-id: acct_source"
    refute first =~ "old-refresh-never-send"
    refute second =~ "new-refresh-never-send"
  end

  test "security regression: source-owned Responses does not reread or retry non-401 statuses",
       %{root: root, store_dir: store_dir} do
    source_path =
      configure_source_owned_openai!(root, store_dir, "forbidden-access", "hidden-refresh")

    source_bytes = File.read!(source_path)
    {url, server} = start_single_status_server(403)
    configure_responses_endpoint!(url)

    assert {:error, {:responses_http, 403, :redacted}} =
             Responses.complete(:openai, empty_request(), receive_timeout: 1_000)

    assert %{requests: 1} = Task.await(server, 2_000)
    assert File.read!(source_path) == source_bytes
  end

  test "security regression: concurrent changed-source 401s have one bounded retry per caller",
       %{root: root, store_dir: store_dir} do
    caller_count = 6

    source_path =
      configure_source_owned_openai!(root, store_dir, "shared-old", "shared-old-refresh")

    {url, server} =
      start_concurrent_changed_401_server(
        source_path,
        caller_count,
        "shared-new",
        "shared-new-refresh"
      )

    configure_responses_endpoint!(url)

    results =
      1..caller_count
      |> Enum.map(fn _index ->
        Task.async(fn ->
          Responses.complete(:openai, empty_request(), receive_timeout: 3_000)
        end)
      end)
      |> Task.await_many(4_000)

    assert Enum.all?(results, &match?({:ok, %{text: "retried"}}, &1))

    assert %{initial: initial, retries: retries, extra_request?: false} =
             Task.await(server, 4_000)

    assert length(initial) == caller_count
    assert length(retries) == caller_count
    assert Enum.all?(initial, &String.contains?(&1, "authorization: Bearer shared-old"))
    assert Enum.all?(retries, &String.contains?(&1, "authorization: Bearer shared-new"))
    refute inspect(initial) =~ "shared-old-refresh"
    refute inspect(retries) =~ "shared-new-refresh"
  end

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"

  defp empty_request, do: %{instructions: "", input: [], tools: nil}

  defp configure_source_owned_openai!(root, store_dir, access_token, refresh_token) do
    source_path = Path.join(root, "codex-auth.json")
    write_codex_source!(source_path, access_token, refresh_token)

    envelope = %{
      "version" => 1,
      "provider" => "openai",
      "account_id" => "acct_source",
      "origin" => "external_cli",
      "owner" => "source_owned",
      "source" => "codex_file",
      "generation" => 7,
      "tokens" => %{}
    }

    store_path = Path.join(store_dir, "openai.json")
    File.write!(store_path, Jason.encode!(envelope))
    File.chmod!(store_path, 0o600)
    Application.put_env(:arbor_llm, :oauth_source_files, %{openai: source_path})
    source_path
  end

  defp write_codex_source!(path, access_token, refresh_token) do
    File.write!(
      path,
      Jason.encode!(%{
        "tokens" => %{
          "access_token" => access_token,
          "account_id" => "acct_source",
          "refresh_token" => refresh_token
        }
      })
    )
  end

  defp configure_responses_endpoint!(url) do
    Application.put_env(:arbor_llm, :oauth_response_endpoints, %{openai: url})
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])
  end

  defp start_unchanged_401_server do
    {listener, url} = listen()

    server =
      Task.async(fn ->
        {socket, request} = accept_request!(listener)
        send_http!(socket, 401, Jason.encode!(%{"detail" => "provider-body-secret"}))
        :gen_tcp.close(socket)
        retried? = accepts_connection?(listener, 300)
        :gen_tcp.close(listener)
        %{request: request, retried?: retried?}
      end)

    {url, server}
  end

  defp start_changed_401_server(source_path, access_token, refresh_token) do
    {listener, url} = listen()

    server =
      Task.async(fn ->
        {first_socket, first} = accept_request!(listener)
        write_codex_source!(source_path, access_token, refresh_token)
        send_http!(first_socket, 401, Jason.encode!(%{"token" => refresh_token}))
        :gen_tcp.close(first_socket)

        {second_socket, second} = accept_request!(listener)
        send_sse_success!(second_socket)
        :gen_tcp.close(second_socket)

        extra_request? = accepts_connection?(listener, 300)
        :gen_tcp.close(listener)
        %{first: first, second: second, extra_request?: extra_request?}
      end)

    {url, server}
  end

  defp start_single_status_server(status) do
    {listener, url} = listen()

    server =
      Task.async(fn ->
        {socket, _request} = accept_request!(listener)
        send_http!(socket, status, Jason.encode!(%{"detail" => "redacted"}))
        :gen_tcp.close(socket)
        requests = if accepts_connection?(listener, 300), do: 2, else: 1
        :gen_tcp.close(listener)
        %{requests: requests}
      end)

    {url, server}
  end

  defp start_concurrent_changed_401_server(source_path, count, access_token, refresh_token) do
    {listener, url} = listen()

    server =
      Task.async(fn ->
        initial = Enum.map(1..count, fn _index -> accept_request!(listener) end)
        write_codex_source!(source_path, access_token, refresh_token)

        Enum.each(initial, fn {socket, _request} ->
          send_http!(socket, 401, Jason.encode!(%{"token" => refresh_token}))
          :gen_tcp.close(socket)
        end)

        retries =
          Enum.map(1..count, fn _index ->
            {socket, request} = accept_request!(listener)
            send_sse_success!(socket)
            :gen_tcp.close(socket)
            request
          end)

        extra_request? = accepts_connection?(listener, 300)
        :gen_tcp.close(listener)

        %{
          initial: Enum.map(initial, &elem(&1, 1)),
          retries: retries,
          extra_request?: extra_request?
        }
      end)

    {url, server}
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {listener, "http://127.0.0.1:#{port}/responses"}
  end

  defp accept_request!(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    {:ok, request} = receive_http_headers(socket, "")
    {socket, request}
  end

  defp accepts_connection?(listener, timeout) do
    case :gen_tcp.accept(listener, timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, :timeout} ->
        false
    end
  end

  defp send_http!(socket, status, body) do
    reason = if status == 401, do: "Unauthorized", else: "Forbidden"

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )
  end

  defp send_sse_success!(socket) do
    body =
      sse(%{"type" => "response.output_text.delta", "delta" => "retried"}) <> "data: [DONE]\n\n"

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )
  end

  defp start_drip_server(chunk_count, delay_ms) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, _request} = receive_http_headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
              "transfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
          )

        result = send_drip_chunks(socket, chunk_count, delay_ms, 0)
        :gen_tcp.close(socket)
        result
      end)

    url = "http://127.0.0.1:#{port}/responses"
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])
    {url, server}
  end

  defp start_error_server(status, body) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, request} = receive_http_headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} Unauthorized\r\ncontent-type: application/json\r\n" <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        %{request: request}
      end)

    url = "http://127.0.0.1:#{port}/responses"
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])
    {url, server}
  end

  defp start_drop_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        :gen_tcp.close(socket)
        :closed
      end)

    url = "http://127.0.0.1:#{port}/responses"
    Application.put_env(:arbor_llm, :trusted_oauth_response_endpoints, [url])
    {url, server}
  end

  defp receive_http_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> receive_http_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_drip_chunks(_socket, maximum, _delay_ms, sent) when sent >= maximum,
    do: %{sent: sent, closed?: false}

  defp send_drip_chunks(socket, maximum, delay_ms, sent) do
    chunk = sse(%{"type" => "response.output_text.delta", "delta" => "x"})
    frame = Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"

    case :gen_tcp.send(socket, frame) do
      :ok ->
        Process.sleep(delay_ms)
        send_drip_chunks(socket, maximum, delay_ms, sent + 1)

      {:error, _reason} ->
        %{sent: sent, closed?: true}
    end
  end
end
