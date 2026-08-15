defmodule Arbor.Commands.PlatformInventory.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.PlatformInventory.{Core, Encode}
  alias Arbor.Commands.SourceCoupling.GitInventory

  @moduletag :fast
  describe "project/1 admission" do
    test "accepts closed atom and string bundle and file schemas" do
      atom_bundle = bundle([file("apps/arbor_shell/lib/a.ex")])
      assert {:ok, atom_report} = Core.project(atom_bundle)

      string_file = string_file(file("apps/arbor_shell/lib/a.ex"))
      string_bundle = atom_bundle |> string_bundle() |> Map.put("files", [string_file])
      assert {:ok, string_report} = Core.project(string_bundle)

      assert atom_report == string_report
      assert atom_report["status"] == "unreviewed"
    end

    test "rejects mixed, extra, missing, nil, struct, and obsolete provenance input" do
      base = bundle([file("apps/arbor_shell/lib/a.ex")])

      assert {:error, :invalid_bundle_keys} =
               Core.project(Map.put(base, :provenance_source, "test"))

      assert {:error, :invalid_bundle_keys} =
               Core.project(Map.delete(base, :selected_index_digest))

      assert {:error, :invalid_bundle_keys} = Core.project(Map.put(base, "files", base.files))
      assert {:error, :nil_bundle_value} = Core.project(Map.put(base, :head_tree_oid, nil))
      assert {:error, :invalid_bundle} = Core.project(Date.utc_today())

      row = hd(base.files)

      assert {:error, :invalid_file_keys} =
               Core.project(%{base | files: [Map.put(row, :extra, true)]})

      assert {:error, :invalid_file_keys} =
               Core.project(%{base | files: [Map.delete(row, :bytes)]})

      mixed = row |> Map.delete(:path) |> Map.put("path", row.path)
      assert {:error, :invalid_file_keys} = Core.project(%{base | files: [mixed]})
      assert {:error, :invalid_file} = Core.project(%{base | files: [Date.utc_today()]})
    end

    test "enforces one to 5000 rows, one MiB files, and 64 MiB total" do
      assert {:error, :empty_files} = Core.project(bundle([]))

      too_many = Enum.map(1..5001, &file("apps/arbor_shell/lib/f#{&1}.ex", ""))
      assert {:error, :too_many_files} = Core.project(bundle(too_many))

      oversized_bytes = String.duplicate("x", 1_048_577)

      assert {:error, {:file_too_large, _}} =
               Core.project(bundle([file("apps/arbor_shell/lib/large.ex", oversized_bytes)]))

      one_mebibyte = String.duplicate("x", 1_048_576)
      total_over_limit = Enum.map(1..65, &file("apps/arbor_shell/lib/f#{&1}.ex", one_mebibyte))
      assert {:error, :total_bytes_limit} = Core.project(bundle(total_over_limit))
    end

    test "aligns SHA-1 and SHA-256 OIDs with the selected object format" do
      sha1_bundle = bundle([file("apps/arbor_shell/lib/a.ex")])
      assert {:ok, _} = Core.project(sha1_bundle)

      sha256_bundle =
        bundle([file("apps/arbor_shell/lib/a.ex", "", "sha256")], object_format: "sha256")

      assert {:ok, _} = Core.project(sha256_bundle)

      assert {:error, {:oid_format_mismatch, :head_tree}} =
               Core.project(%{sha1_bundle | object_format: "sha256"})

      wrong_file_format = file("apps/arbor_shell/lib/a.ex", "", "sha256")

      assert {:error, {:oid_format_mismatch, "apps/arbor_shell/lib/a.ex"}} =
               Core.project(%{sha1_bundle | files: [wrong_file_format]})
    end

    test "requires the selected index digest and keeps its domain distinct from report digests" do
      source = file("apps/arbor_shell/lib/a.ex")
      valid = bundle([source])
      assert {:ok, report} = Core.project(valid)

      assert report["provenance"]["index_manifest_digest"] != valid.selected_index_digest

      assert {:error, :selected_index_digest_mismatch} =
               Core.project(%{valid | selected_index_digest: String.duplicate("0", 64)})

      assert {:error, :invalid_selected_index_digest} =
               Core.project(%{
                 valid
                 | selected_index_digest: String.upcase(valid.selected_index_digest)
               })
    end

    test "rejects content and declared-size mismatches before projection" do
      source = file("apps/arbor_shell/lib/a.ex", "defmodule Arbor.Shell.A, do: :broken\n")
      valid = bundle([source])

      wrong_oid = %{source | blob_oid: String.duplicate("c", 40)}

      assert {:error, {:oid_content_mismatch, "apps/arbor_shell/lib/a.ex"}} =
               Core.project(%{valid | files: [wrong_oid]})

      wrong_size = %{source | byte_size: source.byte_size + 1}

      assert {:error, {:invalid_byte_size, "apps/arbor_shell/lib/a.ex"}} =
               Core.project(%{valid | files: [wrong_size]})
    end

    test "rejects duplicate, traversal, oversized, and invalid UTF-8 paths" do
      first = file("apps/arbor_shell/lib/a.ex")
      second = file("apps/arbor_shell/lib/b.ex")
      valid = bundle([first, second])

      assert {:error, {:duplicate_paths, "apps/arbor_shell/lib/a.ex"}} =
               Core.project(%{valid | files: [first, %{second | path: first.path}]})

      traversal = %{first | path: "apps/arbor_shell/../arbor_shell/lib/a.ex"}
      assert {:error, {:invalid_path, _}} = Core.project(%{valid | files: [traversal, second]})

      oversized_path = %{first | path: String.duplicate("p", 4_097)}

      assert {:error, {:invalid_path, _}} =
               Core.project(%{valid | files: [oversized_path, second]})

      invalid_utf8_path = %{first | path: <<"apps/arbor_shell/lib/", 255, "/a.ex">>}
      assert {:error, :invalid_path} = Core.project(%{valid | files: [invalid_utf8_path, second]})
    end

    test "rejects unsupported modes, malformed OIDs, and nonbinary or nil row values" do
      source = file("apps/arbor_shell/lib/a.ex")
      valid = bundle([source])

      assert {:error, {:invalid_mode, "120000", _}} =
               Core.project(%{valid | files: [%{source | mode: "120000"}]})

      assert {:error, {:invalid_oid, _}} =
               Core.project(%{valid | files: [%{source | blob_oid: "not-an-oid"}]})

      assert {:error, :invalid_path} = Core.project(%{valid | files: [%{source | path: nil}]})

      assert {:error, {:invalid_oid, _}} =
               Core.project(%{valid | files: [%{source | blob_oid: nil}]})

      assert {:error, {:invalid_mode, nil, _}} =
               Core.project(%{valid | files: [%{source | mode: nil}]})

      assert {:error, {:invalid_byte_size, _}} =
               Core.project(%{valid | files: [%{source | byte_size: "0"}]})

      assert {:error, {:invalid_bytes, _}} =
               Core.project(%{valid | files: [%{source | bytes: nil}]})

      assert {:error, {:invalid_bytes, _}} =
               Core.project(%{valid | files: [%{source | bytes: :not_binary}]})
    end

    test "rejects invalid object format and malformed head-tree provenance" do
      valid = bundle([file("apps/arbor_shell/lib/a.ex")])

      assert {:error, :invalid_object_format} =
               Core.project(%{valid | object_format: "sha512"})

      assert {:error, :invalid_object_format} =
               Core.project(%{valid | object_format: :sha1})

      assert {:error, :invalid_head_tree_oid} =
               Core.project(%{valid | head_tree_oid: "not-an-oid"})

      assert {:error, :nil_bundle_value} =
               Core.project(%{valid | head_tree_oid: nil})
    end
  end

  describe "projection" do
    test "sorts reordered files and classifications deterministically" do
      first = file("apps/arbor_shell/lib/a.ex", "defmodule Arbor.Shell.A do\nend\n")
      second = file("apps/arbor_shell/lib/b.ex", "defmodule Arbor.Shell.B do\nend\n")
      classifications = [classification(first), classification(second)]

      assert {:ok, left} = Core.project(bundle([first, second], classifications: classifications))

      assert {:ok, right} =
               Core.project(
                 bundle([second, first], classifications: Enum.reverse(classifications))
               )

      assert left == right

      assert Enum.map(left["entries"], & &1["path"]) == [
               "apps/arbor_shell/lib/a.ex",
               "apps/arbor_shell/lib/b.ex"
             ]
    end

    test "reports exact missing, extra, and stale review failures and admitted-row counts" do
      first = file("apps/arbor_shell/lib/a.ex")
      second = file("apps/arbor_shell/lib/b.ex")
      stale = %{classification(first) | "blob_oid" => String.duplicate("c", 40)}
      extra = classification(file("apps/arbor_shell/lib/extra.ex"))

      assert {:ok, report} =
               Core.project(bundle([first, second], classifications: [extra, stale]))

      assert report["status"] == "mismatch"

      assert report["comparison"]["failures"] |> Enum.map(& &1["reason"]) == [
               "extra_review",
               "missing_review",
               "stale_blob"
             ]

      assert report["counts"]["total_files"] == 2
      assert report["counts"]["reviewed_files"] == 1
      assert report["counts"]["unreviewed_files"] == 1
      assert report["counts"]["by_class"]["trusted_host"] == 2
    end

    test "propagates Ast errors and validates the complete report" do
      malformed = file("apps/arbor_shell/lib/broken.ex", "defmodule Broken do\n  def oops(\n")

      assert {:error, {:parse_error, "apps/arbor_shell/lib/broken.ex", _}} =
               Core.project(bundle([malformed]))

      assert {:ok, report} = Core.project(bundle([file("apps/arbor_shell/lib/a.ex")]))
      assert :ok = Encode.validate_report(report)
      assert {:error, _} = Core.show(Map.delete(report, "provenance"), [])
    end
  end

  describe "show/2" do
    setup do
      {:ok, report: projected_report()}
    end

    test "accepts unique closed options and validates relabeled output", %{report: report} do
      assert {:ok, shown} = Core.show(report, mode: "check", output: "json")
      assert shown["mode"] == "check"
      assert shown["output"] == "json"
      assert :ok = Encode.validate_report(shown)
      assert {:ok, _} = Core.show(report, [])
    end

    test "rejects duplicate, unknown, malformed, and invalid options", %{report: report} do
      assert {:error, {:duplicate_option, :mode}} =
               Core.show(report, mode: "report", mode: "check")

      assert {:error, {:duplicate_option, :output}} =
               Core.show(report, output: "human", output: "json")

      assert {:error, {:unknown_option, :format}} = Core.show(report, format: "json")
      assert {:error, :invalid_options} = Core.show(report, [:mode])
      assert {:error, {:invalid_option, :output}} = Core.show(report, output: "yaml")
      assert {:error, {:invalid_option, :mode}} = Core.show(report, mode: "delete")
      assert {:error, {:invalid_option, :mode}} = Core.show(report, mode: :check)
      assert {:error, {:invalid_option, :output}} = Core.show(report, output: :json)
      assert {:error, :invalid_options} = Core.show(report, [{"mode", "check"}])
      assert {:error, :invalid_options} = Core.show(report, %{"mode" => "check"})
      assert {:error, _} = Core.show(%{"mode" => "report"}, [])
    end
  end

  defp projected_report do
    {:ok, report} = Core.project(bundle([file("apps/arbor_shell/lib/a.ex")]))
    report
  end

  defp bundle(files, opts \\ []) do
    object_format = Keyword.get(opts, :object_format, "sha1")
    classifications = Keyword.get(opts, :classifications, [])
    head_tree_oid = Keyword.get(opts, :head_tree_oid, oid_for_format(object_format, "d"))
    triples = Enum.map(files, &{&1.path, &1.mode, &1.blob_oid})
    {:ok, selected_index_digest} = GitInventory.selected_index_digest(triples)

    %{
      files: files,
      head_tree_oid: head_tree_oid,
      object_format: object_format,
      selected_index_digest: selected_index_digest
    }
    |> maybe_put_classifications(classifications, Keyword.has_key?(opts, :classifications))
  end

  defp maybe_put_classifications(bundle, classifications, true),
    do: Map.put(bundle, :classifications, classifications)

  defp maybe_put_classifications(bundle, _classifications, false), do: bundle

  defp string_bundle(bundle) do
    Map.new(bundle, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp string_file(file), do: Map.new(file, fn {key, value} -> {Atom.to_string(key), value} end)

  defp file(path, bytes \\ "", object_format \\ "sha1") do
    %{
      path: path,
      blob_oid: Core.git_blob_oid(bytes, object_format),
      mode: "100644",
      byte_size: byte_size(bytes),
      bytes: bytes
    }
  end

  defp classification(file) do
    %{
      "path" => file.path,
      "blob_oid" => file.blob_oid,
      "class" => "trusted_host",
      "rationale" => "reviewed"
    }
  end

  defp oid_for_format("sha1", char), do: String.duplicate(char, 40)
  defp oid_for_format("sha256", char), do: String.duplicate(char, 64)
end
