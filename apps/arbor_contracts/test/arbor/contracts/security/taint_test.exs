defmodule Arbor.Contracts.Security.TaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.Taint

  @moduletag :fast

  describe "struct defaults" do
    test "default struct has conservative values" do
      taint = %Taint{}
      assert taint.level == :trusted
      assert taint.sensitivity == :internal
      assert taint.sanitizations == 0
      assert taint.confidence == :unverified
      assert taint.source == nil
      assert taint.chain == []
    end

    test "all fields can be set" do
      taint = %Taint{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0xFF,
        confidence: :verified,
        source: "external_api",
        chain: ["step_1", "step_2"]
      }

      assert taint.level == :hostile
      assert taint.sensitivity == :restricted
      assert taint.sanitizations == 0xFF
      assert taint.confidence == :verified
      assert taint.source == "external_api"
      assert taint.chain == ["step_1", "step_2"]
    end
  end

  describe "sanitization_bits/0" do
    test "returns all 8 sanitization bit positions" do
      bits = Taint.sanitization_bits()
      assert map_size(bits) == 8
      assert bits[:xss] == 0b00000001
      assert bits[:sqli] == 0b00000010
      assert bits[:command_injection] == 0b00000100
      assert bits[:path_traversal] == 0b00001000
      assert bits[:prompt_injection] == 0b00010000
      assert bits[:ssrf] == 0b00100000
      assert bits[:log_injection] == 0b01000000
      assert bits[:deserialization] == 0b10000000
    end

    test "all bits are distinct powers of 2" do
      values = Map.values(Taint.sanitization_bits())
      assert length(Enum.uniq(values)) == 8

      Enum.each(values, fn v ->
        assert Bitwise.band(v, v - 1) == 0, "#{v} is not a power of 2"
      end)
    end
  end

  describe "sanitization_bit/1" do
    test "returns bit for known sanitizations" do
      assert {:ok, 0b00000001} = Taint.sanitization_bit(:xss)
      assert {:ok, 0b00010000} = Taint.sanitization_bit(:prompt_injection)
    end

    test "returns :error for unknown sanitizations" do
      assert :error = Taint.sanitization_bit(:unknown)
    end
  end

  describe "ordering constants" do
    test "levels returns severity order" do
      assert Taint.levels() == [:trusted, :derived, :untrusted, :hostile]
    end

    test "sensitivities returns classification order" do
      assert Taint.sensitivities() == [:public, :internal, :confidential, :restricted]
    end

    test "confidences returns certainty order" do
      assert Taint.confidences() == [:unverified, :plausible, :corroborated, :verified]
    end
  end

  describe "Jason encoding" do
    test "encodes to JSON" do
      taint = %Taint{level: :untrusted, source: "api"}
      assert {:ok, json} = Jason.encode(taint)
      decoded = Jason.decode!(json)
      assert decoded["level"] == "untrusted"
      assert decoded["sensitivity"] == "internal"
      assert decoded["sanitizations"] == 0
      assert decoded["confidence"] == "unverified"
      assert decoded["source"] == "api"
      assert decoded["chain"] == []
    end

    test "round-trips through JSON with atom restoration" do
      taint = %Taint{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0b00010001,
        confidence: :verified,
        source: "test",
        chain: ["a", "b"]
      }

      json = Jason.encode!(taint)
      decoded = Jason.decode!(json)

      assert decoded["level"] == "hostile"
      assert decoded["sensitivity"] == "restricted"
      assert decoded["sanitizations"] == 0b00010001
      assert decoded["confidence"] == "verified"
    end
  end
end
