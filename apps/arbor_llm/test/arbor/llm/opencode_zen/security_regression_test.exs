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

  # A model that exists only in this suite's fixture catalog. Transport
  # behaviour must not depend on the live free tier's rotating membership.
  @fixture_model "fixture-admitted-free"

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Message
  alias Arbor.LLM.OpenCodeZen
  alias Arbor.LLM.Request

  setup do
    previous_path = Application.get_env(:arbor_llm, :opencode_zen_acknowledgement_path)
    previous_admission = Application.get_env(:arbor_llm, :opencode_zen_admission_path)
    previous_proxy = Application.get_env(:arbor_llm, :trusted_proxy_endpoints)
    previous_openai = System.get_env("OPENAI_API_KEY")
    previous_egress = Application.get_env(:arbor_security, :allow_opencode_zen_egress)

    # These tests exercise the TRANSPORT (headers, credentials, admission), not
    # the egress gate. The gate correctly DENIES keyless egress at the shipped
    # default (`allow_opencode_zen_egress` unset/false) — that denial is pinned
    # separately in arbor_security's egress_gate_test. Without the allowance
    # here, no request ever reaches the capture server and every wire assertion
    # fails with `received?: false`. Grant it for the duration and restore.
    Application.put_env(:arbor_security, :allow_opencode_zen_egress, true)

    ack_path =
      Path.join(System.tmp_dir!(), "opencode-zen-ack-#{System.unique_integer([:positive])}.json")

    Application.put_env(:arbor_llm, :opencode_zen_acknowledgement_path, ack_path)
    File.rm(ack_path)

    # These tests exercise the TRANSPORT (headers, credentials, admission
    # enforcement), not which models the live free tier currently serves. Pin a
    # fixture catalog so they stay valid as the real catalog rotates — coupling
    # them to shipped ids is what made them fail wholesale when the fabricated
    # catalog was replaced with measured evidence.
    fixture_path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-fixture-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      fixture_path,
      JSON.encode!(%{
        "version" => 1,
        "models" => [
          %{
            "id" => @fixture_model,
            "status" => "admitted",
            "context_window" => 131_072,
            "evidence" => %{
              "tier1" => %{"passed" => true},
              "tier2" => %{"passed" => true}
            }
          }
        ]
      })
    )

    Application.put_env(:arbor_llm, :opencode_zen_admission_path, fixture_path)
    on_exit(fn -> File.rm(fixture_path) end)

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

      if is_nil(previous_egress),
        do: Application.delete_env(:arbor_security, :allow_opencode_zen_egress),
        else: Application.put_env(:arbor_security, :allow_opencode_zen_egress, previous_egress)
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
    # Write a fixture rather than copying the shipped catalog: this test is
    # about fail-closed behaviour when the file disappears, not about which
    # models the live free tier currently admits.
    path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-admission-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "models" => [
          %{
            "id" => @fixture_model,
            "status" => "admitted",
            "evidence" => %{"tier1" => %{"passed" => true}, "tier2" => %{"passed" => true}}
          }
        ]
      })
    )

    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    assert OpenCodeZen.admit_model(@fixture_model) == :ok
    assert OpenCodeZen.admitted_ids() == [@fixture_model]

    File.rm!(path)

    assert OpenCodeZen.admit_model(@fixture_model) ==
             {:error, :opencode_zen_admission_unreadable}

    assert OpenCodeZen.admitted_ids() == []
  end

  test "persist_admission is visible on the next admit/list call" do
    path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-admission-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    admitted = %{
      "version" => 1,
      "models" => [
        %{
          "id" => @fixture_model,
          "evidence" => %{
            "tier1" => %{"passed" => true},
            "tier2" => %{"passed" => true}
          }
        }
      ]
    }

    empty = %{"version" => 1, "models" => []}

    :ok = OpenCodeZen.persist_admission(admitted)
    assert OpenCodeZen.admitted_ids() == [@fixture_model]
    assert OpenCodeZen.admit_model(@fixture_model) == :ok

    :ok = OpenCodeZen.persist_admission(empty)
    assert OpenCodeZen.admitted_ids() == []

    assert OpenCodeZen.admit_model(@fixture_model) ==
             {:error, {:opencode_zen_model_not_admitted, @fixture_model}}
  end

  test "security regression: live evaluation does not open a VM-wide admission bypass for concurrent requests",
       %{ack_path: ack_path} do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-admission-#{System.unique_integer([:positive])}.json"
      )

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

          # Deadline.run/3 owns a worker that does not inherit this process
          # dictionary. A child admit without carried opts must still deny.
          child_admit =
            Task.async(fn -> OpenCodeZen.admit_model(candidate) end)

          receive do
            {:run_probe, url} ->
              complete =
                Adapter.complete(request,
                  base_url: url,
                  receive_timeout: 2_000
                )

              {Task.await(child_admit, 2_000), complete}
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

    {child_admit, eval_result} = Task.await(evaluator, 5_000)

    assert child_admit == {:error, {:opencode_zen_model_not_admitted, candidate}}
    refute match?({:error, {:opencode_zen_model_not_admitted, _}}, eval_result)
    refute eval_result == {:error, :opencode_zen_admission_unreadable}
    assert %{received?: true} = Task.await(eval_server, 2_000)
  end

  test "security regression: caller-supplied probe ids do not admit an unadmitted model", %{
    ack_path: ack_path
  } do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-admission-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, JSON.encode!(%{"version" => 1, "models" => []}) <> "\n")
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    candidate = "unadmitted-smuggled-probe"
    {url, server} = start_capture_server()
    request = %{opencode_request() | model: candidate}

    result =
      Adapter.complete(request,
        opencode_zen_probe_ids: [candidate],
        base_url: url,
        receive_timeout: 1_000
      )

    assert result == {:error, {:opencode_zen_model_not_admitted, candidate}}
    assert %{received?: false} = Task.await(server, 2_000)
  end

  test "security regression: eval probe pin is agent-keyed, not Application env or VM-global",
       %{ack_path: ack_path} do
    :ok = OpenCodeZen.Disclosure.persist("2026-08-21T00:00:00Z")
    assert File.exists?(ack_path)

    path =
      Path.join(
        System.tmp_dir!(),
        "opencode-zen-admission-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, JSON.encode!(%{"version" => 1, "models" => []}) <> "\n")
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:arbor_llm, :opencode_zen_admission_path, path)

    candidate = "unadmitted-eval-pin"
    other = "unadmitted-eval-pin-other"
    eval_agent = "agent_eval_zen_pin_#{System.unique_integer([:positive])}"
    other_agent = "agent_eval_zen_other_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      OpenCodeZen.unregister_eval_probes(eval_agent)
      OpenCodeZen.unregister_eval_probes(other_agent)
    end)

    assert OpenCodeZen.admit_model(candidate) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    prior = Application.fetch_env(:arbor_llm, :eval_opencode_zen_probe_ids)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbor_llm, :eval_opencode_zen_probe_ids, value)
        :error -> Application.delete_env(:arbor_llm, :eval_opencode_zen_probe_ids)
      end
    end)

    Application.put_env(:arbor_llm, :eval_opencode_zen_probe_ids, [candidate])

    assert OpenCodeZen.admit_model(candidate) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    assert OpenCodeZen.admit_model(candidate, agent_id: eval_agent) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    assert :ok = OpenCodeZen.register_eval_probes(eval_agent, [candidate])
    assert OpenCodeZen.admit_model(candidate, agent_id: eval_agent) == :ok

    assert OpenCodeZen.admit_model(candidate) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    assert OpenCodeZen.admit_model(candidate, agent_id: other_agent) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    assert OpenCodeZen.admit_model(other, agent_id: eval_agent) ==
             {:error, {:opencode_zen_model_not_admitted, other}}

    child =
      Task.async(fn ->
        OpenCodeZen.admit_model(candidate, agent_id: eval_agent)
      end)

    assert Task.await(child, 2_000) == :ok

    child_without_principal =
      Task.async(fn -> OpenCodeZen.admit_model(candidate) end)

    assert Task.await(child_without_principal, 2_000) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    {denied_url, denied_server} = start_capture_server()
    request = %{opencode_request() | model: candidate}

    denied =
      Adapter.complete(request,
        base_url: denied_url,
        receive_timeout: 1_000
      )

    assert denied == {:error, {:opencode_zen_model_not_admitted, candidate}}
    assert %{received?: false} = Task.await(denied_server, 2_000)

    {url, server} = start_capture_server()

    result =
      Adapter.complete(request,
        agent_id: eval_agent,
        base_url: url,
        receive_timeout: 2_000
      )

    refute match?({:error, {:opencode_zen_model_not_admitted, _}}, result)
    assert %{received?: true} = Task.await(server, 2_000)

    assert :ok = OpenCodeZen.unregister_eval_probes(eval_agent)

    assert OpenCodeZen.admit_model(candidate, agent_id: eval_agent) ==
             {:error, {:opencode_zen_model_not_admitted, candidate}}

    assert OpenCodeZen.register_eval_probes("system", [candidate]) ==
             {:error, :invalid_eval_probe_registration}

    assert OpenCodeZen.register_eval_probes("", [candidate]) ==
             {:error, :invalid_eval_probe_registration}
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

  test "security regression: the keyless anonymous-auth path never reaches a credentialed provider" do
    # The widening this forbids: `Transport.apply_anonymous_auth/1` deletes the
    # Authorization header and writes an empty one. That is correct for
    # opencode_zen (the relay 401s any bearer) and WRONG for every credentialed
    # provider. If it ever applied to one, that provider's requests would go out
    # stripped of their credential.
    #
    # Asserted directly on the wire rather than by removing the key and hoping
    # for an error: Arbor does not refuse a keyless dispatch for a credentialed
    # provider, and a request without a key is not itself a security problem —
    # the provider simply rejects it. What matters is that a credential the
    # caller DID supply arrives intact, and that the keyless sentinel never
    # appears on a credentialed request.
    {url, server} = start_capture_server("openai")

    _ =
      Adapter.complete(openai_request(),
        base_url: url,
        api_key: "sk-credentialed-must-survive",
        receive_timeout: 2_000
      )

    %{received?: true, request: request} = Task.await(server, 2_000)

    auth = authorization_header(request)

    refute auth == "", "credentialed provider must not be sent with an empty Authorization"
    assert auth =~ "sk-credentialed-must-survive"

    refute request =~ OpenCodeZen.Transport.req_llm_placeholder(),
           "the keyless placeholder must never appear on a credentialed request"
  end

  defp opencode_request do
    %Request{
      provider: "opencode_zen",
      model: @fixture_model,
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

  test "security regression: the placeholder never survives on the STREAMING shape" do
    # `provider.attach_stream/4` returns a %Finch.Request{}, not a
    # %Req.Request{}, carrying the sentinel as a real header. Before the Finch
    # clause existed it fell through `apply_anonymous_auth/1`'s catch-all and
    # shipped `Bearer arbor-keyless-not-a-credential` to the wire. The relay
    # 401s ANY bearer, so streaming turns failed with {:stream_http_error, 401}
    # while the identical non-streaming call succeeded.
    placeholder = Arbor.LLM.OpenCodeZen.Transport.req_llm_placeholder()

    request = %Finch.Request{
      scheme: :https,
      host: "opencode.ai",
      port: 443,
      method: "POST",
      path: "/zen/v1/chat/completions",
      headers: [
        {"Authorization", "Bearer " <> placeholder},
        {"Content-Type", "application/json"}
      ],
      body: "{}",
      query: nil,
      unix_socket: nil,
      private: %{}
    }

    out = Arbor.LLM.OpenCodeZen.apply_anonymous_auth(request)
    joined = Enum.map_join(out.headers, ";", fn {n, v} -> "#{n}=#{v}" end)

    refute joined =~ placeholder, "the keyless placeholder reached the wire: #{joined}"

    assert Enum.any?(out.headers, fn {n, v} ->
             String.downcase(to_string(n)) == "authorization" and v == ""
           end)

    # Honest attribution, never a spoofed opencode/latest.
    assert Enum.any?(out.headers, fn {n, v} ->
             String.downcase(to_string(n)) == "user-agent" and v =~ "Arbor/"
           end)

    refute joined =~ "opencode/latest"

    # Content headers survive.
    assert Enum.any?(out.headers, fn {n, _} ->
             String.downcase(to_string(n)) == "content-type"
           end)
  end
end
