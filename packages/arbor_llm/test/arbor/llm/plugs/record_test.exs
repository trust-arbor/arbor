defmodule Arbor.LLM.Plugs.RecordTest do
  @moduledoc """
  Tests for `Plugs.Record`. Three claims:

    1. **Result present, not replayed** → write fixture, stamp
       `metadata.recorded_to`.
    2. **Result present, replayed** → skip (don't re-record a replay
       and reset its timestamp).
    3. **Result missing** → pass through (Dispatch hasn't run yet).
  """

  # async: false — see FixtureTest for why (shared Application env).
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.LLM.Call
  alias Arbor.LLM.Plugs.Fixture
  alias Arbor.LLM.Plugs.Record

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "arbor_llm_record_test_#{System.unique_integer([:positive])}")

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

  describe "Record.call/1 — result present, not a replay" do
    test "persists the fixture + stamps recorded_to" do
      response = req_response("pong")

      call =
        :complete
        |> Call.new({"openai:gpt-4o-mini", [], []})
        |> Map.put(:result, {:ok, response})

      result = Record.call(call)

      assert File.exists?(Fixture.path_for(call))
      assert result.metadata.recorded_to == Fixture.path_for(call)
    end

    test "persisted fixture round-trips through Fixture.load/1" do
      response = req_response("round-trip")

      call =
        :complete
        |> Call.new({"openai:gpt-4o-mini", [%{role: :user, content: "x"}], []})
        |> Map.put(:result, {:ok, response})

      _ = Record.call(call)

      assert {:ok, {:ok, %ReqLLM.Response{} = response}, %DateTime{}} = Fixture.load(call)
      assert ReqLLM.Response.text(response) == "round-trip"
    end
  end

  describe "Record.call/1 — result present, was a replay" do
    test "does NOT re-record a replayed result", %{tmp_dir: tmp_dir} do
      call =
        :complete
        |> Call.new({"openai:gpt-4o-mini", [], []})
        |> Map.put(:result, {:ok, req_response("from replay")})
        |> Call.put_metadata(%{
          replayed_from: "/some/path/abc.json",
          recorded_at: ~U[2026-01-01 00:00:00Z]
        })

      result = Record.call(call)

      # No new fixture file written.
      refute File.exists?(Fixture.path_for(call))
      # No recorded_to metadata.
      refute Map.has_key?(result.metadata, :recorded_to)
      # The call passes through with replay metadata intact.
      assert result.metadata.replayed_from == "/some/path/abc.json"

      # Verify it's really an empty dir (no surprise files from
      # somewhere else).
      assert File.ls!(tmp_dir) == []
    end
  end

  describe "Record.call/1 — result missing" do
    test "passes through unchanged (Dispatch hasn't run)" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      result = Record.call(call)

      refute File.exists?(Fixture.path_for(call))
      assert result.result == nil
      refute Map.has_key?(result.metadata, :recorded_to)
    end
  end

  describe "Record.call/1 — halted call" do
    test "halted call passes through (use macro injects this)" do
      response = req_response("halted but has result")

      call =
        :complete
        |> Call.new({"openai:x", [], []})
        |> Map.put(:result, {:ok, response})
        |> Call.halt()

      result = Record.call(call)

      # Halted-passthrough wins over the result-is-set clause.
      refute File.exists?(Fixture.path_for(call))
      refute Map.has_key?(result.metadata, :recorded_to)
    end
  end

  defp req_response(text) do
    %ReqLLM.Response{
      id: "response-test",
      model: "gpt-4o-mini",
      context: ReqLLM.Context.new([]),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ReqLLM.Message.ContentPart.text(text)]
      },
      stream?: false,
      stream: nil,
      usage: %{},
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }
  end
end
