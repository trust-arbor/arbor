defmodule Arbor.Commands.AppEnvInventory.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.AppEnvInventory
  alias Arbor.Commands.AppEnvInventory.Core
  alias Arbor.Commands.SourceCoupling.GitInventory

  @moduletag :fast

  test "legacy owner list is the closed four-app set" do
    assert Core.legacy_owners() == [
             :arbor_contracts,
             :arbor_common,
             :arbor_signals,
             :arbor_monitor
           ]
  end

  test "projects classified findings and clean status for empty inventory" do
    assert {:ok, clean} = Core.project(valid_bundle([]))

    assert clean["status"] == "clean"
    assert clean["counts"]["total"] == 0

    assert clean["counts"]["by_class"] == %{
             "production" => 0,
             "test_support" => 0,
             "config_block" => 0
           }

    assert clean["counts"]["by_trust"] == %{
             "literal" => 0,
             "resolved" => 0,
             "untrusted" => 0
           }

    assert clean["counts"]["by_owner"]["unresolved"] == 0
    refute Map.has_key?(clean, "errors")

    lib = "Application.get_env(:arbor_common, :k)\n"
    testf = "Application.put_env(:arbor_signals, :k, 1)\n"
    cfg = "import Config\nconfig :arbor_monitor, :k, 1\n"

    assert {:ok, residue} =
             Core.project(
               valid_bundle([
                 file_entry("apps/foo/lib/a.ex", lib),
                 file_entry("apps/foo/test/a_test.exs", testf),
                 file_entry("config/dev.exs", cfg)
               ])
             )

    assert residue["status"] == "residue"
    assert residue["counts"]["production"] == 1
    assert residue["counts"]["test_support"] == 1
    assert residue["counts"]["config_block"] == 1
    assert residue["counts"]["total"] == 3
    assert residue["counts"]["by_class"]["production"] == 1
    assert residue["counts"]["by_trust"]["literal"] == 3
    assert residue["counts"]["by_owner"]["arbor_common"] == 1
    assert residue["counts"]["by_owner"]["arbor_signals"] == 1
    assert residue["counts"]["by_owner"]["arbor_monitor"] == 1
  end

  test "omitted keys and defaulted empty input never produce a clean verdict" do
    assert {:error, {:missing_files, :files}} = Core.project(%{})

    assert {:error, {:missing_provenance, :tree_oid}} =
             Core.project(%{
               files: [],
               object_format: "sha1",
               provenance_source: "test_injection"
             })

    assert {:error, {:missing_provenance, :object_format}} =
             Core.project(%{
               files: [],
               tree_oid: String.duplicate("a", 40),
               provenance_source: "test_injection"
             })

    assert {:error, {:missing_provenance, :provenance_source}} =
             Core.project(%{
               files: [],
               tree_oid: String.duplicate("a", 40),
               object_format: "sha1"
             })

    assert {:error, {:missing_files, :files}} =
             Core.project(%{
               files: nil,
               tree_oid: String.duplicate("a", 40),
               object_format: "sha1",
               provenance_source: "test_injection"
             })
  end

  test "rejects malformed provenance, OID format, paths, modes, and sizes" do
    bytes = "Application.get_env(:arbor_common, :k)\n"
    good = file_entry("apps/foo/lib/a.ex", bytes)

    assert {:error, :invalid_object_format} =
             Core.project(%{valid_bundle([good]) | object_format: "sha3"})

    assert {:error, :invalid_provenance_source} =
             Core.project(%{valid_bundle([good]) | provenance_source: "unknown"})

    assert {:error, {:invalid_tree_oid, "ZZ"}} =
             Core.project(%{valid_bundle([good]) | tree_oid: "ZZ"})

    assert {:error, {:oid_format_mismatch, :tree}} =
             Core.project(%{valid_bundle([good]) | tree_oid: String.duplicate("a", 64)})

    assert {:error, {:invalid_oid, _}} =
             Core.project(valid_bundle([%{good | blob_oid: String.upcase(good.blob_oid)}]))

    sha256_oid = Core.git_blob_oid(bytes, "sha256")

    assert {:error, {:oid_format_mismatch, "apps/foo/lib/a.ex"}} =
             Core.project(valid_bundle([%{good | blob_oid: sha256_oid}]))

    assert {:error, {:invalid_path, "../escape.ex"}} =
             Core.project(valid_bundle([file_entry("../escape.ex", bytes)]))

    assert {:error, {:invalid_mode, "120000", "apps/foo/lib/a.ex"}} =
             Core.project(valid_bundle([file_entry("apps/foo/lib/a.ex", bytes, mode: "120000")]))

    assert {:error, {:invalid_byte_size, "apps/foo/lib/a.ex"}} =
             Core.project(
               valid_bundle([Map.put(file_entry("apps/foo/lib/a.ex", bytes), :byte_size, 1)])
             )

    assert {:error, {:duplicate_paths, "apps/foo/lib/a.ex"}} =
             Core.project(valid_bundle([good, file_entry("apps/foo/lib/a.ex", bytes)]))
  end

  test "rejects claimed blob OIDs that do not match git blob contents" do
    bytes = "Application.get_env(:arbor_common, :k)\n"
    good = file_entry("apps/foo/lib/a.ex", bytes)
    wrong = %{good | blob_oid: String.duplicate("b", 40)}

    assert {:error, {:oid_content_mismatch, "apps/foo/lib/a.ex"}} =
             Core.project(valid_bundle([wrong]))

    mutated = %{good | bytes: bytes <> " "}

    assert {:error, {:oid_content_mismatch, "apps/foo/lib/a.ex"}} =
             Core.project(valid_bundle([mutated]))
  end

  test "parse failure returns an error instead of a clean report" do
    bytes = "defmodule Oops do\n"

    assert {:error, {:parse_error, "apps/foo/lib/bad.ex", _}} =
             Core.project(valid_bundle([file_entry("apps/foo/lib/bad.ex", bytes)]))
  end

  test "load_elixir_index skips non-source modes and fails closed on source symlinks" do
    oid = String.duplicate("a", 40)

    skipped = """
    120000 #{oid} 0\tdocs/link
    160000 #{oid} 0\tdeps/some_gitlink
    100644 #{oid} 0\tmix.exs
    """

    run_git = fn _root, args, _stdin ->
      cond do
        args == ["rev-parse", "HEAD^{tree}"] ->
          {:ok, oid <> "\n"}

        args == ["ls-files", "-z", "--stage"] ->
          {:ok, nul_join(skipped)}

        args == ["cat-file", "--batch-check"] ->
          {:ok, "#{oid} blob 8\n"}

        args == ["cat-file", "--batch"] ->
          {:ok, "#{oid} blob 8\nxxxxxxxx\n"}

        true ->
          flunk("unexpected git args: #{inspect(args)}")
      end
    end

    assert {:ok, %{files: files}} =
             GitInventory.load_elixir_index("/tmp", run_git: run_git)

    assert Enum.map(files, & &1.path) == ["mix.exs"]
    assert Enum.all?(files, &(&1.mode in ["100644", "100755"]))
    assert Enum.all?(files, &(&1.byte_size == byte_size(&1.bytes)))

    source_symlink = "120000 #{oid} 0\tapps/foo/lib/x.ex\n"

    run_symlink = fn _root, args, _stdin ->
      cond do
        args == ["rev-parse", "HEAD^{tree}"] -> {:ok, oid <> "\n"}
        args == ["ls-files", "-z", "--stage"] -> {:ok, nul_join(source_symlink)}
        true -> flunk("git must not fetch blobs for a source symlink")
      end
    end

    assert {:error, {:symlink_blob, "apps/foo/lib/x.ex"}} =
             GitInventory.load_elixir_index("/tmp", run_git: run_symlink)
  end

  test "load_elixir_index includes tracked arbor_integrations Elixir sources" do
    mix_oid = String.duplicate("a", 40)
    integ_oid = String.duplicate("b", 40)

    staged = """
    100644 #{mix_oid} 0\tmix.exs
    100644 #{integ_oid} 0\tapps/arbor_integrations/lib/x.ex
    """

    run_git = fn _root, args, stdin ->
      cond do
        args == ["rev-parse", "HEAD^{tree}"] ->
          {:ok, mix_oid <> "\n"}

        args == ["ls-files", "-z", "--stage"] ->
          {:ok, nul_join(staged)}

        args == ["cat-file", "--batch-check"] ->
          {:ok, batch_check_output(stdin)}

        args == ["cat-file", "--batch"] ->
          {:ok, batch_payload_output(stdin)}

        true ->
          flunk("unexpected git args: #{inspect(args)}")
      end
    end

    assert {:ok, %{files: files}} =
             GitInventory.load_elixir_index("/tmp", run_git: run_git)

    assert Enum.map(files, & &1.path) == ["mix.exs", "apps/arbor_integrations/lib/x.ex"]
  end

  test "production run refuses synthetic inventory" do
    assert {:error, {:production_opts_forbid_synthetic, _}} =
             AppEnvInventory.run(inventory: %{files: []})
  end

  test "malformed file maps return a bounded error instead of raising" do
    assert {:error, :invalid_files} =
             Core.project(valid_bundle([%{foo: :bar}]))

    assert {:error, {:missing_provenance, :object_format}} =
             Core.project(%{
               files: [%{"path" => "apps/foo/lib/a.ex", "blob_oid" => String.duplicate("b", 40)}],
               tree_oid: String.duplicate("a", 40)
             })

    assert {:error, :invalid_files} =
             Core.project(
               valid_bundle([
                 %{"path" => "apps/foo/lib/a.ex", "blob_oid" => String.duplicate("b", 40)}
               ])
             )
  end

  test "invalid and duplicate digest triples return a bounded error" do
    alias Arbor.Commands.AppEnvInventory.Encode

    assert {:error, :invalid_manifest_pairs} = Encode.scan_manifest_digest([{1, "oid"}])
    assert {:error, :invalid_manifest_pairs} = Encode.scan_manifest_digest([{"p", "100644"}])
    assert {:error, :invalid_manifest_pairs} = Encode.scan_manifest_digest(:not_a_list)

    assert {:error, :invalid_manifest_pairs} =
             Encode.scan_manifest_digest([{"", "100644", "oid"}])

    assert {:error, :duplicate_manifest_pairs} =
             Encode.scan_manifest_digest([
               {"apps/foo/lib/a.ex", "100644", String.duplicate("a", 40)},
               {"apps/foo/lib/a.ex", "100755", String.duplicate("b", 40)}
             ])

    assert {:ok, digest} =
             Encode.scan_manifest_digest([
               {"apps/foo/lib/a.ex", "100644", String.duplicate("a", 40)}
             ])

    assert byte_size(digest) == 64
  end

  test "explicit root without arbor_kernel marker is rejected even if contracts exists" do
    tmp = Path.join(System.tmp_dir!(), "k2a-root-#{System.unique_integer([:positive])}")
    contracts = Path.join([tmp, "apps", "arbor_contracts"])
    File.mkdir_p!(contracts)
    File.write!(Path.join(contracts, "mix.exs"), "defmodule Fake.MixProject do\nend\n")

    try do
      assert {:error, :invalid_root_marker} = AppEnvInventory.run(root: tmp, mode: "report")
    after
      File.rm_rf!(tmp)
    end
  end

  defp valid_bundle(files, opts \\ []) do
    format = Keyword.get(opts, :format, "sha1")
    tree_len = if format == "sha256", do: 64, else: 40

    %{
      files: files,
      tree_oid: Keyword.get(opts, :tree_oid, String.duplicate("a", tree_len)),
      object_format: format,
      provenance_source: Keyword.get(opts, :provenance_source, "test_injection")
    }
  end

  defp file_entry(path, bytes, opts \\ []) do
    format = Keyword.get(opts, :format, "sha1")
    mode = Keyword.get(opts, :mode, "100644")
    oid = Keyword.get(opts, :oid, Core.git_blob_oid(bytes, format))

    %{path: path, blob_oid: oid, mode: mode, bytes: bytes}
  end

  defp nul_join(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.join("\0")
    |> Kernel.<>("\0")
  end

  defp batch_check_output(stdin) do
    stdin
    |> String.split("\n", trim: true)
    |> Enum.map_join("\n", fn oid -> "#{oid} blob 8" end)
    |> Kernel.<>("\n")
  end

  defp batch_payload_output(stdin) do
    stdin
    |> String.split("\n", trim: true)
    |> Enum.map_join("", fn oid -> "#{oid} blob 8\nxxxxxxxx\n" end)
  end
end
