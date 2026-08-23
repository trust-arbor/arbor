defmodule Arbor.Contracts.ShellStringSpawnSourceGuardTest do
  @moduledoc """
  Structural AST source guard: production `apps/*/lib` must not contain
  `Port.open({:spawn, ...})` shell-string spawns or `System.cmd("sh"|"bash", ["-c", ...])`.

  Scan set is git-tracked files only (`git ls-files`). Detection is AST-only so
  this module's fixture text cannot match the production scan.
  """

  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast

  @repo_root Path.expand("../../../../..", __DIR__)

  test "production apps/*/lib has no Port spawn-string or System.cmd sh/bash -c sites" do
    paths = tracked_lib_files()
    assert paths != [], "expected git-tracked apps/*/lib files"

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

    assert hits == [], "forbidden shell-string spawn forms found: #{inspect(hits)}"
  end

  test "red fixtures: Port.open spawn-string" do
    source = """
    defmodule RedPortSpawn do
      def go(cmd), do: Port.open({:spawn, cmd}, [:binary])
    end
    """

    hits = detect_forbidden(Code.string_to_quoted!(source))
    assert {:port_spawn_string, :spawn} in hits
  end

  test "red fixtures: System.cmd sh -c and bash -c" do
    source_sh = """
    defmodule RedSh do
      def go(cmd), do: System.cmd("sh", ["-c", cmd])
    end
    """

    source_bash = """
    defmodule RedBash do
      def go(cmd), do: System.cmd("bash", ["-c", cmd], cd: "/")
    end
    """

    assert {:system_cmd_shell_c, "sh"} in detect_forbidden(Code.string_to_quoted!(source_sh))
    assert {:system_cmd_shell_c, "bash"} in detect_forbidden(Code.string_to_quoted!(source_bash))
  end

  test "green fixtures: spawn_executable and non-shell -c are admitted" do
    source = """
    defmodule Green do
      def port(exe, args) do
        Port.open({:spawn_executable, exe}, [:binary, args: args])
      end

      def git, do: System.cmd("git", ["-c", "core.hooksPath=/dev/null", "status"])
      def docker, do: System.cmd("docker", ["exec", "c", "/bin/bash.real", "-c", "true"])
    end
    """

    assert detect_forbidden(Code.string_to_quoted!(source)) == []
  end

  test "contained mode uses the attested inventory without Git metadata" do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-shell-source-guard-#{System.unique_integer([:positive])}"
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

  # ---------------------------------------------------------------------------
  # Scan set: git-tracked production lib files only
  # ---------------------------------------------------------------------------

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
    (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")) and
      match?([_, _, "lib" | _], Path.split(path)) and
      String.starts_with?(path, "apps/")
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

  defp hits_for_node({{:., _, [{:__aliases__, _, [:Port]}, :open]}, _, [first_arg | _rest]}) do
    port_spawn_hits(first_arg)
  end

  defp hits_for_node({{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, args}) do
    system_cmd_hits(args)
  end

  defp hits_for_node(_node), do: MapSet.new()

  defp port_spawn_hits({:{}, _, [:spawn | _]}), do: MapSet.new([{:port_spawn_string, :spawn}])
  defp port_spawn_hits({:spawn, _, _}), do: MapSet.new([{:port_spawn_string, :spawn}])

  # 2-tuple form written as {:spawn, cmd}
  defp port_spawn_hits({a, b}) when is_atom(a) and a == :spawn and not is_list(b) do
    MapSet.new([{:port_spawn_string, :spawn}])
  end

  defp port_spawn_hits(_), do: MapSet.new()

  defp system_cmd_hits([exe, args | _opts]) do
    exe_name = literal_string(exe)

    if exe_name in ["sh", "bash"] and list_contains_c_flag?(args) do
      MapSet.new([{:system_cmd_shell_c, exe_name}])
    else
      MapSet.new()
    end
  end

  defp system_cmd_hits(_), do: MapSet.new()

  defp literal_string(value) when is_binary(value), do: value
  defp literal_string(_), do: nil

  defp list_contains_c_flag?(list) when is_list(list) do
    Enum.any?(list, fn
      "-c" -> true
      _ -> false
    end)
  end

  defp list_contains_c_flag?(_), do: false
end
