defmodule Arbor.Contracts.DependencyHierarchyTest do
  @moduledoc """
  Drift guard for the repository's Arbor dependency hierarchy.

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
       longest-path levels computed from the actual application and extracted-package `mix.exs` deps. Add a
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
      File.regular?(Path.join([dir, "packages", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "could not locate umbrella root from #{__DIR__}"
      true -> find_root(Path.dirname(dir))
    end
  end

  # ── Parse the real Arbor dep graph from tracked applications/packages ────────
  # Default reads process env (production contained Mix). Explicit `env` maps are
  # for hermetic proofs only — never System.put_env.
  defp dep_graph do
    dep_graph(umbrella_root(), inventory_env_from_system())
  end

  defp dep_graph(root, env) when is_binary(root) and is_map(env) do
    projects = tracked_mix_files(root, env)
    known_apps = MapSet.new(projects, &Path.basename(Path.dirname(&1)))

    {graph, _owners} =
      Enum.reduce(projects, {%{}, %{}}, fn path, {graph, owners} ->
        app = Path.basename(Path.dirname(path))

        assert not Map.has_key?(owners, app),
               "duplicate application owner #{app}: #{inspect(Map.get(owners, app))} and #{path}"

        {Map.put(graph, app, in_umbrella_deps(path, root, known_apps)),
         Map.put(owners, app, path)}
      end)

    for {owner, deps} <- graph, dependency <- deps do
      assert Map.has_key?(graph, dependency),
             "missing repository dependency #{dependency} declared by #{owner}"
    end

    graph
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
        args = ["-C", root, "ls-files", "-z", "--", "apps/*/mix.exs", "packages/arbor_*/mix.exs"]

        case System.cmd("git", args, stderr_to_stdout: true) do
          {out, 0} ->
            out
            |> String.split(<<0>>, trim: true)
            |> Enum.filter(&app_mix_project_path?/1)
            |> Enum.map(&Path.join(root, &1))

          _ ->
            # Not a git checkout (e.g. an extracted tarball) — best-effort fallback.
            # In-repo CI/local always take the git path above. Contained mode never
            # reaches this branch.
            Path.wildcard(Path.join([root, "apps", "*", "mix.exs"])) ++
              Path.wildcard(Path.join([root, "packages", "arbor_*", "mix.exs"]))
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
      [scope, app, "mix.exs"]
      when scope in ["apps", "packages"] and is_binary(app) ->
        String.starts_with?(app, "arbor_")

      _ ->
        false
    end
  end

  defp in_umbrella_deps(path, root, known_apps \\ MapSet.new()) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, deps} =
      Macro.prewalk(ast, [], fn
        {:{}, _metadata, [dep, _requirement, opts]} = node, acc
        when is_atom(dep) and is_list(opts) ->
          if to_string(dep) =~ ~r/^arbor_/ and
               (Keyword.get(opts, :in_umbrella) == true or
                  repository_path_dep?(dep, opts, path, root)) do
            {node, [to_string(dep) | acc]}
          else
            {node, acc}
          end

        {dep, opts} = node, acc when is_atom(dep) and is_list(opts) ->
          if to_string(dep) =~ ~r/^arbor_/ and
               (Keyword.get(opts, :in_umbrella) == true or
                  repository_path_dep?(dep, opts, path, root)) do
            {node, [to_string(dep) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    published_deps =
      ast
      |> published_dependency_declarations()
      |> Enum.flat_map(fn
        {dep, requirement} when is_atom(dep) and is_binary(requirement) ->
          published_repository_dep(dep, requirement, [], known_apps)

        {:{}, _metadata, [dep, requirement, opts]} when is_atom(dep) and is_list(opts) ->
          published_repository_dep(dep, requirement, opts, known_apps)

        _ ->
          []
      end)

    Enum.uniq(deps ++ published_deps)
  end

  defp published_repository_dep(dep, requirement, opts, known_apps) do
    name = Atom.to_string(dep)

    if is_binary(requirement) and String.starts_with?(name, "arbor_") and
         MapSet.member?(known_apps, name) and
         not Enum.any?([:path, :git, :github, :hex], &Keyword.has_key?(opts, &1)) do
      [name]
    else
      []
    end
  end

  # Published tuples resemble keyword metadata; inspect only returned dependency
  # lists and statically reached helpers, preserving legacy path/umbrella parsing.
  defp published_dependency_declarations(ast) do
    nodes = block_expressions(ast)

    functions =
      Enum.reduce(nodes, %{}, fn
        {kind, _metadata, [{name, _context, args}, body]}, acc
        when kind in [:def, :defp] and is_atom(name) and args in [nil, []] ->
          Map.update(acc, name, [Keyword.get(body, :do)], &[Keyword.get(body, :do) | &1])

        _, acc ->
          acc
      end)

    deps =
      functions
      |> Map.get(:deps, [])
      |> Enum.flat_map(&dependency_list(&1, functions, MapSet.new([:deps])))

    project_deps =
      functions
      |> Map.get(:project, [])
      |> Enum.flat_map(fn body ->
        case return_expression(body) do
          entries when is_list(entries) ->
            Enum.flat_map(entries, fn
              {:deps, value} -> dependency_list(value, functions, MapSet.new())
              _ -> []
            end)

          _ ->
            []
        end
      end)

    nested_deps =
      Enum.flat_map(nodes, fn
        {:defmodule, _metadata, [_module, body]} ->
          published_dependency_declarations(Keyword.get(body, :do))

        _ ->
          []
      end)

    deps ++ project_deps ++ nested_deps
  end

  defp dependency_list({:__block__, _metadata, expressions}, functions, seen),
    do: dependency_list(List.last(expressions), functions, seen)

  defp dependency_list(entries, functions, seen) when is_list(entries),
    do: Enum.flat_map(entries, &dependency_entry(&1, functions, seen))

  defp dependency_list({:++, _metadata, [left, right]}, functions, seen),
    do: dependency_list(left, functions, seen) ++ dependency_list(right, functions, seen)

  defp dependency_list({:|>, _metadata, [entries, _filter]}, functions, seen),
    do: dependency_list(entries, functions, seen)

  defp dependency_list({:case, _metadata, [_selector, clauses]}, functions, seen),
    do: Enum.flat_map(case_returns(clauses), &dependency_list(&1, functions, seen))

  defp dependency_list({name, _metadata, args}, functions, seen)
       when is_atom(name) and args in [nil, []] do
    if MapSet.member?(seen, name) do
      []
    else
      functions
      |> Map.get(name, [])
      |> Enum.flat_map(&dependency_list(&1, functions, MapSet.put(seen, name)))
    end
  end

  defp dependency_list(_dynamic, _functions, _seen), do: []

  # A helper in a dependency list must return one tuple, while a helper used
  # as the list itself must return a list. Do not flatten nested lists or walk
  # tuple options: those positions can contain dependency-shaped metadata.
  defp dependency_entry({dep, _requirement} = entry, _functions, _seen) when is_atom(dep),
    do: [entry]

  defp dependency_entry({:{}, _metadata, [dep, _requirement, _opts]} = entry, _functions, _seen)
       when is_atom(dep),
       do: [entry]

  defp dependency_entry({:__block__, _metadata, expressions}, functions, seen),
    do: dependency_entry(List.last(expressions), functions, seen)

  defp dependency_entry({:case, _metadata, [_selector, clauses]}, functions, seen),
    do: Enum.flat_map(case_returns(clauses), &dependency_entry(&1, functions, seen))

  defp dependency_entry({name, _metadata, args}, functions, seen)
       when is_atom(name) and args in [nil, []] do
    if MapSet.member?(seen, name) do
      []
    else
      functions
      |> Map.get(name, [])
      |> Enum.flat_map(&dependency_entry(&1, functions, MapSet.put(seen, name)))
    end
  end

  defp dependency_entry(_dynamic, _functions, _seen), do: []

  # Without evaluating operator environment, conservatively retain possible
  # branch returns. In particular, a public version dependency in the nil
  # branch remains a known-owner edge even when another branch supplies a
  # dynamic local override. Existing source admission filters each tuple.
  defp case_returns(clauses) when is_list(clauses) do
    clauses
    |> Keyword.get(:do, [])
    |> Enum.flat_map(fn
      {:->, _metadata, [_patterns, body]} -> [body]
      _other -> []
    end)
  end

  defp return_expression({:__block__, _metadata, expressions}), do: List.last(expressions)
  defp return_expression(expression), do: expression

  defp block_expressions({:__block__, _metadata, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp repository_path_dep?(dep, opts, project_path, root) do
    case Keyword.get(opts, :path) do
      target when is_binary(target) ->
        target
        |> Path.expand(Path.dirname(project_path))
        |> Path.relative_to(Path.expand(root))
        |> Path.split()
        |> case do
          [scope, app] when scope in ["apps", "packages"] -> app == Atom.to_string(dep)
          _external_or_unresolved -> false
        end

      _dynamic_or_absent ->
        false
    end
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
  test "tracked packages and repository path edges cannot disappear from the graph" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)
    package = Path.join(fixture.linked, "packages/arbor_signals/mix.exs")
    File.mkdir_p!(Path.dirname(package))

    File.write!(package, """
    defmodule Signals.MixProject do
      def project, do: [app: :arbor_signals, deps: []]
    end
    """)

    File.write!(Path.join(fixture.linked, "apps/arbor_shell/mix.exs"), """
    defmodule Shell.MixProject do
      def project do
        [app: :arbor_shell, deps: [
          {:arbor_kernel, in_umbrella: true},
          {:arbor_signals, path: "../../packages/arbor_signals", runtime: false}
        ]]
      end
    end
    """)

    git!(fixture.linked, ["add", "packages/arbor_signals/mix.exs"])
    graph = dep_graph(fixture.linked, %{})
    assert graph["arbor_signals"] == []
    assert Enum.sort(graph["arbor_shell"]) == ["arbor_kernel", "arbor_signals"]
    assert compute_levels(graph)["arbor_shell"] == 1
  end

  test "published dependencies use only tracked or attested project owners" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    # An on-disk project is not an owner until the selected inventory admits it.
    untracked = Path.join(fixture.linked, "packages/arbor_untracked/mix.exs")
    File.mkdir_p!(Path.dirname(untracked))
    File.write!(untracked, "defmodule Untracked do def deps, do: [] end")

    nested = Path.join(fixture.linked, "packages/arbor_nested/examples/standalone/mix.exs")
    File.mkdir_p!(Path.dirname(nested))
    File.write!(nested, "defmodule Nested do def deps, do: [] end")
    git!(fixture.linked, ["add", "packages/arbor_nested/examples/standalone/mix.exs"])

    inventory_paths = [
      "apps/arbor_kernel/mix.exs",
      "apps/arbor_shell/mix.exs",
      "packages/arbor_nested/examples/standalone/mix.exs"
    ]

    assert {:ok, inventory} = SourceInventory.build(String.duplicate("e", 40), inventory_paths)
    assert {:ok, bytes} = SourceInventory.encode(inventory)
    manifest = Path.join(fixture.scratch, "versioned-source-inventory.json")
    File.write!(manifest, bytes)

    modes = [
      %{},
      %{"ARBOR_MIX_CONTAINED" => "1", "ARBOR_SOURCE_INVENTORY_PATH" => manifest}
    ]

    for declaration <- [
          "{:arbor_kernel, \"~> 0.1.0-dev\"}",
          "{:arbor_kernel, \"~> 0.1.0-dev\", runtime: false}"
        ] do
      File.write!(Path.join(fixture.linked, "apps/arbor_shell/mix.exs"), """
      defmodule Shell.MixProject do
        def deps do
          [
            #{declaration},
            {:arbor_unknown, "~> 0.1.0"},
            {:external, "~> 1.0"},
            {:arbor_untracked, "~> 0.1.0"},
            {:arbor_nested, "~> 0.1.0"}
          ]
        end
      end
      """)

      for env <- modes do
        graph = dep_graph(fixture.linked, env)
        assert graph == %{"arbor_kernel" => [], "arbor_shell" => ["arbor_kernel"]}
        assert compute_levels(graph) == %{"arbor_kernel" => 0, "arbor_shell" => 1}
      end
    end
  end

  test "returned dependency helpers preserve conditional public package edges" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)
    project = Path.join(fixture.linked, "apps/arbor_shell/mix.exs")

    for declaration <- [
          "def deps, do: [package_dependency()]",
          """
          def deps, do: selected_deps()
          defp selected_deps do
            case System.get_env("HIERARCHY_PACKAGE_LIST") do
              nil -> [package_dependency()]
              _configured -> []
            end
          end
          """
        ] do
      File.write!(project, """
      defmodule Shell.MixProject do
        def project, do: [deps: deps()]
        #{declaration}

        defp package_dependency do
          case System.get_env("HIERARCHY_PACKAGE_PATH") do
            nil -> {:arbor_kernel, "~> 2.0.0-dev"}
            path -> {:arbor_kernel, "~> 2.0.0-dev", path: path, override: true}
          end
        end
      end
      """)

      graph = dep_graph(fixture.linked, %{})
      assert graph == %{"arbor_kernel" => [], "arbor_shell" => ["arbor_kernel"]}
      assert compute_levels(graph) == %{"arbor_kernel" => 0, "arbor_shell" => 1}
    end
  end

  test "entry helpers do not turn metadata or unresolved sources into dependency edges" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)
    project = Path.join(fixture.linked, "apps/arbor_shell/mix.exs")

    File.write!(project, """
    defmodule Shell.MixProject do
      @versions [{:arbor_kernel, "~> 2.0.0-dev"}]
      def deps do
        [metadata_entry(), nested_list(), attribute_entry(), dynamic_entry(),
         foreign_entry(), dynamic_version(), returned_external(), cycle_a(),
         Foreign.package_dependency()]
      end

      defp metadata_entry, do: {:external, "~> 1.0", metadata: [arbor_kernel: "~> 2.0.0-dev"]}
      defp nested_list, do: [{:arbor_kernel, "~> 2.0.0-dev"}]
      defp attribute_entry, do: @versions
      defp unused_entry, do: {:arbor_kernel, "~> 2.0.0-dev"}
      defp foreign_entry, do: {:arbor_kernel, "~> 2.0.0-dev", git: "https://example.invalid/kernel.git"}
      defp dynamic_version, do: {:arbor_kernel, dependency_version()}
      defp cycle_a, do: cycle_b()
      defp cycle_b, do: cycle_a()

      defp dynamic_entry do
        case System.get_env("HIERARCHY_PACKAGE_PATH") do
          nil -> {:arbor_kernel, "~> 2.0.0-dev", path: dependency_path()}
          path -> {:arbor_kernel, "~> 2.0.0-dev", path: path}
        end
      end

      defp returned_external do
        _not_returned = {:arbor_kernel, "~> 2.0.0-dev"}
        case {:arbor_kernel, "~> 2.0.0-dev"} do
          {:arbor_kernel, "~> 2.0.0-dev"} -> {:external, "~> 1.0"}
        end
      end

      defmodule Foreign do
        def package_dependency, do: {:arbor_kernel, "~> 2.0.0-dev"}
      end
    end
    """)

    assert dep_graph(fixture.linked, %{}) == %{"arbor_kernel" => [], "arbor_shell" => []}
  end

  test "dependency-like metadata does not create hierarchy edges" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)
    project = Path.join(fixture.linked, "apps/arbor_shell/mix.exs")

    File.write!(project, """
    defmodule Shell.MixProject do
      @labels [arbor_kernel: "Kernel"]
      @versions [arbor_kernel: "~> 2.0.0-dev", arbor_shell: "~> 0.1.0"]
      @examples [{:arbor_kernel, "~> 2.0.0-dev", runtime: false}]
      def project, do: [deps: deps(), package: [arbor_kernel: "~> 2.0.0-dev"]]
      defp labels, do: [arbor_kernel: "~> 2.0.0-dev"]

      defp deps do
        _labels = [arbor_kernel: "~> 2.0.0-dev"]
        [{:external, "~> 1.0", metadata: [arbor_kernel: "~> 2.0.0-dev"]}]
      end
    end
    """)

    assert dep_graph(fixture.linked, %{}) == %{"arbor_kernel" => [], "arbor_shell" => []}

    for declaration <- [
          "[{:arbor_kernel, \"~> 2.0.0-dev\"}]",
          "core_deps() ++ optional_deps()"
        ] do
      File.write!(project, """
      defmodule Shell.MixProject do
        def project, do: [deps: #{declaration}, package: [arbor_shell: "~> 0.1.0"]]
        defp core_deps, do: [{:arbor_kernel, "~> 2.0.0-dev"}] |> Enum.uniq()
        defp optional_deps, do: repeated_deps()
        defp repeated_deps, do: optional_deps()
        defp labels, do: [arbor_shell: "~> 0.1.0"]
      end
      """)

      graph = dep_graph(fixture.linked, %{})
      assert graph == %{"arbor_kernel" => [], "arbor_shell" => ["arbor_kernel"]}
      assert compute_levels(graph) == %{"arbor_kernel" => 0, "arbor_shell" => 1}
    end
  end

  test "version requirements cannot hide a foreign or dynamic source override" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    for declaration <- [
          "{:arbor_kernel, \"~> 0.1.0\", path: \"../../../arbor_kernel\"}",
          "{:arbor_kernel, \"~> 0.1.0\", path: dependency_path()}",
          "{:arbor_kernel, \"~> 0.1.0\", git: \"https://example.invalid/kernel.git\"}",
          "{:arbor_kernel, \"~> 0.1.0\", github: \"external/kernel\"}",
          "{:arbor_kernel, \"~> 0.1.0\", hex: :external_kernel}",
          "{:arbor_kernel, dependency_version()}"
        ] do
      File.write!(Path.join(fixture.linked, "apps/arbor_shell/mix.exs"), """
      defmodule Shell.MixProject do
        def deps, do: [#{declaration}]
      end
      """)

      assert dep_graph(fixture.linked, %{}) == %{"arbor_kernel" => [], "arbor_shell" => []}
    end
  end

  test "duplicate application/package owners fail closed" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)
    duplicate = Path.join(fixture.linked, "packages/arbor_shell/mix.exs")
    File.mkdir_p!(Path.dirname(duplicate))

    File.write!(duplicate, """
    defmodule DuplicateShell.MixProject do
      def project, do: [app: :arbor_shell, deps: []]
    end
    """)

    git!(fixture.linked, ["add", "packages/arbor_shell/mix.exs"])

    assert_raise ExUnit.AssertionError, ~r/duplicate application owner arbor_shell/, fn ->
      dep_graph(fixture.linked, %{})
    end
  end

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
      CLAUDE.md's "Library Hierarchy" has drifted from the real application/package mix.exs graph.
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
      "apps/arbor_kernel/mix.exs",
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
    assert Map.has_key?(graph, "arbor_kernel")
    assert Map.has_key?(graph, "arbor_shell")
    refute Map.has_key?(graph, "arbor_integrations")
    assert map_size(graph) == 2

    # Graph is acyclic for the fixture apps (shell deps contracts).
    _ = compute_levels(graph)
  end

  # ── Linked-worktree fixture (private tmp; never touches the real umbrella) ──

  test "versioned local package dependencies contribute to hierarchy levels" do
    suffix = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-versioned-package-dep-#{suffix}")
    project = Path.join(root, "packages/arbor_persistence_sql/mix.exs")
    File.mkdir_p!(Path.dirname(project))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(project, """
    defmodule VersionedPackageFixture do
      def deps do
        [{:arbor_persistence, "~> 0.1.0-dev", path: "../arbor_persistence"}]
      end
    end
    """)

    assert in_umbrella_deps(project, root) == ["arbor_persistence"]
  end

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
    File.mkdir_p!(Path.join([root, "apps", "arbor_kernel"]))
    File.mkdir_p!(Path.join([root, "apps", "arbor_shell"]))

    File.write!(Path.join([root, "apps", "arbor_kernel", "mix.exs"]), """
    defmodule Arbor.Kernel.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_kernel, version: "0.0.1", elixir: "~> 1.14", deps: []]
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
          deps: [{:arbor_kernel, in_umbrella: true}]
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
