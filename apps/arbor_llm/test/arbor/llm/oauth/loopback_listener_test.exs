defmodule Arbor.LLM.OAuth.Login.LoopbackListenerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :security_regression
  @port 1457
  @ipv4 {127, 0, 0, 1}
  @registry Arbor.LLM.OAuth.Login.LoopbackRegistry

  alias Arbor.Common.OAuth.HttpClient.Response
  alias Arbor.LLM.OAuth
  alias Arbor.LLM.OAuth.Login.Loopback
  alias Arbor.LLM.OAuth.Login.LoopbackPrompt
  alias Arbor.LLM.OAuth.Login.LoopbackResolver
  alias Arbor.LLM.OAuth.Login.PendingStore

  defmodule SharedStubClient do
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(request) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.responses do
          [response | rest] ->
            {{:ok, response}, %{state | responses: rest, requests: [request | state.requests]}}

          [] ->
            {{:error, {:transport_error, :other}}, state}
        end
      end)
    end

    def set(responses), do: Agent.update(__MODULE__, &%{&1 | responses: responses})
    def request_count, do: Agent.get(__MODULE__, &length(&1.requests))
  end

  setup do
    stop_all_flows()

    start_supervised!(%{
      id: SharedStubClient,
      start:
        {Agent, :start_link, [fn -> %{responses: [], requests: []} end, [name: SharedStubClient]]}
    })

    prior_adapter = Application.get_env(:arbor_common, :oauth_http_client)
    prior_store_dir = Application.get_env(:arbor_llm, :oauth_store_dir)
    Application.put_env(:arbor_common, :oauth_http_client, SharedStubClient)

    store_dir =
      Path.join(System.tmp_dir!(), "arbor-loopback-#{System.unique_integer([:positive])}")

    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    pending_snapshot = :sys.get_state(PendingStore)

    on_exit(fn ->
      stop_all_flows()
      restore_env(:arbor_common, :oauth_http_client, prior_adapter)
      restore_env(:arbor_llm, :oauth_store_dir, prior_store_dir)
      File.rm_rf(store_dir)
      :sys.replace_state(PendingStore, fn _ -> pending_snapshot end)
    end)

    :ok
  end

  test "facade returns a handle-free redacted prompt and automatically publishes credentials" do
    SharedStubClient.set([token_response()])

    assert {:ok, %LoopbackPrompt{} = prompt} =
             Arbor.LLM.start_openai_loopback_login(redirect_uri: :port_1457)

    assert Map.keys(Map.from_struct(prompt)) == [:authorize_url]
    assert inspect(prompt) == "#Arbor.LLM.OAuth.Login.LoopbackPrompt<redacted>"
    url = LoopbackPrompt.authorize_url(prompt)
    state = query_value(url, "state")

    response = request("GET /auth/callback?code=valid-code&state=#{state} HTTP/1.1")
    assert response =~ "200 OK"
    assert response =~ "OpenAI authorization completed"
    refute response =~ state
    refute response =~ "valid-code"
    assert response =~ "cache-control: no-store"
    assert response =~ "referrer-policy: no-referrer"
    assert response =~ "content-security-policy: default-src 'none'"
    assert response =~ "x-content-type-options: nosniff"

    assert eventually(fn -> SharedStubClient.request_count() == 1 end)
    assert {:ok, %{owner: "arbor_owned", origin: "arbor_login"}} = OAuth.provenance(:openai)
    assert eventually(&port_reusable?/0)
  end

  test "wrong-state probes do not consume and replay exchanges only once" do
    SharedStubClient.set([token_response()])
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")

    assert request("GET /auth/callback?code=probe&state=wrong HTTP/1.1") =~ "400 Bad Request"
    assert SharedStubClient.request_count() == 0

    assert request("GET /auth/callback?code=real&state=#{state} HTTP/1.1") =~ "200 OK"
    assert eventually(&port_reusable?/0)
    assert SharedStubClient.request_count() == 1

    assert {:error, _reason} = :gen_tcp.connect(@ipv4, @port, [:binary, active: false], 100)
  end

  test "concurrent correct callbacks produce exactly one exchange" do
    SharedStubClient.set([token_response()])
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")
    line = "GET /auth/callback?code=real&state=#{state} HTTP/1.1"

    tasks = for _ <- 1..2, do: Task.async(fn -> request(line) end)
    responses = Task.await_many(tasks, 5_000)

    assert Enum.count(responses, &String.contains?(&1, "200 OK")) == 1
    assert SharedStubClient.request_count() == 1
  end

  test "a state-matched provider denial is terminal without token exchange" do
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")

    response =
      request(
        "GET /auth/callback?error=access_denied&error_description=private&state=#{state} HTTP/1.1"
      )

    assert response =~ "400 Bad Request"
    assert response =~ "OpenAI authorization failed"
    refute response =~ "private"
    refute response =~ state
    assert SharedStubClient.request_count() == 0
    assert eventually(&port_reusable?/0)
  end

  test "rejects wrong host, path, method, forwarding, and body without consuming" do
    SharedStubClient.set([token_response()])
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")
    query = "code=real&state=#{state}"

    invalid = [
      {"GET /auth/callback?#{query} HTTP/1.1", "evil.example:1457", []},
      {"GET /auth/callback/?#{query} HTTP/1.1", host(), []},
      {"GET /auth/%63allback?#{query} HTTP/1.1", host(), []},
      {"POST /auth/callback?#{query} HTTP/1.1", host(), []},
      {"GET /auth/callback?#{query} HTTP/1.1", host(), ["Forwarded: host=localhost"]},
      {"GET /auth/callback?#{query} HTTP/1.1", host(), ["Content-Length: 1", "", "x"]}
    ]

    for {line, request_host, extra} <- invalid do
      assert raw_request([line, "Host: #{request_host}" | extra]) =~ "400"
    end

    assert SharedStubClient.request_count() == 0
    assert request("GET /auth/callback?#{query} HTTP/1.1") =~ "200 OK"
  end

  test "absolute-form request targets are rejected without consuming the flow" do
    SharedStubClient.set([token_response()])
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")
    query = "code=real&state=#{state}"

    absolute =
      raw_request([
        "GET HTTP://localhost:1457/auth/callback?#{query} HTTP/1.1",
        "Host: #{host()}"
      ])

    refute absolute =~ "200 OK"
    assert SharedStubClient.request_count() == 0
    assert request("GET /auth/callback?#{query} HTTP/1.1") =~ "200 OK"
  end

  test "malformed and oversized callbacks are generic, secret-free, and emit no Cowboy telemetry" do
    {:ok, prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    marker = "SECRET_CALLBACK_MARKER"
    state = query_value(LoopbackPrompt.authorize_url(prompt), "state")
    attach_id = "loopback-no-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      attach_id,
      [:cowboy, :request, :start],
      fn event, _, metadata, _ ->
        send(test_pid, {:cowboy_telemetry, event, metadata})
      end,
      nil
    )

    log =
      capture_log(fn ->
        response = request("GET /auth/callback?code=#{marker}&state=#{state}&state=x HTTP/1.1")
        assert response =~ "OAuth callback rejected"
        refute response =~ marker
        refute response =~ state

        oversized = String.duplicate("a", 5_100)

        oversized_response =
          raw_request(["GET /auth/callback?#{oversized} HTTP/1.1", "Host: #{host()}"])

        refute oversized_response =~ "200 OK"
        refute oversized_response =~ oversized
      end)

    :telemetry.detach(attach_id)
    refute log =~ marker
    refute log =~ state
    refute_received {:cowboy_telemetry, _, _}

    [{flow_id, owner}] =
      Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    assert is_reference(flow_id)
    status = owner |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ marker
    refute status =~ state
    refute status =~ pending_handle()
  end

  test "IPv4, IPv6, and mixed startup bind every validated address" do
    assert {:ok, _prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    stop_all_flows()
    assert eventually(&port_reusable?/0)

    case ipv6_available?() do
      true ->
        assert {:ok, _prompt} = Loopback.start_resolved(:port_1457, [{0, 0, 0, 0, 0, 0, 0, 1}])
        stop_all_flows()

        assert {:ok, _prompt} =
                 Loopback.start_resolved(:port_1457, [@ipv4, {0, 0, 0, 0, 0, 0, 0, 1}])

      false ->
        :ok
    end
  end

  test "partial occupied-port startup rolls back listeners and issues no pending flow" do
    if ipv6_available?() do
      before_count = pending_count()

      {:ok, occupied} =
        :gen_tcp.listen(@port, [:binary, active: false, reuseaddr: true, ip: @ipv4])

      assert {:error, :oauth_loopback_unavailable} =
               Loopback.start_resolved(:port_1457, [
                 {0, 0, 0, 0, 0, 0, 0, 1},
                 @ipv4
               ])

      :gen_tcp.close(occupied)
      assert pending_count() == before_count
      assert port_reusable?()
    end
  end

  test "same-port flow fails closed before issuing and listener child failure cleans pending state" do
    before_count = pending_count()
    assert {:ok, _prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    assert pending_count() == before_count + 1
    assert {:error, :oauth_loopback_unavailable} = Loopback.start_resolved(:port_1457, [@ipv4])
    assert pending_count() == before_count + 1

    [{_, flow_pid, _, _}] =
      DynamicSupervisor.which_children(Arbor.LLM.OAuth.Login.LoopbackSupervisor)

    listener =
      flow_pid
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {id, pid, _, _} when id != Arbor.LLM.OAuth.Login.LoopbackOwner -> pid
        _ -> nil
      end)

    Process.exit(listener, :kill)
    assert eventually(fn -> pending_count() == before_count end)
    assert eventually(&port_reusable?/0)
  end

  test "resolver rejects empty, excessive, and non-loopback answers" do
    assert {:error, _} = LoopbackResolver.validate([])
    assert {:error, _} = LoopbackResolver.validate([{10, 0, 0, 1}])

    assert {:error, _} =
             LoopbackResolver.validate([
               {127, 0, 0, 1},
               {127, 0, 0, 2},
               {127, 0, 0, 3},
               {127, 0, 0, 4},
               {127, 0, 0, 5}
             ])
  end

  test "deadline and owner shutdown discard pending state and release the port" do
    before_count = pending_count()
    {:ok, _prompt} = Loopback.start_resolved(:port_1457, [@ipv4])

    [{_flow_id, owner}] =
      Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    send(owner, :deadline)
    assert eventually(fn -> pending_count() == before_count end)
    assert eventually(&port_reusable?/0)
  end

  test "PendingStore restart tears down listeners and invalidates the flow" do
    {:ok, _prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    old_store = Process.whereis(PendingStore)
    Process.exit(old_store, :kill)

    assert eventually(fn ->
             case Process.whereis(PendingStore) do
               pid when is_pid(pid) -> pid != old_store
               _ -> false
             end
           end)

    assert eventually(&port_reusable?/0)
    assert pending_count() == 0
  end

  test "slow incomplete headers hit the fixed request deadline" do
    {:ok, _prompt} = Loopback.start_resolved(:port_1457, [@ipv4])
    {:ok, socket} = :gen_tcp.connect(@ipv4, @port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, "GET /auth/callback?code=a&state=b HTTP/1.1\r\nHost:")
    Process.sleep(2_200)

    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, response} -> assert response =~ "408 Request Timeout"
      {:error, :closed} -> :ok
    end

    assert pending_count() == 1
  end

  defp token_response do
    id_token =
      [
        Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false),
        Base.url_encode64(
          Jason.encode!(%{
            "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_loopback"}
          }),
          padding: false
        ),
        "sig"
      ]
      |> Enum.join(".")

    %Response{
      status: 200,
      body:
        Jason.encode!(%{
          "access_token" => "access-token",
          "refresh_token" => "refresh-token",
          "id_token" => id_token,
          "token_type" => "Bearer"
        })
    }
  end

  defp request(line), do: raw_request([line, "Host: #{host()}"])

  defp raw_request(lines) do
    {:ok, socket} = :gen_tcp.connect(@ipv4, @port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, Enum.join(lines, "\r\n") <> "\r\n\r\n")
    receive_all(socket, "")
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> receive_all(socket, acc <> data)
      {:error, :closed} -> acc
      {:error, _reason} -> acc
    end
  end

  defp host, do: "localhost:#{@port}"

  defp query_value(url, key) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!(key)
  end

  defp pending_count do
    state = :sys.get_state(PendingStore)
    map_size(state.openai)
  end

  defp pending_handle do
    :sys.get_state(PendingStore).openai |> Map.keys() |> List.first()
  end

  defp stop_all_flows do
    case Process.whereis(Arbor.LLM.OAuth.Login.LoopbackSupervisor) do
      nil ->
        :ok

      supervisor ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
          DynamicSupervisor.terminate_child(supervisor, pid)
        end
    end
  end

  defp port_reusable? do
    case :gen_tcp.listen(@port, [:binary, active: false, reuseaddr: true, ip: @ipv4]) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end

  defp ipv6_available? do
    case :gen_tcp.listen(0, [:binary, :inet6, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
