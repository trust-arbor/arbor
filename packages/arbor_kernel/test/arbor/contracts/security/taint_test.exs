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

  describe "exact validation and joins" do
    test "canonicalizes exact atom and string-keyed maps without creating atoms" do
      attrs = %{
        level: :untrusted,
        sensitivity: :restricted,
        sanitizations: 3,
        confidence: :verified,
        source: "api",
        chain: ["ingress"]
      }

      assert {:ok, taint} = Taint.canonicalize(attrs)
      assert taint.level == :untrusted
      assert {:ok, ^taint} = Taint.canonicalize(%{attrs | level: "untrusted"})

      key = "taint_key_that_must_not_be_created_#{System.unique_integer([:positive])}"
      before = :erlang.system_info(:atom_count)
      assert {:error, :invalid_taint_shape} = Taint.canonicalize(Map.put(attrs, key, :value))
      assert :erlang.system_info(:atom_count) == before
    end

    test "rejects malformed and unbounded taints" do
      taint = %Taint{}

      for invalid <- [
            %{taint | level: :unknown},
            %{taint | sanitizations: -1},
            %{taint | sanitizations: 256},
            %{taint | source: String.duplicate("x", Taint.max_source_bytes() + 1)},
            %{taint | chain: List.duplicate("x", Taint.max_chain_entries() + 1)},
            Map.put(taint, :extra, :value),
            %{taint | chain: [<<255>>]}
          ] do
        assert {:error, :invalid_taint} = Taint.canonicalize(invalid)
      end
    end

    test "joins dimensions monotonically and sanitizations by intersection" do
      left = %Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b0111,
        confidence: :verified,
        source: "z-source",
        chain: ["shared", "left"]
      }

      right = %Taint{
        level: :hostile,
        sensitivity: :restricted,
        sanitizations: 0b0101,
        confidence: :plausible,
        source: "a-source",
        chain: ["shared", "right"]
      }

      assert {:ok, joined} = Taint.join(left, right)
      assert joined.level == :hostile
      assert joined.sensitivity == :restricted
      assert joined.sanitizations == 0b0101
      assert joined.confidence == :plausible
      assert joined.source == "a-source"
      assert joined.chain == ["left", "right", "shared", "z-source"]
    end

    test "whole-struct join is commutative, associative, and idempotent" do
      a = %Taint{source: "a", chain: ["a1"], sanitizations: 0b111}
      b = %Taint{source: "b", chain: ["b1"], level: :derived, sanitizations: 0b011}
      c = %Taint{source: "c", chain: ["c1"], sensitivity: :confidential, sanitizations: 0b001}

      assert {:ok, ab} = Taint.join(a, b)
      assert {:ok, ba} = Taint.join(b, a)
      assert ab == ba
      assert {:ok, aa} = Taint.join(a, a)
      assert aa == a

      assert {:ok, left} = Taint.join(ab, c)
      assert {:ok, bc} = Taint.join(b, c)
      assert {:ok, right} = Taint.join(a, bc)
      assert left == right
      assert {:ok, same} = Taint.join(left, left)
      assert same == left
    end

    test "equivalent differently ordered provenance labels converge" do
      left = %Taint{source: "root", chain: ["b", "a"]}
      right = %Taint{source: "root", chain: ["a", "b"]}

      assert {:ok, joined_left} = Taint.join(left, right)
      assert {:ok, joined_right} = Taint.join(right, left)
      assert joined_left == joined_right
      assert Taint.validate(joined_left) == :ok
    end

    test "provenance overflow returns an absorbing invalid durable taint" do
      left = %Taint{source: "left", chain: Enum.map(1..16, &"left-#{&1}")}
      right = %Taint{source: "right"}

      assert {:ok, invalid} = Taint.join(left, right)
      assert invalid == Taint.invalid_durable_provenance()
      assert {:ok, ^invalid} = Taint.join(invalid, %Taint{source: "later"})
    end

    test "a max-chain union remains valid when the source is already present" do
      max_chain = %Taint{source: "shared", chain: Enum.map(1..16, &"label-#{&1}")}

      assert {:ok, joined} = Taint.join(max_chain, %Taint{source: "shared"})
      assert Taint.validate(joined) == :ok

      assert Enum.sort([joined.source | joined.chain]) == [
               "label-1",
               "label-10",
               "label-11",
               "label-12",
               "label-13",
               "label-14",
               "label-15",
               "label-16",
               "label-2",
               "label-3",
               "label-4",
               "label-5",
               "label-6",
               "label-7",
               "label-8",
               "label-9",
               "shared"
             ]

      assert {:ok, invalid} = Taint.join(max_chain, %Taint{source: "seventeenth"})
      assert invalid == Taint.invalid_durable_provenance()
    end

    test "rejects improper chains at the public validation boundary" do
      taint = %Taint{chain: ["bounded" | :improper_tail]}
      assert {:error, :invalid_taint} = Taint.validate(taint)
      assert {:error, :invalid_taint} = Taint.canonicalize(taint)
    end

    test "security regression: join_many rejects improper and empty lists without raising" do
      assert {:error, :invalid_taint_list} =
               Taint.join_many([%Taint{} | :improper_tail])

      assert {:error, :empty_taint_list} = Taint.join_many([])
    end

    test "security regression: join_many enforces its exact input ceiling" do
      max = Taint.max_join_inputs()
      taint = %Taint{source: "bounded"}

      assert max == 256
      assert {:ok, ^taint} = Taint.join_many(List.duplicate(taint, max))

      over_limit = List.duplicate(taint, max) ++ [taint | :unvisited_tail]
      assert {:error, :taint_join_limit_exceeded} = Taint.join_many(over_limit)
    end

    test "security regression: oversized taint maps reject before key enumeration" do
      oversized = Map.new(1..100_000, &{&1, &1})
      assert {:error, :invalid_taint_shape} = Taint.canonicalize(oversized)
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

    test "security regression: invalid taint cannot bypass validation through Jason" do
      invalid = %Taint{sanitizations: 999}
      assert {:error, %Protocol.UndefinedError{}} = Jason.encode(invalid)
    end
  end
end
