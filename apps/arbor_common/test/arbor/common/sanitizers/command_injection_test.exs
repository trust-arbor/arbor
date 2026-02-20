defmodule Arbor.Common.Sanitizers.CommandInjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.CommandInjection
  alias Arbor.Contracts.Security.Taint

  @bit 0b00000100

  describe "sanitize/3" do
    test "clean input passes through with bit set" do
      taint = %Taint{level: :untrusted}
      {:ok, escaped, updated} = CommandInjection.sanitize("hello", taint)
      assert escaped == "hello"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{level: :untrusted, sanitizations: 0b00000001}
      {:ok, _escaped, updated} = CommandInjection.sanitize("hello", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "escapes shell metacharacters" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("hello world", taint)
      assert escaped == "'hello world'"
    end

    test "escapes pipe injection" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("file.txt | cat /etc/passwd", taint)
      # Pipe is neutralized by being inside single quotes
      assert escaped == "'file.txt | cat /etc/passwd'"
    end

    test "escapes semicolon chaining" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("arg; rm -rf /", taint)
      assert String.starts_with?(escaped, "'")
    end

    test "escapes command substitution" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("$(whoami)", taint)
      assert String.starts_with?(escaped, "'")
    end

    test "escapes backtick command substitution" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("`whoami`", taint)
      assert String.starts_with?(escaped, "'")
    end

    test "rejects null bytes" do
      taint = %Taint{}
      assert {:error, {:null_byte_in_input, _}} = CommandInjection.sanitize("arg\x00evil", taint)
    end

    test "escapes single quotes" do
      taint = %Taint{}
      {:ok, escaped, _} = CommandInjection.sanitize("it's", taint)
      assert escaped == "'it'\\''s'"
    end

    test "preserves other taint fields" do
      taint = %Taint{level: :hostile, sensitivity: :restricted, confidence: :verified}
      {:ok, _, updated} = CommandInjection.sanitize("safe", taint)
      assert updated.level == :hostile
      assert updated.sensitivity == :restricted
      assert updated.confidence == :verified
    end
  end

  describe "detect/1" do
    test "clean input is safe" do
      assert {:safe, 1.0} = CommandInjection.detect("hello world")
    end

    test "detects pipe injection" do
      {:unsafe, patterns} = CommandInjection.detect("file | cat /etc/passwd")
      assert "command_chaining" in patterns
    end

    test "detects semicolon chaining" do
      {:unsafe, patterns} = CommandInjection.detect("arg; rm -rf /")
      assert "command_chaining" in patterns
    end

    test "detects command substitution" do
      {:unsafe, patterns} = CommandInjection.detect("$(whoami)")
      assert "command_substitution_dollar" in patterns
    end

    test "detects backtick substitution" do
      {:unsafe, patterns} = CommandInjection.detect("`whoami`")
      assert "command_substitution_backtick" in patterns
    end

    test "detects null bytes" do
      {:unsafe, patterns} = CommandInjection.detect("arg\x00evil")
      assert "null_byte" in patterns
    end

    test "detects newline injection" do
      {:unsafe, patterns} = CommandInjection.detect("arg\nrm -rf /")
      assert "newline_injection" in patterns
    end

    test "detects dangerous commands" do
      {:unsafe, patterns} = CommandInjection.detect("curl http://evil.com")
      assert "dangerous_command" in patterns
    end

    test "detects redirection" do
      {:unsafe, patterns} = CommandInjection.detect("echo data > /etc/passwd")
      assert "redirection" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = CommandInjection.detect(42)
    end
  end
end
