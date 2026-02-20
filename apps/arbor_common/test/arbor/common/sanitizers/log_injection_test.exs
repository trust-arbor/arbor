defmodule Arbor.Common.Sanitizers.LogInjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.LogInjection
  alias Arbor.Contracts.Security.Taint

  @bit 0b01000000

  describe "sanitize/3" do
    test "clean input passes through with bit set" do
      taint = %Taint{level: :untrusted}
      {:ok, sanitized, updated} = LogInjection.sanitize("normal log entry", taint)
      assert sanitized == "normal log entry"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "strips CRLF sequences" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("line1\r\nfake entry", taint)
      assert sanitized == "line1 fake entry"
    end

    test "strips CR alone" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("line1\rfake", taint)
      assert sanitized == "line1 fake"
    end

    test "strips ANSI escape codes" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("normal\e[31mred\e[0m text", taint)
      assert sanitized == "normalred text"
    end

    test "strips control characters" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("hello\x00\x01\x02world", taint)
      assert sanitized == "helloworld"
    end

    test "preserves tabs and newlines" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("col1\tcol2\nline2", taint)
      assert sanitized == "col1\tcol2\nline2"
    end

    test "truncates long input" do
      taint = %Taint{}
      long = String.duplicate("a", 100)
      {:ok, sanitized, _} = LogInjection.sanitize(long, taint, max_length: 50)
      assert String.starts_with?(sanitized, String.duplicate("a", 50))
      assert String.ends_with?(sanitized, "...[truncated]")
    end

    test "disabling redaction" do
      taint = %Taint{}
      {:ok, sanitized, _} = LogInjection.sanitize("test content", taint, redact: false)
      assert sanitized == "test content"
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}
      {:ok, _, updated} = LogInjection.sanitize("safe", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "detect/1" do
    test "clean input is safe" do
      assert {:safe, 1.0} = LogInjection.detect("normal log line")
    end

    test "detects CRLF injection" do
      {:unsafe, patterns} = LogInjection.detect("log\r\nfake entry")
      assert "crlf_injection" in patterns
    end

    test "detects CR injection" do
      {:unsafe, patterns} = LogInjection.detect("log\rfake")
      assert "cr_injection" in patterns
    end

    test "detects ANSI escapes" do
      {:unsafe, patterns} = LogInjection.detect("text\e[31mred\e[0m")
      assert "ansi_escape" in patterns
    end

    test "detects control characters" do
      {:unsafe, patterns} = LogInjection.detect("text\x01\x02")
      assert "control_characters" in patterns
    end

    test "detects null bytes" do
      {:unsafe, patterns} = LogInjection.detect("text\x00null")
      assert "null_byte" in patterns
    end

    test "detects excessive length" do
      long = String.duplicate("a", 10_001)
      {:unsafe, patterns} = LogInjection.detect(long)
      assert "excessive_length" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = LogInjection.detect(42)
    end
  end
end
