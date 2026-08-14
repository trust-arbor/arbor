defmodule Mix.Tasks.Arbor.Packaging.AppEnvInventoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Arbor.Commands.AppEnvInventory
  alias Arbor.Commands.AppEnvInventory.Core
  alias Mix.Tasks.Arbor.Packaging.AppEnvInventory, as: Task

  @moduletag :fast

  test "rejects unknown options" do
    assert {:error, {:arguments, :unknown_or_invalid_option}} =
             Task.execute(["--write-report"])
  end

  test "check mode reports residue and clean from injected inventory" do
    bytes = "Application.get_env(:arbor_common, :k)\n"

    residue = %{
      files: [file_entry("apps/foo/lib/a.ex", bytes)],
      tree_oid: String.duplicate("a", 40),
      object_format: "sha1"
    }

    assert {:ok, report} =
             AppEnvInventory.run_for_test(mode: "check", inventory: residue)

    assert report["status"] == "residue"
    assert report["mode"] == "check"
    assert report["counts"]["total"] == 1
    assert report["counts"]["by_class"]["production"] == 1

    empty = %{
      files: [],
      tree_oid: String.duplicate("a", 40),
      object_format: "sha1"
    }

    assert {:ok, clean} = AppEnvInventory.run_for_test(mode: "check", inventory: empty)
    assert clean["status"] == "clean"
    assert clean["counts"]["total"] == 0
  end

  test "report mode prints residue and exits successfully" do
    report = summary_report("report", "residue")
    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      output =
        capture_io(fn ->
          assert Task.finish_report(report, %{mode: "report", json: false}) == :ok
        end)

      assert output =~ "status=residue"
    after
      Mix.shell(old)
    end

    assert Task.exit_reason("report", "residue") == :ok
  end

  test "check mode exits nonzero only for residue" do
    residue = summary_report("check", "residue")
    clean = summary_report("check", "clean")
    old = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    try do
      capture_io(fn ->
        assert catch_exit(Task.finish_report(residue, %{mode: "check", json: false})) ==
                 {:shutdown, 1}
      end)

      capture_io(fn ->
        assert Task.finish_report(clean, %{mode: "check", json: false}) == :ok
      end)
    after
      Mix.shell(old)
    end

    assert Task.exit_reason("check", "residue") == {:shutdown, 1}
    assert Task.exit_reason("check", "clean") == :ok
  end

  test "hard parse error returns no report" do
    bytes = "defmodule Oops do\n"

    assert {:error, {:parse_error, "apps/foo/lib/bad.ex", _}} =
             AppEnvInventory.run_for_test(
               mode: "check",
               inventory: %{
                 files: [file_entry("apps/foo/lib/bad.ex", bytes)],
                 tree_oid: String.duplicate("a", 40),
                 object_format: "sha1"
               }
             )
  end

  test "production execute refuses runtime hooks" do
    assert {:error, {:production_task_forbids_runtime_hooks, _}} =
             Task.execute(["--json"], inventory: %{files: []})
  end

  defp file_entry(path, bytes) do
    %{
      path: path,
      blob_oid: Core.git_blob_oid(bytes, "sha1"),
      mode: "100644",
      bytes: bytes
    }
  end

  defp summary_report(mode, status) do
    %{
      "status" => status,
      "mode" => mode,
      "output" => "human",
      "counts" => %{
        "production" => if(status == "residue", do: 1, else: 0),
        "test_support" => 0,
        "config_block" => 0,
        "untrusted" => 0,
        "total" => if(status == "residue", do: 1, else: 0),
        "by_class" => %{"production" => 1, "test_support" => 0, "config_block" => 0},
        "by_trust" => %{"literal" => 1, "resolved" => 0, "untrusted" => 0},
        "by_owner" => %{
          "arbor_contracts" => 0,
          "arbor_common" => 1,
          "arbor_signals" => 0,
          "arbor_monitor" => 0,
          "unresolved" => 0
        }
      }
    }
  end
end
