defmodule Arbor.RepoGuards.CompileOnlyDependencyCallsTest do
  @moduledoc """
  Who may call a first-party dependency declared `runtime: false`.

  The extracted packages (Signals, Capabilities, Trust, Historian, Persistence,
  LLM) are started by a host application, by boot profile, and not by OTP's
  dependency order. So their consumers declare them `runtime: false` and take a
  normal dependency on the host instead. That makes a call into the package
  safe exactly when the caller is the host, or depends on the host at runtime:
  the host is then loaded and started first, and it brings the package up.

  A caller with no runtime path to the host has no such guarantee. In a release
  or peer that does not include the host, the call fails with `undef`. A
  package under `packages/` can never depend on a host, so a package may not
  call a compile-only dependency at all: it declares the dependency normally,
  or goes through a configured port.

  The rule is written down in `docs/arbor/CONTRACT_RULES.md` section 10. The
  check reads compiled import tables, so aliases, `defdelegate` and captured
  functions cannot hide a call. Struct patterns are not calls.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  # Package => the application that starts it in the composed product.
  @hosts %{
    arbor_signals: :arbor_kernel_runtime,
    arbor_capabilities: :arbor_security,
    arbor_capabilities_oidc: :arbor_security,
    arbor_capabilities_signals: :arbor_security,
    arbor_trust: :arbor_trust_host,
    arbor_historian: :arbor_historian_host,
    arbor_persistence: :arbor_persistence_host,
    arbor_persistence_sql: :arbor_persistence_host,
    arbor_persistence_eventstore: :arbor_persistence_host,
    arbor_llm: :arbor_llm_host
  }

  # {caller, compile-only dependency} pairs that call without a runtime path to
  # the host. Each is a debt with an owner, not a precedent. Remove the entry
  # when the calls are gone; the second test fails on a stale entry.
  @known_exceptions %{
    # The adapter binds Capabilities to Signals and is itself started by the
    # Security host. Standalone, its user must start both.
    {:arbor_capabilities_signals, :arbor_capabilities} => "adapter composed by arbor_security",
    {:arbor_capabilities_signals, :arbor_signals} => "adapter composed by arbor_security",
    # Pure functions on contracts that sit in the wrong library; also pinned
    # call by call in the package's own guard.
    {:arbor_llm, :arbor_capabilities} => "Tool.CallFailure and SigningAuthority.Validator",
    {:arbor_llm, :arbor_signals} => "Signals.Taint in the tool loop",
    # Should go through a configured event-store port.
    {:arbor_trust, :arbor_persistence} => "Trust.EventStore and Trust.EventConverter",
    # L2 libraries below Kernel Runtime that emit or subscribe directly.
    {:arbor_cartographer, :arbor_signals} => "ClusterKeeper.durable_emit",
    {:arbor_web, :arbor_signals} => "SignalLive subscribe and unsubscribe"
  }

  test "a compile-only dependency is called only by its host or by an app that depends on the host" do
    projects = projects()
    offenders = offenders(projects)
    unexpected = Map.drop(offenders, Map.keys(@known_exceptions))

    assert unexpected == %{},
           "These call a `runtime: false` dependency with no runtime dependency on the " <>
             "application that starts it. Depend on the host, declare the dependency " <>
             "normally, or go through a configured port " <>
             "(docs/arbor/CONTRACT_RULES.md section 10):\n" <> describe(unexpected)
  end

  test "every recorded exception is still needed" do
    offenders = offenders(projects())
    stale = Map.keys(@known_exceptions) -- Map.keys(offenders)

    assert stale == [],
           "These recorded exceptions no longer call their compile-only dependency. " <>
             "Remove them from @known_exceptions: #{inspect(stale)}"
  end

  test "the guard sees the composed build" do
    projects = projects()
    checked = for {app, %{compile_only: deps}} <- projects, built?(app), _dep <- deps, do: app

    # A build that holds only a few applications would make the first test pass
    # by checking nothing.
    assert length(checked) > 30

    for host <- @hosts |> Map.values() |> Enum.uniq() do
      assert Map.has_key?(projects, host), "host #{host} is not a tracked project"
    end
  end

  defp offenders(projects) do
    for {app, %{compile_only: deps}} <- projects,
        built?(app),
        dep <- deps,
        built?(dep),
        calls = live_calls(app, dep),
        calls != [],
        not started_for?(app, dep, projects),
        into: %{} do
      {{app, dep}, calls}
    end
  end

  defp started_for?(app, dep, projects) do
    case Map.fetch(@hosts, dep) do
      {:ok, host} -> app == host or host in runtime_closure(app, projects)
      :error -> false
    end
  end

  defp runtime_closure(app, projects), do: closure([app], projects, MapSet.new())

  defp closure([], _projects, seen), do: seen

  defp closure([app | rest], projects, seen) do
    next =
      projects
      |> Map.get(app, %{runtime: []})
      |> Map.fetch!(:runtime)
      |> Enum.reject(&MapSet.member?(seen, &1))

    closure(next ++ rest, projects, MapSet.union(seen, MapSet.new(next)))
  end

  defp describe(offenders) do
    offenders
    |> Enum.sort()
    |> Enum.map_join("\n", fn {{app, dep}, calls} ->
      sample = calls |> Enum.sort() |> Enum.take(5) |> Enum.map_join("\n", &("    " <> &1))
      "  #{app} -> #{dep} (#{length(calls)} calls, host #{inspect(@hosts[dep])}):\n#{sample}"
    end)
  end

  # ── compiled calls ───────────────────────────────────────────────────────────

  defp live_calls(app, dep) do
    targets = dep |> beams() |> MapSet.new(&module_name/1)

    for path <- beams(app),
        {module, imports, source} = chunks(path),
        not exempt?(module, source),
        {target, function, arity} <- imports,
        MapSet.member?(targets, target),
        function != :__struct__ do
      "#{inspect(module)} calls #{inspect(target)}.#{function}/#{arity}"
    end
  end

  # Mix tasks run in a project where every dependency is loaded, and test
  # support modules exist only in the test build.
  defp exempt?(module, source) do
    String.starts_with?(Atom.to_string(module), "Elixir.Mix.Tasks.") or
      String.contains?(source, "/test/")
  end

  defp chunks(path) do
    {:ok, {module, [imports: imports, compile_info: info]}} =
      :beam_lib.chunks(String.to_charlist(path), [:imports, :compile_info])

    {module, imports, info |> Keyword.get(:source, ~c"") |> List.to_string()}
  end

  defp module_name(path), do: path |> Path.basename(".beam") |> String.to_atom()
  defp built?(app), do: beams(app) != []

  defp beams(app) do
    Path.wildcard(
      Path.join([Mix.Project.build_path(), "lib", Atom.to_string(app), "ebin", "*.beam"])
    )
  end

  # ── declared dependencies ────────────────────────────────────────────────────

  defp projects do
    root = find_root(__DIR__)
    paths = tracked_mix_files(root)
    known = MapSet.new(paths, &app_name/1)

    Map.new(paths, fn path ->
      deps = path |> declared_deps() |> Enum.filter(fn {name, _opts} -> name in known end)

      {app_name(path),
       %{
         compile_only: for({name, opts} <- deps, opts[:runtime] == false, uniq: true, do: name),
         runtime: for({name, opts} <- deps, runtime_dep?(opts), uniq: true, do: name)
       }}
    end)
  end

  defp runtime_dep?(opts) do
    opts[:runtime] != false and
      case opts[:only] do
        nil -> true
        only -> :prod in List.wrap(only)
      end
  end

  defp app_name(path), do: path |> Path.dirname() |> Path.basename() |> String.to_atom()

  # Parsed as AST, like the hierarchy guard: a dependency named in a comment is
  # not a dependency.
  defp declared_deps(path) do
    {_ast, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:{}, _meta, [name, _requirement, opts]} = node, acc
        when is_atom(name) and is_list(opts) ->
          {node, [{name, literal_opts(opts)} | acc]}

        {name, opts} = node, acc when is_atom(name) and is_list(opts) ->
          {node, [{name, literal_opts(opts)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.filter(found, fn {_name, opts} -> opts[:path] != nil or opts[:in_umbrella] == true end)
  end

  defp literal_opts(opts) do
    if Keyword.keyword?(opts) do
      Keyword.take(opts, [:path, :in_umbrella, :runtime, :only])
    else
      []
    end
  end

  defp tracked_mix_files(root) do
    args = ["-C", root, "ls-files", "-z", "--", "apps/*/mix.exs", "packages/arbor_*/mix.exs"]

    relative =
      case System.cmd("git", args, stderr_to_stdout: true) do
        {out, 0} ->
          String.split(out, <<0>>, trim: true)

        _not_a_checkout ->
          Path.wildcard(Path.join(root, "{apps/*,packages/arbor_*}/mix.exs"))
          |> Enum.map(&Path.relative_to(&1, root))
      end

    relative
    |> Enum.filter(&(length(Path.split(&1)) == 3))
    |> Enum.map(&Path.join(root, &1))
  end

  defp find_root(dir) do
    cond do
      File.regular?(Path.join([dir, "packages", "arbor_kernel", "mix.exs"])) -> dir
      Path.dirname(dir) == dir -> raise "could not locate umbrella root from #{__DIR__}"
      true -> find_root(Path.dirname(dir))
    end
  end
end
