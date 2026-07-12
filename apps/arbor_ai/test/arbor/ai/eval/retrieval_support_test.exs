defmodule Arbor.AI.Eval.RetrievalSupportTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.Eval.RetrievalSupport

  setup do
    original = Application.get_env(:arbor_llm, :trusted_eval_endpoints)
    Application.put_env(:arbor_llm, :trusted_eval_endpoints, ["http://bounded.test"])

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:arbor_llm, :trusted_eval_endpoints),
        else: Application.put_env(:arbor_llm, :trusted_eval_endpoints, original)
    end)

    :ok
  end

  test "rejects malformed option containers before keyword access" do
    assert RetrievalSupport.validate_opts(%{}) ==
             {:error, {:invalid_options, :keyword_required}}

    assert RetrievalSupport.validate_opts([:not_a_keyword]) ==
             {:error, {:invalid_options, :keyword_required}}
  end

  test "security regression: public eval helpers are total for improper and malformed terms" do
    improper = [{:model, "value"} | :improper]

    assert {:error, _reason} = RetrievalSupport.required_string(improper, :model)
    assert {:error, _reason} = RetrievalSupport.string_option(improper, :model, "default")
    assert {:error, _reason} = RetrievalSupport.positive_integer_option(improper, :top_k, 5)

    assert {:error, _reason} =
             RetrievalSupport.optional_positive_integer_option(improper, :max_tokens)

    assert {:error, _reason} =
             RetrievalSupport.callback_option(improper, :embed_fn, 4, fn -> :ok end)

    assert {:error, _reason} =
             RetrievalSupport.endpoint_option([], :base_url, "http://localhost", :invalid)

    assert {:error, _reason} = RetrievalSupport.truncate_utf8(:not_text, 10)

    assert {:error, _reason} =
             RetrievalSupport.embeddings_for_model([%{} | :improper], "model", "index")

    assert {:error, _reason} =
             RetrievalSupport.validate_query_dimensions([:invalid | :improper], [1.0])

    assert {:error, _reason} = RetrievalSupport.parse_router_response(%{}, MapSet.new(), 1)
    assert {:error, _reason} = RetrievalSupport.validate_router_prompt(%{})
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

  test "security regression: index loading rejects hardlinked files" do
    source_path = temp_path("hardlink-source")
    linked_path = temp_path("hardlink")
    File.write!(source_path, Jason.encode!(%{"actions" => [minimal_action()]}))
    :ok = File.ln(source_path, linked_path)

    on_exit(fn -> File.rm(linked_path) end)
    on_exit(fn -> File.rm(source_path) end)

    assert RetrievalSupport.load_index(linked_path) ==
             {:error, {:index_file_rejected, linked_path, :hardlink}}
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
    root = temp_dir("swap")
    path = Path.join(root, "index.json")
    regular_path = Path.join(root, "regular.json")
    fifo_path = Path.join(root, "fifo")
    body = Jason.encode!(%{"actions" => [minimal_action()]})

    File.mkdir_p!(root)
    File.write!(path, body)
    File.write!(regular_path, body)
    {_, 0} = System.cmd("mkfifo", [fifo_path])

    on_exit(fn -> File.rm_rf(root) end)

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

  test "security regression: same-size same-second index rewrites use the new receipt bytes" do
    path = temp_path("same-size-rewrite")
    first = Jason.encode!(%{"actions" => [minimal_action("First.Action")]})
    second = Jason.encode!(%{"actions" => [minimal_action("Other.Action")]})
    assert byte_size(first) == byte_size(second)

    File.write!(path, first)
    {:ok, initial_stat} = File.stat(path, time: :posix)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, [%{module: "First.Action"}]} = RetrievalSupport.load_index(path)

    File.write!(path, second)
    :ok = File.touch(path, initial_stat.mtime)
    {:ok, rewritten_stat} = File.stat(path, time: :posix)
    assert rewritten_stat.size == initial_stat.size
    assert rewritten_stat.mtime == initial_stat.mtime

    assert {:ok, [%{module: "Other.Action"}]} = RetrievalSupport.load_index(path)
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

  test "security regression: drip-fed HTTP activity cannot extend the absolute eval deadline" do
    {url, server} = start_drip_server(100, 10)
    started = System.monotonic_time(:millisecond)

    assert RetrievalSupport.post_json(url, %{}, 120, 1_024) ==
             {:error, {:transport_error, {:deadline_exceeded, 120}}}

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 100
    assert elapsed < 300

    assert %{sent: sent, closed?: true} = Task.await(server, 2_000)
    assert sent < 100
  end

  defp minimal_action(module \\ "Arbor.Actions.Test") do
    %{
      "module" => module,
      "description" => "test",
      "embeddings" => %{}
    }
  end

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "arbor-ai-retrieval-#{label}-#{temp_suffix()}.json"
    )
  end

  defp temp_dir(label) do
    Path.join(System.tmp_dir!(), "arbor-ai-retrieval-#{label}-#{temp_suffix()}")
  end

  defp temp_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp start_drip_server(chunk_count, delay_ms) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, _request} = receive_http_headers(socket, "")

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
              "transfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
          )

        result = send_drip_chunks(socket, chunk_count, delay_ms, 0)
        :gen_tcp.close(socket)
        result
      end)

    url = "http://127.0.0.1:#{port}/api/chat"

    Application.put_env(:arbor_llm, :trusted_eval_endpoints, [
      "http://bounded.test",
      "http://127.0.0.1:#{port}"
    ])

    {url, server}
  end

  defp receive_http_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> receive_http_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_drip_chunks(_socket, maximum, _delay_ms, sent) when sent >= maximum,
    do: %{sent: sent, closed?: false}

  defp send_drip_chunks(socket, maximum, delay_ms, sent) do
    case :gen_tcp.send(socket, "1\r\n \r\n") do
      :ok ->
        Process.sleep(delay_ms)
        send_drip_chunks(socket, maximum, delay_ms, sent + 1)

      {:error, _reason} ->
        %{sent: sent, closed?: true}
    end
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
