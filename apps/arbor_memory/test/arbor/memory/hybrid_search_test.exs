defmodule Arbor.Memory.HybridSearchTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Memory
  alias Arbor.Memory.Test.DurableGraphAuthority
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag :integration
  @model "synthetic-hybrid-wiring-768"
  @base "http://127.0.0.1:1234/v1"
  @corpus Path.expand("../../../priv/eval_datasets/knowledge_hybrid/corpus.json", __DIR__)

  setup do
    DurableGraphAuthority.start!()
    agent = "agent_hybrid_#{System.unique_integer([:positive])}"
    {:ok, cap} = Arbor.Security.grant(principal: agent, resource: "arbor://memory/search")
    assert {:ok, nil} = Memory.init_for_agent(agent, index_enabled: false, auto_embed: false)

    settings = [
      {:arbor_memory, :hybrid_knowledge_search},
      {:arbor_llm, :trusted_proxy_endpoints},
      {:arbor_llm, :pipeline},
      {:arbor_security, :egress_gate_enforcing}
    ]

    previous =
      Enum.map(settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    req_options = Req.default_options()
    Application.put_env(:arbor_memory, :hybrid_knowledge_search, route())
    Application.put_env(:arbor_llm, :trusted_proxy_endpoints, %{"lm_studio" => [@base]})
    Application.delete_env(:arbor_llm, :pipeline)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)
    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__}, retry: false)

    corpus = @corpus |> File.read!() |> Jason.decode!()

    vectors =
      Map.new(corpus["documents"] ++ corpus["queries"], fn entry ->
        {entry["content"] || entry["query"], vector(entry["wiring_axis"])}
      end)

    backend = start_supervised!({Agent, fn -> :normal end})
    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(observer, {:embedding_http, self(), conn.method, request})
      mode = Agent.get(backend, & &1)

      if mode == :held do
        receive do
          :release -> :ok
        after
          10_000 -> raise "test-owned embedding response was not released"
        end
      end

      if mode == :unavailable do
        Req.Test.transport_error(conn, :econnrefused)
      else
        rows =
          request["input"]
          |> Enum.with_index()
          |> Enum.map(fn {text, index} ->
            %{
              "index" => index,
              "embedding" => Map.get(vectors, text, vector(7)),
              "object" => "embedding"
            }
          end)
          |> corrupt(mode)

        response = %{
          "object" => "list",
          "model" => @model,
          "data" => rows,
          "usage" => %{
            "prompt_tokens" => length(request["input"]),
            "total_tokens" => length(request["input"])
          }
        }

        response =
          if mode == :over_budget,
            do: Map.put(response, "padding", String.duplicate("x", 2_097_152)),
            else: response

        Req.Test.json(conn, response)
      end
    end)

    on_exit(fn ->
      Req.default_options(req_options)

      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Arbor.Security.revoke(cap.id)
      :ets.delete(:arbor_memory_graphs, agent)
    end)

    %{agent: agent, cap: cap, corpus: corpus, backend: backend}
  end

  test "public hybrid read connects real prepared batch inputs to authoritative IDs and provenance",
       ctx do
    ids = seed(ctx)
    before = durable_record(ctx.agent)

    for query <- ctx.corpus["queries"] do
      assert {:ok, substring} = Memory.search_knowledge(ctx.agent, query["query"])

      if query["id"] == "partial_name" do
        assert Enum.map(substring, & &1.id) == [ids["anna"]]
      else
        assert substring == []
      end

      assert {:ok, result} = search(ctx, query["query"])
      assert Enum.map(result.results, & &1.id) == Enum.map(query["relevant_ids"], &ids[&1])
      assert_receive {:embedding_http, _, "POST", body}
      assert body["model"] == @model
      assert hd(body["input"]) == query["query"]

      expected =
        before.data["payload"]["nodes"]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_id, node} -> node["content"] end)

      assert tl(body["input"]) == expected
      refute Map.has_key?(body, "require_live_pipeline")
      assert result.measurement.candidate_count == length(expected)
      assert result.measurement.input_bytes == Enum.sum(Enum.map(body["input"], &byte_size/1))
      assert result.measurement.semantic_weight == 0.7
      assert_in_delta result.measurement.keyword_weight, 0.3, 0.00001
      assert result.measurement.usage != %{}

      for entry <- result.results do
        source = before.data["provenance"]["nodes"][entry.id]
        assert entry.payload == before.data["payload"]["nodes"][entry.id]
        assert {:ok, envelope} = TaintEnvelope.verify(source["envelope"], entry.payload)
        assert entry.provenance.taint == envelope.taint
        assert Atom.to_string(entry.provenance.status) == source["status"]

        assert entry.payload["confidence"] ==
                 before.data["payload"]["nodes"][entry.id]["confidence"]
      end
    end

    assert durable_record(ctx.agent) == before
  end

  test "ordinary substring remains available while hybrid is disabled", ctx do
    seed(ctx)
    Application.put_env(:arbor_memory, :hybrid_knowledge_search, false)
    assert {:error, :hybrid_search_disabled} = search(ctx, "restart only crashed child")
    assert {:ok, [_]} = Memory.search_knowledge(ctx.agent, "parameterized")
    refute_receive {:embedding_http, _, _, _}
  end

  test "capability denial and a foreign agent require authority before any embedding", ctx do
    seed(ctx)

    assert {:error, {:unauthorized, _}} =
             Memory.authorize_hybrid_search("ungranted", ctx.agent, "restart only crashed child")

    assert {:error, {:unauthorized, _}} =
             Memory.authorize_hybrid_search(
               ctx.agent,
               "other_agent",
               "restart only crashed child"
             )

    refute_receive {:embedding_http, _, _, _}
  end

  test "an explicitly scoped read capability admits a different caller's graph read", ctx do
    ids = seed(ctx)
    caller = "agent_hybrid_delegate_#{System.unique_integer([:positive])}"

    assert {:ok, cap} =
             Arbor.Security.grant(
               principal: caller,
               resource: "arbor://memory/search/#{ctx.agent}"
             )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)

    assert {:ok, %{results: [result]}} =
             Memory.authorize_hybrid_search(caller, ctx.agent, "restart only crashed child")

    assert result.id == ids["supervisor"]
    assert_receive {:embedding_http, _, "POST", _}
  end

  test "local dispatch preserves the authoritative Trust on-host tier policy", ctx do
    seed(ctx)
    before = durable_record(ctx.agent)

    assert :allow =
             Arbor.Trust.authorize_egress(ctx.agent, :on_host,
               egress_taint: TaintEnvelope.missing_fallback(),
               egress_destination: @base,
               egress_provider: "lm_studio",
               egress_model: @model,
               egress_runtime: "arbor"
             )

    assert {:ok, %{results: [_]}} = search(ctx, "restart only crashed child")
    assert_receive {:embedding_http, _, "POST", _}
    assert durable_record(ctx.agent) == before
  end

  test "untrusted request options and nonliteral or external routes cannot select embedding egress",
       ctx do
    seed(ctx)

    for opts <- [
          [provider: "openai"],
          [base_url: @base],
          [embedding: vector(0)],
          [limit: 1, limit: 2],
          [min_score: -1],
          [types: [:unreviewed]],
          [types: [:fact | :improper]]
        ] do
      assert {:error, :invalid_hybrid_search_request} =
               search(ctx, "restart only crashed child", opts)
    end

    for change <- [
          [provider: "openai"],
          [base_url: "http://localhost:1234/v1"],
          [base_url: "https://example.com/v1"],
          [timeout_ms: 30_001],
          [min_cosine: nil],
          [semantic_weight: 2]
        ] do
      Application.put_env(:arbor_memory, :hybrid_knowledge_search, Keyword.merge(route(), change))

      assert {:error, :invalid_hybrid_search_configuration} =
               search(ctx, "restart only crashed child")
    end

    refute_receive {:embedding_http, _, _, _}
  end

  test "full eligible corpus and query byte limits fail before HTTP instead of truncating", ctx do
    assert {:ok, _} =
             Memory.add_knowledge(ctx.agent, %{type: :fact, content: String.duplicate("x", 8193)})

    before = durable_record(ctx.agent)
    assert {:error, {:hybrid_search_limit_exceeded, :text_bytes, 8192}} = search(ctx, "query")
    assert {:error, :invalid_hybrid_search_request} = search(ctx, String.duplicate("q", 4097))
    refute_receive {:embedding_http, _, _, _}
    assert durable_record(ctx.agent) == before
  end

  test "a limited result still embeds every item in a bounded durable corpus", ctx do
    for index <- 1..8 do
      content = String.pad_trailing("bounded document #{index}: ", 8192, "x")
      assert {:ok, _} = Memory.add_knowledge(ctx.agent, %{type: :fact, content: content})
    end

    before = durable_record(ctx.agent)
    assert map_size(before.data["payload"]["nodes"]) == 8
    assert {:ok, %{results: [_], measurement: measurement}} = search(ctx, "query", limit: 1)
    assert measurement.candidate_count == 8
    assert measurement.input_bytes == 8 * 8192 + 5
    assert_receive {:embedding_http, _, "POST", body}
    assert length(body["input"]) == 9
    refute_receive {:embedding_http, _, _, _}
    assert durable_record(ctx.agent) == before
  end

  test "pure aggregate policy rejects an over-budget inventory without truncation" do
    # The current Codec's conservative JSON reserve rejects this inventory
    # before persistence. Exercise this independent defensive policy as a pure
    # decision, without manufacturing an authoritative oversized graph.
    nodes =
      Map.new(1..33, fn index ->
        id = "synthetic-#{index}"
        {id, %{id: id, type: :fact, relevance: 1.0, content: String.duplicate("x", 8192)}}
      end)

    assert {:error, {:hybrid_search_limit_exceeded, :batch_bytes, 262_144}} =
             Arbor.Memory.HybridSearchCore.candidates(%{graph: %{nodes: nodes}}, "query", [])
  end

  test "caller thresholds may tighten but cannot loosen operator floors", ctx do
    seed(ctx)
    query = "restart only crashed child"
    assert {:ok, %{results: [_]}} = search(ctx, query, min_cosine: 0, min_score: 0)
    assert_receive {:embedding_http, _, "POST", _}
    assert {:ok, %{results: [], measurement: %{min_score: 1}}} = search(ctx, query, min_score: 1)
    assert_receive {:embedding_http, _, "POST", _}

    assert {:ok, %{results: [], measurement: %{min_cosine: 0.7, min_score: 0.6}}} =
             search(ctx, "Ann", min_cosine: 0, min_score: 0)

    assert_receive {:embedding_http, _, "POST", _}
  end

  test "oversized result payload refuses publication without dropping provenance", ctx do
    assert {:ok, _} =
             Memory.add_knowledge(ctx.agent, %{
               type: :fact,
               content: "restart only crashed child",
               metadata: %{"bounded_diagnostic" => String.duplicate("x", 65_536)}
             })

    before = durable_record(ctx.agent)

    assert {:error, {:hybrid_search_limit_exceeded, :result_bytes, 65_536}} =
             search(ctx, "restart only crashed child")

    assert_receive {:embedding_http, _, "POST", _}
    assert durable_record(ctx.agent) == before
  end

  test "empty explicit type inventory performs no provider call", ctx do
    seed(ctx)

    assert {:ok, %{results: [], measurement: %{candidate_count: 0, usage: %{}}}} =
             search(ctx, "restart only crashed child", types: [:goal])

    refute_receive {:embedding_http, _, _, _}
  end

  test "malformed indexed responses never fall back to keyword or hash retrieval", ctx do
    seed(ctx)
    before = durable_record(ctx.agent)

    for mode <- [:duplicate, :missing, :zero, :wrong_dimension, :over_budget, :unavailable] do
      Agent.update(ctx.backend, fn _ -> mode end)
      assert {:error, _} = search(ctx, "restart only crashed child")
      assert_receive {:embedding_http, _, "POST", _}
      refute_receive {:embedding_http, _, _, _}
      assert durable_record(ctx.agent) == before
    end
  end

  test "graph changes during a held HTTP result refuse stale publication", ctx do
    seed(ctx)
    Agent.update(ctx.backend, fn _ -> :held end)
    task = Task.async(fn -> search(ctx, "restart only crashed child") end)
    assert_receive {:embedding_http, worker, "POST", _}, 5_000

    assert {:ok, _} =
             Memory.add_knowledge(ctx.agent, %{
               type: :fact,
               content: "A committed concurrent change."
             })

    send(worker, :release)
    assert {:error, :hybrid_search_snapshot_changed} = Task.await(task, 10_000)
    refute_receive {:embedding_http, _, _, _}
  end

  test "revocation during a held HTTP result refuses publication", ctx do
    seed(ctx)
    Agent.update(ctx.backend, fn _ -> :held end)
    task = Task.async(fn -> search(ctx, "restart only crashed child") end)
    assert_receive {:embedding_http, worker, "POST", _}, 5_000
    assert :ok = Arbor.Security.revoke(ctx.cap.id)
    send(worker, :release)
    assert {:error, {:unauthorized, _}} = Task.await(task, 10_000)
    refute_receive {:embedding_http, _, _, _}
  end

  test "custom Record or Replay composition is rejected before sending graph content", ctx do
    seed(ctx)
    Application.put_env(:arbor_llm, :pipeline, [Arbor.LLM.Plugs.Replay, Arbor.LLM.Plugs.Dispatch])

    assert {:error, :live_embedding_pipeline_unsupported} =
             search(ctx, "restart only crashed child")

    refute_receive {:embedding_http, _, _, _}
  end

  defp route,
    do: [
      enabled: true,
      provider: "lm_studio",
      model: @model,
      base_url: @base,
      timeout_ms: 10_000,
      min_cosine: 0.7,
      min_score: 0.6,
      semantic_weight: 0.7
    ]

  defp search(ctx, query, opts \\ []),
    do: Memory.authorize_hybrid_search(ctx.agent, ctx.agent, query, opts)

  defp durable_record(agent) do
    assert {:ok, record} =
             Persistence.get(:arbor_memory_durable, BufferedStore, "knowledge_graph:#{agent}")

    record
  end

  defp seed(ctx) do
    Map.new(ctx.corpus["documents"], fn doc ->
      assert {:ok, id} =
               Memory.add_knowledge(ctx.agent, %{
                 type: :fact,
                 content: doc["content"],
                 confidence: 0.4,
                 metadata: %{"fixture_id" => doc["id"]}
               })

      {doc["id"], id}
    end)
  end

  defp vector(axis), do: for(index <- 0..767, do: if(index == axis, do: 1.0, else: 0.0))
  defp corrupt([first | rest], :duplicate), do: [first, %{first | "index" => 0} | tl(rest)]
  defp corrupt([_first | rest], :missing), do: rest

  defp corrupt(rows, :zero),
    do: Enum.map(rows, &Map.put(&1, "embedding", List.duplicate(0.0, 768)))

  defp corrupt([first | rest], :wrong_dimension), do: [Map.put(first, "embedding", [1.0]) | rest]
  defp corrupt(rows, _), do: rows
end
