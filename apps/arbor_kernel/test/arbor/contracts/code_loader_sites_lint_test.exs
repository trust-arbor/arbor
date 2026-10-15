defmodule Arbor.Contracts.CodeLoaderSitesLintTest do
  @moduledoc """
  Drift guard: production `apps/*/lib` Code loader call sites are closed.

  Every `Code.eval_string/eval_quoted/eval_file/compile_string/compile_quoted/
  compile_file/require_file` call (plus `apply(Code, ...)` and
  `:rpc.call(..., Code, ...)`) is an in-VM code-execution crossing. A new
  site must be added to `@allowlist` here on purpose — with the same scrutiny
  the existing ones got — rather than landing silently.

  Detection is AST-based (not grep), so a mention inside a `@moduledoc`, a
  comment, or a generated-source heredoc does not count. Scan set is
  git-tracked `apps/*/lib` only (`git ls-files`), matching
  `shell_string_spawn_source_guard_test.exs`.

  Human justification for each remaining site lives in
  `docs/security/code-eval-inventory.md`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast
  @moduletag :security

  @repo_root Path.expand("../../../../..", __DIR__)
  @inventory_doc "docs/security/code-eval-inventory.md"

  @code_loaders MapSet.new([
                  :eval_string,
                  :eval_quoted,
                  :eval_file,
                  :compile_string,
                  :compile_quoted,
                  :compile_file,
                  :require_file
                ])

  # {path-from-repo-root, scanner label}. Must equal reality exactly.
  # Reviewed 2026-10-15 — see docs/security/code-eval-inventory.md.
  @allowlist [
    {"apps/arbor_actions/lib/arbor/actions/code.ex", "Code.compile_string"},
    {"apps/arbor_actions/lib/arbor/actions/security/sweep_candidate.ex", "Code.compile_string"},
    {"apps/arbor_actions/lib/arbor/actions/security/synthesize_detector.ex",
     "Code.compile_string"},
    {"apps/arbor_kernel_runtime/lib/mix/tasks/arbor/eval.ex", ":rpc.call(Code, :eval_string)"}
  ]

  test "production apps/*/lib Code loader sites are exactly the reviewed allowlist" do
    sites = scan(tracked_lib_files())
    found = sites |> Enum.map(&{&1.file, &1.what}) |> Enum.sort()
    expected = Enum.sort(@allowlist)

    new = found -- expected
    stale = expected -- found

    assert new == [],
           "New in-VM Code loader site(s) under apps/*/lib. Review, then add to " <>
             "@allowlist in #{Path.relative_to_cwd(__ENV__.file)} and " <>
             "#{@inventory_doc}:\n" <>
             format_sites(Enum.filter(sites, &({&1.file, &1.what} in new)))

    assert stale == [],
           "Allowlisted site(s) no longer contain that loader call — remove them " <>
             "from @allowlist so the list stays honest: #{inspect(stale)}"
  end

  test "inventory doc names every allowlisted production site" do
    doc_path = Path.join(@repo_root, @inventory_doc)
    assert File.exists?(doc_path), "expected #{@inventory_doc} to exist"

    doc = File.read!(doc_path)

    Enum.each(@allowlist, fn {file, what} ->
      assert doc =~ file,
             "#{@inventory_doc} must name allowlisted file #{file}"

      assert doc =~ what,
             "#{@inventory_doc} must name loader #{what} for #{file}"
    end)
  end

  test "the scanner recognizes direct calls, apply/3, and :rpc.call" do
    snippet = """
    defmodule Snippet do
      def a(src), do: Code.compile_string(src)
      def b, do: &Code.eval_string/1
      def c(src), do: apply(Code, :eval_quoted, [src])
      def d(expr), do: :rpc.call(node(), Code, :eval_string, [expr])
      def e, do: "Code.compile_string(x)"
      def f(src), do: Code.string_to_quoted(src)
    end
    """

    assert snippet |> code_loader_calls() |> Enum.map(&elem(&1, 0)) == [
             "Code.compile_string",
             "Code.eval_string",
             "apply(Code, :eval_quoted)",
             ":rpc.call(Code, :eval_string)"
           ]
  end

  test "contained mode uses the attested inventory without Git metadata" do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-code-loader-guard-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    tracked = "apps/tracked/lib/tracked.ex"
    ignored = "apps/ignored/lib/ignored.ex"
    File.mkdir_p!(Path.dirname(Path.join(root, tracked)))
    File.mkdir_p!(Path.dirname(Path.join(root, ignored)))
    File.write!(Path.join(root, tracked), "defmodule Tracked, do: nil\n")
    File.write!(Path.join(root, ignored), "defmodule Ignored, do: nil\n")

    assert {:ok, inventory} =
             SourceInventory.build(String.duplicate("d", 40), [
               tracked,
               "apps/tracked/test/tracked_test.exs"
             ])

    assert {:ok, bytes} = SourceInventory.encode(inventory)
    manifest_path = Path.join(root, "source_inventory.json")
    File.write!(manifest_path, bytes)

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => manifest_path
    }

    assert tracked_lib_files(root, env) == [tracked]

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      tracked_lib_files(root, %{"ARBOR_MIX_CONTAINED" => "1"})
    end
  end

  defp tracked_lib_files, do: tracked_lib_files(@repo_root, inventory_env_from_system())

  defp tracked_lib_files(root, env) when is_binary(root) and is_map(env) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" ->
        contained_tracked_lib_files(env)

      _ ->
        {output, 0} =
          System.cmd("git", ["ls-files", "-z", "--", "apps"],
            cd: root,
            stderr_to_stdout: true
          )

        output
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&production_lib_source?/1)
        |> Enum.sort()
    end
  end

  defp inventory_env_from_system do
    %{}
    |> put_env_if_present("ARBOR_MIX_CONTAINED")
    |> put_env_if_present("ARBOR_SOURCE_INVENTORY_PATH")
  end

  defp put_env_if_present(env, key) do
    case System.get_env(key) do
      nil -> env
      value -> Map.put(env, key, value)
    end
  end

  defp contained_tracked_lib_files(env) do
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
          |> Enum.filter(&production_lib_source?/1)
          |> Enum.sort()
        else
          {:error, :enoent} -> flunk_missing_inventory({:enoent, path})
          {:error, :oversized_manifest} -> flunk_missing_inventory({:oversized_manifest, path})
          {:error, reason} -> flunk_missing_inventory({reason, path})
          other -> flunk_missing_inventory({other, path})
        end
    end
  end

  defp admit_manifest_byte_size(size, max_bytes)
       when is_integer(size) and is_integer(max_bytes) and size >= 0 and max_bytes > 0 do
    if size <= max_bytes, do: :ok, else: {:error, :oversized_manifest}
  end

  defp resolve_source_inventory_path(env) do
    case Map.fetch(env, "ARBOR_SOURCE_INVENTORY_PATH") do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _value} -> {:error, :invalid_inventory_path}
      :error -> {:error, :missing_inventory_path}
    end
  end

  defp flunk_missing_inventory(detail) do
    flunk(
      "contained Mix requires a valid ARBOR_SOURCE_INVENTORY_PATH regular-file manifest; " <>
        "refusing a filesystem fallback that would weaken the tracked-only invariant" <>
        " (detail: #{inspect(detail)})"
    )
  end

  defp production_lib_source?(path) do
    String.ends_with?(path, ".ex") and
      match?([_, _, "lib" | _], Path.split(path)) and
      String.starts_with?(path, "apps/")
  end

  defp scan(paths) do
    Enum.flat_map(paths, fn path ->
      abs = Path.join(@repo_root, path)

      abs
      |> File.read!()
      |> code_loader_calls()
      |> Enum.map(fn {what, line} ->
        %{file: path, what: what, line: line}
      end)
    end)
  end

  defp code_loader_calls(source) when is_binary(source) do
    {:ok, ast} = Code.string_to_quoted(source, emit_warnings: false)
    code_loader_calls(ast)
  end

  defp code_loader_calls(ast) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        case site(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    Enum.reverse(hits)
  end

  defp site({{:., _, [{:__aliases__, _, [:Code]}, fun]}, meta, _args})
       when is_atom(fun) do
    if MapSet.member?(@code_loaders, fun), do: {"Code.#{fun}", meta[:line]}
  end

  defp site({:apply, meta, [{:__aliases__, _, [:Code]}, fun, _args]})
       when is_atom(fun) do
    if MapSet.member?(@code_loaders, fun), do: {"apply(Code, :#{fun})", meta[:line]}
  end

  defp site(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :apply]}, meta,
          [{:__aliases__, _, [:Code]}, fun, _args]}
       )
       when is_atom(fun) do
    if MapSet.member?(@code_loaders, fun), do: {"apply(Code, :#{fun})", meta[:line]}
  end

  defp site({{:., _, [:rpc, :call]}, meta, [_node, {:__aliases__, _, [:Code]}, fun | _]})
       when is_atom(fun) do
    if MapSet.member?(@code_loaders, fun), do: {":rpc.call(Code, :#{fun})", meta[:line]}
  end

  defp site(_node), do: nil

  defp format_sites(sites) do
    Enum.map_join(sites, "\n", fn %{file: f, what: w, line: l} -> "  #{f}:#{l} #{w}" end)
  end
end
