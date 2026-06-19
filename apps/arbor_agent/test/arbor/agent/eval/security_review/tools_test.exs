defmodule Arbor.Agent.Eval.SecurityReview.ToolsTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Tools

  defp scope do
    dir = Path.join(System.tmp_dir!(), "sectools_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))
    File.write!(Path.join(dir, "a.ex"), "defmodule A do\n  def authorize, do: :ok\nend\n")
    File.write!(Path.join(dir, "sub/b.ex"), "defmodule B do\n  def verify, do: true\nend\n")
    # a secret OUTSIDE the scope, to prove confinement
    secret = Path.join(System.tmp_dir!(), "outside_secret_#{System.unique_integer([:positive])}")
    File.write!(secret, "TOPSECRET")

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(secret)
    end)

    {dir, secret}
  end

  defp tool(tools, name), do: Enum.find(tools, &(&1.name == name))
  defp run(tools, name, args), do: tool(tools, name).execute.(args)

  test "list_files returns in-scope .ex files (relative paths)" do
    {dir, _} = scope()
    tools = Tools.for_scope(dir)
    assert %{files: files} = run(tools, "list_files", %{})
    assert "a.ex" in files
    assert "sub/b.ex" in files
  end

  test "read_file reads an in-scope file" do
    {dir, _} = scope()
    tools = Tools.for_scope(dir)
    assert %{content: content} = run(tools, "read_file", %{"path" => "a.ex"})
    assert content =~ "def authorize"
  end

  test "read_file DENIES a traversal escape (the safety guarantee)" do
    {dir, secret} = scope()
    tools = Tools.for_scope(dir)

    # Try to climb out to the secret via ../
    rel_escape = Path.relative_to(secret, dir)
    assert %{error: err} = run(tools, "read_file", %{"path" => rel_escape})
    assert err =~ "outside the review scope"

    # An absolute path to the secret is likewise denied.
    assert %{error: _} = run(tools, "read_file", %{"path" => secret})

    # And the content never leaks.
    refute match?(%{content: _}, run(tools, "read_file", %{"path" => rel_escape}))
  end

  test "search finds a literal pattern across in-scope files" do
    {dir, _} = scope()
    tools = Tools.for_scope(dir)
    assert %{matches: matches, match_count: n} = run(tools, "search", %{"pattern" => "authorize"})
    assert n >= 1
    assert Enum.any?(matches, &(&1.file == "a.ex"))
  end

  test "search/read reject non-string / empty args without raising" do
    {dir, _} = scope()
    tools = Tools.for_scope(dir)
    assert %{error: _} = run(tools, "read_file", %{"path" => nil})
    assert %{error: _} = run(tools, "search", %{"pattern" => ""})
  end
end
