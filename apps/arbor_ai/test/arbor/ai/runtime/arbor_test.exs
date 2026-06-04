defmodule Arbor.AI.Runtime.ArborTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.Runtime.Arbor, as: RuntimeArbor

  describe "profile/0" do
    test "declares full Arbor support" do
      profile = RuntimeArbor.profile()
      assert profile.runtime_id == :arbor
      assert profile.display_name =~ "BEAM-native"

      # All eight questions YES for arbor — the runtime that owns
      # everything Arbor-native.
      assert profile.owns_model_loop
      assert profile.owns_thread_history
      assert profile.supports_jido_actions
      assert profile.supports_action_hooks
      assert profile.supports_native_tools
      assert profile.runs_context_engine
      assert profile.exposes_compaction_data
      assert profile.unsupported_features == []
    end
  end

  describe "prepare/2" do
    test "returns the request unchanged (pass-through)" do
      request = %Arbor.LLM.Request{model: "claude-opus-4-6", provider: "anthropic"}
      assert {:ok, ^request} = RuntimeArbor.prepare(request, [])
    end
  end

  # execute/3 hits Client.complete which makes real network calls.
  # Live behavior is covered by arbor_llm's fixture suite; here we
  # only test the prepare path + profile declaration so the behaviour
  # impl is pinned.
end
