defmodule Arbor.Contracts.AI.RuntimeProfileTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.AI.RuntimeProfile

  @valid_attrs %{
    runtime_id: :arbor,
    display_name: "Arbor (BEAM-native)",
    owns_model_loop: true,
    owns_thread_history: true,
    supports_jido_actions: true,
    supports_action_hooks: true,
    supports_native_tools: true,
    runs_context_engine: true,
    exposes_compaction_data: true
  }

  describe "new/1" do
    test "builds a complete profile from attrs" do
      assert {:ok, %RuntimeProfile{} = p} = RuntimeProfile.new(@valid_attrs)

      assert p.runtime_id == :arbor
      assert p.display_name == "Arbor (BEAM-native)"
      assert p.owns_model_loop
      assert p.unsupported_features == []
      assert p.extra_facts == %{}
    end

    test "accepts keyword list" do
      assert {:ok, %RuntimeProfile{runtime_id: :arbor}} =
               RuntimeProfile.new(Enum.to_list(@valid_attrs))
    end

    test "accepts string-keyed map" do
      string_attrs = for {k, v} <- @valid_attrs, into: %{}, do: {Atom.to_string(k), v}
      assert {:ok, %RuntimeProfile{runtime_id: :arbor}} = RuntimeProfile.new(string_attrs)
    end

    test "rejects missing required runtime_id" do
      assert {:error, {:missing_or_invalid, :runtime_id}} =
               RuntimeProfile.new(Map.delete(@valid_attrs, :runtime_id))
    end

    test "rejects non-boolean for question field" do
      attrs = Map.put(@valid_attrs, :owns_model_loop, :yes)

      assert {:error, {:missing_or_invalid, :owns_model_loop}} =
               RuntimeProfile.new(attrs)
    end

    test "rejects missing display_name" do
      assert {:error, {:missing_or_invalid, :display_name}} =
               RuntimeProfile.new(Map.delete(@valid_attrs, :display_name))
    end

    test "preserves unsupported_features and extra_facts" do
      attrs =
        Map.merge(@valid_attrs, %{
          unsupported_features: [:vision],
          extra_facts: %{retry_budget: :owner}
        })

      assert {:ok,
              %RuntimeProfile{
                unsupported_features: [:vision],
                extra_facts: %{retry_budget: :owner}
              }} =
               RuntimeProfile.new(attrs)
    end
  end

  describe "supports?/2" do
    setup do
      {:ok, profile} =
        RuntimeProfile.new(
          Map.merge(@valid_attrs, %{
            supports_jido_actions: false,
            unsupported_features: [:vision]
          })
        )

      {:ok, profile: profile}
    end

    test "returns the per-question boolean", %{profile: p} do
      assert RuntimeProfile.supports?(p, :model_loop)
      assert RuntimeProfile.supports?(p, :thread_history)
      refute RuntimeProfile.supports?(p, :jido_actions)
    end

    test "unsupported_features wins over boolean fields", %{profile: p} do
      # `:vision` isn't a question field, but it IS in unsupported_features —
      # supports? must return false to fail closed.
      refute RuntimeProfile.supports?(p, :vision)
    end

    test "unknown feature returns false (fail closed)", %{profile: p} do
      refute RuntimeProfile.supports?(p, :brand_new_capability_2030)
    end
  end
end
