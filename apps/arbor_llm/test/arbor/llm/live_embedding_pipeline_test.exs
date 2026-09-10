defmodule Arbor.LLM.LiveEmbeddingPipelineTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM
  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.{Dispatch, Record, Replay}

  @moduletag :fast
  @moduletag :integration
  @model "live-composition-fixture"

  defmodule FixtureDispatch do
    use Arbor.LLM.Plug

    def call(%Call{} = call) do
      send(
        Process.whereis(Elixir.Arbor.LLM.LiveEmbeddingPipelineTest),
        {:fixture_dispatch, call.metadata}
      )

      %{
        call
        | result:
            {:ok, [%{index: 0, embedding: [0.0, 1.0]}], %{prompt_tokens: 1, total_tokens: 1}}
      }
    end
  end

  setup do
    Process.register(self(), __MODULE__)

    previous =
      Enum.map(
        [:pipeline, :rate_limit_backoff_dispatch_fn, :rate_limit_backoff_sleep_fn],
        &{&1, Application.fetch_env(:arbor_llm, &1)}
      )

    Application.delete_env(:arbor_llm, :pipeline)
    Req.Test.set_req_test_to_shared()
    observer = self()
    mode = start_supervised!({Agent, fn -> :normal end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:embedding_http, self(), conn.method, Jason.decode!(body)})

      if Agent.get(mode, & &1) == :held do
        receive do
          :release -> :ok
        after
          10_000 -> raise "test-owned embedding request was not released"
        end
      end

      if Agent.get(mode, & &1) == :rate_limited do
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "test rate limit"}})
      else
        Req.Test.json(conn, %{
          "model" => @model,
          "data" => [%{"index" => 0, "embedding" => [1.0, 0.0]}],
          "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}
        })
      end
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_llm, key, value)
        {key, :error} -> Application.delete_env(:arbor_llm, key)
      end)
    end)

    %{mode: mode}
  end

  test "public live embedding uses real prepared HTTP and strips private selection" do
    assert :ok = LLM.validate_live_embedding_pipeline()

    assert {:ok, result} =
             embed(
               require_live_pipeline: true,
               provider_usage_context: %{
                 live_embedding_pipeline: [FixtureDispatch],
                 eval_fixture: %{mode: :replay}
               }
             )

    assert result.association_version == 1
    assert result.provider == "lm_studio"
    assert result.model == @model
    assert result.indexed_embeddings == [%{index: 0, embedding: [1.0, 0.0]}]
    assert_receive {:embedding_http, _, "POST", body}
    assert body["input"] == ["bounded fixture"]
    assert body["model"] == @model
    refute Map.has_key?(body, "require_live_pipeline")
    refute Map.has_key?(body, "provider_usage_context")
    refute Map.has_key?(body, "live_embedding_pipeline")
    refute_receive {:fixture_dispatch, _}
  end

  test "security regression: custom Record Replay or dispatch cannot masquerade as fresh embeddings" do
    for pipeline <- [[Replay, Dispatch], [Dispatch, Record], [FixtureDispatch], [], nil] do
      Application.put_env(:arbor_llm, :pipeline, pipeline)

      assert {:error, :live_embedding_pipeline_unsupported} =
               LLM.validate_live_embedding_pipeline()

      assert {:error, :live_embedding_pipeline_unsupported} = embed(require_live_pipeline: true)
      refute_receive {:embedding_http, _, _, _}
      refute_receive {:fixture_dispatch, _}
      assert Application.get_env(:arbor_llm, :pipeline) == pipeline
    end
  end

  test "security regression: invalid live-only markers fail before HTTP" do
    for invalid <- [false, "true", [], %{}] do
      assert {:error, :invalid_live_embedding_requirement} = embed(require_live_pipeline: invalid)
      refute_receive {:embedding_http, _, _, _}
    end
  end

  test "ordinary embedding retains its explicitly configured pipeline" do
    Application.put_env(:arbor_llm, :pipeline, [FixtureDispatch])
    assert {:ok, result} = embed()
    assert result.indexed_embeddings == [%{index: 0, embedding: [0.0, 1.0]}]
    assert_receive {:fixture_dispatch, _}
    refute_receive {:embedding_http, _, _, _}
  end

  test "security regression: caller metadata cannot forge live composition admission" do
    Application.put_env(:arbor_llm, :pipeline, [FixtureDispatch])
    spoof = %{"live_embedding_pipeline" => [Dispatch], live_embedding_pipeline: []}

    assert {:error, :live_embedding_pipeline_unsupported} =
             embed(require_live_pipeline: true, provider_usage_context: spoof)

    refute_receive {:fixture_dispatch, _}
    assert {:ok, _} = embed(provider_usage_context: spoof)
    assert_receive {:fixture_dispatch, metadata}
    refute Map.has_key?(metadata, :live_embedding_pipeline)
    refute Map.has_key?(metadata, "live_embedding_pipeline")
    refute_receive {:embedding_http, _, _, _}
  end

  test "live HTTP 429 remains an error with no extra dispatch or callback",
       ctx do
    observer = self()
    Agent.update(ctx.mode, fn _ -> :rate_limited end)
    Application.put_env(:arbor_llm, :rate_limit_backoff_dispatch_fn, &FixtureDispatch.call/1)

    Application.put_env(:arbor_llm, :rate_limit_backoff_sleep_fn, fn _ ->
      send(observer, :backoff_sleep)
    end)

    assert {:error, %{status: 429}} = embed(require_live_pipeline: true)
    assert_receive {:embedding_http, _, "POST", _}
    refute_receive {:embedding_http, _, _, _}
    refute_receive {:fixture_dispatch, _}
    refute_receive :backoff_sleep
  end

  test "held active HTTP keeps stock composition while later live calls refuse changed config",
       ctx do
    Agent.update(ctx.mode, fn _ -> :held end)
    task = Task.async(fn -> embed(require_live_pipeline: true) end)
    assert_receive {:embedding_http, worker, "POST", _}, 5_000
    Application.put_env(:arbor_llm, :pipeline, [FixtureDispatch])
    send(worker, :release)
    assert {:ok, result} = Task.await(task, 10_000)
    assert result.indexed_embeddings == [%{index: 0, embedding: [1.0, 0.0]}]
    assert {:error, :live_embedding_pipeline_unsupported} = embed(require_live_pipeline: true)
    assert {:ok, ordinary} = embed()
    assert ordinary.indexed_embeddings == [%{index: 0, embedding: [0.0, 1.0]}]
    assert_receive {:fixture_dispatch, _}
    refute_receive {:embedding_http, _, _, _}
  end

  defp embed(opts \\ []) do
    opts =
      Keyword.merge(
        [
          timeout_ms: 15_000,
          req_http_options: [plug: {Req.Test, __MODULE__}, retry: false, redirect: false]
        ],
        opts
      )

    LLM.embed_batch("lm_studio", @model, ["bounded fixture"], opts)
  end
end
