defmodule Arbor.AI.Eval.Graders.EmbeddingSimilarityTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.Graders.EmbeddingSimilarity

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vector = [1.0, 2.0, 3.0]
      assert_in_delta EmbeddingSimilarity.cosine_similarity(vector, vector), 1.0, 0.001
    end

    test "returns 0.0 for orthogonal vectors" do
      assert_in_delta(
        EmbeddingSimilarity.cosine_similarity([1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
        0.0,
        0.001
      )
    end

    test "returns -1.0 for opposite vectors" do
      assert_in_delta EmbeddingSimilarity.cosine_similarity([1.0, 0.0], [-1.0, 0.0]),
                      -1.0,
                      0.001
    end

    test "handles zero vectors" do
      assert EmbeddingSimilarity.cosine_similarity([0.0, 0.0], [1.0, 2.0]) == 0.0
    end

    test "security regression: validated extreme vectors avoid underflow and overflow" do
      tiny = [1.0e-300, -1.0e-300]
      mixed = [1.0e100, 1.0e-300, -1.0e100]

      assert_in_delta EmbeddingSimilarity.cosine_similarity(tiny, tiny), 1.0, 1.0e-12
      assert_in_delta EmbeddingSimilarity.cosine_similarity(mixed, mixed), 1.0, 1.0e-12

      assert_in_delta(
        EmbeddingSimilarity.cosine_similarity(tiny, [-1.0e-300, 1.0e-300]),
        -1.0,
        1.0e-12
      )

      assert EmbeddingSimilarity.cosine_similarity([1.0e101], [1.0e101]) == 0.0
    end
  end

  describe "grade/3" do
    test "grades injected embeddings and respects a custom threshold" do
      embed_fn = fn texts, url, model, timeout ->
        send(self(), {:embed, texts, url, model, timeout})
        {:ok, [[1.0, 0.0], [0.8, 0.2]]}
      end

      result =
        EmbeddingSimilarity.grade("read file", "read a file",
          embed_url: "http://embedding.test/v1/embeddings",
          embed_model: "embed-model",
          timeout: 321,
          threshold: 0.95,
          embed_fn: embed_fn
        )

      assert_receive {:embed, ["read file", "read a file"], "http://embedding.test/v1/embeddings",
                      "embed-model", 321}

      assert_in_delta result.score, 0.9701, 0.001
      assert result.passed
      assert result.detail =~ "cosine_similarity="
      assert {:ok, _json} = Jason.encode(result)
    end

    test "returns unavailable when the embedding callback fails" do
      result =
        EmbeddingSimilarity.grade("hello", "hello",
          embed_fn: fn _, _, _, _ -> {:error, :offline} end
        )

      assert result.score == 0.0
      refute result.passed
      assert result.detail == "embedding unavailable: :offline"
    end

    test "security regression: combining-grapheme diagnostics obey a UTF-8 byte ceiling" do
      combining = "a" <> String.duplicate("\u1AB0", 10_000)

      result =
        EmbeddingSimilarity.grade("hello", "hello",
          embed_fn: fn _, _, _, _ -> {:error, combining} end
        )

      assert byte_size(result.detail) <= 1_024
      assert String.valid?(result.detail)
      refute result.detail =~ combining
    end

    test "handles malformed input, options, and embedding responses" do
      assert EmbeddingSimilarity.grade(%{}, "expected").detail =~
               "embedding unavailable: {:invalid_input, :text_required}"

      assert EmbeddingSimilarity.grade("actual", "expected", threshold: 2).detail =~
               "invalid_option"

      result =
        EmbeddingSimilarity.grade("actual", "expected",
          embed_fn: fn _, _, _, _ -> {:ok, [[1.0], :malformed]} end
        )

      assert result.score == 0.0
      refute result.passed
      assert result.detail =~ "numeric_vector_required"

      improper = [1.0 | 2.0]

      improper_result =
        EmbeddingSimilarity.grade("actual", "expected",
          embed_fn: fn _, _, _, _ -> {:ok, [improper, [1.0]]} end
        )

      refute improper_result.passed
      assert improper_result.detail =~ "proper_vector_required"
    end

    test "security regression: oversized invalid embedding ingress never reaches callback" do
      parent = self()
      oversized = String.duplicate("x", 2_000_000) <> <<255>>

      result =
        EmbeddingSimilarity.grade(oversized, "expected",
          embed_fn: fn _, _, _, _ -> send(parent, :embed_called) end
        )

      refute_receive :embed_called
      refute result.passed
      assert result.detail =~ "text_bytes_exceeded"
    end

    test "security regression: malformed and path-confused endpoints fail before callback" do
      parent = self()

      for endpoint <- [
            "ftp://embedding.test/v1/embeddings",
            "http://user:pass@embedding.test/v1/embeddings",
            "http://embedding.test/v1/embeddings?next=/evil",
            "http://embedding.test/v1/embeddings#fragment",
            "http://embedding.test:99999/v1/embeddings",
            "http://embedding.test:abc/v1/embeddings",
            "http://embedding.test:/v1/embeddings",
            "http://[::1]x/v1/embeddings",
            "http://embedding.test:80:90/v1/embeddings",
            "http://bad host/v1/embeddings",
            "http://embedding.test/other"
          ] do
        result =
          EmbeddingSimilarity.grade("actual", "expected",
            embed_url: endpoint,
            embed_fn: fn _, _, _, _ -> send(parent, :embed_called) end
          )

        refute result.passed
        assert result.detail =~ "invalid_option"
      end

      refute_receive :embed_called
    end

    test "security regression: embedding options are capped before Keyword traversal" do
      opts = List.duplicate({:threshold, 0.5}, 17)
      result = EmbeddingSimilarity.grade("actual", "expected", opts)

      refute result.passed
      assert result.detail =~ "option_count_exceeded"

      unsupported = EmbeddingSimilarity.grade("actual", "expected", unknown: "value")
      refute unsupported.passed
      assert unsupported.detail =~ "unsupported"
    end

    test "exercises the deterministic default HTTP embedding boundary" do
      previous_options = Req.default_options()
      parent = self()

      on_exit(fn -> Req.default_options(previous_options) end)

      Req.default_options(
        adapter: fn request ->
          body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
          send(parent, {:embedding_request, request.url.path, body})

          response_body =
            Jason.encode!(%{
              "data" => [
                %{"index" => 0, "embedding" => [1.0, 0.0]},
                %{"index" => 1, "embedding" => [0.8, 0.2]}
              ]
            })

          response =
            Req.Response.new(
              status: 200,
              headers: %{"content-type" => ["application/json"]},
              body: response_body
            )

          {request, response}
        end
      )

      result =
        EmbeddingSimilarity.grade("actual", "expected",
          embed_url: "http://embedding.test/v1/embeddings",
          embed_model: "http-model",
          timeout: 1_000
        )

      assert_receive {:embedding_request, "/v1/embeddings", request_body}
      assert request_body == %{"input" => ["actual", "expected"], "model" => "http-model"}
      assert_in_delta result.score, 0.9701, 0.001
      assert result.passed
    end

    test "security regression: default HTTP grader path accepts reversed indexed wire order" do
      previous_options = Req.default_options()

      on_exit(fn -> Req.default_options(previous_options) end)

      data = [
        %{"index" => 1, "embedding" => [0.8, 0.2]},
        %{"index" => 0, "embedding" => [1.0, 0.0]}
      ]

      Req.default_options(adapter: embedding_response_adapter(data))

      assert {:ok, [first, second], %{}} =
               Arbor.LLM.decode_embedding_response(%{"data" => data}, 2)

      assert first == [1.0, 0.0]
      assert second == [0.8, 0.2]

      result =
        EmbeddingSimilarity.grade("actual", "expected",
          embed_url: "http://embedding.test/v1/embeddings",
          embed_model: "http-model",
          timeout: 1_000
        )

      assert_in_delta result.score, 0.9701, 0.001
      assert result.passed
    end

    test "security regression: default HTTP grader rejects malformed embedding indices" do
      previous_options = Req.default_options()

      on_exit(fn -> Req.default_options(previous_options) end)

      malformed_batches = [
        [
          %{"index" => 0, "embedding" => [1.0, 0.0]},
          %{"index" => 0, "embedding" => [1.0, 0.0]}
        ],
        [
          %{"embedding" => [1.0, 0.0]},
          %{"index" => 1, "embedding" => [1.0, 0.0]}
        ],
        [
          %{"index" => -1, "embedding" => [1.0, 0.0]},
          %{"index" => 1, "embedding" => [1.0, 0.0]}
        ],
        [
          %{"index" => 1_000_000, "embedding" => [1.0, 0.0]},
          %{"index" => 1, "embedding" => [1.0, 0.0]}
        ],
        [
          %{"index" => 0.0, "embedding" => [1.0, 0.0]},
          %{"index" => 1, "embedding" => [1.0, 0.0]}
        ]
      ]

      for data <- malformed_batches do
        Req.default_options(adapter: embedding_response_adapter(data))

        result =
          EmbeddingSimilarity.grade("actual", "expected",
            embed_url: "http://embedding.test/v1/embeddings",
            embed_model: "http-model",
            timeout: 1_000,
            threshold: 0.99
          )

        refute result.passed
        assert result.detail =~ "invalid_embedding_response"
      end
    end
  end

  defp embedding_response_adapter(data) do
    fn request ->
      body = Jason.encode!(%{"data" => data})

      response =
        Req.Response.new(
          status: 200,
          headers: %{"content-type" => ["application/json"]},
          body: body
        )

      {request, response}
    end
  end
end
