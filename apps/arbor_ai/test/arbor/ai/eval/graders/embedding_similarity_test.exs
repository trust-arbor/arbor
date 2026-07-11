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
                %{"embedding" => [1.0, 0.0]},
                %{"embedding" => [0.8, 0.2]}
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
  end
end
