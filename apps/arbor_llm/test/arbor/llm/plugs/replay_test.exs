defmodule Arbor.LLM.Plugs.ReplayTest do
  @moduledoc """
  Tests for `Plugs.Replay`. Three claims:

    1. **Fixture present** → fill in result, halt, stamp provenance
       in metadata (`replayed_from` + `recorded_at`).
    2. **Fixture missing** → pass through unchanged (let downstream
       plugs handle the real call).
    3. **Already has a result** → pass through (don't overwrite an
       upstream plug's work).
  """

  # async: false — see FixtureTest for why (shared Application env).
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Fixture
  alias Arbor.LLM.Plugs.Replay
  alias Arbor.LLM.Response

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_llm_replay_test_#{System.unique_integer([:positive])}")

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

    :ok
  end

  describe "Replay.call/1 — fixture present" do
    test "fills result, halts, stamps provenance" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      :ok =
        Fixture.save(
          call,
          {:ok, %Response{text: "pong", finish_reason: :stop, content_parts: [], usage: %{}}}
        )

      replayed = Replay.call(call)

      assert replayed.halted == true
      assert {:ok, %Response{text: "pong"}} = replayed.result
      assert replayed.metadata.replayed_from == Fixture.path_for(call)
      assert %DateTime{} = replayed.metadata.recorded_at
    end

    test "security regression: malformed fixture halts replay instead of falling through" do
      call = Call.new(:embed_cloud, {"openai:text-embedding", ["hello"], []})

      fixture = %{
        "operation" => "embed_cloud",
        "request_hash" => Fixture.request_hash(call),
        "recorded_at" => "2026-07-11T00:00:00Z",
        "response" => %{"outcome" => "ok", "value" => "malformed"}
      }

      File.write!(Fixture.path_for(call), Jason.encode!(fixture))

      replayed = Replay.call(call)
      assert replayed.halted == true
      assert {:error, {:invalid_embedding_fixture, _reason}} = replayed.result
      assert replayed.metadata.fixture_invalid == true
    end
  end

  describe "Replay.call/1 — fixture missing" do
    test "passes through unchanged" do
      call = Call.new(:complete, {"openai:never-saved", [], []})

      result = Replay.call(call)

      assert result.halted == false
      assert result.result == nil
      refute Map.has_key?(result.metadata, :replayed_from)
    end
  end

  describe "Replay.call/1 — call already has a result" do
    test "passes through (doesn't overwrite an upstream plug's work)" do
      existing_response = %Response{text: "set by an earlier plug"}

      call =
        :complete
        |> Call.new({"openai:x", [], []})
        |> Map.put(:result, {:ok, existing_response})

      # Save a fixture for this hash — Replay should NOT consult it.
      :ok = Fixture.save(call, {:ok, %Response{text: "from fixture"}})

      result = Replay.call(call)

      assert {:ok, %Response{text: "set by an earlier plug"}} = result.result
      refute Map.has_key?(result.metadata, :replayed_from)
    end
  end

  describe "Replay.call/1 — halted call (use macro)" do
    test "halted call passes through unchanged" do
      call = Call.new(:complete, {}) |> Call.halt()

      result = Replay.call(call)

      assert result == call
    end
  end
end
