defmodule Arbor.LLM.CallTest do
  @moduledoc """
  Tests for the conn-like struct that gets threaded through the
  `Arbor.LLM` plug pipeline. Small surface — `new/2`, `halt/1`,
  `put_metadata/2`, `assign/3` — but those four are load-bearing
  for every plug, so the contract is worth pinning down.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.Call

  describe "new/2" do
    test "constructs with operation + request, defaults the rest" do
      call = Call.new(:complete, {"openai:gpt-4o-mini", [], []})

      assert call.operation == :complete
      assert call.request == {"openai:gpt-4o-mini", [], []}
      assert call.result == nil
      assert call.halted == false
      assert call.assigns == %{}
    end

    test "stamps metadata.started_at" do
      before_call = DateTime.utc_now()
      call = Call.new(:complete, {})
      after_call = DateTime.utc_now()

      assert %DateTime{} = call.metadata.started_at

      assert DateTime.compare(call.metadata.started_at, before_call) in [:gt, :eq]
      assert DateTime.compare(call.metadata.started_at, after_call) in [:lt, :eq]
    end

    test "operation must be an atom (compile-time guard via @type)" do
      # The struct accepts any operation; runtime guard is at Dispatch.
      # This test pins the docstring claim that callers should pass
      # one of the four known operation atoms.
      for op <- [:complete, :stream, :embed_cloud, :embed_local] do
        assert %Call{operation: ^op} = Call.new(op, {})
      end
    end
  end

  describe "halt/1" do
    test "sets halted: true, leaves everything else untouched" do
      call =
        :complete
        |> Call.new({"openai:gpt-4o-mini", [], []})
        |> Call.assign(:agent_id, "agent_42")
        |> Call.put_metadata(%{trace_id: "abc"})
        |> Call.halt()

      assert call.halted == true
      assert call.operation == :complete
      assert call.request == {"openai:gpt-4o-mini", [], []}
      assert call.assigns == %{agent_id: "agent_42"}
      assert call.metadata.trace_id == "abc"
    end

    test "halt is idempotent" do
      call = Call.new(:complete, {}) |> Call.halt() |> Call.halt() |> Call.halt()
      assert call.halted == true
    end
  end

  describe "put_metadata/2" do
    test "merges (doesn't replace) existing metadata" do
      call =
        :complete
        |> Call.new({})
        |> Call.put_metadata(%{replayed_from: "/tmp/x.json"})
        |> Call.put_metadata(%{recorded_at: ~U[2026-06-02 12:00:00Z]})

      # Both keys present; started_at from new/2 is also preserved.
      assert call.metadata.replayed_from == "/tmp/x.json"
      assert call.metadata.recorded_at == ~U[2026-06-02 12:00:00Z]
      assert %DateTime{} = call.metadata.started_at
    end

    test "later puts override earlier ones for the same key" do
      call =
        Call.new(:complete, {})
        |> Call.put_metadata(%{trace_id: "first"})
        |> Call.put_metadata(%{trace_id: "second"})

      assert call.metadata.trace_id == "second"
    end
  end

  describe "assign/3" do
    test "sets a key in assigns" do
      call = Call.new(:complete, {}) |> Call.assign(:agent_id, "agent_7")
      assert call.assigns == %{agent_id: "agent_7"}
    end

    test "later assigns override earlier ones for the same key" do
      call =
        Call.new(:complete, {})
        |> Call.assign(:agent_id, "first")
        |> Call.assign(:agent_id, "second")

      assert call.assigns.agent_id == "second"
    end

    test "multiple keys coexist" do
      call =
        Call.new(:complete, {})
        |> Call.assign(:agent_id, "agent_7")
        |> Call.assign(:budget_remaining, 3.50)

      assert call.assigns == %{agent_id: "agent_7", budget_remaining: 3.50}
    end
  end
end
