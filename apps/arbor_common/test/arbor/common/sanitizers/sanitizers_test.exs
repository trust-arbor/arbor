defmodule Arbor.Common.SanitizersTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers
  alias Arbor.Contracts.Security.Taint

  describe "sanitize/4" do
    test "routes to correct module" do
      taint = %Taint{level: :untrusted}
      {:ok, escaped, _} = Sanitizers.sanitize(:command_injection, "hello world", taint)
      assert escaped == "'hello world'"
    end

    test "returns error for unknown sanitizer" do
      taint = %Taint{}
      assert {:error, {:unknown_sanitizer, :bogus}} = Sanitizers.sanitize(:bogus, "test", taint)
    end

    test "passes opts through" do
      taint = %Taint{}

      {:ok, resolved, _} =
        Sanitizers.sanitize(:path_traversal, "file.txt", taint, allowed_root: "/workspace")

      assert resolved == "/workspace/file.txt"
    end
  end

  describe "sanitize_all/4" do
    test "chains multiple sanitizers" do
      taint = %Taint{level: :untrusted}

      {:ok, sanitized, updated} =
        Sanitizers.sanitize_all([:log_injection, :xss], "hello\r\nworld", taint)

      # Log injection strips CRLF, XSS entity-encodes
      refute String.contains?(sanitized, "\r\n")
      # Both bits should be set
      assert Bitwise.band(updated.sanitizations, 0b01000000) == 0b01000000
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
    end

    test "stops on first error" do
      taint = %Taint{}

      # path_traversal without allowed_root option will error
      assert {:error, {:missing_option, :allowed_root}} =
               Sanitizers.sanitize_all([:log_injection, :path_traversal], "test", taint)
    end

    test "empty list returns unchanged" do
      taint = %Taint{}
      {:ok, value, unchanged} = Sanitizers.sanitize_all([], "test", taint)
      assert value == "test"
      assert unchanged.sanitizations == 0
    end
  end

  describe "needs_sanitization?/2" do
    test "returns true when bit not set" do
      taint = %Taint{sanitizations: 0}
      assert Sanitizers.needs_sanitization?(taint, :xss)
    end

    test "returns false when bit is set" do
      taint = %Taint{sanitizations: 0b00000001}
      refute Sanitizers.needs_sanitization?(taint, :xss)
    end

    test "returns true for unknown sanitizer" do
      taint = %Taint{sanitizations: 0xFF}
      assert Sanitizers.needs_sanitization?(taint, :bogus)
    end

    test "checks only the specific bit" do
      taint = %Taint{sanitizations: 0b00000010}
      refute Sanitizers.needs_sanitization?(taint, :sqli)
      assert Sanitizers.needs_sanitization?(taint, :xss)
    end
  end

  describe "detect/2" do
    test "routes detection to correct module" do
      {:unsafe, patterns} = Sanitizers.detect(:xss, "<script>alert(1)</script>")
      assert "script_tag" in patterns
    end

    test "returns safe for clean input" do
      assert {:safe, 1.0} = Sanitizers.detect(:xss, "hello")
    end

    test "returns error for unknown sanitizer" do
      assert {:error, {:unknown_sanitizer, :bogus}} = Sanitizers.detect(:bogus, "test")
    end
  end

  describe "types/0" do
    test "returns all sanitizer types" do
      types = Sanitizers.types()
      assert :xss in types
      assert :sqli in types
      assert :command_injection in types
      assert :path_traversal in types
      assert :prompt_injection in types
      assert :ssrf in types
      assert :log_injection in types
      assert :deserialization in types
      assert length(types) == 8
    end
  end

  describe "module_for/1" do
    test "returns module for known type" do
      assert {:ok, Arbor.Common.Sanitizers.XSS} = Sanitizers.module_for(:xss)
    end

    test "returns error for unknown type" do
      assert :error = Sanitizers.module_for(:bogus)
    end
  end
end
