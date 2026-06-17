defmodule Arbor.Contracts.DependencyHierarchyTest do
  @moduledoc """
  Drift guard for the umbrella's in-umbrella dependency hierarchy.

  This test is the enforcement half of `app-hierarchy-reevaluation`
  (`.arbor/roadmap/1-brainstorming/`). The canonical hierarchy docs (CLAUDE.md →
  "Library Hierarchy") repeatedly rotted out of sync with the real `mix.exs`
  graph (ai mislabelled "standalone", five apps undocumented, level buckets
  wrong). This test makes the docs un-rottable by checking them against the
  source of truth — the `deps` declarations themselves — at CI time.

  It asserts two invariants:

    1. **Acyclic** — the in-umbrella dependency graph has no cycles. (Under
       longest-path leveling this is equivalent to "every dep targets a strictly
       lower level"; a cycle is the only way that can break.)
    2. **Docs match reality** — CLAUDE.md's published `L0..Ln` block equals the
       longest-path levels computed from the actual `apps/*/mix.exs` deps. Add a
       dep that changes the levels and this fails until CLAUDE.md is updated.

  Parsing is done via the mix.exs AST (not a regex) so module names mentioned in
  COMMENTS are not mistaken for real deps (a real foot-gun: arbor_orchestrator's
  deps comment names arbor_commands/arbor_dashboard, which a naive grep counts as
  a cycle).
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  # ── Locate the umbrella root (robust to CI cwd) ──────────────────────────────
  defp umbrella_root do
    find_root(__DIR__)
  end

  defp find_root(dir) do
    cond do
      File.exists?(Path.join([dir, "apps", "arbor_contracts", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "could not locate umbrella root from #{__DIR__}"
      true -> find_root(Path.dirname(dir))
    end
  end

  # ── Parse the real in-umbrella dep graph from apps/*/mix.exs (via AST) ────────
  defp dep_graph do
    root = umbrella_root()

    tracked_mix_files(root)
    |> Map.new(fn path ->
      app = Path.basename(Path.dirname(path))
      {app, in_umbrella_deps(path)}
    end)
  end

  # Use git-TRACKED mix.exs files, not a filesystem glob, so the computed graph
  # reflects the COMMITTED umbrella and is identical in CI and locally. A bare
  # `Path.wildcard` picks up gitignored local-only apps (e.g.
  # `apps/arbor_integrations/`, a private business-integrations app excluded via
  # .gitignore) — which made this test pass on a dev machine but fail in CI's
  # clean checkout, since the docs describe only the committed apps.
  defp tracked_mix_files(root) do
    case System.cmd("git", ["-C", root, "ls-files", "apps/*/mix.exs"], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.map(&Path.join(root, &1))

      _ ->
        # Not a git checkout (e.g. an extracted tarball) — best-effort fallback.
        # In-repo CI/local always take the git path above.
        Path.wildcard(Path.join([root, "apps", "*", "mix.exs"]))
    end
  end

  defp in_umbrella_deps(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, deps} =
      Macro.prewalk(ast, [], fn
        {dep, opts} = node, acc when is_atom(dep) and is_list(opts) ->
          if to_string(dep) =~ ~r/^arbor_/ and Keyword.get(opts, :in_umbrella) == true do
            {node, [to_string(dep) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(deps)
  end

  # ── Longest-path level computation with cycle detection ──────────────────────
  # level(app) = 0 if no in-umbrella deps, else 1 + max(level(dep)).
  defp compute_levels(graph) do
    Enum.reduce(Map.keys(graph), %{}, fn app, cache ->
      {_lvl, cache} = level_of(app, graph, cache, MapSet.new())
      cache
    end)
  end

  defp level_of(app, graph, cache, stack) do
    cond do
      Map.has_key?(cache, app) ->
        {Map.fetch!(cache, app), cache}

      MapSet.member?(stack, app) ->
        throw({:cycle, app, MapSet.to_list(MapSet.put(stack, app))})

      true ->
        deps = Map.get(graph, app, [])
        next_stack = MapSet.put(stack, app)

        {lvl, cache} =
          Enum.reduce(deps, {0, cache}, fn dep, {mx, c} ->
            {dep_lvl, c} = level_of(dep, graph, c, next_stack)
            {max(mx, dep_lvl + 1), c}
          end)

        {lvl, Map.put(cache, app, lvl)}
    end
  end

  defp levels_by_bucket(level_map) do
    level_map
    |> Enum.group_by(fn {_app, lvl} -> lvl end, fn {app, _lvl} -> app end)
    |> Map.new(fn {lvl, apps} -> {lvl, Enum.sort(apps)} end)
  end

  # ── Parse CLAUDE.md's published "Ln  app, app, ..." block ────────────────────
  defp claude_md_levels do
    content = File.read!(Path.join(umbrella_root(), "CLAUDE.md"))

    Regex.scan(~r/^L(\d+)\s+(.+)$/m, content)
    |> Map.new(fn [_full, lvl, rest] ->
      apps =
        rest
        # drop any trailing parenthetical annotation, e.g. "(zero in-umbrella deps)"
        |> String.replace(~r/\(.*$/, "")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.sort()

      {String.to_integer(lvl), apps}
    end)
  end

  # ── Tests ────────────────────────────────────────────────────────────────────
  test "the in-umbrella dependency graph is acyclic" do
    graph = dep_graph()

    try do
      _ = compute_levels(graph)
      assert map_size(graph) > 0, "parsed an empty dep graph — parser/path bug"
    catch
      {:cycle, app, path} ->
        flunk("""
        In-umbrella dependency CYCLE detected involving `#{app}`.
        Cycle path: #{Enum.join(path, " -> ")}
        Every in-umbrella dep must point to a strictly LOWER level — a cycle means
        two apps depend on each other (directly or transitively). Break it with a
        facade/behaviour-injection seam (CONTRACT_RULES §8-9) instead of a hard dep.
        """)
    end
  end

  test "CLAUDE.md's published L0-Ln hierarchy matches the real mix.exs graph" do
    computed = dep_graph() |> compute_levels() |> levels_by_bucket()
    documented = claude_md_levels()

    assert documented != %{},
           "could not parse any 'Ln  app, ...' lines from CLAUDE.md — format changed?"

    if computed != documented do
      mismatches =
        for lvl <- Enum.sort(Map.keys(Map.merge(computed, documented))),
            Map.get(computed, lvl) != Map.get(documented, lvl) do
          "  L#{lvl}:\n    mix.exs  : #{inspect(Map.get(computed, lvl))}\n    CLAUDE.md: #{inspect(Map.get(documented, lvl))}"
        end

      flunk("""
      CLAUDE.md's "Library Hierarchy" has drifted from the real apps/*/mix.exs graph.
      Update the Ln block in CLAUDE.md to match the computed levels below
      (this is the source of truth — the deps don't lie):

      #{Enum.join(mismatches, "\n")}
      """)
    end
  end
end
