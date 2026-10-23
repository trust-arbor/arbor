defmodule Arbor.Contracts.UnpinnedNpxExampleSourceGuardTest do
  @moduledoc """
  Docs hygiene guard for MCPhantom-class copy/paste: production `apps/*/lib`
  must not document unpinned `npx -y` installs or the archived
  `@modelcontextprotocol/server-github` package.

  Glow's 2026-10 write-up (MCPhantom) showed coding agents installing deprecated
  MCP servers remembered from training data. Arbor's operator-facing moduledocs
  were citing that archived GitHub server with `npx -y` and no version pin
  (exposure-check group W). An operator who copies the example would approve
  an unmaintained package.

  Scan set is git-tracked `apps/*/lib` only (`git ls-files`). Detection is
  textual so `@moduledoc` examples count — that is the surface operators copy.
  This module's fixture strings are not part of that scan.
  """

  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.SourceInventory

  @moduletag :fast

  @repo_root Path.expand("../../../../..", __DIR__)

  # Deprecated npm package; development moved to github/github-mcp-server.
  # Split so this file's own source cannot match the production scan.
  @archived_github_pkg "@modelcontextprotocol/" <> "server-github"

  test "production apps/*/lib has no unpinned npx -y examples" do
    paths = tracked_lib_files()
    assert paths != [], "expected git-tracked apps/*/lib files"

    hits =
      paths
      |> Enum.flat_map(fn path ->
        abs = Path.join(@repo_root, path)

        for {kind, spec} <- detect_unpinned_npx_y(File.read!(abs)) do
          {path, kind, spec}
        end
      end)

    assert hits == [],
           "unpinned `npx -y` examples found (pin an exact x.y.z, or use a " <>
             "versioned image such as ghcr.io/github/github-mcp-server:v2.0.3): " <>
             inspect(hits)
  end

  test "production apps/*/lib does not cite archived server-github" do
    paths = tracked_lib_files()
    assert paths != [], "expected git-tracked apps/*/lib files"

    hits =
      paths
      |> Enum.flat_map(fn path ->
        abs = Path.join(@repo_root, path)
        source = File.read!(abs)

        if String.contains?(source, @archived_github_pkg) do
          [{path, @archived_github_pkg}]
        else
          []
        end
      end)

    assert hits == [],
           "archived #{@archived_github_pkg} citations found; use GitHub's " <>
             "maintained github-mcp-server pinned to an exact version: " <>
             inspect(hits)
  end

  test "red fixtures: unpinned npx -y list and CLI forms" do
    list_source = ~s|command: ["npx", "-y", "#{@archived_github_pkg}"]|
    yes_source = ~s|command: ["npx", "--yes", "some-mcp-server"]|
    cli_source = "npx -y @scope/pkg /workspace"

    assert {:unpinned_npx_y_list, @archived_github_pkg} in detect_unpinned_npx_y(list_source)
    assert {:unpinned_npx_y_list, "some-mcp-server"} in detect_unpinned_npx_y(yes_source)
    assert {:unpinned_npx_y_cli, "@scope/pkg"} in detect_unpinned_npx_y(cli_source)
  end

  test "green fixtures: exact-version npx -y and docker image pins are admitted" do
    source = """
    command: ["npx", "-y", "@modelcontextprotocol/server-filesystem@1.0.0", "/workspace"]
    command: ["npx", "--yes", "promptfoo@1.2.3"]
    npx -y @scope/pkg@2.0.3 --help
    command: ["docker", "run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN",
              "ghcr.io/github/github-mcp-server:v2.0.3"]
    """

    assert detect_unpinned_npx_y(source) == []
  end

  test "green fixtures: npx without -y is outside this guard" do
    # manager.ex historically used unpinned npx *without* -y; the archived-package
    # test covers that citation. This guard is specifically `npx -y` / `npx --yes`.
    source = ~s|command: ["npx", "github-server"]|
    assert detect_unpinned_npx_y(source) == []
  end

  test "contained mode uses the attested inventory without Git metadata" do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-npx-example-guard-#{System.unique_integer([:positive])}"
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
  # Detector (textual — moduledoc examples are the point)
  # ---------------------------------------------------------------------------

  @list_npx_y ~r/"npx",\s*"(?:-y|--yes)",\s*"([^"]+)"/
  @cli_npx_y ~r/(?<![[:alnum:]\-_])npx\s+(?:-y|--yes)\s+(\S+)/

  defp detect_unpinned_npx_y(source) when is_binary(source) do
    list_hits =
      for [_, spec] <- Regex.scan(@list_npx_y, source),
          not exact_npm_version?(spec),
          do: {:unpinned_npx_y_list, spec}

    cli_hits =
      for [whole, spec] <- Regex.scan(@cli_npx_y, source),
          not list_form_match?(whole),
          spec = unwrap_cli_token(spec),
          is_binary(spec),
          not exact_npm_version?(spec),
          do: {:unpinned_npx_y_cli, spec}

    (list_hits ++ cli_hits)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `"npx", "-y", "pkg"` contains the substring `npx", "-y"` not `npx -y`.
  # Still skip any accidental overlap with quoted list text.
  defp list_form_match?(whole), do: String.contains?(whole, "\",")

  defp unwrap_cli_token(token) do
    trimmed = token |> String.trim_leading("\"'") |> String.trim_trailing("\"',")

    cond do
      trimmed == "" -> nil
      String.starts_with?(trimmed, "-") -> nil
      true -> trimmed
    end
  end

  defp exact_npm_version?(spec) when is_binary(spec) do
    case Regex.run(~r/^(?:@[^\/]+\/)?[^@]+@(.+)$/, spec) do
      [_, version] -> version =~ ~r/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?$/
      nil -> false
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
end
