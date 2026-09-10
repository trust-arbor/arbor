defmodule Arbor.LLM.Eval.SubjectFixturesTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.Adapter.ReqLLM, as: Adapter
  alias Arbor.LLM.Eval.Subject
  alias Arbor.LLM.{Client, Message, Request, Response, Tool}

  @moduletag :fast
  @model "named-eval-fixture-model"

  defmodule UnsupportedAdapter do
    def complete(_request, _opts), do: {:ok, %Response{text: "unsupported adapter ran"}}
  end

  setup do
    Req.Test.set_req_test_to_shared()
    previous_req = Req.default_options()
    previous_sets = Application.fetch_env(:arbor_llm, :eval_fixture_sets)
    previous_pipeline = Application.fetch_env(:arbor_llm, :pipeline)
    root = Path.join(System.tmp_dir!(), "named-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "regular-file"), "owned fixture sentinel")
    backend = start_supervised!({Agent, fn -> :available end})
    observer = self()

    # Static per-test operator configuration; calls never swap Application env.
    Application.put_env(:arbor_llm, :eval_fixture_sets, %{
      "capture" => %{mode: :record, path: root},
      "offline" => %{mode: :replay, path: root},
      "other_destination" => %{mode: :replay, path: Path.join(root, "other")},
      "relative" => %{mode: :record, path: "relative/path"},
      "invalid_mode" => %{mode: :automatic, path: root},
      "blocked_destination" => %{mode: :record, path: Path.join(root, "regular-file")}
    })

    Application.delete_env(:arbor_llm, :pipeline)
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.method == "GET" do
        send(observer, {:readiness_probe, conn.request_path})
        Req.Test.json(conn, %{"data" => [], "models" => []})
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)
        send(observer, {:prepared_http, self(), conn.method, request})

        case Agent.get(backend, & &1) do
          :available ->
            http_response(conn)

          :unavailable ->
            Req.Test.transport_error(conn, :econnrefused)

          :held ->
            receive do
              :release_fixture_response -> http_response(conn)
            after
              2_000 -> raise "test-owned HTTP fixture was not released"
            end
        end
      end
    end)

    on_exit(fn ->
      Req.default_options(previous_req)
      restore_env(:eval_fixture_sets, previous_sets)
      restore_env(:pipeline, previous_pipeline)
      File.rm_rf!(root)
    end)

    {:ok, root: root, backend: backend}
  end

  test "public Subject records real prepared HTTP and replays output and usage with provider unavailable",
       %{
         root: root,
         backend: backend
       } do
    assert {:ok, recorded} = run("public round trip", fixture_set: "capture")
    assert_receive {:prepared_http, _worker, "POST", body}
    assert body["model"] == @model
    assert [%{"content" => "public round trip", "role" => "user"}] = body["messages"]
    refute Map.has_key?(body, "eval_fixture_set")
    refute Map.has_key?(body, "fixture_set")
    refute Map.has_key?(body, "max_tokens")

    [fixture] = fixtures(root)
    bytes = File.read!(fixture)

    assert %{"schema_version" => 2, "response" => %{"value" => %{"response_kind" => "req_llm"}}} =
             Jason.decode!(bytes)

    refute bytes =~ root
    refute bytes =~ "arbor-local"
    refute bytes =~ "eval_fixture_set"
    assert recorded.text == "fixture answer"
    assert recorded.usage.input_tokens == 3
    assert recorded.usage.output_tokens == 2
    assert recorded.usage.total_tokens == 5
    assert recorded.usage.cached_tokens == 1
    assert recorded.usage.reasoning_tokens == 1
    assert recorded.usage.cache_creation_tokens == 0
    assert recorded.usage.tool_usage == %{}
    assert recorded.usage.image_usage == %{}

    Agent.update(backend, fn _ -> :unavailable end)
    assert {:error, _provider_failure} = run("unavailable ordinary control")
    assert_receive {:prepared_http, _worker, "POST", _body}

    assert {:ok, replayed} = run("public round trip", fixture_set: "offline", timeout: 1_500)
    assert Map.drop(replayed, [:duration_ms]) == Map.drop(recorded, [:duration_ms])

    # The ordinary failure control can retry. Match this replay request so its
    # earlier transport messages cannot be mistaken for a replay dispatch.
    refute_receive {:prepared_http, _, _,
                    %{"messages" => [%{"content" => "public round trip", "role" => "user"}]}}

    assert File.read!(fixture) == bytes
    assert fixtures(root) == [fixture]
  end

  test "security regression: cold catalog replay and unsupported routes perform no readiness probes",
       %{root: root} do
    # Cache eviction is fixture lifecycle only. Exercise the public Subject
    # with no previously discovered provider availability, then restore it.
    table = :arbor_provider_catalog
    cached = if :ets.whereis(table) == :undefined, do: [], else: :ets.take(table, :catalog)

    on_exit(fn ->
      if :ets.whereis(table) != :undefined do
        :ets.delete(table, :catalog)
        :ets.insert(table, cached)
      end
    end)

    assert {:error, {:eval_fixture_not_found, "offline"}} =
             run("cold miss", fixture_set: "offline")

    for provider <- ["xai_oauth", "acp"] do
      assert {:error, :eval_fixture_adapter_unsupported} =
               run("unsupported cold", fixture_set: "offline", provider: provider)
    end

    refute_receive {:prepared_http, _, _, _}
    refute_receive {:readiness_probe, _}
    assert fixtures(root) == []
  end

  test "security regression: missing scoped replay never calls provider or creates a fixture", %{
    root: root
  } do
    assert {:error, {:eval_fixture_not_found, "offline"}} = run("missing", fixture_set: "offline")
    refute_receive {:prepared_http, _, _, _}
    assert fixtures(root) == []
  end

  test "security regression: malformed and mismatched fixtures fail closed without provider fallback",
       %{root: root} do
    assert {:ok, _} = run("malformed fixture", fixture_set: "capture")
    assert_receive {:prepared_http, _, _, _}
    [fixture] = fixtures(root)
    original = File.read!(fixture)
    decoded = Jason.decode!(original)

    for malformed <- [
          "{not json",
          Jason.encode!(Map.put(decoded, "request_hash", "wrong")),
          Jason.encode!(Map.put(decoded, "schema_version", 999)),
          Jason.encode!(
            put_in(decoded, ["response", "value", "usage", "tool_usage"], %{
              "a:web_search" => %{"a:count" => 1, "a:unit" => %{"atom" => "unknown"}}
            })
          ),
          Jason.encode!(
            put_in(decoded, ["response", "value", "usage", "cache_creation_tokens"], -1)
          ),
          Jason.encode!(
            put_in(decoded, ["response", "value", "usage", "tool_usage"], %{
              "a:web_search" => %{
                "a:count" => 1,
                "a:unit" => %{"atom" => "call"},
                "a:unknown" => 1
              }
            })
          )
        ] do
      File.write!(fixture, malformed)

      assert {:error, {:invalid_fixture, _reason}} =
               run("malformed fixture", fixture_set: "offline")

      refute_receive {:prepared_http, _, _, _}
      assert File.read!(fixture) == malformed
    end
  end

  test "security regression: a tighter output budget finds the fixture then rejects its response",
       %{root: root} do
    assert {:ok, _} = run("bounded replay", fixture_set: "capture")
    assert_receive {:prepared_http, _, _, _}
    [fixture] = fixtures(root)
    bytes = File.read!(fixture)

    assert {:error, reason} = run("bounded replay", fixture_set: "offline", max_output_bytes: 128)
    assert inspect(reason) =~ "decoded_term_limit_exceeded"
    refute inspect(reason) =~ "eval_fixture_not_found"
    refute_receive {:prepared_http, _, _, _}
    assert File.read!(fixture) == bytes
  end

  test "generation inputs and selected destination remain part of fixture identity", %{root: root} do
    assert {:ok, _} = run("identity", fixture_set: "capture", temperature: 0.2, max_tokens: 40)
    assert_receive {:prepared_http, _, _, _}
    assert length(fixtures(root)) == 1

    for opts <- [
          [fixture_set: "offline", temperature: 0.3, max_tokens: 40],
          [fixture_set: "offline", temperature: 0.2, max_tokens: 41],
          [fixture_set: "offline", temperature: 0.2, max_tokens: 40, model: "another-model"],
          [fixture_set: "offline", temperature: 0.2, max_tokens: 40, provider: "ollama"],
          [fixture_set: "other_destination", temperature: 0.2, max_tokens: 40]
        ] do
      assert {:error, {:eval_fixture_not_found, _set}} = run("identity", opts)
    end

    refute_receive {:prepared_http, _, _, _}
    assert length(fixtures(root)) == 1
  end

  test "concurrent ordinary call remains uncaptured while named Subject records", %{
    root: root,
    backend: backend
  } do
    # Warm only the ordinary public route before the controlled POST barrier.
    # The separate cold-catalog test still proves named replay needs no probes.
    assert {:ok, _} = run("ordinary route preflight")
    assert_receive {:prepared_http, _, "POST", _}
    assert fixtures(root) == []

    Agent.update(backend, fn _ -> :held end)
    named = Task.async(fn -> run("named concurrent", fixture_set: "capture") end)
    ordinary = Task.async(fn -> run("ordinary concurrent") end)

    assert_receive {:prepared_http, first, "POST", first_body}, 1_000
    assert_receive {:prepared_http, second, "POST", second_body}, 1_000

    assert Enum.sort([
             hd(first_body["messages"])["content"],
             hd(second_body["messages"])["content"]
           ]) ==
             ["named concurrent", "ordinary concurrent"]

    send(second, :release_fixture_response)
    send(first, :release_fixture_response)
    assert {:ok, named_result} = Task.await(named)
    assert {:ok, ordinary_result} = Task.await(ordinary)
    assert named_result.text == ordinary_result.text
    refute Map.has_key?(ordinary_result, :usage)
    assert length(fixtures(root)) == 1

    assert {:error, {:eval_fixture_not_found, "offline"}} =
             run("ordinary concurrent", fixture_set: "offline")

    refute_receive {:prepared_http, _, _, _}
  end

  test "named fixture configuration is explicit and rejects caller supplied paths and modes", %{
    root: root
  } do
    for {selection, expected} <- [
          {"unknown", {:unknown_eval_fixture_set, "unknown"}},
          {"../capture", :invalid_eval_fixture_set_name},
          {%{mode: :record, path: root}, :invalid_eval_fixture_set_name},
          {nil, :invalid_eval_fixture_set_name},
          {"relative", {:invalid_eval_fixture_set_config, "relative"}},
          {"invalid_mode", {:invalid_eval_fixture_set_config, "invalid_mode"}}
        ] do
      assert {:error, ^expected} = run("invalid selection", fixture_set: selection)
    end

    refute_receive {:prepared_http, _, _, _}
    assert fixtures(root) == []
  end

  test "named fixture rejects streaming, unsupported adapters and short-circuiting client middleware" do
    assert {:error, :eval_fixture_stream_unsupported} =
             run("stream", fixture_set: "capture", stream: true)

    unsupported = Client.new(adapters: %{"lm_studio" => UnsupportedAdapter})

    assert {:error, :eval_fixture_adapter_unsupported} =
             run("adapter", fixture_set: "capture", client: unsupported)

    middleware = fn _request, _next -> {:ok, %Response{text: "middleware bypass"}} end
    client = Client.new(adapters: %{"lm_studio" => Adapter}, middleware: [middleware])

    assert {:error, :eval_fixture_middleware_unsupported} =
             run("middleware", fixture_set: "capture", client: client)

    refute_receive {:prepared_http, _, _, _}
  end

  test "named fixture rejects a custom pipeline before transport without rewriting ordinary calls",
       %{root: root} do
    Application.put_env(:arbor_llm, :pipeline, [
      Arbor.LLM.Plugs.ResponseLimit,
      Arbor.LLM.Plugs.Dispatch
    ])

    assert {:error, :eval_fixture_unsupported_pipeline} =
             run("custom named", fixture_set: "capture")

    refute_receive {:prepared_http, _, _, _}
    assert {:ok, %{text: "fixture answer"}} = run("custom ordinary")
    assert_receive {:prepared_http, _, _, _}
    assert fixtures(root) == []
  end

  test "failed fixture publication returns an error after real HTTP without claiming capture", %{
    root: root
  } do
    assert {:error, {:fixture_record_failed, _reason}} =
             run("cannot publish", fixture_set: "blocked_destination")

    assert_receive {:prepared_http, _, _, _}
    assert File.read!(Path.join(root, "regular-file")) == "owned fixture sentinel"
    assert fixtures(root) == []
  end

  test "scoped identity ignores transport credentials while binding remaining generation fields",
       %{root: root} do
    tool = %Tool{
      name: "example",
      description: "Synthetic tool",
      input_schema: %{"type" => "object", "properties" => %{}}
    }

    request = %Request{
      provider: "lm_studio",
      model: @model,
      messages: [%Message{role: :user, content: "generation identity"}],
      top_p: 0.8,
      tools: [tool]
    }

    assert {:ok, recorded} =
             Adapter.complete(request,
               eval_fixture_set: "capture",
               api_key: "synthetic-secret-one"
             )

    assert_receive {:prepared_http, _, _, body}
    assert body["top_p"] == 0.8
    assert [%{"function" => %{"name" => "example"}}] = body["tools"]
    [fixture] = fixtures(root)
    refute File.read!(fixture) =~ "synthetic-secret-one"

    assert {:ok, replayed} =
             Adapter.complete(request,
               eval_fixture_set: "offline",
               api_key: "synthetic-secret-two",
               receive_timeout: 900
             )

    assert recorded.text == replayed.text
    assert recorded.usage == replayed.usage

    assert {:error, {:eval_fixture_not_found, "offline"}} =
             Adapter.complete(%{request | top_p: 0.9}, eval_fixture_set: "offline")

    assert {:error, {:eval_fixture_not_found, "offline"}} =
             Adapter.complete(%{request | tools: [%{tool | description: "Changed tool"}]},
               eval_fixture_set: "offline"
             )

    refute_receive {:prepared_http, _, _, _}
    assert fixtures(root) == [fixture]
  end

  test "adapter boundary revalidates private selector instead of trusting a destination map", %{
    root: root
  } do
    request = %Request{
      provider: "lm_studio",
      model: @model,
      messages: [%Message{role: :user, content: "forged map"}]
    }

    assert {:error, :invalid_eval_fixture_set_name} =
             Adapter.complete(request, eval_fixture_set: %{mode: :record, path: root})

    assert {:error, {:unknown_eval_fixture_set, "unknown"}} =
             Adapter.complete(request, eval_fixture_set: "unknown")

    refute_receive {:prepared_http, _, _, _}
    assert fixtures(root) == []
  end

  defp run(prompt, opts \\ []) do
    Subject.run(
      prompt,
      Keyword.merge([provider: "lm_studio", model: @model, timeout: 3_000], opts)
    )
  end

  defp fixtures(root), do: Path.wildcard(Path.join(root, "*.json")) |> Enum.sort()

  defp restore_env(key, {:ok, value}), do: Application.put_env(:arbor_llm, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:arbor_llm, key)

  defp http_response(conn) do
    Req.Test.json(conn, %{
      "id" => "named_fixture_response",
      "object" => "chat.completion",
      "created" => 0,
      "model" => @model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "fixture answer"}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 3,
        "completion_tokens" => 2,
        "total_tokens" => 5,
        "prompt_tokens_details" => %{"cached_tokens" => 1},
        "completion_tokens_details" => %{"reasoning_tokens" => 1}
      }
    })
  end
end
