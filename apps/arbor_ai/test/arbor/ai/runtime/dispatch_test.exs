defmodule Arbor.AI.Runtime.DispatchTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.AI.Runtime.Dispatch
  alias Arbor.LLM.Request
  alias Arbor.LLM.Message

  # The dispatch helper bridges ModelProfile.entry → Selector → Client.complete.
  # Client.complete itself is exercised by arbor_llm's suite; here we focus on:
  #   - the rewrite-provider step happens correctly
  #   - the telemetry event fires with the chosen tuple
  #   - the choose/3 variant returns the selection without an LLM call
  #
  # We don't mock Client.complete — instead we test `choose/3` (no LLM call)
  # for the selection path and pin telemetry behaviour with a test handler.
  # The full dispatch path with a real LLM call is integration-level and
  # belongs alongside the existing arbor_llm fixture tests.

  defp build_request(model, opts \\ []) do
    %Request{
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: model,
      messages: [Message.new(:user, "hello")],
      tools: [],
      tool_choice: nil,
      max_tokens: 100,
      temperature: 0.7,
      reasoning_effort: nil,
      provider_options: %{}
    }
  end

  describe "choose/2 — selection without LLM call" do
    test "synthesized legacy entry falls through with :legacy provider" do
      # "totally-unknown-thing-9000" misses llm_db and synthesizes a single-
      # provider entry with id: :legacy. Selector picks it as the only path.
      request = build_request("totally-unknown-thing-9000")

      assert {:ok, %{selection: %{provider: %{id: :legacy}, runtime: :arbor}}} =
               Dispatch.choose(request)
    end

    test "policy.default_runtime is respected for synthesized entries" do
      request = build_request("totally-unknown-thing-9000")

      # Synthesized entry only supports :arbor — asking for :acp errors.
      assert {:error, {:selection_failed, {:no_provider_supports_runtime, :acp}}} =
               Dispatch.choose(request, %{default_runtime: :acp})
    end

    test "model_id string variant works without a Request" do
      assert {:ok, %{selection: %{provider: %{id: :legacy}}}} =
               Dispatch.choose("totally-unknown-thing-9000")
    end

    test "selection errors propagate as {:selection_failed, reason}" do
      request = build_request("totally-unknown-thing-9000")

      assert {:error, {:selection_failed, _}} =
               Dispatch.choose(request, %{provider: :bedrock})
    end
  end

  describe "telemetry — [:arbor, :runtime, :selected]" do
    setup do
      handler_id = "dispatch-test-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:arbor, :runtime, :selected],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "fires with the chosen tuple on choose/2" do
      request = build_request("totally-unknown-thing-9000")
      {:ok, _} = Dispatch.choose(request)

      assert_receive {:telemetry, [:arbor, :runtime, :selected], %{count: 1}, metadata}, 500
      assert metadata.canonical_id == "totally-unknown-thing-9000"
      assert metadata.provider == :legacy
      assert metadata.runtime == :arbor
    end

    test "extra_meta is merged into the metadata map" do
      request = build_request("totally-unknown-thing-9000")
      {:ok, _} = Dispatch.choose(request, %{}, %{request_id: "req_abc", agent_id: "agent_x"})

      assert_receive {:telemetry, [:arbor, :runtime, :selected], _, metadata}, 500
      assert metadata.request_id == "req_abc"
      assert metadata.agent_id == "agent_x"
      # Built-in metadata still present
      assert metadata.canonical_id == "totally-unknown-thing-9000"
    end

    test "does not fire when selection errors" do
      request = build_request("totally-unknown-thing-9000")

      assert {:error, _} =
               Dispatch.choose(request, %{default_runtime: :acp})

      refute_receive {:telemetry, _, _, _}, 100
    end
  end
end
