defmodule Arbor.LLM.Plugs.FixtureTest do
  @moduledoc """
  Tests the shared fixture helpers — request hashing + JSON
  round-trip for all four operation types.

  The round-trip is the load-bearing claim: `load(call)` should
  reconstruct what `save(call, result)` persisted. Each operation
  has its own result shape, so each gets its own round-trip test:

    * `:complete` → `{:ok, %ReqLLM.Response{}}`
    * `:stream` → `{:ok, [%StreamEvent{}, ...]}`
    * `:embed_cloud` / `:embed_local` → `{:ok, embeddings, usage}`
    * any → `{:error, reason}` (reason gets stringified)

  Fixtures land in a per-test tmp dir to avoid polluting the
  committed fixtures path.
  """

  # async: false — tests mutate `Application.put_env(:arbor_llm, :recorder, ...)`
  # which is process-global. Running concurrently would let tests
  # read each other's tmp_dir setting.
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.FileReceipt
  alias Arbor.LLM.OwnedStream
  alias Arbor.LLM.Plugs.Fixture
  alias Arbor.LLM.StreamEvent

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_llm_fixture_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original_config = Application.get_env(:arbor_llm, :recorder)
    Application.put_env(:arbor_llm, :recorder, fixtures_path: tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      case original_config do
        nil -> Application.delete_env(:arbor_llm, :recorder)
        value -> Application.put_env(:arbor_llm, :recorder, value)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ── Request hash stability ─────────────────────────────────────────

  describe "request_hash/1" do
    test "identical call shape → identical hash" do
      call_a =
        Call.new(
          :complete,
          {"openai:gpt-4o-mini", [%{role: :user, content: "hi"}], [temperature: 0.0]}
        )

      call_b =
        Call.new(
          :complete,
          {"openai:gpt-4o-mini", [%{role: :user, content: "hi"}], [temperature: 0.0]}
        )

      assert Fixture.request_hash(call_a) == Fixture.request_hash(call_b)
    end

    test "different model → different hash" do
      call_a = Call.new(:complete, {"openai:gpt-4o-mini", [], []})
      call_b = Call.new(:complete, {"openai:gpt-4o", [], []})

      refute Fixture.request_hash(call_a) == Fixture.request_hash(call_b)
    end

    test "different operation → different hash even with same request" do
      complete_call = Call.new(:complete, {"openai:x", [], []})
      stream_call = Call.new(:stream, {"openai:x", [], []})

      refute Fixture.request_hash(complete_call) == Fixture.request_hash(stream_call)
    end

    test "scrubs per-call-volatile opts (signed_request, base_url, provider)" do
      with_volatile =
        Call.new(
          :complete,
          {"openai:gpt-4o-mini", [],
           [
             temperature: 0.0,
             signed_request: %{nonce: "abc", sig: "xyz"},
             base_url: "http://localhost:11434/v1",
             provider: "ollama"
           ]}
        )

      without_volatile =
        Call.new(:complete, {"openai:gpt-4o-mini", [], [temperature: 0.0]})

      assert Fixture.request_hash(with_volatile) == Fixture.request_hash(without_volatile)
    end

    test "opts ordering doesn't matter (Keyword.sort under the hood)" do
      call_a = Call.new(:complete, {"openai:gpt-4o-mini", [], [temperature: 0.0, max_tokens: 32]})
      call_b = Call.new(:complete, {"openai:gpt-4o-mini", [], [max_tokens: 32, temperature: 0.0]})

      assert Fixture.request_hash(call_a) == Fixture.request_hash(call_b)
    end
  end

  # ── Path resolution ────────────────────────────────────────────────

  describe "path_for/1" do
    test "lands under the configured fixtures_path", %{tmp_dir: tmp_dir} do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})
      path = Fixture.path_for(call)

      assert String.starts_with?(path, tmp_dir)
      assert String.ends_with?(path, ".json")
    end
  end

  describe "fixture publication" do
    test "security regression: publication is in-process and contains no Python helper" do
      {FileReceipt, beam, _filename} = :code.get_object_code(FileReceipt)
      assert :binary.match(beam, "/usr/bin/python3") == :nomatch
    end

    test "security regression: publication is atomic no-clobber", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no-clobber.json")

      assert :ok = FileReceipt.publish(path, "first", 1_024)
      assert {:error, :destination_exists} = FileReceipt.publish(path, "second", 1_024)
      assert File.read!(path) == "first"

      assert {:ok, %File.Stat{type: :regular, links: 1}} = File.lstat(path)
      refute Enum.any?(File.ls!(tmp_dir), &String.starts_with?(&1, ".arbor-fixture-"))
    end

    @tag timeout: 8_000
    test "security regression: publication has no suspendable helper child", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "in-process-publication.json")
      body = :binary.copy("x", 16_777_216)
      known_ports = MapSet.new(Port.list())
      task = Task.async(fn -> FileReceipt.publish(path, body, byte_size(body)) end)

      case await_publish_helper(task, known_ports, System.monotonic_time(:millisecond) + 1_000) do
        {:completed, result} ->
          assert result == :ok

        {:helper, os_pid} ->
          :ok = signal_os_process(os_pid, "-STOP")

          try do
            result = Task.await(task, 6_000)
            orphaned? = os_process_alive?(os_pid)

            refute orphaned?,
                   "suspended fixture helper outlived the publication owner deadline"

            assert result == :ok
          after
            terminate_os_process(os_pid)
          end
      end
    end
  end

  # ── Round-trip: :complete ──────────────────────────────────────────

  describe "save/2 + load/1 — :complete" do
    test "round-trips a plain text response" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [%{role: :user, content: "hi"}], []})

      original_response =
        {:ok,
         req_response("Hello there!",
           finish_reason: :stop,
           usage: %{input_tokens: 12, output_tokens: 4, total_cost: 3.0e-6}
         )}

      :ok = Fixture.save(call, original_response)

      {:ok, replayed, %DateTime{}} = Fixture.load(call)

      assert {:ok, %ReqLLM.Response{} = replayed_response} = replayed
      assert ReqLLM.Response.text(replayed_response) == "Hello there!"
      assert replayed_response.finish_reason == :stop
      assert replayed_response.message.role == :assistant
      assert replayed_response.provider_meta == %{}
      assert replayed_response.error == nil

      # Usage values survive — verifying that the cost data (which we
      # care about for the future CostTracker plug) survives the
      # round-trip in usable form.
      assert replayed_response.usage[:input_tokens] == 12
      assert replayed_response.usage[:output_tokens] == 4
      assert replayed_response.usage[:total_cost] == 3.0e-6
    end

    test "round-trips a tool-call response" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      original_response =
        {:ok,
         req_response("Let me check.",
           finish_reason: :tool_calls,
           tool_calls: [ReqLLM.ToolCall.new("call_abc", "get_weather", ~s({"city":"NYC"}))],
           usage: %{input_tokens: 58, output_tokens: 16}
         )}

      :ok = Fixture.save(call, original_response)
      {:ok, replayed, _ts} = Fixture.load(call)

      assert {:ok,
              %ReqLLM.Response{finish_reason: :tool_calls, message: message} = replayed_response} =
               replayed

      assert [%ReqLLM.ToolCall{id: "call_abc", function: function}] = message.tool_calls
      assert function["name"] == "get_weather"
      assert Jason.decode!(function["arguments"]) == %{"city" => "NYC"}
      assert ReqLLM.Response.text(replayed_response) == "Let me check."
    end

    test "writes a closed v2 ReqLLM payload without provider internals" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      response =
        req_response("answer",
          content: [
            ReqLLM.Message.ContentPart.thinking("private reasoning"),
            ReqLLM.Message.ContentPart.text("answer")
          ],
          reasoning_details: [
            %ReqLLM.Message.ReasoningDetails{
              text: "private reasoning",
              signature: "encrypted-signature",
              encrypted?: true,
              provider: :openai,
              provider_data: %{"secret" => "provider-internal"}
            }
          ],
          tool_calls: [ReqLLM.ToolCall.new("call_1", "lookup", "{}")],
          usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5, total_cost: 0.01}
        )

      :ok = Fixture.save(call, {:ok, response})
      fixture = call |> Fixture.path_for() |> File.read!() |> Jason.decode!()
      value = fixture["response"]["value"]

      assert fixture["schema_version"] == 2
      assert value["response_kind"] == "req_llm"
      assert value["thinking"] == ["private reasoning"]
      assert value["tool_calls"] == [%{"id" => "call_1", "name" => "lookup", "arguments" => "{}"}]
      refute Map.has_key?(value, "context")
      refute Map.has_key?(value, "provider_meta")
      refute Map.has_key?(value, "raw")
      refute Map.has_key?(value, "error")
      refute File.read!(Fixture.path_for(call)) =~ "encrypted-signature"
      refute File.read!(Fixture.path_for(call)) =~ "provider-internal"
    end

    test "preserves thinking-part fallback when reasoning details are empty" do
      call = Call.new(:complete, {"openai:empty-reasoning-details", [], []})

      response =
        req_response("answer",
          content: [
            ReqLLM.Message.ContentPart.thinking("fallback reasoning"),
            ReqLLM.Message.ContentPart.text("answer")
          ],
          reasoning_details: [%ReqLLM.Message.ReasoningDetails{text: ""}]
        )

      :ok = Fixture.save(call, {:ok, response})
      {:ok, {:ok, replayed}, _recorded_at} = Fixture.load(call)

      assert ReqLLM.Response.thinking(replayed) == "fallback reasoning"
    end

    test "loads legacy v1 Arbor response wire shape into ReqLLM" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      write_fixture(call, %{
        "outcome" => "ok",
        "value" => %{
          "text" => "legacy answer",
          "finish_reason" => "tool_calls",
          "content_parts" => [
            %{"kind" => "thinking", "text" => "legacy reasoning", "signature" => "ignore-me"},
            %{
              "kind" => "tool_call",
              "id" => "legacy-call",
              "name" => "lookup",
              "arguments" => %{"q" => "x"}
            },
            %{"kind" => "text", "text" => "legacy answer"}
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_cost" => 0.02},
          "warnings" => ["ignored"]
        }
      })

      assert {:ok, {:ok, %ReqLLM.Response{} = response}, %DateTime{}} = Fixture.load(call)
      assert ReqLLM.Response.text(response) == "legacy answer"
      assert ReqLLM.Response.thinking(response) == "legacy reasoning"
      assert [%ReqLLM.ToolCall{id: "legacy-call"}] = response.message.tool_calls
      assert response.usage == %{input_tokens: 4, output_tokens: 2, total_cost: 0.02}
    end

    test "rejects unknown fixture versions and malformed v2 complete values" do
      call = Call.new(:complete, {"openai:versioned", [], []})

      write_fixture(
        call,
        %{
          "schema_version" => 99,
          "outcome" => "ok",
          "value" => %{}
        },
        99
      )

      assert {:error, {:invalid_fixture, {:unsupported_schema_version, 99}}} = Fixture.load(call)

      write_fixture(
        call,
        %{
          "schema_version" => 2,
          "outcome" => "ok",
          "value" => %{
            "response_kind" => "not_req_llm",
            "text" => "x",
            "thinking" => [],
            "tool_calls" => [],
            "finish_reason" => "stop",
            "usage" => %{}
          }
        },
        2
      )

      assert {:error, {:invalid_fixture, _reason}} = Fixture.load(call)
    end

    test "rejects normalized Arbor responses instead of persisting them as raw" do
      call = Call.new(:complete, {"openai:wrong-boundary", [], []})

      assert {:error, reason} =
               Fixture.save(call, {:ok, %Arbor.LLM.Response{text: "not live boundary"}})

      assert inspect(reason) =~ "req_llm_response_required"
      refute File.exists?(Fixture.path_for(call))
    end

    test "rejects unknown keys in v2 usage" do
      call = Call.new(:complete, {"openai:v2-usage", [], []})

      write_fixture(
        call,
        %{
          "outcome" => "ok",
          "value" => %{
            "response_kind" => "req_llm",
            "text" => "answer",
            "thinking" => [],
            "tool_calls" => [],
            "finish_reason" => "stop",
            "usage" => %{"input_tokens" => 1, "provider_secret" => 2}
          }
        },
        2
      )

      assert {:error, {:invalid_fixture, _reason}} = Fixture.load(call)
    end

    test "rejects oversized and count-excess complete response collections without publication" do
      cases = [
        {
          "oversized text",
          req_response("",
            content: [ReqLLM.Message.ContentPart.text(String.duplicate("x", 1_048_577))]
          )
        },
        {
          "content count",
          req_response("", content: List.duplicate(ReqLLM.Message.ContentPart.text("x"), 100_001))
        },
        {
          "reasoning count",
          req_response("",
            content: [],
            reasoning_details: List.duplicate(reasoning_detail(), 100_001)
          )
        },
        {
          "tool call count",
          req_response("", content: [], tool_calls: List.duplicate(tool_call(), 100_001))
        }
      ]

      Enum.each(cases, fn {label, response} ->
        call = Call.new(:complete, {"openai:bounded-#{label}", [], []})

        assert {:error, reason} = Fixture.save(call, {:ok, response})
        assert inspect(reason) =~ "complete_response", label
        refute File.exists?(Fixture.path_for(call))
      end)
    end

    test "fails closed for nil or malformed live content and reasoning details" do
      malformed = [
        req_response("", content: nil),
        req_response("", content: [%{type: :text, text: "answer"}]),
        req_response("", content: [], reasoning_details: "not-a-list"),
        req_response("", content: [], reasoning_details: [%{text: "not-a-struct"}])
      ]

      Enum.each(Enum.with_index(malformed), fn {response, index} ->
        call = Call.new(:complete, {"openai:malformed-#{index}", [], []})
        assert {:error, _reason} = Fixture.save(call, {:ok, response})
        refute File.exists?(Fixture.path_for(call))
      end)
    end

    test "round-trips an :error result" do
      call = Call.new(:complete, {"openai:bogus-model", [], []})

      :ok = Fixture.save(call, {:error, :model_not_found})

      # The exact reason gets stringified via inspect() on save and
      # tagged with :replayed_error on load — we don't care about the
      # exact string, just that the error tag survives the round-trip.
      assert {:ok, {:error, {:replayed_error, reason}}, %DateTime{}} = Fixture.load(call)
      assert is_binary(reason)
      assert reason =~ "model_not_found"
    end
  end

  # ── Round-trip: :stream ────────────────────────────────────────────

  describe "save/2 + load/1 — :stream" do
    test "round-trips a list of stream events" do
      call = Call.new(:stream, {"openai:gpt-4o-mini", [], []})

      events = [
        %StreamEvent{type: :delta, data: %{text: "Hello"}},
        %StreamEvent{type: :delta, data: %{text: " world"}},
        %StreamEvent{type: :step_finish, data: %{terminal?: true}}
      ]

      :ok = Fixture.save(call, {:ok, events})
      {:ok, {:ok, replayed_events}, _ts} = Fixture.load(call)

      assert length(replayed_events) == 3
      [first, second, third] = replayed_events

      assert %StreamEvent{type: :delta, data: %{text: "Hello"}} = first
      assert %StreamEvent{type: :delta, data: %{text: " world"}} = second
      assert %StreamEvent{type: :step_finish} = third
    end

    test "security regression: recording enforces the cumulative event limit" do
      event_call =
        Call.new(
          :stream,
          {"openai:bounded-stream", [], [max_stream_events: 4, timeout_ms: 1_000]}
        )

      events = List.duplicate(%StreamEvent{type: :delta, data: %{text: "x"}}, 100)

      assert {:error, event_reason} = Fixture.save(event_call, {:ok, events})
      assert inspect(event_reason) =~ "stream_limit_exceeded"
      refute File.exists?(Fixture.path_for(event_call))
    end

    test "security regression: recording rejects unowned lazy streams before enumeration" do
      unowned_call = Call.new(:stream, {"openai:unowned-stream", [], [timeout_ms: 100]})
      test_pid = self()

      unowned =
        Stream.resource(
          fn -> :waiting end,
          fn state ->
            send(test_pid, :unowned_next_called)
            {:halt, state}
          end,
          fn _state -> :ok end
        )

      assert {:error, unowned_reason} = Fixture.save(unowned_call, {:ok, unowned})
      assert inspect(unowned_reason) =~ "owned_stream_or_eager_list_required"
      refute_receive :unowned_next_called
      refute File.exists?(Fixture.path_for(unowned_call))
    end

    test "security regression: live BoundedStream result is rejected without enumeration" do
      call = Call.new(:stream, {"openai:bounded-stream", [], []})
      stream = %Arbor.LLM.Adapter.ReqLLM.BoundedStream{stream: []}

      assert {:error, reason} = Fixture.save(call, {:ok, stream})
      assert inspect(reason) =~ "owned_stream_or_eager_list_required"
      refute File.exists?(Fixture.path_for(call))
    end

    test "security regression: recording deadline synchronously cleans up an owned stream" do
      deadline_call = Call.new(:stream, {"openai:owned-stall", [], [timeout_ms: 20]})
      test_pid = self()

      source =
        Stream.resource(
          fn -> :waiting end,
          fn state ->
            send(test_pid, {:owned_next_stalled, self()})
            Process.sleep(:infinity)
            {:halt, state}
          end,
          fn _state -> :ok end
        )

      {:ok, stream} =
        OwnedStream.new(source,
          deadline_ms: System.monotonic_time(:millisecond) + 1_000,
          timeout_ms: 1_000,
          validator: fn event -> {:ok, event} end
        )

      producer = stream.producer

      assert {:error, deadline_reason} = Fixture.save(deadline_call, {:ok, stream})

      assert inspect(deadline_reason) =~ "fixture_record_deadline_exceeded"
      assert_receive {:owned_next_stalled, ^producer}, 200
      refute Process.alive?(producer)
      refute Process.alive?(stream.controller)
      refute File.exists?(Fixture.path_for(deadline_call))

      refute Enum.any?(
               File.ls!(Fixture.fixtures_root()),
               &String.starts_with?(&1, ".arbor-fixture-")
             )
    end
  end

  # ── Round-trip: embeddings ─────────────────────────────────────────

  describe "save/2 + load/1 — :embed_cloud and :embed_local" do
    test ":embed_cloud round-trips a vector + usage" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["hello"], []})

      indexed = [%{index: 0, embedding: [0.1, 0.2, 0.3, 0.4]}]
      :ok = Fixture.save(call, {:ok, indexed, %{input_tokens: 5}})

      persisted = Fixture.path_for(call) |> File.read!() |> Jason.decode!()
      assert get_in(persisted, ["response", "value", "association_version"]) == 1

      {:ok, {:ok, replayed, usage}, _ts} = Fixture.load(call)

      assert replayed == indexed
      assert usage[:input_tokens] == 5
    end

    test "legacy single-input positional fixture remains unambiguous and replayable" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["hello"], []})

      write_fixture(call, %{
        "outcome" => "ok",
        "value" => %{
          "embeddings" => [[0.1, 0.2]],
          "usage" => %{"input_tokens" => 2}
        }
      })

      assert {:ok, {:ok, [%{index: 0, embedding: [0.1, 0.2]}], %{input_tokens: 2}}, %DateTime{}} =
               Fixture.load(call)
    end

    test "legacy multi-input positional fixture fails closed as ambiguous" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["first", "second"], []})

      write_fixture(call, %{
        "outcome" => "ok",
        "value" => %{
          "embeddings" => [[1.0, 0.0], [0.0, 1.0]],
          "usage" => %{}
        }
      })

      assert Fixture.load(call) ==
               {:error, {:invalid_embedding_fixture, :ambiguous_legacy_positional_embeddings}}
    end

    test "security regression: malformed and unsupported embedding fixture terms return bounded errors" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["hello"], []})

      malformed_values = [
        "not-an-object",
        %{"indexed_embeddings" => %{}, "usage" => %{}},
        %{
          "association_version" => 2,
          "indexed_embeddings" => [%{"index" => 0, "embedding" => [1.0]}],
          "usage" => %{}
        },
        %{"association_version" => 1, "embeddings" => [[1.0]], "usage" => %{}},
        %{"embeddings" => %{}, "usage" => %{}}
      ]

      for value <- malformed_values do
        write_fixture(call, %{"outcome" => "ok", "value" => value})

        assert {:error, reason} = Fixture.load(call)
        assert byte_size(inspect(reason)) < 1_024
      end
    end

    test ":embed_local round-trips with an LLMDB.Model spec" do
      model =
        LLMDB.Model.new!(%{id: "nomic-embed-text", model: "nomic-embed-text", provider: :openai})

      call = Call.new(:embed_local, {model, ["hello"], [base_url: "http://localhost:11434/v1"]})

      indexed = [%{index: 0, embedding: [1.0, 2.0, 3.0]}]
      :ok = Fixture.save(call, {:ok, indexed, %{}})

      {:ok, {:ok, replayed, _usage}, _ts} = Fixture.load(call)

      assert replayed == indexed
    end

    test ":embed_local hashes the LLMDB.Model struct stably across runs" do
      model_a =
        LLMDB.Model.new!(%{id: "nomic-embed-text", model: "nomic-embed-text", provider: :openai})

      model_b =
        LLMDB.Model.new!(%{id: "nomic-embed-text", model: "nomic-embed-text", provider: :openai})

      call_a = Call.new(:embed_local, {model_a, ["x"], []})
      call_b = Call.new(:embed_local, {model_b, ["x"], []})

      assert Fixture.request_hash(call_a) == Fixture.request_hash(call_b)
    end

    test "security regression: replay rejects reordered, duplicate, missing, and fabricated indices" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["first", "second"], []})
      path = Fixture.path_for(call)

      invalid_associations = [
        [
          %{"index" => 1, "embedding" => [0.0, 1.0]},
          %{"index" => 0, "embedding" => [1.0, 0.0]}
        ],
        [
          %{"index" => 0, "embedding" => [1.0, 0.0]},
          %{"index" => 0, "embedding" => [0.0, 1.0]}
        ],
        [%{"index" => 0, "embedding" => [1.0, 0.0]}],
        [
          %{"index" => 0, "embedding" => [1.0, 0.0]},
          %{"index" => 2, "embedding" => [0.0, 1.0]}
        ]
      ]

      for associations <- invalid_associations do
        File.rm(path)

        :ok =
          Fixture.save(call, {
            :ok,
            [%{index: 0, embedding: [1.0, 0.0]}, %{index: 1, embedding: [0.0, 1.0]}],
            %{}
          })

        fixture = path |> File.read!() |> Jason.decode!()

        tampered =
          put_in(
            fixture,
            ["response", "value", "indexed_embeddings"],
            associations
          )

        File.write!(path, Jason.encode!(tampered))
        assert {:error, {:invalid_embedding_fixture, _reason}} = Fixture.load(call)
      end
    end
  end

  # ── load/1 fallback ────────────────────────────────────────────────

  describe "load/1" do
    test "returns :not_found when no fixture exists" do
      call = Call.new(:complete, {"openai:never-saved", [], []})
      assert Fixture.load(call) == :not_found
    end

    test "security regression: fixture replay rejects outside symlinks and FIFOs", %{
      tmp_dir: tmp_dir
    } do
      outside = Path.join(System.tmp_dir!(), "arbor-fixture-outside-#{System.unique_integer()}")
      File.write!(outside, ~s({"recorded_at":"2026-01-01T00:00:00Z","response":{}}))
      on_exit(fn -> File.rm(outside) end)

      symlink_call = Call.new(:complete, {"openai:symlink", [], []})
      symlink_path = Fixture.path_for(symlink_call)
      File.ln_s!(outside, symlink_path)

      assert Fixture.load(symlink_call) ==
               {:error, {:invalid_fixture, {:fixture_read_failed, :symlink_rejected}}}

      fifo_call = Call.new(:complete, {"openai:fifo", [], []})
      fifo_path = Fixture.path_for(fifo_call)
      {_, 0} = System.cmd("mkfifo", [fifo_path])

      task = Task.async(fn -> Fixture.load(fifo_call) end)

      assert {:ok,
              {:error, {:invalid_fixture, {:fixture_read_failed, {:not_regular_file, _type}}}}} =
               Task.yield(task, 1_000)

      assert Path.dirname(symlink_path) == tmp_dir
    end

    test "security regression: fixture replay rejects hardlinked files", %{tmp_dir: tmp_dir} do
      call = Call.new(:complete, {"openai:hardlink", [], []})
      fixture_path = Fixture.path_for(call)
      outside = tmp_dir <> "-hardlink-source.json"

      :ok = Fixture.save(call, {:ok, req_response("linked")})
      :ok = File.rename(fixture_path, outside)
      :ok = File.ln(outside, fixture_path)
      on_exit(fn -> File.rm(outside) end)

      assert Fixture.load(call) ==
               {:error, {:invalid_fixture, {:fixture_read_failed, :hardlink_rejected}}}
    end

    test "security regression: fixture recording rejects symlink, hardlink, and FIFO destinations",
         %{tmp_dir: tmp_dir} do
      outside = tmp_dir <> "-publication-target.json"
      File.write!(outside, "outside-original")
      on_exit(fn -> File.rm(outside) end)

      symlink_call = Call.new(:complete, {"openai:save-symlink", [], []})
      symlink_path = Fixture.path_for(symlink_call)
      File.ln_s!(outside, symlink_path)

      assert {:error, symlink_reason} =
               Fixture.save(symlink_call, {:ok, req_response("must-not-write")})

      assert inspect(symlink_reason) =~ "not_regular_file"
      assert File.read!(outside) == "outside-original"
      File.rm!(symlink_path)

      hardlink_call = Call.new(:complete, {"openai:save-hardlink", [], []})
      hardlink_path = Fixture.path_for(hardlink_call)
      File.ln!(outside, hardlink_path)

      assert {:error, hardlink_reason} =
               Fixture.save(hardlink_call, {:ok, req_response("must-not-write")})

      assert inspect(hardlink_reason) =~ "hardlink_rejected"
      assert File.read!(outside) == "outside-original"
      File.rm!(hardlink_path)

      fifo_call = Call.new(:complete, {"openai:save-fifo", [], []})
      fifo_path = Fixture.path_for(fifo_call)
      {_, 0} = System.cmd("mkfifo", [fifo_path])

      task = Task.async(fn -> Fixture.save(fifo_call, {:ok, req_response("x")}) end)
      assert {:ok, {:error, fifo_reason}} = Task.yield(task, 500)
      assert inspect(fifo_reason) =~ "not_regular_file"

      refute Enum.any?(File.ls!(tmp_dir), &String.starts_with?(&1, ".arbor-fixture-"))
    end

    test "security regression: fixture serialization rejects fake structs and bignums boundedly" do
      call = Call.new(:complete, {"openai:hostile-serialization", [], []})
      huge = :erlang.bsl(1, 1_000_000)

      response =
        req_response("ok",
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "ok", metadata: %{}}],
          usage: %{input_tokens: huge}
        )

      assert {:error, reason} = Fixture.save(call, {:ok, response})
      assert byte_size(inspect(reason)) < 1_024
      refute File.exists?(Fixture.path_for(call))
    end
  end

  # ── recorded_at timestamp ──────────────────────────────────────────

  describe "recorded_at" do
    test "save stamps recorded_at; load returns a DateTime" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      before_save = DateTime.utc_now()
      :ok = Fixture.save(call, {:ok, req_response("x")})
      after_save = DateTime.utc_now()

      {:ok, _result, recorded_at} = Fixture.load(call)

      assert %DateTime{} = recorded_at
      assert DateTime.compare(recorded_at, before_save) in [:gt, :eq]
      assert DateTime.compare(recorded_at, after_save) in [:lt, :eq]
    end
  end

  defp req_response(text, opts \\ []) do
    content = Keyword.get(opts, :content, [ReqLLM.Message.ContentPart.text(text)])

    %ReqLLM.Response{
      id: "response-test",
      model: "gpt-4o-mini",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: content,
        tool_calls: Keyword.get(opts, :tool_calls),
        reasoning_details: Keyword.get(opts, :reasoning_details)
      },
      stream?: false,
      stream: nil,
      usage: Keyword.get(opts, :usage, %{}),
      finish_reason: Keyword.get(opts, :finish_reason, :stop),
      provider_meta: %{"provider_secret" => "must-not-persist"},
      error: nil
    }
  end

  defp reasoning_detail do
    %ReqLLM.Message.ReasoningDetails{text: "reasoning"}
  end

  defp tool_call do
    ReqLLM.ToolCall.new("call", "lookup", "{}")
  end

  defp write_fixture(call, response, schema_version \\ nil) do
    fixture = %{
      "operation" => Atom.to_string(call.operation),
      "request_hash" => Fixture.request_hash(call),
      "recorded_at" => "2026-07-11T00:00:00Z",
      "response" => response
    }

    fixture =
      if is_nil(schema_version),
        do: fixture,
        else: Map.put(fixture, "schema_version", schema_version)

    File.write!(Fixture.path_for(call), Jason.encode!(fixture))
  end

  defp await_publish_helper(task, known_ports, deadline) do
    case find_python_helper(known_ports) do
      {:ok, os_pid} ->
        {:helper, os_pid}

      :error ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            {:completed, result}

          {:exit, reason} ->
            {:completed, {:error, reason}}

          nil ->
            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(1)
              await_publish_helper(task, known_ports, deadline)
            else
              {:completed, Task.await(task, 6_000)}
            end
        end
    end
  end

  defp find_python_helper(known_ports) do
    Port.list()
    |> Enum.reject(&MapSet.member?(known_ports, &1))
    |> Enum.find_value(:error, fn port ->
      with {:name, ~c"/usr/bin/python3"} <- Port.info(port, :name),
           {:os_pid, os_pid} when is_integer(os_pid) <- Port.info(port, :os_pid) do
        {:ok, os_pid}
      else
        _other -> nil
      end
    end)
  end

  defp signal_os_process(os_pid, signal) do
    executable = System.find_executable("kill") || "/bin/kill"

    case System.cmd(executable, [signal, Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :signal_failed}
    end
  end

  defp os_process_alive?(os_pid), do: signal_os_process(os_pid, "-0") == :ok

  defp terminate_os_process(os_pid) do
    _ = signal_os_process(os_pid, "-CONT")
    _ = signal_os_process(os_pid, "-KILL")
    await_os_process_down(os_pid, System.monotonic_time(:millisecond) + 500)
  end

  defp await_os_process_down(os_pid, deadline) do
    if os_process_alive?(os_pid) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(1)
      await_os_process_down(os_pid, deadline)
    else
      :ok
    end
  end
end
