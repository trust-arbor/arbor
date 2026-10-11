defmodule Arbor.Actions.Security.CodeCompileSitesLintTest do
  @moduledoc """
  Drift guard: the set of modules under `apps/arbor_actions/lib` that turn text
  or AST into running code is closed.

  Every `Code.compile_string/eval_string/...` site is an in-VM code-execution
  crossing (the 2026-08-16 in-VM crossings class; F-008 in the 2026-10-11
  cross-library review was `SweepCandidate` compiling caller-supplied
  `module_source` verbatim). A new site must be added to `@allowlist` here on
  purpose — with the same scrutiny the existing ones got — rather than landing
  silently. Mirrors the hierarchy drift guard in
  `apps/arbor_kernel/test/arbor/contracts/dependency_hierarchy_test.exs`: the
  allowlist must equal reality exactly, so a stale entry fails too.

  Detection is AST-based (not grep), so a mention inside a `@moduledoc`, a
  comment, or a generated-source heredoc (e.g. `DetectorTestTemplate` emits test
  files that call `Code.compile_string` at THEIR runtime) does not count — only
  an actual call, capture, or `apply(Code, ...)` in the module's own code does.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security

  # Paths relative to apps/arbor_actions/lib. Each is reviewed:
  #   * code.ex — the `Arbor.Actions.Code` action (compiles agent code on purpose,
  #     behind its own capability gate)
  #   * security/synthesize_detector.ex — compiles the DetectorTemplate output it
  #     just generated from a validated spec (G1 self-check)
  #   * security/sweep_candidate.ex — compiles the DetectorTemplate output it
  #     REGENERATES from the candidate's validated spec (F-008: never the
  #     caller's module_source)
  @allowlist [
    "arbor/actions/code.ex",
    "arbor/actions/security/synthesize_detector.ex",
    "arbor/actions/security/sweep_candidate.ex"
  ]

  # The Code functions that load code into the VM from text, AST, or a file.
  # (`Code.string_to_quoted/2` only PARSES and is deliberately not listed.)
  @code_loaders [
    :compile_string,
    :eval_string,
    :compile_quoted,
    :eval_quoted,
    :compile_file,
    :eval_file,
    :require_file
  ]

  test "code-loading call sites under lib/ are exactly the reviewed allowlist" do
    sites = scan(lib_root())
    found = sites |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort()

    new = found -- @allowlist
    stale = @allowlist -- found

    assert new == [],
           "New code-loading site(s) under apps/arbor_actions/lib — an in-VM " <>
             "code-execution crossing. Review, then add to @allowlist in " <>
             "#{Path.relative_to_cwd(__ENV__.file)} on purpose:\n" <>
             format_sites(Enum.filter(sites, &(&1.file in new)))

    assert stale == [],
           "Allowlisted file(s) no longer contain a code-loading call — remove them " <>
             "from @allowlist so the list stays honest: #{inspect(stale)}"
  end

  test "the scanner recognizes direct calls, captures, apply/3, and Module.create" do
    snippet = """
    defmodule Snippet do
      def a(src), do: Code.compile_string(src)
      def b, do: &Code.eval_string/1
      def c(src), do: apply(Code, :eval_quoted, [src])
      def d(q), do: Module.create(Foo, q, Macro.Env.location(__ENV__))
      # Code.compile_string in a comment and in a string are not calls:
      def e, do: "Code.compile_string(x)"
      def f(src), do: Code.string_to_quoted(src)
    end
    """

    assert snippet |> code_loading_calls() |> Enum.map(&elem(&1, 0)) == [
             "Code.compile_string",
             "Code.eval_string",
             "apply(Code, :eval_quoted)",
             "Module.create"
           ]
  end

  # ---------------------------------------------------------------------------
  # Scanner
  # ---------------------------------------------------------------------------

  defp lib_root do
    app_root = find_app_root(__DIR__)
    Path.join(app_root, "lib")
  end

  # Walk up from this test file to the arbor_actions app root (its mix.exs).
  defp find_app_root(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) and
          File.exists?(Path.join([dir, "lib", "arbor_actions.ex"])) ->
        dir

      Path.dirname(dir) == dir ->
        raise "could not locate the arbor_actions app root from #{__DIR__}"

      true ->
        find_app_root(Path.dirname(dir))
    end
  end

  defp scan(lib_root) do
    lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> code_loading_calls()
      |> Enum.map(fn {what, line} ->
        %{file: Path.relative_to(path, lib_root), what: what, line: line}
      end)
    end)
  end

  defp code_loading_calls(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        case site(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    Enum.reverse(hits)
  end

  # `Code.fun(...)` and the capture `&Code.fun/n` (both carry the remote-call node).
  defp site({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args})
       when fun in @code_loaders,
       do: {"Code.#{fun}", meta[:line]}

  # `Module.create/3` loads a module from AST.
  defp site({{:., _, [{:__aliases__, _, [:Module]}, :create]}, meta, _args}),
    do: {"Module.create", meta[:line]}

  # `apply(Code, :fun, args)` — the dynamic form that hides from static analysis.
  defp site({:apply, meta, [{:__aliases__, _, [:Code]}, fun, _args]})
       when fun in @code_loaders,
       do: {"apply(Code, :#{fun})", meta[:line]}

  defp site(_node), do: nil

  defp format_sites(sites) do
    Enum.map_join(sites, "\n", fn %{file: f, what: w, line: l} -> "  #{f}:#{l} #{w}" end)
  end
end
