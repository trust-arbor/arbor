defmodule Arbor.Common.ProjectContextTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Common.ProjectContext

  setup do
    root = Path.join(System.tmp_dir!(), "pctx-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    on_exit(fn -> File.rm_rf(root) end)
    # globals: [] so tests don't pick up the real ~/.claude/CLAUDE.md
    {:ok, root: root, opts: [globals: []]}
  end

  test "loads AGENTS.md from the project root, labeled with its source path", %{
    root: root,
    opts: opts
  } do
    File.write!(Path.join(root, "AGENTS.md"), "root rules")
    out = ProjectContext.load(root, opts)
    assert out =~ "--- Context from: #{Path.join(root, "AGENTS.md")} ---"
    assert out =~ "root rules"
  end

  test "AGENTS.md wins over CLAUDE.md in the same directory", %{root: root, opts: opts} do
    File.write!(Path.join(root, "AGENTS.md"), "agents wins")
    File.write!(Path.join(root, "CLAUDE.md"), "claude loses")
    out = ProjectContext.load(root, opts)
    assert out =~ "agents wins"
    refute out =~ "claude loses"
  end

  test "falls back to CLAUDE.md when no AGENTS.md (Arbor's current state)", %{
    root: root,
    opts: opts
  } do
    File.write!(Path.join(root, "CLAUDE.md"), "claude conventions")
    assert ProjectContext.load(root, opts) =~ "claude conventions"
  end

  test "walks root → cwd, collecting one file per level, root-first order", %{
    root: root,
    opts: opts
  } do
    deep = Path.join([root, "sub", "deep"])
    File.mkdir_p!(deep)
    File.write!(Path.join(root, "AGENTS.md"), "ROOTCTX")
    File.write!(Path.join([root, "sub", "CLAUDE.md"]), "SUBCTX")
    File.write!(Path.join(deep, "AGENTS.md"), "DEEPCTX")

    out = ProjectContext.load(deep, opts)
    assert out =~ "ROOTCTX" and out =~ "SUBCTX" and out =~ "DEEPCTX"

    pos = fn s -> :binary.match(out, s) |> elem(0) end
    # global-first-then-root→cwd: ROOT before SUB before DEEP (nearest last)
    assert pos.("ROOTCTX") < pos.("SUBCTX")
    assert pos.("SUBCTX") < pos.("DEEPCTX")
  end

  test "stops at the .git root — a nested .git becomes the ceiling", %{root: root, opts: opts} do
    # nested project: root/pkg/.git ; loading from pkg/x must NOT reach root's AGENTS.md
    File.write!(Path.join(root, "AGENTS.md"), "OUTER")
    pkg = Path.join(root, "pkg")
    File.mkdir_p!(Path.join(pkg, ".git"))
    File.write!(Path.join(pkg, "AGENTS.md"), "INNER")
    x = Path.join(pkg, "x")
    File.mkdir_p!(x)

    out = ProjectContext.load(x, opts)
    assert out =~ "INNER"
    refute out =~ "OUTER"
  end

  test "returns empty string when no context files exist", %{root: root, opts: opts} do
    assert ProjectContext.load(root, opts) == ""
  end

  test "enforces the shared byte cap (truncates + marks)", %{root: root, opts: opts} do
    File.write!(Path.join(root, "AGENTS.md"), String.duplicate("x", 5_000))
    out = ProjectContext.load(root, Keyword.put(opts, :max_bytes, 100))
    assert out =~ "truncated"
    # content is capped to ~the budget (5000 -> ~100), well under the original; small slack from
    # the truncation marker/labeling is fine for a context byte cap.
    assert out |> String.graphemes() |> Enum.count(&(&1 == "x")) <= 110
  end
end
