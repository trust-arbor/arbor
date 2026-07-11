defmodule Arbor.AI.Eval.RetrievalSupportTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.Eval.RetrievalSupport

  test "rejects malformed option containers before keyword access" do
    assert RetrievalSupport.validate_opts(%{}) ==
             {:error, {:invalid_options, :keyword_required}}

    assert RetrievalSupport.validate_opts([:not_a_keyword]) ==
             {:error, {:invalid_options, :keyword_required}}
  end

  test "rejects index files beyond the hard byte ceiling before decoding" do
    path = temp_path("oversized")

    File.open!(path, [:write, :binary], fn io ->
      {:ok, _position} = :file.position(io, 16_777_216)
      IO.binwrite(io, "x")
    end)

    on_exit(fn -> File.rm(path) end)

    assert RetrievalSupport.load_index(path) ==
             {:error, {:index_size_exceeded, path, 16_777_216}}
  end

  test "rejects excessive index entries and vector dimensions with shaped errors" do
    entries_path = temp_path("entries")
    dimensions_path = temp_path("dimensions")
    on_exit(fn -> File.rm(entries_path) end)
    on_exit(fn -> File.rm(dimensions_path) end)

    action = %{"module" => "Arbor.Actions.Test", "description" => "test", "embeddings" => %{}}
    File.write!(entries_path, Jason.encode!(%{"actions" => List.duplicate(action, 2_001)}))

    assert RetrievalSupport.load_index(entries_path) ==
             {:error, {:invalid_index, entries_path, {:entry_count_exceeded, 2_000}}}

    vector_action =
      Map.put(action, "embeddings", %{"embed-model" => List.duplicate(0.0, 8_193)})

    File.write!(dimensions_path, Jason.encode!(%{"actions" => [vector_action]}))

    assert RetrievalSupport.load_index(dimensions_path) ==
             {:error,
              {:invalid_index, dimensions_path, 0,
               {:invalid_embedding, "embed-model", {:vector_dimensions_exceeded, 8_192}}}}
  end

  test "rejects inconsistent dimensions for one indexed model" do
    path = temp_path("inconsistent-dimensions")
    on_exit(fn -> File.rm(path) end)

    actions = [
      %{
        "module" => "Arbor.Actions.One",
        "description" => "one",
        "embeddings" => %{"embed-model" => [1.0, 0.0]}
      },
      %{
        "module" => "Arbor.Actions.Two",
        "description" => "two",
        "embeddings" => %{"embed-model" => [1.0]}
      }
    ]

    File.write!(path, Jason.encode!(%{"actions" => actions}))

    assert RetrievalSupport.load_index(path) ==
             {:error,
              {:invalid_index, path, {:inconsistent_embedding_dimensions, "embed-model", 2, 1}}}
  end

  test "enforces conservative retrieval and transport option ceilings" do
    cases = [
      {:top_k, 101, 5, 100},
      {:candidate_k, 501, 10, 500},
      {:max_desc_chars, 4_097, 200, 4_096},
      {:timeout, 300_001, 30_000, 300_000},
      {:judge_timeout, 300_001, 60_000, 300_000},
      {:max_tokens, 16_385, 1_024, 16_384}
    ]

    for {key, value, default, maximum} <- cases do
      assert RetrievalSupport.positive_integer_option([{key, value}], key, default) ==
               {:error, {:invalid_option, key, {:integer_range_required, 1, maximum}}}
    end
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor-ai-retrieval-#{label}-#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end
end
