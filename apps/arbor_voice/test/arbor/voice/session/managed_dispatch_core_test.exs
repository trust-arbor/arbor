defmodule Arbor.Voice.Session.ManagedDispatchCoreTest do
  @moduledoc """
  Pure one-dispatch turn core (VP-05D1 / VOICE-10).
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag spec: "VOICE-10"

  alias Arbor.Voice.CodingPlanFactory
  alias Arbor.Voice.Session.ManagedDispatchCore
  alias Arbor.Voice.Session.ToolTaskCore

  describe "new/0 and accessors" do
    test "starts open with no receipt" do
      assert ManagedDispatchCore.new() == %{slot: :open, receipt: nil}
      assert ManagedDispatchCore.receipt(ManagedDispatchCore.new()) == nil

      assert ManagedDispatchCore.confirmation_sentence() ==
               "I've dispatched that coding task; this voice turn is complete."

      assert CodingPlanFactory.worker_provider() == "grok"
      assert CodingPlanFactory.max_intent_bytes() == ManagedDispatchCore.max_task_intent_bytes()
      assert {:ok, "ok intent"} = CodingPlanFactory.admit_intent("ok intent")
      assert {:error, :invalid_intent} = CodingPlanFactory.admit_intent("bad\nline")
      assert ManagedDispatchCore.valid_task_id?("task_abc_1")
      refute ManagedDispatchCore.valid_task_id?("bad id")
      refute ManagedDispatchCore.valid_task_id?("")
    end
  end

  describe "reserve_dispatch/2" do
    test "non-dispatch tools pass through without closing the slot" do
      core = ManagedDispatchCore.new()

      assert {:other, ^core} =
               ManagedDispatchCore.reserve_dispatch(core, %{
                 name: "consult_agent",
                 arguments: %{"message" => "hi"}
               })
    end

    test "first dispatch admits candidate and closes slot" do
      core = ManagedDispatchCore.new()

      assert {:admit, %{slot: :closed, receipt: nil}, candidate} =
               ManagedDispatchCore.reserve_dispatch(core, %{
                 name: "dispatch_coding_task",
                 arguments: %{"task" => "fix the bug"}
               })

      assert candidate == %{
               "provider" => "grok",
               "task" => "fix the bug"
             }
    end

    test "second dispatch rejects without reopening; invalid first attempt also closes" do
      core = ManagedDispatchCore.new()

      assert {:reject, closed, json} =
               ManagedDispatchCore.reserve_dispatch(core, %{
                 name: "dispatch_coding_task",
                 arguments: %{}
               })

      assert closed.slot == :closed
      # Established normalize: invalid_arguments → tool_error code.
      assert json == ToolTaskCore.normalize({:error, :invalid_arguments})
      assert Jason.decode!(json) == %{"code" => "tool_error"}

      assert {:reject, still_closed, reject_json} =
               ManagedDispatchCore.reserve_dispatch(closed, %{
                 name: "dispatch_coding_task",
                 arguments: %{"task" => "another"}
               })

      assert still_closed.slot == :closed
      assert reject_json == ToolTaskCore.normalize({:error, :tool_error})
      assert Jason.decode!(reject_json) == %{"code" => "tool_error"}
    end

    test "control-bearing intent is rejected via shared CodingPlanFactory.admit_intent/1" do
      core = ManagedDispatchCore.new()

      assert {:reject, closed, json} =
               ManagedDispatchCore.reserve_dispatch(core, %{
                 name: "dispatch_coding_task",
                 arguments: %{"task" => "bad\nintent"}
               })

      assert closed.slot == :closed
      assert json == ToolTaskCore.normalize({:error, :invalid_arguments})
      assert Jason.decode!(json) == %{"code" => "tool_error"}
    end
  end

  describe "maybe_receipt/3 and select_raw_assistant/2" do
    test "builds receipt only for exact success envelope and selects fixed sentence" do
      {:admit, core, candidate} =
        ManagedDispatchCore.reserve_dispatch(ManagedDispatchCore.new(), %{
          name: "dispatch_coding_task",
          arguments: %{"task" => "ship it"}
        })

      success =
        Jason.encode!(%{
          "success" => true,
          "result" => %{"task_id" => "task_voice_1", "status" => "dispatched"}
        })

      with_receipt = ManagedDispatchCore.maybe_receipt(core, candidate, success)

      assert ManagedDispatchCore.receipt(with_receipt) == %{
               "provider" => "grok",
               "task" => "ship it",
               "task_id" => "task_voice_1",
               "outcome" => "dispatched"
             }

      assert ManagedDispatchCore.select_raw_assistant(with_receipt, "model prose") ==
               ManagedDispatchCore.confirmation_sentence()
    end

    test "malformed, error, timeout, and forged outputs produce no receipt" do
      {:admit, core, candidate} =
        ManagedDispatchCore.reserve_dispatch(ManagedDispatchCore.new(), %{
          name: "dispatch_coding_task",
          arguments: %{"task" => "ship it"}
        })

      for output <- [
            ToolTaskCore.normalize(:tool_timeout),
            ToolTaskCore.normalize(:tool_failed),
            ToolTaskCore.normalize({:error, :tool_error}),
            Jason.encode!(%{"success" => true, "result" => %{"task_id" => "bad id", "status" => "dispatched"}}),
            Jason.encode!(%{"success" => true, "result" => %{"task_id" => "ok", "status" => "running"}}),
            "not-json",
            Jason.encode!(%{"task_id" => "task_1", "status" => "dispatched"})
          ] do
        next = ManagedDispatchCore.maybe_receipt(core, candidate, output)
        assert next.receipt == nil
        assert ManagedDispatchCore.select_raw_assistant(next, "keep me") == "keep me"
      end

      # Nil candidate never creates a receipt even with success JSON.
      success =
        Jason.encode!(%{
          "success" => true,
          "result" => %{"task_id" => "task_ok", "status" => "dispatched"}
        })

      assert ManagedDispatchCore.maybe_receipt(core, nil, success).receipt == nil
    end

    test "second success does not replace an existing receipt" do
      {:admit, core, candidate} =
        ManagedDispatchCore.reserve_dispatch(ManagedDispatchCore.new(), %{
          name: "dispatch_coding_task",
          arguments: %{"task" => "first"}
        })

      first =
        ManagedDispatchCore.maybe_receipt(
          core,
          candidate,
          Jason.encode!(%{
            "success" => true,
            "result" => %{"task_id" => "task_first", "status" => "dispatched"}
          })
        )

      second =
        ManagedDispatchCore.maybe_receipt(
          first,
          %{"provider" => "grok", "task" => "other"},
          Jason.encode!(%{
            "success" => true,
            "result" => %{"task_id" => "task_second", "status" => "dispatched"}
          })
        )

      assert second.receipt["task_id"] == "task_first"
    end
  end
end
