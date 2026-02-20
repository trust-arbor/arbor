defmodule Arbor.Common.Sanitizers.DeserializationTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.Deserialization
  alias Arbor.Contracts.Security.Taint

  @bit 0b10000000

  describe "sanitize/3 - JSON mode" do
    test "valid JSON passes with bit set" do
      taint = %Taint{level: :untrusted}
      json = Jason.encode!(%{"name" => "test", "value" => 42})
      {:ok, decoded, updated} = Deserialization.sanitize(json, taint)
      assert decoded == %{"name" => "test", "value" => 42}
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "invalid JSON returns error" do
      taint = %Taint{}
      assert {:error, {:json_decode_error, _}} = Deserialization.sanitize("{invalid", taint)
    end

    test "deeply nested JSON rejected" do
      taint = %Taint{}
      # Build 35-deep nesting
      deep = Enum.reduce(1..35, "0", fn _, acc -> "{\"a\":#{acc}}" end)
      assert {:error, {:max_depth_exceeded, 32}} = Deserialization.sanitize(deep, taint)
    end

    test "custom max depth" do
      taint = %Taint{}
      nested = Jason.encode!(%{"a" => %{"b" => %{"c" => 1}}})

      assert {:error, {:max_depth_exceeded, 2}} =
               Deserialization.sanitize(nested, taint, max_depth: 2)
    end

    test "oversized JSON rejected" do
      taint = %Taint{}
      # Build a large array
      large = Jason.encode!(Enum.map(1..10_001, &%{"id" => &1}))
      assert {:error, {:max_size_exceeded, _, 10_000}} = Deserialization.sanitize(large, taint)
    end

    test "custom max size" do
      taint = %Taint{}
      data = Jason.encode!(%{"a" => [1, 2, 3, 4, 5]})

      assert {:error, {:max_size_exceeded, _, 3}} =
               Deserialization.sanitize(data, taint, max_size: 3)
    end

    test "byte size limit" do
      taint = %Taint{}
      large = String.duplicate("a", 100)

      assert {:error, {:too_large, 100, 50}} =
               Deserialization.sanitize(large, taint, max_byte_size: 50)
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}
      {:ok, _, updated} = Deserialization.sanitize("{}", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "sanitize/3 - ETF mode" do
    test "safe ETF binary passes" do
      taint = %Taint{}
      # Encode a simple term safely
      etf = :erlang.term_to_binary(%{key: "value"})
      {:ok, decoded, updated} = Deserialization.sanitize(etf, taint, format: :etf)
      assert decoded == %{key: "value"}
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "ETF with existing atoms passes" do
      taint = %Taint{}
      etf = :erlang.term_to_binary([:ok, :error, :hello])
      {:ok, decoded, _} = Deserialization.sanitize(etf, taint, format: :etf)
      assert decoded == [:ok, :error, :hello]
    end
  end

  describe "detect/1" do
    test "normal string is safe" do
      assert {:safe, 1.0} = Deserialization.detect("just a string")
    end

    test "detects ETF magic number" do
      etf = :erlang.term_to_binary(:test)
      {:unsafe, patterns} = Deserialization.detect(etf)
      assert "binary_term_format" in patterns
    end

    test "detects excessive size" do
      large = String.duplicate("x", 10_485_761)
      {:unsafe, patterns} = Deserialization.detect(large)
      assert "excessive_size" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = Deserialization.detect(42)
    end
  end

  describe "validate_depth/2" do
    test "flat map within limit" do
      assert :ok = Deserialization.validate_depth(%{"a" => 1}, 5)
    end

    test "nested map within limit" do
      assert :ok = Deserialization.validate_depth(%{"a" => %{"b" => 1}}, 5)
    end

    test "nested map exceeds limit" do
      deep = %{"a" => %{"b" => %{"c" => 1}}}
      assert {:error, {:max_depth_exceeded, 2}} = Deserialization.validate_depth(deep, 2)
    end

    test "list nesting counted" do
      assert :ok = Deserialization.validate_depth([1, [2, [3]]], 5)

      assert {:error, {:max_depth_exceeded, 1}} =
               Deserialization.validate_depth([1, [2, [3]]], 1)
    end
  end

  describe "validate_size/2" do
    test "small data within limit" do
      assert :ok = Deserialization.validate_size(%{"a" => 1}, 100)
    end

    test "data exceeds limit" do
      data = Enum.map(1..10, &{"key_#{&1}", &1}) |> Map.new()

      assert {:error, {:max_size_exceeded, _, 5}} =
               Deserialization.validate_size(data, 5)
    end
  end
end
