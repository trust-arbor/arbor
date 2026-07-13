defmodule Arbor.AI.Eval.CatalogTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.Eval.Graders.{EmbeddingSimilarity, IntentConformance}
  alias Arbor.AI.Eval.Subjects.{EmbeddingRetrieval, HybridRetrieval, LLMRouter}

  test "resolves exactly the AI-owned symbolic subjects" do
    assert Arbor.AI.eval_subject("embedding_retrieval") == EmbeddingRetrieval
    assert Arbor.AI.eval_subject("llm_router") == LLMRouter
    assert Arbor.AI.eval_subject("hybrid_retrieval") == HybridRetrieval

    assert Arbor.AI.eval_subject("passthrough") == nil
    assert Arbor.AI.eval_subject("Arbor.AI.Eval.Subjects.EmbeddingRetrieval") == nil
    assert Arbor.AI.eval_subject(EmbeddingRetrieval) == nil

    assert Enum.sort(Arbor.AI.eval_subject_names()) ==
             Enum.sort(["embedding_retrieval", "llm_router", "hybrid_retrieval"])
  end

  test "resolves exactly the AI-owned symbolic graders" do
    assert Arbor.AI.eval_grader("embedding_similarity") == EmbeddingSimilarity
    assert Arbor.AI.eval_grader("intent_conformance") == IntentConformance

    assert Arbor.AI.eval_grader("exact_match") == nil
    assert Arbor.AI.eval_grader("Arbor.AI.Eval.Graders.EmbeddingSimilarity") == nil
    assert Arbor.AI.eval_grader(EmbeddingSimilarity) == nil

    assert Enum.sort(Arbor.AI.eval_grader_names()) ==
             Enum.sort(["embedding_similarity", "intent_conformance"])
  end

  test "unknown untrusted strings do not intern atoms" do
    unknown = "untrusted_eval_#{System.unique_integer([:positive, :monotonic])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert Arbor.AI.eval_subject(unknown) == nil
    assert Arbor.AI.eval_grader(unknown) == nil
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end
end
