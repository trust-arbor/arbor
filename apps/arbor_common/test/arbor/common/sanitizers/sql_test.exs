defmodule Arbor.Common.Sanitizers.SQLTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.Sanitizers.SQL
  alias Arbor.Contracts.Security.Taint

  @bit 0b00000010

  describe "sanitize/3 - like_pattern mode" do
    test "clean input passes through with bit set" do
      taint = %Taint{level: :untrusted}
      {:ok, escaped, updated} = SQL.sanitize("search term", taint)
      assert escaped == "search term"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "escapes percent wildcard" do
      taint = %Taint{}
      {:ok, escaped, _} = SQL.sanitize("100%", taint)
      assert escaped == "100\\%"
    end

    test "escapes underscore wildcard" do
      taint = %Taint{}
      {:ok, escaped, _} = SQL.sanitize("user_name", taint)
      assert escaped == "user\\_name"
    end

    test "escapes backslash" do
      taint = %Taint{}
      {:ok, escaped, _} = SQL.sanitize("path\\file", taint)
      assert escaped == "path\\\\file"
    end

    test "escapes all metacharacters together" do
      taint = %Taint{}
      {:ok, escaped, _} = SQL.sanitize("%_\\%", taint)
      assert escaped == "\\%\\_\\\\\\%"
    end

    test "preserves existing sanitization bits" do
      taint = %Taint{sanitizations: 0b00000001}
      {:ok, _, updated} = SQL.sanitize("term", taint)
      assert Bitwise.band(updated.sanitizations, 0b00000001) == 0b00000001
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end
  end

  describe "sanitize/3 - identifier mode" do
    test "allowed identifier passes" do
      taint = %Taint{}

      {:ok, value, updated} =
        SQL.sanitize("name", taint, mode: :identifier, allowed_identifiers: [:name, :status])

      assert value == "name"
      assert Bitwise.band(updated.sanitizations, @bit) == @bit
    end

    test "disallowed identifier rejected" do
      taint = %Taint{}

      assert {:error, {:identifier_not_allowed, "evil"}} =
               SQL.sanitize("evil", taint,
                 mode: :identifier,
                 allowed_identifiers: [:name, :status]
               )
    end

    test "missing allowed_identifiers option" do
      taint = %Taint{}

      assert {:error, {:missing_option, :allowed_identifiers}} =
               SQL.sanitize("name", taint, mode: :identifier)
    end
  end

  describe "escape_like_pattern/1" do
    test "escapes percent" do
      assert SQL.escape_like_pattern("100%") == "100\\%"
    end

    test "escapes underscore" do
      assert SQL.escape_like_pattern("a_b") == "a\\_b"
    end

    test "escapes backslash" do
      assert SQL.escape_like_pattern("a\\b") == "a\\\\b"
    end

    test "clean string unchanged" do
      assert SQL.escape_like_pattern("hello") == "hello"
    end
  end

  describe "detect/1" do
    test "clean input is safe" do
      assert {:safe, 1.0} = SQL.detect("SELECT name FROM users")
    end

    test "detects SQL comment dash" do
      {:unsafe, patterns} = SQL.detect("admin'--")
      assert "sql_comment_dash" in patterns
    end

    test "detects block comment" do
      {:unsafe, patterns} = SQL.detect("admin'/*comment*/")
      assert "sql_comment_block" in patterns
    end

    test "detects UNION SELECT" do
      {:unsafe, patterns} = SQL.detect("' UNION SELECT * FROM users")
      assert "union_select" in patterns
    end

    test "detects stacked query with DROP" do
      {:unsafe, patterns} = SQL.detect("'; DROP TABLE users")
      assert "stacked_query" in patterns
    end

    test "detects tautology" do
      {:unsafe, patterns} = SQL.detect("' OR 1=1")
      assert "tautology" in patterns
    end

    test "detects string tautology" do
      {:unsafe, patterns} = SQL.detect("' OR 'a'='a'")
      assert "string_tautology" in patterns
    end

    test "detects extended stored procedure" do
      {:unsafe, patterns} = SQL.detect("xp_cmdshell")
      assert "extended_stored_proc" in patterns
    end

    test "detects SLEEP-based timing attack" do
      {:unsafe, patterns} = SQL.detect("SLEEP(5)")
      assert "time_based" in patterns
    end

    test "detects BENCHMARK timing attack" do
      {:unsafe, patterns} = SQL.detect("BENCHMARK(10000000, SHA1('test'))")
      assert "time_based" in patterns
    end

    test "detects file operations" do
      {:unsafe, patterns} = SQL.detect("INTO OUTFILE '/tmp/dump'")
      assert "file_write" in patterns
    end

    test "non-string returns safe" do
      assert {:safe, 1.0} = SQL.detect(42)
    end
  end
end
