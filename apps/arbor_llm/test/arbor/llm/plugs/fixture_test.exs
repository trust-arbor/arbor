defmodule Arbor.LLM.Plugs.FixtureTest do
  @moduledoc """
  Tests the shared fixture helpers — request hashing + JSON
  round-trip for all four operation types.

  The round-trip is the load-bearing claim: `load(call)` should
  reconstruct what `save(call, result)` persisted. Each operation
  has its own result shape, so each gets its own round-trip test:

    * `:complete` → `{:ok, %Arbor.LLM.Response{}}`
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
  alias Arbor.LLM.ContentPart
  alias Arbor.LLM.Plugs.Fixture
  alias Arbor.LLM.Response
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

  # ── Round-trip: :complete ──────────────────────────────────────────

  describe "save/2 + load/1 — :complete" do
    test "round-trips a plain text response" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [%{role: :user, content: "hi"}], []})

      original_response =
        {:ok,
         %Response{
           text: "Hello there!",
           finish_reason: :stop,
           content_parts: [ContentPart.text("Hello there!")],
           usage: %{input_tokens: 12, output_tokens: 4, total_cost: 3.0e-6},
           warnings: []
         }}

      :ok = Fixture.save(call, original_response)

      {:ok, replayed, %DateTime{}} = Fixture.load(call)

      assert {:ok, %Response{} = replayed_response} = replayed
      assert replayed_response.text == "Hello there!"
      assert replayed_response.finish_reason == :stop
      assert replayed_response.warnings == []
      assert replayed_response.raw == nil, "raw is deliberately not round-tripped"

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
         %Response{
           text: "",
           finish_reason: :tool_calls,
           content_parts: [
             ContentPart.tool_call("call_abc", "get_weather", %{"city" => "NYC"}),
             ContentPart.text("Let me check.")
           ],
           usage: %{input_tokens: 58, output_tokens: 16},
           warnings: []
         }}

      :ok = Fixture.save(call, original_response)
      {:ok, replayed, _ts} = Fixture.load(call)

      assert {:ok, %Response{finish_reason: :tool_calls, content_parts: parts}} = replayed

      tool_call_part = Enum.find(parts, &(&1.kind == :tool_call))
      assert tool_call_part.id == "call_abc"
      assert tool_call_part.name == "get_weather"
      # Arguments are serialized to a string and don't reconstruct as
      # a map by default — the round-trip preserves the data but not
      # the exact shape of map vs JSON string. The replay path here
      # uses stringification for unknown nested terms. Callers needing
      # to assert on argument values can re-parse the JSON.
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
  end

  # ── Round-trip: embeddings ─────────────────────────────────────────

  describe "save/2 + load/1 — :embed_cloud and :embed_local" do
    test ":embed_cloud round-trips a vector + usage" do
      call = Call.new(:embed_cloud, {"voyage:voyage-3", ["hello"], []})

      indexed = [%{index: 0, embedding: [0.1, 0.2, 0.3, 0.4]}]
      :ok = Fixture.save(call, {:ok, indexed, %{input_tokens: 5}})

      {:ok, {:ok, replayed, usage}, _ts} = Fixture.load(call)

      assert replayed == indexed
      assert usage[:input_tokens] == 5
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
        assert Fixture.load(call) == :not_found
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

      assert Fixture.load(symlink_call) == :not_found

      fifo_call = Call.new(:complete, {"openai:fifo", [], []})
      fifo_path = Fixture.path_for(fifo_call)
      {_, 0} = System.cmd("mkfifo", [fifo_path])

      task = Task.async(fn -> Fixture.load(fifo_call) end)
      assert {:ok, :not_found} = Task.yield(task, 1_000)

      assert Path.dirname(symlink_path) == tmp_dir
    end

    test "security regression: fixture replay rejects hardlinked files", %{tmp_dir: tmp_dir} do
      call = Call.new(:complete, {"openai:hardlink", [], []})
      fixture_path = Fixture.path_for(call)
      outside = tmp_dir <> "-hardlink-source.json"

      :ok = Fixture.save(call, {:ok, %Response{text: "linked"}})
      :ok = File.rename(fixture_path, outside)
      :ok = File.ln(outside, fixture_path)
      on_exit(fn -> File.rm(outside) end)

      assert Fixture.load(call) == :not_found
    end
  end

  # ── recorded_at timestamp ──────────────────────────────────────────

  describe "recorded_at" do
    test "save stamps recorded_at; load returns a DateTime" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      before_save = DateTime.utc_now()
      :ok = Fixture.save(call, {:ok, %Response{text: "x"}})
      after_save = DateTime.utc_now()

      {:ok, _result, recorded_at} = Fixture.load(call)

      assert %DateTime{} = recorded_at
      assert DateTime.compare(recorded_at, before_save) in [:gt, :eq]
      assert DateTime.compare(recorded_at, after_save) in [:lt, :eq]
    end
  end
end
