defmodule Arbor.MixProjectPathsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast

  @root Path.expand("../../..", __DIR__)
  @helper Path.join(@root, "build_support/mix_project_paths.exs")

  Code.require_file(@helper)

  @fallbacks [build_path: "../../_build", deps_path: "../../deps"]

  describe "project_paths/2" do
    test "preserves the existing relative fallbacks outside contained mode" do
      assert Arbor.MixProjectPaths.project_paths(@fallbacks, %{
               "ARBOR_MIX_CONTAINED" => "0",
               "MIX_BUILD_PATH" => "/ignored/build",
               "MIX_DEPS_PATH" => "/ignored/deps"
             }) == @fallbacks
    end

    test "uses canonical absolute paths in contained mode" do
      env = %{
        "ARBOR_MIX_CONTAINED" => "1",
        "MIX_BUILD_PATH" => "/arbor/build",
        "MIX_DEPS_PATH" => "/arbor/deps"
      }

      assert Arbor.MixProjectPaths.project_paths(@fallbacks, env) == [
               build_path: "/arbor/build",
               deps_path: "/arbor/deps"
             ]
    end

    test "fails closed for missing, empty, relative, and noncanonical paths" do
      invalid_envs = [
        %{"ARBOR_MIX_CONTAINED" => "1", "MIX_DEPS_PATH" => "/arbor/deps"},
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "build",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "/arbor/build/../build",
          "MIX_DEPS_PATH" => "/arbor/deps"
        },
        %{
          "ARBOR_MIX_CONTAINED" => "1",
          "MIX_BUILD_PATH" => "/arbor/build",
          "MIX_DEPS_PATH" => "/arbor/deps/"
        }
      ]

      Enum.each(invalid_envs, fn env ->
        assert_raise ArgumentError, ~r/contained Mix requires/, fn ->
          Arbor.MixProjectPaths.project_paths(@fallbacks, env)
        end
      end)
    end
  end

  test "every git-tracked project file uses the shared path helper" do
    # Zero-arity: production dual-path reads closed System env (contained
    # validation consumes ARBOR_* without mutating env in this test process).
    paths = tracked_mix_files()

    assert paths != []

    Enum.each(paths, fn path ->
      source = File.read!(path)
      ast = Code.string_to_quoted!(source)

      assert source =~ "Code.require_file"
      assert source =~ "build_support/mix_project_paths.exs"

      assert Enum.any?(project_path_calls(ast), fn args ->
               Keyword.has_key?(args, :build_path) and Keyword.has_key?(args, :deps_path)
             end),
             "#{Path.relative_to(path, @root)} does not configure both Mix paths through the shared helper"

      assert source =~ ~r/build_path:\s*paths\[:build_path\]/
      assert source =~ ~r/deps_path:\s*paths\[:deps_path\]/
    end)
  end

  test "contained mode: missing or invalid inventory fails closed without wildcard" do
    fixture = linked_worktree_fixture()

    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    # Missing path key — fail before filesystem; no fixed guest-path substitute.
    error =
      assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
        tracked_mix_files(fixture.linked, %{"ARBOR_MIX_CONTAINED" => "1"})
      end

    assert error.message =~ "missing_inventory_path"
    assert error.message =~ "before_filesystem"

    # Empty path — fail before filesystem.
    error =
      assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
        tracked_mix_files(fixture.linked, %{
          "ARBOR_MIX_CONTAINED" => "1",
          "ARBOR_SOURCE_INVENTORY_PATH" => ""
        })
      end

    assert error.message =~ "invalid_inventory_path"
    assert error.message =~ "before_filesystem"

    # Missing file
    missing = Path.join(fixture.scratch, "missing-inventory.json")

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      tracked_mix_files(fixture.linked, %{
        "ARBOR_MIX_CONTAINED" => "1",
        "ARBOR_SOURCE_INVENTORY_PATH" => missing
      })
    end

    # Invalid JSON / non-admitted bytes
    bad = Path.join(fixture.scratch, "bad-inventory.json")
    File.write!(bad, "{not-valid-inventory\n")

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      tracked_mix_files(fixture.linked, %{
        "ARBOR_MIX_CONTAINED" => "1",
        "ARBOR_SOURCE_INVENTORY_PATH" => bad
      })
    end

    # Directory shape (unsafe)
    dir_path = Path.join(fixture.scratch, "dir-inventory")
    File.mkdir_p!(dir_path)

    assert_raise ExUnit.AssertionError, ~r/ARBOR_SOURCE_INVENTORY_PATH/, fn ->
      tracked_mix_files(fixture.linked, %{
        "ARBOR_MIX_CONTAINED" => "1",
        "ARBOR_SOURCE_INVENTORY_PATH" => dir_path
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
        tracked_mix_files(fixture.linked, %{
          "ARBOR_MIX_CONTAINED" => "1",
          "ARBOR_SOURCE_INVENTORY_PATH" => oversized
        })
      end

    assert error.message =~ "oversized_manifest"
  end

  test "contained mode: linked worktree with inaccessible Git metadata uses attested inventory" do
    fixture = linked_worktree_fixture()
    on_exit(fn -> cleanup_linked_worktree_fixture(fixture) end)

    # Private gitignored app lives only in the fixture worktree (never the real umbrella).
    private_rel = "apps/arbor_integrations/mix.exs"
    private_abs = Path.join(fixture.linked, private_rel)
    File.mkdir_p!(Path.dirname(private_abs))
    File.write!(private_abs, "defmodule Arbor.Integrations.MixProject do\nend\n")
    assert File.exists?(private_abs)

    inventory_paths = [
      "apps/arbor_kernel/mix.exs",
      "mix.exs"
    ]

    assert {:ok, inventory} =
             SourceInventory.build(String.duplicate("c", 40), inventory_paths)

    assert {:ok, bytes} = SourceInventory.encode(inventory)
    manifest_path = Path.join(fixture.scratch, "source_inventory.json")
    File.write!(manifest_path, bytes)

    # Seal host Git metadata for the linked worktree (common dir under main .git).
    # PATH=/nonexistent alone only proves no git binary; this proves metadata isolation.
    seal_git_metadata!(fixture.main)

    # Git must fail against the linked worktree once metadata is inaccessible.
    {_out, git_code} =
      System.cmd("git", ["-C", fixture.linked, "ls-files"], stderr_to_stdout: true)

    assert git_code != 0

    env = %{
      "ARBOR_MIX_CONTAINED" => "1",
      "ARBOR_SOURCE_INVENTORY_PATH" => manifest_path
    }

    # Explicit env map — no process-global System.put_env (safe under async: true).
    paths = tracked_mix_files(fixture.linked, env)
    relative = Enum.map(paths, &Path.relative_to(&1, fixture.linked))

    assert "mix.exs" in relative
    assert "apps/arbor_kernel/mix.exs" in relative
    refute "apps/arbor_integrations/mix.exs" in relative
  end

  # Use git-TRACKED mix.exs files outside contained mode so the computed set
  # reflects the COMMITTED umbrella. Contained mode reads the owner-attested
  # source-inventory manifest instead — never Path.wildcard (which would admit
  # gitignored private apps such as apps/arbor_integrations/).
  #
  # Zero-arity reads process env (production contained Mix). Explicit `env`
  # maps are for hermetic fixture proofs only — never System.put_env.
  defp tracked_mix_files do
    tracked_mix_files(@root, inventory_env_from_system())
  end

  defp tracked_mix_files(root, env) when is_binary(root) and is_map(env) do
    case Map.get(env, "ARBOR_MIX_CONTAINED") do
      "1" ->
        contained_tracked_mix_files(root, env)

      _ ->
        {output, 0} =
          System.cmd("git", ["-C", root, "ls-files", "--", "mix.exs", "apps/*/mix.exs"],
            stderr_to_stdout: true
          )

        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&mix_project_path?/1)
        |> Enum.map(&Path.join(root, &1))
    end
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
          |> Enum.filter(&mix_project_path?/1)
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

  defp mix_project_path?("mix.exs"), do: true

  defp mix_project_path?(path) when is_binary(path) do
    case Path.split(path) do
      ["apps", app, "mix.exs"] when is_binary(app) and app != "" and app != "." and app != ".." ->
        true

      _ ->
        false
    end
  end

  defp project_path_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Arbor, :MixProjectPaths]}, :project_paths]}, _, [args]} =
            node,
        calls
        when is_list(args) ->
          if Keyword.keyword?(args), do: {node, [args | calls]}, else: {node, calls}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  # ── Linked-worktree fixture (private tmp; never touches the real umbrella) ──

  defp linked_worktree_fixture do
    scratch =
      Path.join(System.tmp_dir!(), "arbor-mpp-lt-#{System.unique_integer([:positive])}")

    main = Path.join(scratch, "main")
    linked = Path.join(scratch, "linked")
    File.mkdir_p!(main)

    git!(main, ["init"])
    git!(main, ["config", "user.email", "test@example.com"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["checkout", "-b", "main"])

    File.write!(Path.join(main, ".gitignore"), "apps/arbor_integrations/\n")
    write_tiny_mix_project(main)
    git!(main, ["add", "-A"])
    git!(main, ["commit", "-m", "init"])
    git!(main, ["branch", "feature"])
    git!(main, ["worktree", "add", linked, "feature"])

    %{scratch: scratch, main: main, linked: linked, git_sealed?: false}
  end

  defp write_tiny_mix_project(root) do
    File.mkdir_p!(Path.join([root, "apps", "arbor_kernel"]))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule TinyRoot.MixProject do
      use Mix.Project
      def project, do: [app: :tiny_root, version: "0.0.1", elixir: "~> 1.14"]
    end
    """)

    File.write!(Path.join([root, "apps", "arbor_kernel", "mix.exs"]), """
    defmodule Arbor.Kernel.MixProject do
      use Mix.Project
      def project, do: [app: :arbor_kernel, version: "0.0.1", elixir: "~> 1.14", deps: []]
    end
    """)
  end

  defp seal_git_metadata!(main_repo) when is_binary(main_repo) do
    git_dir = Path.join(main_repo, ".git")
    # Make the entire common Git directory unreadable/unexecutable so linked
    # worktree metadata resolution fails closed.
    :ok = File.chmod(git_dir, 0o000)
  end

  defp cleanup_linked_worktree_fixture(%{main: main, scratch: scratch}) do
    git_dir = Path.join(main, ".git")
    # Restore permissions so rm_rf can remove the sealed tree.
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
