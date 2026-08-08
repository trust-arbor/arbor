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

  alias Arbor.Contracts.Coding.SourceInventory

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
  # Default reads process env (production contained Mix). Explicit `env` maps are
  # for hermetic proofs only — never System.put_env.
  defp dep_graph do
    dep_graph(umbrella_root(), inventory_env_from_system())
  end

  defp dep_graph(root, env) when is_binary(root) and is_map(env) do
    tracked_mix_files(root, env)
    |> Map.new(fn path ->
      app = Path.basename(Path.dirname(path))
      {app, in_umbrella_deps(path)}
    end)
  end

  defp inventory_env_from_system do
    %{}
    |> put_env_if_present("ARBOR_MIX_CONTAINED")
    |> put_env_if_present("ARBOR_SOURCE_INVENTORY_PATH")
  end

  defp put_env_if_present(map, key) do
    case System.get_env(key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  # Use git-TRACKED mix.exs files outside contained mode so the computed graph
  # reflects the COMMITTED umbrella and is identical in CI and locally. A bare
  # `Path.wildcard` picks up gitignored local-only apps (e.g.
  # `apps/arbor_integrations/`, a private business-integrations app excluded via
  # .gitignore) — which made this test pass on a dev machine but fail in CI's
  # clean checkout, since the docs describe only the committed apps.
  #
  # Contained mode (`ARBOR_MIX_CONTAINED=1`) has no host Git metadata. It
  # consumes the owner-attested source-inventory manifest at
  # ARBOR_SOURCE_INVENTORY_PATH instead and never falls back to Path.wildcard.
  defp tracked_mix_files(root, env) when is_binary(root) and is_map(env) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" ->
        contained_tracked_mix_files(root, env)

      _ ->
        case System.cmd("git", ["-C", root, "ls-files", "apps/*/mix.exs"], stderr_to_stdout: true) do
          {out, 0} ->
            out |> String.split("\n", trim: true) |> Enum.map(&Path.join(root, &1))

          _ ->
            # Not a git checkout (e.g. an extracted tarball) — best-effort fallback.
            # In-repo CI/local always take the git path above. Contained mode never
            # reaches this branch.
            Path.wildcard(Path.join([root, "apps", "*", "mix.exs"]))
        end
    end
  end

  defp contained_tracked_mix_files(root, env) when is_binary(root) and is_map(env) do
    case resolve_source_inventory_path(env) do
      {:error, reason} ->
        flunk_missing_inventory({reason, :before_filesystem})

      {:ok, path} ->
        max_bytes = SourceInventory.max_encoded_bytes()

        with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
             :ok <- admit_manifest_byte_size(size, max_bytes),
             {:ok, bytes} <- File.read(path),
             {:ok, decoded} <- Jason.decode(bytes),
             {:ok, inventory} <- SourceInventory.new(decoded) do
          inventory
          |> SourceInventory.paths()
          |> Enum.filter(&app_mix_project_path?/1)
          |> Enum.map(&Path.join(root, &1))
        else
          {:error, :enoent} ->
            flunk_missing_inventory({:enoent, path})

          {:error, :oversized_manifest} ->
            flunk_missing_inventory({:oversized_manifest, path})

          {:error, reason} ->
            flunk_missing_inventory({reason, path})

          other ->
            flunk_missing_inventory({other, path})
        end
    end
  end

  defp admit_manifest_byte_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size >= 0 and max_bytes > 0 do
    if size <= max_bytes, do: :ok, else: {:error, :oversized_manifest}
  end

  # Obtain ARBOR_SOURCE_INVENTORY_PATH only from the supplied env map.
  # Missing, empty, or invalid values fail closed before any filesystem access.
  defp resolve_source_inventory_path(env) when is_map(env) do
    case Map.fetch(env, "ARBOR_SOURCE_INVENTORY_PATH") do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, _} ->
        {:error, :invalid_inventory_path}

      :error ->
        {:error, :missing_inventory_path}
    end
  end

  defp flunk_missing_inventory(detail) do
    flunk(
      "contained Mix requires a valid ARBOR_SOURCE_INVENTORY_PATH regular-file manifest; " <>
        "refusing Path.wildcard fallback that would weaken the tracked-only invariant" <>
        " (detail: #{inspect(detail)})"
    )
  end

  defp app_mix_project_path?(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app, "mix.exs"] when is_binary(app) and app != "" and app != "." and app != ".." ->
        true

      _ ->
        false
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
    # Ordinary Git path via process env (local/CI). Contained validation sets
    # ARBOR_MIX_CONTAINED=1 and supplies the attested inventory instead.
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

  test "contained mode: missing or invalid inventory fails closed without wildcard" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    # Missing path key — fail before filesystem; no fixed guest-path substitute.
    error =
      assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
        dep_graph(fixture.linked, %{"ARBOR_MIX_CONTAINED" => "1"})
      end

    assert error.message =~ "missing_inventory_path"
    assert error.message =~ "before_filesystem"

    # Empty path — fail before filesystem.
    error =
      assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
        dep_graph(fixture.linked, %{
          "ARBOR_MIX_CONTAINED" => "1",
          "ARBOR_SOURCE_INVENTORY_PATH" => ""
        })
      end

    assert error.message =~ "invalid_inventory_path"
    assert error.message =~ "before_filesystem"

    missing = Path.join(fixture.scratch, "missing-inventory.json")

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      dep_graph(fixture.linked, %{
        "ARBOR_MIX_CONTAINED" => "1",
        "ARBOR_SOURCE_INVENTORY_PATH" => missing
      })
    end

    bad = Path.join(fixture.scratch, "bad-inventory.json")
    File.write!(bad, "{not-valid\n")

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      dep_graph(fixture.linked, %{
        "ARBOR_MIX_CONTAINED" => "1",
        "ARBOR_SOURCE_INVENTORY_PATH" => bad
      })
    end

    # Oversized regular manifest rejected from lstat size before File.read.
    max = SourceInventory.max_encoded_bytes()
    oversized = Path.join(fixture.scratch, "oversized-inventory.json")
    {:ok, io} = File.open(oversized, [:write, :binary, :raw])
    :ok = :file.pwrite(io, max, <<0>>)
    :ok = File.close(io)
    {:ok, %File.Stat{type: :regular, size: size}} = File.lstat(oversized)
    assert size == max + 1

    error =
      assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
        dep_graph(fixture.linked, %{
          "ARBOR_MIX_CONTAINED" => "1",
          "ARBOR_SOURCE_INVENTORY_PATH" => oversized
        })
      end

    assert error.message =~ "oversized_manifest"
  end

  test "contained mode: linked worktree with inaccessible Git metadata uses attested inventory" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    # Plant gitignored private app only inside the fixture worktree — never the
    # real umbrella root (avoids cross-module races on apps/arbor_integrations).
    private_abs = Path.join(fixture.linked, "apps/arbor_integrations/mix.exs")
    File.mkdir_p!(Path.dirname(private_abs))

    File.write!(private_abs, """
    defmodule Arbor.Integrations.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_integrations, version: "0.0.1", deps: []]
    end
    """)

    inventory_paths = [
      "apps/arbor_contracts/mix.exs",
      "apps/arbor_shell/mix.exs"
    ]

    assert {:ok, inventory} =
             SourceInventory.build(String.duplicate("d", 40), inventory_paths)

    assert {:ok, bytes} = SourceInventory.encode(inventory)
    manifest_path = Path.join(fixture.scratch, "source_inventory.json")
    File.write!(manifest_path, bytes)

    seal_git_metadata!(fixture.main)

    {_out, git_code} =
      System.cmd("git", ["-C", fixture.linked, "ls-files"], stderr_to_stdout: true)

    assert git_code != 0

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => manifest_path
    }

    graph = dep_graph(fixture.linked, env)
    assert Map.has_key?(graph, "arbor_contracts")
    assert Map.has_key?(graph, "arbor_shell")
    refute Map.has_key?(graph, "arbor_integrations")
    assert map_size(graph) == 2

    # Graph is acyclic for the fixture apps (shell deps contracts).
    _ = compute_levels(graph)
  end

  # ── Linked-worktree fixture (private tmp; never touches the real umbrella) ──

  defp linked_worktree_fixture do
    scratch =
      Path.join(System.tmp_dir!(), "arbor-dep-lt-#{System.unique_integer([:positive])}")

    main = Path.join(scratch, "main")
    linked = Path.join(scratch, "linked")
    File.mkdir_p!(main)

    git!(main, ["init"])
    git!(main, ["config", "user.email", "test@example.com"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["checkout", "-b", "main"])

    File.write!(Path.join(main, ".gitignore"), "apps/arbor_integrations/\n")
    write_hierarchy_fixture(main)
    git!(main, ["add", "-A"])
    git!(main, ["commit", "-m", "init"])
    git!(main, ["branch", "feature"])
    git!(main, ["worktree", "add", linked, "feature"])

    %{scratch: scratch, main: main, linked: linked}
  end

  defp write_hierarchy_fixture(root) do
    File.mkdir_p!(Path.join([root, "apps", "arbor_contracts"]))
    File.mkdir_p!(Path.join([root, "apps", "arbor_shell"]))

    File.write!(Path.join([root, "apps", "arbor_contracts", "mix.exs"]), """
    defmodule Arbor.Contracts.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_contracts, version: "0.0.1", elixir: "~> 1.14", deps: []]
    end
    """)

    File.write!(Path.join([root, "apps", "arbor_shell", "mix.exs"]), """
    defmodule Arbor.Shell.MixProject do
      use Mix.Project
      def project do
        [
          app: :arbor_shell,
          version: "0.0.1",
          elixir: "~> 1.14",
          deps: [{:arbor_contracts, in_umbrella: true}]
        ]
      end
    end
    """)
  end

  defp seal_git_metadata!(main_repo) when is_binary(main_repo) do
    git_dir = Path.join(main_repo, ".git")
    :ok = File.chmod(git_dir, 0o000)
  end

  defp cleanup_linked_worktree_fixture(%{main: main, scratch: scratch}) do
    git_dir = Path.join(main, ".git")
    _ = File.chmod(git_dir, 0o700)
    _ = restore_git_tree_modes(git_dir)
    File.rm_rf(scratch)
    :ok
  end

  defp restore_git_tree_modes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        _ = File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, entries} ->
            Enum.each(entries, fn name ->
              restore_git_tree_modes(Path.join(path, name))
            end)

          _ ->
            :ok
        end

      {:ok, %File.Stat{type: :regular}} ->
        _ = File.chmod(path, 0o600)

      _ ->
        :ok
    end
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
