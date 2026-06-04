defmodule Arbor.AI.Runtime.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.AI.Runtime.Registry

  describe "lookup/1" do
    test "returns Runtime.Arbor for :arbor" do
      assert Registry.lookup(:arbor) == Arbor.AI.Runtime.Arbor
    end

    test "returns Runtime.Acp for :acp" do
      assert Registry.lookup(:acp) == Arbor.AI.Runtime.Acp
    end

    test "unknown runtime atom falls through to Runtime.Arbor" do
      assert Registry.lookup(:totally_unknown_runtime) == Arbor.AI.Runtime.Arbor
    end
  end

  describe "all/0" do
    test "returns the default registry map" do
      registry = Registry.all()
      assert registry[:arbor] == Arbor.AI.Runtime.Arbor
      assert registry[:acp] == Arbor.AI.Runtime.Acp
    end

    test "operator overlay merges on top of defaults" do
      defmodule FakeRuntime do
        @behaviour Arbor.AI.Runtime
        def prepare(req, _opts), do: {:ok, req}
        def execute(_p, _cb, _opts), do: {:ok, %Arbor.LLM.Response{text: "fake"}}

        def profile do
          {:ok, p} =
            Arbor.Contracts.AI.RuntimeProfile.new(%{
              runtime_id: :fake,
              display_name: "Fake",
              owns_model_loop: true,
              owns_thread_history: true,
              supports_jido_actions: false,
              supports_action_hooks: false,
              supports_native_tools: false,
              runs_context_engine: false,
              exposes_compaction_data: false
            })

          p
        end
      end

      Application.put_env(:arbor_ai, :runtime_registry, %{arbor: FakeRuntime, fake: FakeRuntime})

      try do
        assert Registry.lookup(:arbor) == FakeRuntime
        assert Registry.lookup(:fake) == FakeRuntime
        # Defaults that aren't overridden stay
        assert Registry.lookup(:acp) == Arbor.AI.Runtime.Acp
      after
        Application.delete_env(:arbor_ai, :runtime_registry)
      end
    end
  end

  describe "profile/1" do
    test "returns the RuntimeProfile for :arbor" do
      profile = Registry.profile(:arbor)
      assert profile.runtime_id == :arbor
      assert profile.owns_model_loop == true
      assert profile.supports_jido_actions == true
    end

    test "returns the RuntimeProfile for :acp with correctly-downgraded support" do
      profile = Registry.profile(:acp)
      assert profile.runtime_id == :acp
      # ACP doesn't own the model loop — the CLI does
      assert profile.owns_model_loop == false
      # Jido actions don't compose through ACP
      refute profile.supports_jido_actions
      assert :jido_actions in profile.unsupported_features
    end
  end
end
