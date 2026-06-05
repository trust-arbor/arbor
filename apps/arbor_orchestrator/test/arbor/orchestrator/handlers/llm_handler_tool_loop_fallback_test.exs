defmodule Arbor.Orchestrator.Handlers.LlmHandlerToolLoopFallbackTest do
  @moduledoc """
  Pins the tool-loop fallback wrapper added in B4. The wrapper sits
  above `ToolLoop.run/3` and applies provider/model overrides from the
  agent's `session.llm_fallback_chain` when ToolLoop returns a
  fallback-eligible error. Runtime overrides are no-ops here (tool
  loops go through `Client.complete` which only routes by provider).

  Tested via the @doc-false `call_with_tool_loop_fallback/3` helper with
  an injected attempt function so the test stays focused on the
  fallback control flow without needing a real Client + ToolLoop.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.Request
  alias Arbor.Orchestrator.Handlers.LlmHandler

  defp build_request,
    do: %Request{
      provider: "anthropic",
      model: "claude-opus-4-6",
      runtime: :arbor,
      messages: [],
      provider_options: %{}
    }

  describe "call_with_tool_loop_fallback/3" do
    test "empty chain → calls do_call once and returns its result" do
      counter = :counters.new(1, [])

      do_call = fn _req ->
        :counters.add(counter, 1, 1)
        {:ok, %{text: "first try"}}
      end

      assert {:ok, %{text: "first try"}} =
               LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [])

      assert :counters.get(counter, 1) == 1
    end

    test "primary success → fallback chain never consulted" do
      do_call = fn _ -> {:ok, %{text: "ok"}} end

      assert {:ok, _} =
               LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                 %{model: "claude-sonnet-4-6"}
               ])
    end

    test "primary fails with eligible error → fallback applied with model override" do
      attempts = :ets.new(:attempts, [:public, :ordered_set])

      do_call = fn req ->
        idx = :ets.info(attempts, :size)
        :ets.insert(attempts, {idx, req})

        if idx == 0 do
          {:error, :timeout}
        else
          {:ok, %{text: "fallback success", served_by: req.model}}
        end
      end

      result =
        LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
          %{model: "claude-sonnet-4-6"}
        ])

      assert {:ok, %{served_by: "claude-sonnet-4-6"}} = result

      [{_, _orig}, {_, fallback_req}] = :ets.tab2list(attempts) |> Enum.sort()
      assert fallback_req.model == "claude-sonnet-4-6"
      # Provider stays as original since override only set :model
      assert fallback_req.provider == "anthropic"
    end

    test "non-eligible error propagates immediately, fallback not tried" do
      counter = :counters.new(1, [])

      do_call = fn _ ->
        :counters.add(counter, 1, 1)
        {:error, :bad_prompt_format}
      end

      assert {:error, :bad_prompt_format} =
               LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                 %{model: "claude-sonnet-4-6"}
               ])

      # Only the primary attempt; fallback skipped (non-eligible error)
      assert :counters.get(counter, 1) == 1
    end

    test "provider override flows through" do
      attempts = :ets.new(:attempts, [:public, :ordered_set])

      do_call = fn req ->
        idx = :ets.info(attempts, :size)
        :ets.insert(attempts, {idx, req})

        if idx == 0 do
          {:error, :timeout}
        else
          {:ok, %{provider: req.provider}}
        end
      end

      result =
        LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
          %{provider: :openai}
        ])

      assert {:ok, %{provider: "openai"}} = result
    end

    test "runtime override is logged and dropped (tool loop can't honor it)" do
      attempts = :ets.new(:attempts, [:public, :ordered_set])

      do_call = fn req ->
        idx = :ets.info(attempts, :size)
        :ets.insert(attempts, {idx, req})

        if idx == 0 do
          {:error, :timeout}
        else
          {:ok, %{}}
        end
      end

      # Entry has ONLY :runtime → after dropping :runtime, entry is empty
      # → :no_change → entry skipped, no second attempt against ToolLoop.
      # Fallback chain is exhausted, last error returned.
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert {:error, :timeout} =
                   LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                     %{runtime: :acp}
                   ])
        end)

      assert log =~ "tool loops go through Client.complete"
    end

    test "runtime override + model override → entry retried with model only" do
      attempts = :ets.new(:attempts, [:public, :ordered_set])

      do_call = fn req ->
        idx = :ets.info(attempts, :size)
        :ets.insert(attempts, {idx, req})

        if idx == 0 do
          {:error, :timeout}
        else
          {:ok, %{model: req.model, runtime: req.runtime}}
        end
      end

      import ExUnit.CaptureLog

      result =
        capture_log(fn ->
          assert {:ok, %{model: "claude-sonnet-4-6", runtime: :arbor}} =
                   LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                     %{runtime: :acp, model: "claude-sonnet-4-6"}
                   ])
        end)

      assert result =~ "runtime override has no effect"
    end

    test "all attempts fail → returns last error" do
      do_call = fn _ -> {:error, :timeout} end

      assert {:error, :timeout} =
               LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                 %{model: "claude-sonnet-4-6"},
                 %{model: "claude-haiku-4-5-20251001"}
               ])
    end

    test "fallback eligibility re-checked at each step (mid-chain switch to non-eligible)" do
      attempts = :ets.new(:attempts, [:public, :ordered_set])

      do_call = fn req ->
        idx = :ets.info(attempts, :size)
        :ets.insert(attempts, {idx, req})

        cond do
          idx == 0 -> {:error, :timeout}
          idx == 1 -> {:error, :bad_prompt_format}
          true -> {:ok, %{}}
        end
      end

      # Chain has 2 fallbacks. First retry returns non-eligible error
      # → stop, propagate. Second fallback should never run.
      assert {:error, :bad_prompt_format} =
               LlmHandler.call_with_tool_loop_fallback(do_call, build_request(), [
                 %{model: "claude-sonnet-4-6"},
                 %{model: "claude-haiku-4-5-20251001"}
               ])

      # 2 attempts total: primary + first fallback. Second fallback skipped.
      assert :ets.info(attempts, :size) == 2
    end
  end
end
