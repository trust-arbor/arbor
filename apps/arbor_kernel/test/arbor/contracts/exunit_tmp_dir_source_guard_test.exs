defmodule Arbor.Contracts.ExUnitTmpDirSourceGuardTest do
  @moduledoc """
  Structural AST source guard: tracked `apps/*/test` must not use ExUnit's
  literal `:tmp_dir` tag (`@tag`, `@moduletag`, or `@describetag`).

  That tag creates repository-local application tmp directories, which fail
  under a read-only contained candidate mount. Tests must allocate exclusive
  scratch roots under `System.tmp_dir!()` instead.

  Scan set is git-tracked files only (`git ls-files`). Detection is AST-only so
  this module's fixture text cannot match the production scan.
  """

  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast

  @repo_root Path.expand("../../../../..", __DIR__)
  @tag_attrs [:tag, :moduletag, :describetag]

  test "tracked apps/*/test has no literal ExUnit tmp_dir tags" do
    paths = tracked_test_files()
    assert paths != [], "expected git-tracked apps/*/test files"

    hits =
      paths
      |> Enum.flat_map(fn path ->
        abs = Path.join(@repo_root, path)

        forms =
          abs
          |> File.read!()
          |> Code.string_to_quoted!()
          |> detect_forbidden()

        for form <- forms, do: {path, form}
      end)

    assert hits == [], "forbidden ExUnit tmp_dir tags found: #{inspect(hits)}"
  end

  test "red fixtures: @tag :tmp_dir" do
    source = """
    defmodule RedTag do
      use ExUnit.Case
      @tag :tmp_dir
      test "writes", %{tmp_dir: tmp_dir} do
        File.write!(Path.join(tmp_dir, "x"), "y")
      end
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:exunit_tmp_dir_tag, :tag} in hits
  end

  test "red fixtures: @moduletag :tmp_dir and @describetag :tmp_dir" do
    source_module = """
    defmodule RedModuleTag do
      use ExUnit.Case
      @moduletag :tmp_dir
      test "uses module tmp", %{tmp_dir: tmp_dir}, do: tmp_dir
    end
    """

    source_describe = """
    defmodule RedDescribeTag do
      use ExUnit.Case

      describe "files" do
        @describetag :tmp_dir
        test "uses describe tmp", %{tmp_dir: tmp_dir}, do: tmp_dir
      end
    end
    """

    assert {:exunit_tmp_dir_tag, :moduletag} in detect_forbidden(
             Code.string_to_quoted!(source_module)
           )

    assert {:exunit_tmp_dir_tag, :describetag} in detect_forbidden(
             Code.string_to_quoted!(source_describe)
           )
  end

  test "red fixtures: keyword and list tmp_dir tag forms" do
    source_keyword = """
    defmodule RedKeywordTag do
      use ExUnit.Case
      @tag tmp_dir: true
      test "keyword", %{tmp_dir: tmp_dir}, do: tmp_dir
    end
    """

    source_suffix = """
    defmodule RedSuffixTag do
      use ExUnit.Case
      @tag tmp_dir: "custom"
      test "suffix", %{tmp_dir: tmp_dir}, do: tmp_dir
    end
    """

    source_list = """
    defmodule RedListTag do
      use ExUnit.Case
      @tag [:fast, :tmp_dir]
      test "list", %{tmp_dir: tmp_dir}, do: tmp_dir
    end
    """

    source_mixed = """
    defmodule RedMixedTag do
      use ExUnit.Case
      @tag :fast, tmp_dir: true
      test "mixed", %{tmp_dir: tmp_dir}, do: tmp_dir
    end
    """

    assert {:exunit_tmp_dir_tag, :tag} in detect_forbidden(Code.string_to_quoted!(source_keyword))
    assert {:exunit_tmp_dir_tag, :tag} in detect_forbidden(Code.string_to_quoted!(source_suffix))
    assert {:exunit_tmp_dir_tag, :tag} in detect_forbidden(Code.string_to_quoted!(source_list))
    assert {:exunit_tmp_dir_tag, :tag} in detect_forbidden(Code.string_to_quoted!(source_mixed))
  end

  test "green fixtures: unrelated tags, setup callbacks, and fixture text are admitted" do
    source = """
    defmodule Green do
      use ExUnit.Case
      @moduledoc "Do not write @tag :tmp_dir, @moduletag :tmp_dir, or @describetag :tmp_dir."
      @moduletag :fast
      @describetag :slow
      @tag :fast
      @tag skip: true

      setup :tmp_dir_fixture

      test "uses an explicit OS temp root", %{tmp_dir: tmp_dir} do
        assert tmp_dir
      end

      defp tmp_dir_fixture(_) do
        tmp_dir = Path.join(System.tmp_dir!(), "green")
        {:ok, tmp_dir: tmp_dir}
      end
    end
    """

    assert detect_forbidden(Code.string_to_quoted!(source)) == []
  end

  test "contained mode uses the attested inventory without Git metadata" do
    token = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(System.tmp_dir!(), "arbor-exunit-tmp-dir-guard-" <> token)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    tracked = "apps/tracked/test/tracked_test.exs"
    ignored = "apps/ignored/test/ignored_test.exs"
    File.mkdir_p!(Path.dirname(Path.join(root, tracked)))
    File.mkdir_p!(Path.dirname(Path.join(root, ignored)))
    File.write!(Path.join(root, tracked), "defmodule Tracked, do: nil\n")
    File.write!(Path.join(root, ignored), "defmodule Ignored, do: nil\n")

    assert {:ok, inventory} =
             SourceInventory.build(String.duplicate("d", 40), [
               tracked,
               "apps/tracked/lib/tracked.ex"
             ])

    assert {:ok, bytes} = SourceInventory.encode(inventory)
    manifest_path = Path.join(root, "source_inventory.json")
    File.write!(manifest_path, bytes)

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => manifest_path
    }

    assert tracked_test_files(root, env) == [tracked]

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      tracked_test_files(root, %{"ARBOR_MIX_CONTAINED" => "1"})
    end
  end

  # ---------------------------------------------------------------------------
  # Scan set: git-tracked app test files only
  # ---------------------------------------------------------------------------

  defp tracked_test_files, do: tracked_test_files(@repo_root, inventory_env_from_system())

  defp tracked_test_files(root, env) when is_binary(root) and is_map(env) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" ->
        contained_tracked_test_files(env)

      _ ->
        {output, 0} =
          System.cmd("git", ["ls-files", "-z", "--", "apps"],
            cd: root,
            stderr_to_stdout: true
          )

        output
        |> String.split(<<0>>, trim: true)
        |> Enum.filter(&app_test_source?/1)
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

  defp contained_tracked_test_files(env) do
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
          |> Enum.filter(&app_test_source?/1)
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

  defp app_test_source?(path) when is_binary(path) do
    if String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs") do
      case Path.split(path) do
        ["apps", app, "test" | _]
        when is_binary(app) and app != "" and app != "." and app != ".." ->
          true

        _ ->
          false
      end
    else
      false
    end
  end

  # ---------------------------------------------------------------------------
  # Detector (AST only)
  # ---------------------------------------------------------------------------

  defp detect_forbidden(ast) do
    {_ast, hits} =
      Macro.prewalk(ast, MapSet.new(), fn node, hits ->
        {node, MapSet.union(hits, hits_for_node(node))}
      end)

    hits |> MapSet.to_list() |> Enum.sort()
  end

  defp hits_for_node({:@, _, [{attr, _, args}]}) do
    if attr in @tag_attrs and tmp_dir_tag?(args) do
      MapSet.new([{:exunit_tmp_dir_tag, attr}])
    else
      MapSet.new()
    end
  end

  defp hits_for_node(_node), do: MapSet.new()

  defp tmp_dir_tag?(args) when is_list(args), do: Enum.any?(args, &tmp_dir_tag_value?/1)
  defp tmp_dir_tag?(_), do: false

  defp tmp_dir_tag_value?(:tmp_dir), do: true
  defp tmp_dir_tag_value?({:tmp_dir, _value}), do: true
  defp tmp_dir_tag_value?(list) when is_list(list), do: Enum.any?(list, &tmp_dir_tag_value?/1)
  defp tmp_dir_tag_value?(_), do: false
end
