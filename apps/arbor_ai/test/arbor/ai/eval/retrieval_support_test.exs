defmodule Arbor.AI.Eval.RetrievalSupportTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.RetrievalSupport

  test "rejects malformed option containers before keyword access" do
    assert RetrievalSupport.validate_opts(%{}) ==
             {:error, {:invalid_options, :keyword_required}}

    assert RetrievalSupport.validate_opts([:not_a_keyword]) ==
             {:error, {:invalid_options, :keyword_required}}
  end

  test "security regression: UTF-8 truncation enforces a hard byte ceiling" do
    single_grapheme = "a" <> String.duplicate("\u0301", 5_000)

    truncated = RetrievalSupport.truncate_utf8(single_grapheme, 32)

    assert byte_size(truncated) <= 32
    assert String.valid?(truncated)
    refute truncated == single_grapheme
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

  test "security regression: index loading rejects symlinks and non-regular files" do
    target_path = temp_path("symlink-target")
    symlink_path = temp_path("symlink")
    directory_path = temp_path("directory")

    File.write!(target_path, Jason.encode!(%{"actions" => [minimal_action()]}))
    File.ln_s!(target_path, symlink_path)
    File.mkdir!(directory_path)

    on_exit(fn -> File.rm(symlink_path) end)
    on_exit(fn -> File.rm(target_path) end)
    on_exit(fn -> File.rmdir(directory_path) end)

    assert RetrievalSupport.load_index(symlink_path) ==
             {:error, {:index_file_rejected, symlink_path, :symlink}}

    assert RetrievalSupport.load_index(directory_path) ==
             {:error, {:index_file_rejected, directory_path, {:not_regular, :directory}}}
  end

  test "security regression: FIFO index paths return within the absolute read deadline" do
    fifo_path = temp_path("fifo")
    {_, 0} = System.cmd("mkfifo", [fifo_path])
    on_exit(fn -> File.rm(fifo_path) end)

    task = Task.async(fn -> RetrievalSupport.load_index(fifo_path) end)

    assert {:ok, {:error, {:index_file_rejected, ^fifo_path, {:not_regular, type}}}} =
             Task.yield(task, 1_000)

    assert type in [:device, :other]
  end

  test "security regression: index swaps are detected or rejected without blocking" do
    path = temp_path("swap")
    regular_path = temp_path("swap-regular")
    fifo_path = temp_path("swap-fifo")
    body = Jason.encode!(%{"actions" => [minimal_action()]})

    File.write!(path, body)
    File.write!(regular_path, body)
    {_, 0} = System.cmd("mkfifo", [fifo_path])

    on_exit(fn -> File.rm(path) end)
    on_exit(fn -> File.rm(regular_path) end)
    on_exit(fn -> File.rm(fifo_path) end)

    swapper =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        for _ <- 1..2_000 do
          swap_paths(path, regular_path, fifo_path)
        end
      end)

    loaders =
      for _ <- 1..50 do
        Task.async(fn ->
          receive do
            :go -> RetrievalSupport.load_index(path)
          end
        end)
      end

    send(swapper.pid, :go)
    Enum.each(loaders, &send(&1.pid, :go))

    results =
      Enum.map(loaders, fn task ->
        assert {:ok, result} = Task.yield(task, 1_000)
        result
      end)

    Task.await(swapper, 10_000)

    assert Enum.all?(results, fn
             {:ok, [_action]} -> true
             {:error, {:index_file_rejected, ^path, _reason}} -> true
             {:error, {:index_read_failed, ^path, _reason}} -> true
             _other -> false
           end)
  end

  test "security regression: direct index paths are byte bounded before UTF-8 work" do
    oversized_invalid_path = <<255>> <> String.duplicate("p", 4_096)

    assert RetrievalSupport.load_index(oversized_invalid_path) ==
             {:error, {:invalid_option, :index_path, {:byte_size_exceeded, 4_096}}}
  end

  test "security regression: index text fields are byte bounded before retention" do
    path = temp_path("field-limits")
    on_exit(fn -> File.rm(path) end)

    oversized_module = %{minimal_action() | "module" => String.duplicate("m", 513)}
    File.write!(path, Jason.encode!(%{"actions" => [oversized_module]}))

    assert RetrievalSupport.load_index(path) ==
             {:error, {:invalid_index, path, 0, {:field_bytes_exceeded, :module, 512}}}

    oversized_description = %{
      minimal_action()
      | "description" => String.duplicate("d", 16_385)
    }

    File.write!(path, Jason.encode!(%{"actions" => [oversized_description]}))

    assert RetrievalSupport.load_index(path) ==
             {:error, {:invalid_index, path, 0, {:field_bytes_exceeded, :description, 16_384}}}

    oversized_model = %{
      minimal_action()
      | "embeddings" => %{String.duplicate("e", 513) => [1.0]}
    }

    File.write!(path, Jason.encode!(%{"actions" => [oversized_model]}))

    assert RetrievalSupport.load_index(path) ==
             {:error,
              {:invalid_index, path, 0,
               {:invalid_embedding_model, {:field_bytes_exceeded, :model, 512}}}}
  end

  test "security regression: rejects excessive index entries with a shaped error" do
    entries_path = temp_path("entries")
    on_exit(fn -> File.rm(entries_path) end)

    action = %{"module" => "Arbor.Actions.Test", "description" => "test", "embeddings" => %{}}
    File.write!(entries_path, Jason.encode!(%{"actions" => List.duplicate(action, 2_001)}))

    assert RetrievalSupport.load_index(entries_path) ==
             {:error, {:invalid_index, entries_path, {:entry_count_exceeded, 2_000}}}
  end

  test "security regression: rejects excessive vector dimensions with a shaped error" do
    dimensions_path = temp_path("dimensions")
    on_exit(fn -> File.rm(dimensions_path) end)

    action = %{"module" => "Arbor.Actions.Test", "description" => "test", "embeddings" => %{}}

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
      {:judge_timeout, 300_001, 60_000, 300_000}
    ]

    for {key, value, default, maximum} <- cases do
      assert RetrievalSupport.positive_integer_option([{key, value}], key, default) ==
               {:error, {:invalid_option, key, {:integer_range_required, 1, maximum}}}
    end
  end

  test "leaves max_tokens unset and accepts explicit positive integers without a guessed cap" do
    assert RetrievalSupport.optional_positive_integer_option([], :max_tokens) == {:ok, nil}

    assert RetrievalSupport.optional_positive_integer_option([max_tokens: 1_000_000], :max_tokens) ==
             {:ok, 1_000_000}

    assert RetrievalSupport.optional_positive_integer_option([max_tokens: 0], :max_tokens) ==
             {:error, {:invalid_option, :max_tokens, :positive_integer_required}}
  end

  test "security regression: huge max_tokens and external terms are representation bounded" do
    huge_integer = :erlang.bsl(1, 1_000_000)

    assert RetrievalSupport.optional_positive_integer_option(
             [max_tokens: huge_integer],
             :max_tokens
           ) ==
             {:error,
              {:invalid_option, :max_tokens,
               {:integer_range_required, 1, 9_223_372_036_854_775_807}}}

    bounded =
      RetrievalSupport.bounded_external_reason(
        {:transport_failed, List.duplicate(String.duplicate("e", 2_000), 100_000)}
      )

    assert {:transport_failed, values} = bounded
    assert length(values) == 17
    assert List.last(values) == :truncated
    assert byte_size(:erlang.term_to_binary(bounded)) < 12_000

    assert {:error, {:transport_failed, callback_values}} =
             RetrievalSupport.invoke(
               fn ->
                 {:error,
                  {:transport_failed, List.duplicate(String.duplicate("c", 2_000), 100_000)}}
               end,
               [],
               :callback_failed
             )

    assert length(callback_values) == 17
    assert List.last(callback_values) == :truncated
  end

  test "security regression: bounded HTTP collector halts before retaining an oversized body" do
    previous_options = Req.default_options()
    on_exit(fn -> Req.default_options(previous_options) end)

    Req.default_options(
      adapter: fn request ->
        response = Req.Response.new(status: 200)
        request.into.({:data, String.duplicate("x", 1_000_000)}, {request, response}) |> elem(1)
      end
    )

    assert RetrievalSupport.post_json("http://bounded.test/api/chat", %{}, 1_000, 32) ==
             {:error, {:http_response_bytes_exceeded, 32}}
  end

  defp minimal_action do
    %{
      "module" => "Arbor.Actions.Test",
      "description" => "test",
      "embeddings" => %{}
    }
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor-ai-retrieval-#{label}-#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end

  defp swap_paths(path, regular_path, fifo_path) do
    swap_temp = path <> ".swap"

    with :ok <- File.rename(path, swap_temp),
         :ok <- File.rename(fifo_path, path),
         :ok <- File.rename(path, fifo_path),
         :ok <- File.rename(regular_path, path),
         :ok <- File.rename(swap_temp, regular_path) do
      :ok
    else
      {:error, _reason} -> :ok
    end
  end
end
