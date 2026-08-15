defmodule Arbor.Commands.SourceCoupling.GitInventoryTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SourceCoupling.GitInventory

  @moduletag :fast

  describe "load_selected_blobs/3 provenance" do
    test "returns head_tree_oid as a field distinct from the index-selected blob set" do
      tree_oid = String.duplicate("a", 40)
      blob_oid = String.duplicate("b", 40)
      path = "apps/arbor_shell/lib/x.ex"

      assert {:ok, result} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, ["100644 #{blob_oid} 0\t#{path}"])
               )

      assert result.head_tree_oid == tree_oid
      refute Map.has_key?(result, :tree_oid)
      assert [%{path: ^path, blob_oid: ^blob_oid, mode: "100644"}] = result.files

      assert {:ok, digest} = GitInventory.selected_index_digest([{path, "100644", blob_oid}])
      assert result.selected_index_digest == digest
      refute result.selected_index_digest == result.head_tree_oid
    end

    test "index-selected bytes and digest stay bound to the staged set when HEAD^{tree} diverges" do
      head_tree_oid = String.duplicate("c", 40)
      staged_blob_oid = String.duplicate("d", 40)
      other_head = String.duplicate("e", 40)
      other_blob = String.duplicate("f", 40)
      path = "apps/arbor_trust/lib/y.ex"
      staged = ["100644 #{staged_blob_oid} 0\t#{path}"]

      assert {:ok, result} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_trust"],
                 run_git: stub_git(head_tree_oid, staged)
               )

      assert result.head_tree_oid == head_tree_oid
      assert [%{blob_oid: ^staged_blob_oid}] = result.files
      refute result.head_tree_oid == staged_blob_oid

      assert {:ok, same_index_other_head} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_trust"],
                 run_git: stub_git(other_head, staged)
               )

      assert same_index_other_head.selected_index_digest == result.selected_index_digest
      refute same_index_other_head.head_tree_oid == result.head_tree_oid

      assert {:ok, different_index} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_trust"],
                 run_git: stub_git(head_tree_oid, ["100644 #{other_blob} 0\t#{path}"])
               )

      refute different_index.selected_index_digest == result.selected_index_digest
      assert different_index.head_tree_oid == result.head_tree_oid
    end

    test "drops apps/arbor_integrations and unselected apps" do
      tree_oid = String.duplicate("a", 40)
      shell_oid = String.duplicate("1", 40)
      integ_oid = String.duplicate("2", 40)
      other_oid = String.duplicate("3", 40)

      staged = [
        "100644 #{shell_oid} 0\tapps/arbor_shell/lib/x.ex",
        "100644 #{integ_oid} 0\tapps/arbor_integrations/lib/y.ex",
        "100644 #{other_oid} 0\tapps/arbor_dashboard/lib/z.ex"
      ]

      assert {:ok, result} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, staged)
               )

      assert Enum.map(result.files, & &1.path) == ["apps/arbor_shell/lib/x.ex"]
    end

    test "selects only nested production .ex sources and binds only them in the digest" do
      tree_oid = String.duplicate("a", 40)
      source_oid = String.duplicate("1", 40)
      ignored_oid = String.duplicate("2", 40)
      source_path = "apps/arbor_shell/lib/arbor/shell/nested/source.ex"

      staged = [
        "100644 #{source_oid} 0\t#{source_path}",
        "120000 #{ignored_oid} 0\tapps/arbor_shell/.formatter.exs",
        "160000 #{ignored_oid} 0\tapps/arbor_shell/mix.exs",
        "100644 abc 3\tapps/arbor_shell/config/runtime.exs",
        "120000 #{ignored_oid} 0\tapps/arbor_shell/lib/arbor/shell/not_source.exs",
        "160000 #{ignored_oid} 0\tapps/arbor_shell/priv/generated/source.ex",
        "120000 #{ignored_oid} 0\tapps/arbor_shell/test/source_test.exs",
        "120000 #{ignored_oid} 0\tapps/arbor_dashboard/lib/unselected.ex",
        "120000 #{ignored_oid} 0\tapps/arbor_integrations/lib/private.ex"
      ]

      assert {:ok, result} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, staged)
               )

      assert Enum.map(result.files, & &1.path) == [source_path]

      assert {:ok, expected_digest} =
               GitInventory.selected_index_digest([{source_path, "100644", source_oid}])

      assert result.selected_index_digest == expected_digest
    end

    test "rejects invalid selected app identifiers without calling git" do
      run_git = fn _root, _args, _stdin -> flunk("git must not run for invalid selection") end

      assert {:error, :invalid_selected_apps} =
               GitInventory.load_selected_blobs("/tmp", ["../etc"], run_git: run_git)

      assert {:error, :invalid_selected_apps} =
               GitInventory.load_selected_blobs("/tmp", [], run_git: run_git)

      assert {:error, :invalid_selected_apps} =
               GitInventory.load_selected_blobs("/tmp", ["ArborShell"], run_git: run_git)

      assert {:error, :duplicate_selected_apps} =
               GitInventory.load_selected_blobs(
                 "/tmp",
                 ["arbor_shell", "arbor_shell"],
                 run_git: run_git
               )

      too_many = Enum.map(1..257, &"app_#{&1}")

      assert {:error, :selected_app_limit} =
               GitInventory.load_selected_blobs("/tmp", too_many, run_git: run_git)
    end

    test "derives SHA-256 object format from HEAD for an empty selected index set" do
      head_tree_oid = String.duplicate("a", 64)

      assert {:ok, result} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(head_tree_oid, [])
               )

      assert result.files == []
      assert result.object_format == "sha256"
      assert result.head_tree_oid == head_tree_oid
      assert {:ok, result.selected_index_digest} == GitInventory.selected_index_digest([])
    end

    test "rejects object-format mismatch between HEAD^{tree} and selected blobs" do
      head_tree_oid = String.duplicate("a", 64)
      blob_oid = String.duplicate("b", 40)

      assert {:error, {:oid_format_mismatch, :head_tree}} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git:
                   stub_git(head_tree_oid, [
                     "100644 #{blob_oid} 0\tapps/arbor_shell/lib/x.ex"
                   ])
               )
    end

    test "rejects a traversal path in a selected stage record" do
      tree_oid = String.duplicate("a", 40)
      blob_oid = String.duplicate("b", 40)

      assert {:error, {:invalid_path, :traversal}} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git:
                   stub_git(tree_oid, [
                     "100644 #{blob_oid} 0\tapps/arbor_shell/../arbor_shell/lib/x.ex"
                   ])
               )
    end

    test "fails closed for malformed selected production entries" do
      tree_oid = String.duplicate("a", 40)
      blob_oid = String.duplicate("b", 40)
      path = "apps/arbor_shell/lib/nested/source.ex"

      cases = [
        {"100644 abc 0\t#{path}", {:error, {:invalid_oid, "abc"}}},
        {"100644 #{blob_oid} 2\t#{path}", {:error, {:unsupported_selected_stage, path, 2}}},
        {"160000 #{blob_oid} 0\t#{path}", {:error, {:unsupported_selected_mode, "160000", path}}},
        {"120000 #{blob_oid} 0\t#{path}", {:error, {:unsupported_selected_mode, "120000", path}}}
      ]

      for {stage_line, expected} <- cases do
        assert ^expected =
                 GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                   run_git: stub_git(tree_oid, [stage_line])
                 )
      end

      oversized_path = "apps/arbor_shell/lib/" <> String.duplicate("x", 4_097) <> ".ex"

      assert {:error, {:invalid_path, :unbounded}} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, ["100644 #{blob_oid} 0\t#{oversized_path}"])
               )

      duplicate = "100644 #{blob_oid} 0\t#{path}"

      assert {:error, :index_conflict} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, [duplicate, duplicate])
               )

      assert {:error, {:blob_too_large, ^path, 8}} =
               GitInventory.load_selected_blobs("/tmp", ["arbor_shell"],
                 run_git: stub_git(tree_oid, [duplicate]),
                 max_blob_bytes: 7
               )
    end
  end

  describe "selected_index_digest/1" do
    test "is independent of triple order and repeats byte-identically" do
      t1 = {"apps/arbor_shell/lib/a.ex", "100644", String.duplicate("a", 40)}
      t2 = {"apps/arbor_shell/lib/b.ex", "100755", String.duplicate("b", 40)}

      assert {:ok, d1} = GitInventory.selected_index_digest([t1, t2])
      assert {:ok, d2} = GitInventory.selected_index_digest([t2, t1])
      assert {:ok, ^d1} = GitInventory.selected_index_digest([t1, t2])
      assert d1 == d2
      assert byte_size(d1) == 64
    end

    test "rejects malformed, traversal, oversized, and object-format-mismatched triples" do
      oid = String.duplicate("a", 40)
      sha256 = String.duplicate("b", 64)
      path = "apps/arbor_shell/lib/a.ex"

      assert {:error, :invalid_selected_index} = GitInventory.selected_index_digest(:not_a_list)

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([{1, "100644", oid}])

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([{path, "100644"}])

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([{path, "120000", oid}])

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([{path, "100644", "NOT-AN-OID"}])

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([{"apps/../etc/passwd", "100644", oid}])

      assert {:error, :invalid_selected_index} =
               GitInventory.selected_index_digest([
                 {String.duplicate("a", 5000), "100644", oid}
               ])

      assert {:error, :mixed_object_format} =
               GitInventory.selected_index_digest([
                 {path, "100644", oid},
                 {"apps/arbor_shell/lib/b.ex", "100644", sha256}
               ])

      assert {:error, :duplicate_selected_paths} =
               GitInventory.selected_index_digest([{path, "100644", oid}, {path, "100755", oid}])
    end

    test "rejects non-production and integrations paths" do
      oid = String.duplicate("a", 40)

      for path <- [
            "apps/arbor_shell/.formatter.exs",
            "apps/arbor_shell/mix.exs",
            "apps/arbor_shell/config/runtime.exs",
            "apps/arbor_shell/lib/source.exs",
            "apps/arbor_shell/priv/source.ex",
            "apps/arbor_shell/test/source.ex",
            "apps/arbor_integrations/lib/source.ex"
          ] do
        assert {:error, :invalid_selected_index} =
                 GitInventory.selected_index_digest([{path, "100644", oid}])
      end
    end
  end

  defp stub_git(tree_oid, staged_lines) do
    fn _root, args, stdin ->
      cond do
        args == ["rev-parse", "HEAD^{tree}"] ->
          {:ok, tree_oid <> "\n"}

        args == ["ls-files", "-z", "--stage"] ->
          {:ok, nul_join(staged_lines)}

        args == ["cat-file", "--batch-check"] ->
          {:ok, batch_check_output(stdin)}

        args == ["cat-file", "--batch"] ->
          {:ok, batch_payload_output(stdin)}

        true ->
          flunk("unexpected git args: #{inspect(args)}")
      end
    end
  end

  defp nul_join(lines) when is_list(lines) do
    Enum.join(lines, "\0") <> "\0"
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
