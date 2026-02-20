defmodule Arbor.Signals.TaintStructTest do
  use ExUnit.Case, async: true

  alias Arbor.Signals.Taint
  alias Arbor.Contracts.Security.Taint, as: TaintStruct

  @moduletag :fast

  # ── Sensitivity ──────────────────────────────────────────────────────

  describe "valid_sensitivity?/1" do
    test "accepts valid sensitivities" do
      assert Taint.valid_sensitivity?(:public)
      assert Taint.valid_sensitivity?(:internal)
      assert Taint.valid_sensitivity?(:confidential)
      assert Taint.valid_sensitivity?(:restricted)
    end

    test "rejects invalid values" do
      refute Taint.valid_sensitivity?(:secret)
      refute Taint.valid_sensitivity?("public")
    end
  end

  describe "sensitivity_severity/1" do
    test "returns ordered severity values" do
      assert Taint.sensitivity_severity(:public) == 0
      assert Taint.sensitivity_severity(:internal) == 1
      assert Taint.sensitivity_severity(:confidential) == 2
      assert Taint.sensitivity_severity(:restricted) == 3
    end
  end

  describe "max_sensitivity/2" do
    test "returns higher sensitivity" do
      assert Taint.max_sensitivity(:public, :confidential) == :confidential
      assert Taint.max_sensitivity(:restricted, :public) == :restricted
      assert Taint.max_sensitivity(:internal, :internal) == :internal
    end
  end

  # ── Confidence ───────────────────────────────────────────────────────

  describe "valid_confidence?/1" do
    test "accepts valid confidence levels" do
      assert Taint.valid_confidence?(:unverified)
      assert Taint.valid_confidence?(:plausible)
      assert Taint.valid_confidence?(:corroborated)
      assert Taint.valid_confidence?(:verified)
    end

    test "rejects invalid values" do
      refute Taint.valid_confidence?(:certain)
      refute Taint.valid_confidence?("verified")
    end
  end

  describe "confidence_rank/1" do
    test "returns ordered rank values" do
      assert Taint.confidence_rank(:unverified) == 0
      assert Taint.confidence_rank(:plausible) == 1
      assert Taint.confidence_rank(:corroborated) == 2
      assert Taint.confidence_rank(:verified) == 3
    end
  end

  describe "min_confidence/2" do
    test "returns lower confidence (conservative)" do
      assert Taint.min_confidence(:verified, :plausible) == :plausible
      assert Taint.min_confidence(:unverified, :verified) == :unverified
      assert Taint.min_confidence(:corroborated, :corroborated) == :corroborated
    end
  end

  # ── Sanitizations ───────────────────────────────────────────────────

  describe "sanitized?/2" do
    test "checks if a sanitization bit is set" do
      mask = Bitwise.bor(0b00000001, 0b00010000)
      assert Taint.sanitized?(mask, :xss)
      assert Taint.sanitized?(mask, :prompt_injection)
      refute Taint.sanitized?(mask, :sqli)
    end

    test "returns false for unknown sanitization names" do
      refute Taint.sanitized?(0xFF, :nonexistent)
    end
  end

  describe "apply_sanitization/2" do
    test "sets the bit for a named sanitization" do
      mask = Taint.apply_sanitization(0, :xss)
      assert mask == 0b00000001
      assert Taint.sanitized?(mask, :xss)
    end

    test "is idempotent" do
      mask = 0 |> Taint.apply_sanitization(:sqli) |> Taint.apply_sanitization(:sqli)
      assert mask == 0b00000010
    end

    test "ignores unknown sanitization names" do
      assert Taint.apply_sanitization(0, :unknown) == 0
    end
  end

  describe "intersect_sanitizations/2" do
    test "keeps only bits present in both" do
      a = 0b00010011
      b = 0b00010001
      assert Taint.intersect_sanitizations(a, b) == 0b00010001
    end

    test "returns 0 when no overlap" do
      assert Taint.intersect_sanitizations(0b00001111, 0b11110000) == 0
    end
  end

  # ── Struct Propagation ──────────────────────────────────────────────

  describe "propagate_taint/1" do
    test "empty list returns safe defaults" do
      result = Taint.propagate_taint([])
      assert result.level == :trusted
      assert result.sensitivity == :public
      assert result.confidence == :verified
    end

    test "single input passes through" do
      input = %TaintStruct{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00000011,
        confidence: :plausible,
        source: "api"
      }

      result = Taint.propagate_taint([input])
      assert result.level == :untrusted
      assert result.sensitivity == :confidential
      assert result.sanitizations == 0b00000011
      assert result.confidence == :plausible
    end

    test "takes worst level from multiple inputs" do
      a = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified}
      b = %TaintStruct{level: :hostile, sensitivity: :public, confidence: :verified}
      result = Taint.propagate_taint([a, b])
      assert result.level == :hostile
    end

    test "takes highest sensitivity from multiple inputs" do
      a = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified}
      b = %TaintStruct{level: :trusted, sensitivity: :restricted, confidence: :verified}
      result = Taint.propagate_taint([a, b])
      assert result.sensitivity == :restricted
    end

    test "intersects sanitizations (only keeps common ones)" do
      a = %TaintStruct{level: :trusted, sensitivity: :public, sanitizations: 0b00010011, confidence: :verified}
      b = %TaintStruct{level: :trusted, sensitivity: :public, sanitizations: 0b00010001, confidence: :verified}
      result = Taint.propagate_taint([a, b])
      assert result.sanitizations == 0b00010001
    end

    test "takes lowest confidence from multiple inputs" do
      a = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified}
      b = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :unverified}
      result = Taint.propagate_taint([a, b])
      assert result.confidence == :unverified
    end

    test "concatenates chains from multiple inputs" do
      a = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified, chain: ["a"]}
      b = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified, chain: ["b"]}
      result = Taint.propagate_taint([a, b])
      assert "a" in result.chain
      assert "b" in result.chain
    end
  end

  # ── Serialization ───────────────────────────────────────────────────

  describe "to_persistable/1" do
    test "converts struct to string-keyed map" do
      taint = %TaintStruct{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00010001,
        confidence: :plausible,
        source: "api",
        chain: ["step1"]
      }

      result = Taint.to_persistable(taint)
      assert result["taint_level"] == "untrusted"
      assert result["taint_sensitivity"] == "confidential"
      assert result["taint_sanitizations"] == 0b00010001
      assert result["taint_confidence"] == "plausible"
      assert result["taint_source"] == "api"
      assert result["taint_chain"] == ["step1"]
    end
  end

  describe "from_persistable/1" do
    test "restores struct from string-keyed map" do
      map = %{
        "taint_level" => "untrusted",
        "taint_sensitivity" => "confidential",
        "taint_sanitizations" => 17,
        "taint_confidence" => "plausible",
        "taint_source" => "api",
        "taint_chain" => ["step1"]
      }

      result = Taint.from_persistable(map)
      assert result.level == :untrusted
      assert result.sensitivity == :confidential
      assert result.sanitizations == 17
      assert result.confidence == :plausible
      assert result.source == "api"
      assert result.chain == ["step1"]
    end

    test "round-trips through to_persistable -> from_persistable" do
      original = %TaintStruct{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0xFF,
        confidence: :verified,
        source: "test",
        chain: ["a", "b"]
      }

      restored = original |> Taint.to_persistable() |> Taint.from_persistable()
      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.sanitizations == original.sanitizations
      assert restored.confidence == original.confidence
      assert restored.source == original.source
      assert restored.chain == original.chain
    end

    test "fail-closed: corrupt level defaults to :hostile" do
      result = Taint.from_persistable(%{"taint_level" => "garbage"})
      assert result.level == :hostile
    end

    test "fail-closed: corrupt sensitivity defaults to :restricted" do
      result = Taint.from_persistable(%{"taint_sensitivity" => "garbage"})
      assert result.sensitivity == :restricted
    end

    test "fail-closed: corrupt confidence defaults to :unverified" do
      result = Taint.from_persistable(%{"taint_confidence" => "garbage"})
      assert result.confidence == :unverified
    end

    test "handles nil values gracefully" do
      result = Taint.from_persistable(%{})
      assert result.level == :hostile
      assert result.sensitivity == :restricted
      assert result.confidence == :unverified
      assert result.sanitizations == 0
      assert result.chain == []
    end

    test "handles atom values (already deserialized)" do
      result = Taint.from_persistable(%{
        "taint_level" => :trusted,
        "taint_sensitivity" => :public
      })
      assert result.level == :trusted
      assert result.sensitivity == :public
    end
  end

  # ── LLM Output ──────────────────────────────────────────────────────

  describe "for_llm_output/1" do
    test "wipes all sanitization bits" do
      input = %TaintStruct{
        level: :trusted,
        sensitivity: :internal,
        sanitizations: 0xFF,
        confidence: :verified,
        source: "user"
      }

      result = Taint.for_llm_output(input)
      assert result.sanitizations == 0
    end

    test "output is at least :derived" do
      input = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified}
      result = Taint.for_llm_output(input)
      assert result.level == :derived
    end

    test "hostile input stays hostile" do
      input = %TaintStruct{level: :hostile, sensitivity: :public, confidence: :verified}
      result = Taint.for_llm_output(input)
      assert result.level == :hostile
    end

    test "confidence capped at plausible" do
      input = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified}
      result = Taint.for_llm_output(input)
      assert result.confidence == :plausible
    end

    test "preserves sensitivity" do
      input = %TaintStruct{level: :trusted, sensitivity: :restricted, confidence: :verified}
      result = Taint.for_llm_output(input)
      assert result.sensitivity == :restricted
    end

    test "source is set to llm_output" do
      input = %TaintStruct{level: :trusted, sensitivity: :public, confidence: :verified, source: "user"}
      result = Taint.for_llm_output(input)
      assert result.source == "llm_output"
    end
  end

  # ── Data Hash ─────────────────────────────────────────────────────

  describe "data_hash/1" do
    test "produces deterministic hash for same data" do
      data = %{"key" => "value", "number" => 42}
      hash1 = Taint.data_hash(data)
      hash2 = Taint.data_hash(data)
      assert hash1 == hash2
    end

    test "produces different hash for different data" do
      hash1 = Taint.data_hash(%{"a" => 1})
      hash2 = Taint.data_hash(%{"a" => 2})
      assert hash1 != hash2
    end

    test "returns lowercase hex string" do
      hash = Taint.data_hash("test")
      assert Regex.match?(~r/^[0-9a-f]{64}$/, hash)
    end

    test "works with various data types" do
      assert is_binary(Taint.data_hash("string"))
      assert is_binary(Taint.data_hash(42))
      assert is_binary(Taint.data_hash([1, 2, 3]))
      assert is_binary(Taint.data_hash(%{nested: %{key: "val"}}))
    end
  end

  describe "verify_data_hash/2" do
    test "returns :ok for matching hash" do
      data = %{"key" => "value"}
      hash = Taint.data_hash(data)
      assert :ok = Taint.verify_data_hash(data, hash)
    end

    test "returns error for mismatched hash" do
      data = %{"key" => "value"}
      assert {:error, :hash_mismatch} = Taint.verify_data_hash(data, "wrong_hash")
    end

    test "detects modification after hashing" do
      original = %{"key" => "value"}
      hash = Taint.data_hash(original)
      modified = %{"key" => "tampered"}
      assert {:error, :hash_mismatch} = Taint.verify_data_hash(modified, hash)
    end
  end

  describe "to_persistable/2 with data_hash" do
    test "includes taint_data_hash when provided" do
      taint = %TaintStruct{level: :trusted, sensitivity: :public}
      result = Taint.to_persistable(taint, data_hash: "abc123")
      assert result["taint_data_hash"] == "abc123"
    end

    test "excludes taint_data_hash when not provided" do
      taint = %TaintStruct{level: :trusted, sensitivity: :public}
      result = Taint.to_persistable(taint)
      refute Map.has_key?(result, "taint_data_hash")
    end

    test "backward compatible — no opts is same as empty opts" do
      taint = %TaintStruct{level: :trusted, sensitivity: :public}
      result1 = Taint.to_persistable(taint)
      result2 = Taint.to_persistable(taint, [])
      assert result1 == result2
    end
  end

  # ── Bridge ──────────────────────────────────────────────────────────

  describe "from_level/1" do
    test "upgrades atom to struct with defaults" do
      result = Taint.from_level(:untrusted)
      assert %TaintStruct{} = result
      assert result.level == :untrusted
      assert result.sensitivity == :internal
      assert result.confidence == :unverified
    end

    test "works for all valid levels" do
      for level <- [:trusted, :derived, :untrusted, :hostile] do
        result = Taint.from_level(level)
        assert result.level == level
      end
    end
  end
end
