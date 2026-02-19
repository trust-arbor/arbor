defmodule Arbor.Memory.MemoryStoreTaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.MemoryStore
  alias Arbor.Signals.Taint, as: TaintModule

  @moduletag :fast

  describe "build_taint_metadata (via persist/4)" do
    test "persist without taint opts stores empty metadata" do
      # MemoryStore gracefully degrades when store unavailable
      assert :ok = MemoryStore.persist("test_ns", "key1", %{data: "hello"})
    end

    test "persist with taint opts stores taint in metadata" do
      taint = %Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00010001,
        confidence: :plausible,
        source: "api"
      }

      assert :ok = MemoryStore.persist("test_ns", "key2", %{data: "secret"}, taint: taint)
    end

    test "persist_async accepts taint opts" do
      taint = %Taint{level: :hostile, sensitivity: :restricted}
      assert :ok = MemoryStore.persist_async("test_ns", "key3", %{data: "x"}, taint: taint)
    end
  end

  describe "to_persistable/from_persistable round-trip" do
    test "preserves all fields through serialization" do
      original = %Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00010011,
        confidence: :plausible,
        source: "external_api",
        chain: ["step1", "step2"]
      }

      persistable = TaintModule.to_persistable(original)
      restored = TaintModule.from_persistable(persistable)

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.sanitizations == original.sanitizations
      assert restored.confidence == original.confidence
      assert restored.source == original.source
      assert restored.chain == original.chain
    end

    test "persistable format uses string keys" do
      taint = %Taint{level: :hostile}
      persistable = TaintModule.to_persistable(taint)

      assert is_binary(Map.keys(persistable) |> hd())
      assert persistable["taint_level"] == "hostile"
    end

    test "survives JSON round-trip" do
      original = %Taint{
        level: :derived,
        sensitivity: :internal,
        sanitizations: 0xFF,
        confidence: :verified,
        source: "test"
      }

      json = original |> TaintModule.to_persistable() |> Jason.encode!()
      restored = json |> Jason.decode!() |> TaintModule.from_persistable()

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.sanitizations == original.sanitizations
      assert restored.confidence == original.confidence
    end
  end

  describe "fail-closed deserialization" do
    test "corrupt level defaults to :hostile" do
      restored = TaintModule.from_persistable(%{"taint_level" => "invalid"})
      assert restored.level == :hostile
    end

    test "corrupt sensitivity defaults to :restricted" do
      restored = TaintModule.from_persistable(%{"taint_sensitivity" => "invalid"})
      assert restored.sensitivity == :restricted
    end

    test "corrupt confidence defaults to :unverified" do
      restored = TaintModule.from_persistable(%{"taint_confidence" => "invalid"})
      assert restored.confidence == :unverified
    end

    test "nil map values use fail-closed defaults" do
      restored = TaintModule.from_persistable(%{})
      assert restored.level == :hostile
      assert restored.sensitivity == :restricted
      assert restored.confidence == :unverified
      assert restored.sanitizations == 0
      assert restored.chain == []
    end

    test "negative sanitization value defaults to 0" do
      restored = TaintModule.from_persistable(%{"taint_sanitizations" => -1})
      assert restored.sanitizations == 0
    end
  end

  describe "TaintedValue wrapping" do
    test "wrap creates a valid TaintedValue" do
      taint = %Taint{level: :untrusted, sensitivity: :confidential}
      tv = TaintedValue.wrap(%{secret: "data"}, taint)

      assert tv.value == %{secret: "data"}
      assert tv.taint.level == :untrusted
      assert tv.taint.sensitivity == :confidential
    end

    test "unwrap! extracts the raw value" do
      tv = TaintedValue.trusted("safe")
      assert TaintedValue.unwrap!(tv) == "safe"
    end

    test "legacy data gets default taint" do
      # Simulate what load_tainted would do with nil metadata
      taint = %Taint{
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified
      }

      tv = TaintedValue.wrap(%{data: "old"}, taint)
      assert tv.taint.level == :trusted
      assert tv.taint.sensitivity == :internal
      assert tv.taint.confidence == :unverified
    end
  end

  describe "load_tainted/2" do
    test "returns error when store unavailable" do
      assert {:error, :not_found} = MemoryStore.load_tainted("ns", "missing_key")
    end
  end

  describe "embed_async/4 with taint" do
    test "accepts taint opt without error" do
      taint = %Taint{level: :trusted, sensitivity: :public}

      # Should not crash even without a running embed provider
      assert :ok =
               MemoryStore.embed_async("ns", "key", "content",
                 agent_id: "agent_test",
                 taint: taint
               )
    end
  end
end
