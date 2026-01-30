defmodule Arbor.Common.ShellEscapeTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.ShellEscape

  @moduletag :fast

  describe "escape_arg/1" do
    test "returns simple strings unchanged" do
      assert ShellEscape.escape_arg("hello") == "hello"
      assert ShellEscape.escape_arg("simple-path") == "simple-path"
      assert ShellEscape.escape_arg("/usr/bin/test") == "/usr/bin/test"
    end

    test "wraps strings with spaces" do
      assert ShellEscape.escape_arg("hello world") == "'hello world'"
    end

    test "escapes embedded single quotes" do
      assert ShellEscape.escape_arg("it's") == "'it'\\''s'"
    end

    test "wraps strings with double quotes" do
      assert ShellEscape.escape_arg("say \"hello\"") == "'say \"hello\"'"
    end

    test "wraps strings with shell metacharacters" do
      assert ShellEscape.escape_arg("$HOME") == "'$HOME'"
      assert ShellEscape.escape_arg("`whoami`") == "'`whoami`'"
      assert ShellEscape.escape_arg("a;b") == "'a;b'"
      assert ShellEscape.escape_arg("a&b") == "'a&b'"
      assert ShellEscape.escape_arg("a|b") == "'a|b'"
      assert ShellEscape.escape_arg("a>b") == "'a>b'"
      assert ShellEscape.escape_arg("a<b") == "'a<b'"
      assert ShellEscape.escape_arg("a\\b") == "'a\\b'"
    end

    test "wraps strings with glob characters" do
      assert ShellEscape.escape_arg("*.ex") == "'*.ex'"
      assert ShellEscape.escape_arg("file?.txt") == "'file?.txt'"
      assert ShellEscape.escape_arg("[abc]") == "'[abc]'"
    end

    test "wraps strings with bash expansion characters" do
      assert ShellEscape.escape_arg("~user") == "'~user'"
      assert ShellEscape.escape_arg("{a,b}") == "'{a,b}'"
      assert ShellEscape.escape_arg("!event") == "'!event'"
      assert ShellEscape.escape_arg("#comment") == "'#comment'"
    end

    test "wraps strings with whitespace variants" do
      assert ShellEscape.escape_arg("a\nb") == "'a\nb'"
      assert ShellEscape.escape_arg("a\tb") == "'a\tb'"
    end

    test "handles nil as empty quoted string" do
      assert ShellEscape.escape_arg(nil) == "''"
    end

    test "converts non-string values" do
      assert ShellEscape.escape_arg(42) == "42"
      assert ShellEscape.escape_arg(:atom) == "atom"
    end

    test "handles empty string" do
      assert ShellEscape.escape_arg("") == ""
    end

    test "handles multiple special characters" do
      assert ShellEscape.escape_arg("it's a \"test\" & more") ==
               "'it'\\''s a \"test\" & more'"
    end
  end

  describe "escape_arg!/1" do
    test "always wraps in quotes" do
      assert ShellEscape.escape_arg!("simple") == "'simple'"
      assert ShellEscape.escape_arg!("") == "''"
      assert ShellEscape.escape_arg!(nil) == "''"
    end

    test "escapes embedded single quotes" do
      assert ShellEscape.escape_arg!("it's") == "'it'\\''s'"
    end
  end

  describe "escape_args/1" do
    test "escapes and joins multiple arguments" do
      assert ShellEscape.escape_args(["echo", "hello world"]) == "echo 'hello world'"
    end

    test "handles mixed safe and unsafe arguments" do
      assert ShellEscape.escape_args(["git", "commit", "-m", "fix: it's broken"]) ==
               "git commit -m 'fix: it'\\''s broken'"
    end

    test "handles empty list" do
      assert ShellEscape.escape_args([]) == ""
    end
  end

  describe "needs_escaping?/1" do
    test "returns false for safe strings" do
      refute ShellEscape.needs_escaping?("hello")
      refute ShellEscape.needs_escaping?("/usr/bin/test")
      refute ShellEscape.needs_escaping?("file.txt")
    end

    test "returns true for strings with metacharacters" do
      assert ShellEscape.needs_escaping?("hello world")
      assert ShellEscape.needs_escaping?("$HOME")
      assert ShellEscape.needs_escaping?("a;b")
      assert ShellEscape.needs_escaping?("*.ex")
    end
  end
end
