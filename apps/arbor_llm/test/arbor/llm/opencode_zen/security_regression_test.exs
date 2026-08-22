defmodule Arbor.LLM.OpenCodeZen.SecurityRegressionTest do
  @moduledoc """
  Security/privacy regressions for the keyless OpenCode Zen provider.

  Each test names the invariant it pins:
    * no request before disclosure acknowledgement
    * empty Authorization and no credential on the wire
    * honest Arbor User-Agent (never opencode/latest)
    * missing/blank keys for credentialed providers still fail closed
  """

  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Message
  alias Arbor.LLM.OpenCodeZen
  alias Arbor.LLM.Request

  setup do
    previous_path = Application.get_env(:arbor_llm, :opencode_zen_acknowledgement_path)
    previous_admission = Application.get_env(:arbor_llm, :opencode_zen_admission_path)
    previous_proxy = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)
    previous_openai = System.get_env("OPENAI_API_KEY")

    ack_path =
      Path.join(System.tmp_dir!(), "opencode-zen-ack-#{System.unique_integer([:positive])}.json")

    Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, ack_path)
    File.rm(ack_path)

    on_exit(fn ->
      File.rm(ack_path)

      if previous_path,
        do: Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, previous_path),
        else: Application.delete_env(:arbor_llm, :opencode_zen_acknowledgement_path)

      if previous_admission,
        do: Application.put_env(:arbor_llm, :opencode_zen_admission_path, previous_admission),
        else: Application.delete_env(:arbor_llm, :opencode_zen_admission_path)

      restore_env(:trusted_proxy_endpoints, previous_proxy)

      if is_binary(previous_openai),
        do: System.put_env("OPENAI_API_KEY", previous_openai),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    %{ack_path: ack_path}
  end

  test "security regression: no request reaches the provider before disclosure acknowledgement" do
    {url, server} = start_capture_server()

    result =
      Adapter.complete(opencode_request(),
        base_url: url,
        receive_timeout: 1_000
      )

    assert result == {:error, :disclosure_not_acknowledged}
    assert %{received?: false} = Task.await(server, 2_000)
  end

  test "security regression: outgoing Authorization is empty and no API key appears", %{
    ack_path: ack_path
  } do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    {url, server} = start_capture_server()

    _ =
      Adapter.complete(opencode_request(),
        base_url: url,
        receive_timeout: 2_000
      )

    %{received?: true, request: request} = Task.await(server, 2_000)

    assert authorization_header(request) == ""
    refute request =~ OpenCodeZen.Transport.req_llm_placeholder()
    refute request =~ "Bearer "
    refute request =~ "OPENAI_API_KEY"
  end

  test "security regression: attribution identifies Arbor and never spoofs opencode/latest", %{
    ack_path: ack_path
  } do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    {url, server} = start_capture_server()

    _ =
      Adapter.complete(opencode_request(),
        base_url: url,
        receive_timeout: 2_000
      )

    %{request: request} = Task.await(server, 2_000)

    ua = header_value(request, "user-agent")
    assert ua =~ "Arbor/"
    refute ua =~ "opencode/latest"
    assert header_value(request, "http-referer") == OpenCodeZen.Transport.referer()
    assert header_value(request, "x-title") == OpenCodeZen.Transport.title()
  end

  test "security regression: a real api_key for the keyless provider is not transmitted", %{
    ack_path: ack_path
  } do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    secret = "sk-leaked-should-never-appear"
    {url, server} = start_capture_server()

    _ =
      Adapter.complete(opencode_request(),
        base_url: url,
        api_key: secret,
        receive_timeout: 2_000
      )

    %{request: request} = Task.await(server, 2_000)
    refute request =~ secret
    assert authorization_header(request) == ""
  end

  test "security regression: rejected catalog model big-pickle cannot reach the network", %{
    ack_path: ack_path
  } do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    {url, server} = start_capture_server()
    request = %{opencode_request() | model: "big-pickle"}

    complete =
      Adapter.complete(request,
        base_url: url,
        receive_timeout: 1_000
      )

    stream =
      Adapter.stream(request,
        base_url: url,
        receive_timeout: 1_000
      )

    embed =
      Adapter.embed(["hello"], "big-pickle",
        provider: "opencode_zen",
        base_url: url,
        receive_timeout: 1_000
      )

    assert complete == {:error, {:opencode_zen_model_not_admitted, "big-pickle"}}
    assert stream == {:error, {:opencode_zen_model_not_admitted, "big-pickle"}}
    assert embed == {:error, {:opencode_zen_model_not_admitted, "big-pickle"}}
    assert %{received?: false} = Task.await(server, 2_000)
  end

  test "a missing admission catalog denies even after a previously successful load" do
    source = Application.app_dir(:arbor_llm, "priv/opencode_zen/admission.json")

    path =
      Path.join(System.tmp_dir!(), "opencode-zen-admission-#{System.unique_integer([:positive])}.json")

    File.cp!(source, path)
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    assert OpenCodeZen.admit_model("glm-4.6-flash") == :ok
    assert OpenCodeZen.admitted_ids() == ["glm-4.6-flash"]

    File.rm!(path)

    assert OpenCodeZen.admit_model("glm-4.6-flash") ==
             {:error, :opencode_zen_admission_unreadable}

    assert OpenCodeZen.admitted_ids() == []
  end

  test "persist_admission is visible on the next admit/list call" do
    path =
      Path.join(System.tmp_dir!(), "opencode-zen-admission-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    admitted = %{
      "version" => 1,
      "models" => [
        %{
          "id" => "glm-4.6-flash",
          "evidence" => %{
            "tier1" => %{"passed" => true},
            "tier2" => %{"passed" => true}
          }
        }
      ]
    }

    empty = %{"version" => 1, "models" => []}

    :ok = OpenCodeZen.persist_admission(admitted)
    assert OpenCodeZen.admitted_ids() == ["glm-4.6-flash"]
    assert OpenCodeZen.admit_model("glm-4.6-flash") == :ok

    :ok = OpenCodeZen.persist_admission(empty)
    assert OpenCodeZen.admitted_ids() == []

    assert OpenCodeZen.admit_model("glm-4.6-flash") ==
             {:error, {:opencode_zen_model_not_admitted, "glm-4.6-flash"}}
  end

  test "security regression: live evaluation does not open a VM-wide admission bypass for concurrent requests",
       %{ack_path: ack_path} do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    path =
      Path.join(System.tmp_dir!(), "opencode-zen-admission-#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(%{"version" => 1, "models" => []}) <> "\n")
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    candidate = "unadmitted-concurrent-probe"

    assert OpenCodeZen.admit_model(candidate) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    {ordinary_url, ordinary_server} = start_capture_server()
    parent = self()
    request = %{opencode_request() | model: candidate}

    evaluator =
      Task.async(fn ->
        OpenCodeZen.with_probe_models([candidate], fn ->
          send(parent, {:probe_open, self()})

          receive do
            {:run_probe, url} ->
              Adapter.complete(request,
                base_url: url,
                receive_timeout: 2_000
              )
          after
            10_000 ->
              {:error, :evaluator_not_signaled}
          end
        end)
      end)

    assert_receive {:probe_open, eval_pid}, 1_000

    ordinary =
      Adapter.complete(request,
        base_url: ordinary_url,
        receive_timeout: 1_000
      )

    assert ordinary == {:error, {:opencode_zen_model_not_admitted, candidate}}
    assert %{received?: false} = Task.await(ordinary_server, 2_000)

    {eval_url, eval_server} = start_capture_server()
    send(eval_pid, {:run_probe, eval_url})

    eval_result = Task.await(evaluator, 5_000)
    refute match?({:error, {:opencode_zen_model_not_admitted, _}}, eval_result)
    refute eval_result == {:error, :opencode_zen_admission_unreadable}
    assert %{received?: true} = Task.await(eval_server, 2_000)
  end

  test "unreadable admission catalog fails closed with a named error", %{ack_path: ack_path} do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    Application.put_env(
      :arbor_llm,
      :opencode_zen_admission_path,
      "/no/such/opencode-zen-admission-#{System.unique_integer([:positive])}.json"
    )

    {url, server} = start_capture_server()

    result =
      Adapter.complete(opencode_request(),
        base_url: url,
        receive_timeout: 1_000
      )

    assert result == {:error, :opencode_zen_admission_unreadable}
    assert %{received?: false} = Task.await(server, 2_000)
  end

  test "security regression: missing or blank keys for credentialed providers still fail closed" do
    System.delete_env("OPENAI_API_KEY")
    {url, server} = start_capture_server("openai")

    blank =
      Adapter.complete(openai_request(),
        base_url: url,
        api_key: "",
        receive_timeout: 1_000
      )

    missing =
      Adapter.complete(openai_request(),
        base_url: url,
        receive_timeout: 1_000
      )

    assert match?({:error, _}, blank)
    assert match?({:error, _}, missing)
    refute match?({:ok, _}, blank)
    refute match?({:ok, _}, missing)

    # The local listener may or may not see a connection depending on whether
    # ReqLLM fails in prepare_request. Either way the call must not succeed
    # anonymously — that is the widening this test forbids.
    outcome = Task.await(server, 2_000)

    if outcome.received? do
      refute authorization_header(outcome.request) == ""
    end
  end

  defp opencode_request do
    %Request{
      provider: "opencode_zen",
      model: "glm-4.6-flash",
      messages: [%Message{role: :user, content: "hello"}]
    }
  end

  defp openai_request do
    %Request{
      provider: "openai",
      model: "gpt-4o-mini",
      messages: [%Message{role: :user, content: "hello"}]
    }
  end

  defp start_capture_server(provider \\ "opencode_zen") do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 1_000) do
          {:ok, socket} ->
            :ok = :gen_tcp.close(listener)
            {:ok, request} = receive_request_headers(socket, "")

            body =
              JSON.encode!(%{
                "id" => "chatcmpl-test",
                "object" => "chat.completion",
                "choices" => [
                  %{
                    "index" => 0,
                    "message" => %{"role" => "assistant", "content" => "ok"},
                    "finish_reason" => "stop"
                  }
                ],
                "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
              })

            _ =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                  body
              )

            :gen_tcp.close(socket)
            %{received?: true, request: request}

          {:error, :timeout} ->
            :gen_tcp.close(listener)
            %{received?: false, request: nil}
        end
      end)

    url = "http://127.0.0.1:#{port}/v1"

    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{
      provider => [url],
      "opencode_zen" => [url],
      "openai" => [url]
    })

    {url, task}
  end

  defp receive_request_headers(socket, acc) when byte_size(acc) <= 65_536 do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> receive_request_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp authorization_header(request) when is_binary(request) do
    header_value(request, "authorization")
  end

  defp header_value(request, name) when is_binary(request) do
    request
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value("", fn line ->
      case String.split(line, ":", parts: 2) do
        [header, value] ->
          if String.downcase(String.trim(header)) == name, do: String.trim(value)

        _ ->
          nil
      end
    end)
  end

  defp restore_env(_key, nil), do: Application.delete_env(:arbor_llm, :trusted_proxy_endpoints)
  defp restore_env(key, val), do: Application.put_env(:arbor_llm, key, val)
end
