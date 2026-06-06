defmodule Arbor.Actions.CodeReviewTest do
  @moduledoc """
  Tests for `Arbor.Actions.CodeReview.ApplyChanges`. The action is used
  by the code-review-with-fixes pipeline to take an LLM-drafted JSON
  document of per-file changes and write them to disk inside a workdir.

  Path safety is the load-bearing property: the action MUST refuse
  absolute paths, parent-traversal (`..`), and any path that would
  resolve outside the workdir. The pipeline grants the action a
  `arbor://fs/write/<workdir>/**` capability — the action itself is
  the choke point that enforces the workdir bound.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions.CodeReview.ApplyChanges

  setup do
    tmp =
      System.tmp_dir!() |> Path.join("apply_changes_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, workdir: tmp}
  end

  describe "happy path" do
    test "writes a single relative-path file", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [%{file: "hello.txt", content: "world"}]
        })

      assert {:ok, result} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})

      assert result.files_written == 1
      assert [path] = result.paths
      assert File.read!(path) == "world"
    end

    test "creates intermediate directories", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [%{file: "deep/nested/dir/file.ex", content: "defmodule X do\nend"}]
        })

      assert {:ok, result} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})

      assert result.files_written == 1
      assert File.read!(hd(result.paths)) =~ "defmodule X"
    end

    test "writes multiple files in order", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [
            %{file: "a.txt", content: "first"},
            %{file: "b.txt", content: "second"},
            %{file: "c.txt", content: "third"}
          ]
        })

      assert {:ok, result} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})

      assert result.files_written == 3
      assert length(result.paths) == 3
    end

    test "empty changes list is a no-op", %{workdir: workdir} do
      json = Jason.encode!(%{changes: []})

      assert {:ok, %{files_written: 0, paths: []}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end
  end

  describe "path safety regressions" do
    # The action is the choke point that bounds writes to the workdir,
    # so each path-rejection case here is load-bearing. A regression
    # would expand the blast radius of an LLM mistake or a malicious
    # changes_json beyond what the surrounding capability grants.

    test "rejects absolute path", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [%{file: "/etc/passwd", content: "evil"}]
        })

      assert {:error, {:path_rejected, "/etc/passwd", _}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end

    test "rejects parent-directory traversal with ..", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [%{file: "../escape.txt", content: "out of bounds"}]
        })

      assert {:error, {:path_rejected, "../escape.txt", _}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end

    test "rejects multi-level traversal", %{workdir: workdir} do
      json =
        Jason.encode!(%{
          changes: [%{file: "ok/../../escape.txt", content: "deep escape"}]
        })

      assert {:error, {:path_rejected, _, _}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end

    test "halts on first rejection; earlier writes are NOT rolled back", %{workdir: workdir} do
      # This is documented behavior — the doctring says partial state
      # is acceptable because re-iteration overwrites. Lock the
      # current semantics in case someone tries to "fix" them.
      json =
        Jason.encode!(%{
          changes: [
            %{file: "first.txt", content: "written before halt"},
            %{file: "../escape.txt", content: "rejected here"},
            %{file: "third.txt", content: "never written"}
          ]
        })

      assert {:error, {:path_rejected, "../escape.txt", _}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})

      assert File.exists?(Path.join(workdir, "first.txt"))
      refute File.exists?(Path.join(workdir, "third.txt"))
    end
  end

  describe "schema errors" do
    test "rejects non-JSON changes_json", %{workdir: workdir} do
      assert {:error, {:invalid_changes_json, _}} =
               ApplyChanges.run(
                 %{changes_json: "not really json {{", workdir: workdir},
                 %{}
               )
    end

    test "rejects JSON missing changes field", %{workdir: workdir} do
      json = Jason.encode!(%{not_changes: []})

      assert {:error, :changes_field_missing_or_not_a_list} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end

    test "rejects change entry missing file field", %{workdir: workdir} do
      json = Jason.encode!(%{changes: [%{content: "no file key"}]})

      assert {:error, {:invalid_change_entry, _}} =
               ApplyChanges.run(%{changes_json: json, workdir: workdir}, %{})
    end

    test "rejects workdir that doesn't exist" do
      json = Jason.encode!(%{changes: [%{file: "x.txt", content: "x"}]})

      assert {:error, {:workdir_not_a_directory, "/nonexistent/path"}} =
               ApplyChanges.run(
                 %{changes_json: json, workdir: "/nonexistent/path"},
                 %{}
               )
    end
  end
end
